#!/usr/bin/env bash
# =============================================================================
# ocp-vm-migration-diag.sh - DLACZEGO MIGRACJE VM (OpenShift Virtualization)
#                            STOJA W PENDING / NIE KONCZA SIE?
#
# Migracja na zywo to obiekt VirtualMachineInstanceMigration (VMIM). Fazy:
#   Pending -> Scheduling -> Scheduled -> PreparingTarget -> TargetReady -> Running
#   -> Succeeded / Failed.
# Pending = virt-controller nie utworzyl jeszcze poda docelowego (virt-launcher):
#   - kolejka: limity parallelMigrationsPerCluster / parallelOutboundMigrationsPerNode
#     (sloty zajmuja tez migracje, ktorych pod docelowy nie miesci sie na zadnym nodzie),
#   - utworzenie poda odrzucone (ResourceQuota, LimitRange, webhook),
#   - VMI nie da sie migrowac (warunek LiveMigratable=False),
#   - inna migracja tej samej VMI jest w toku.
# Scheduling = pod docelowy istnieje, ale scheduler nie znalazl dla niego noda:
#   - brak pamieci/CPU (z narzutem virt-launchera), nodeSelector/affinity (model CPU!),
#     tainty, nody z kubevirt.io/schedulable=false (virt-handler niegotowy).
# Dalsze fazy = problem z startem poda docelowego, siecia migracyjna albo virt-handlerem.
#
# Running bez konca / Failed = VM zmienia pamiec szybciej, niz siec ja przesyla (timeout),
#   pod docelowy padl, siec migracyjna, przerwanie (anulowanie, drain).
#
# Skrypt dla kazdej oczekujacej migracji ustala PRZYCZYNE i DOWOD; dla trwajacych sprawdza,
# czy sie zbiegaja (pozostala pamiec vs tempo zmian pamieci i przesylu); dla nieudanych
# grupuje powody wg przyczyny, noda i VM; sprawdza siec migracyjna, cechy VM blokujace
# migracje (GPU, PCI, SR-IOV, dyski RWO, host-passthrough...), wolne miejsce na nodach,
# blokady drainu (PDB, MCP), kwoty, historie z Prometheusa, logi virt-controller /
# virt-handler i na koncu PODSUMOWANIE z dzialaniami.
#
# TYLKO ODCZYT: oc get / oc whoami / oc logs + HTTP GET do Prometheusa (thanos-querier).
# Niczego nie zmienia (nie anuluje migracji, nie zmienia konfiguracji).
# Wymagania: oc, jq (>=1.6), curl, column, awk. Uprawnienia: cluster-reader
# (z odczytem obiektow kubevirt.io) + cluster-monitoring-view.
# =============================================================================
set -uo pipefail
export LC_ALL=C

CNV_NS=openshift-cnv; SCOPE_NS=""; HDAYS=7; LOGS=1; LOGH=1; TOPN=40
CURL_K=""; OC_K=()

usage() { cat <<EOF
Uzycie: $0 [opcje]
  -n NAMESPACE  analizuj tylko VM / migracje w tym namespace (domyslnie: wszystkie)
  -c NAMESPACE  namespace OpenShift Virtualization            (domyslnie: $CNV_NS)
  -D DNI        historia migracji z Prometheusa                (domyslnie: $HDAYS)
  -H GODZINY    z ilu ostatnich godzin czytac logi virt-*      (domyslnie: $LOGH)
  -L            bez logow virt-controller / virt-handler
  -t N          ile wierszy w tabelach szczegolowych           (domyslnie: $TOPN)
  -k, --insecure
                nie weryfikuj certyfikatow TLS (oc + thanos-querier)
Przyklady: $0 -k | tee migracje-\$(date +%F_%H%M).txt
           $0 -k -n moje-vm -H 3
EOF
exit "${1:-0}"; }

args=()
for a in "$@"; do case $a in
  --insecure|--insecure-skip-tls-verify|--insecure-skip-tls-verify=true) args+=(-k);;
  --help) args+=(-h);;
  *) args+=("$a");;
esac; done
set -- "${args[@]+"${args[@]}"}"
while getopts "n:c:D:H:Lt:kh" o; do case $o in
  n) SCOPE_NS=$OPTARG;; c) CNV_NS=$OPTARG;; D) HDAYS=$OPTARG;; H) LOGH=$OPTARG;; L) LOGS=0;; t) TOPN=$OPTARG;;
  k) CURL_K="-k"; OC_K=(--insecure-skip-tls-verify=true);; h) usage 0;; *) usage 1;;
esac; done

die()  { echo "BLAD: $*" >&2; exit 1; }
warn() { echo "UWAGA: $*" >&2; }
LINE=$(printf '=%.0s' {1..100})
hdr()  { printf '\n%s\n== %s\n%s\n' "$LINE" "$1" "$LINE"; }
sub()  { printf '\n--- %s\n' "$1"; }
say()  { fold -s -w 96 <<<"$*" | sed 's/^/  | /'; }
table() { local rows; rows=$(cat)
  if [[ $(wc -l <<<"$rows") -le 1 ]]; then echo "  (brak danych)"; else column -t -s $'\t' <<<"$rows" | sed 's/^/  /'; fi; }

# Jedyna droga do klastra: get / whoami / logs.
oc_ro() { case "${1:-}" in
  get|whoami|logs) command oc "${OC_K[@]+"${OC_K[@]}"}" "$@";;
  *) die "oc_ro: zablokowano 'oc $1' (skrypt jest tylko do odczytu)";; esac; }

for c in oc jq curl column awk; do command -v "$c" >/dev/null || die "brak polecenia: $c"; done
[[ $HDAYS =~ ^[0-9]+$ ]] && (( HDAYS > 0 )) || die "-D: podaj liczbe dni"
[[ $LOGH =~ ^[0-9]+$ ]] && (( LOGH > 0 )) || die "-H: podaj liczbe godzin"
[[ $TOPN =~ ^[0-9]+$ ]] || die "-t: podaj liczbe"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: >"$TMP/findings"
# finding PRIORYTET(1=krytyczne,2=wazne,3=info) TEKST
finding() { printf '%s\t%s\n' "$1" "$2" >>"$TMP/findings"; }
ge() { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }

if ! oc_ro whoami >/dev/null 2>"$TMP/err"; then
  grep -qiE 'x509|certificate|tls' "$TMP/err" && [[ -z $CURL_K ]] && die "blad certyfikatu TLS - uruchom ponownie z -k"
  die "brak sesji oc ($(head -c 200 "$TMP/err"))"
fi
TOKEN=${TOKEN:-$(oc_ro whoami -t 2>/dev/null || true)}
THANOS=$(oc_ro get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || true)
PROM_OK=1
[[ -n $TOKEN && -n $THANOS ]] || { warn "brak tokenu lub route thanos-querier - sekcje z Prometheusa beda puste"; PROM_OK=0; }

EMPTY='{"status":"success","data":{"result":[]}}'
prom() { # $1=query|query_range $2=plik  reszta: parametry
  local ep=$1 out=$2; shift 2; local a=() p
  (( PROM_OK )) || { echo "$EMPTY" >"$out"; return 1; }
  for p in "$@"; do a+=(--data-urlencode "$p"); done
  # shellcheck disable=SC2086
  if ! curl -sS $CURL_K --max-time 120 -G -H "Authorization: Bearer $TOKEN" "${a[@]}" \
        "https://$THANOS/api/v1/$ep" >"$out" 2>"$TMP/err"; then
    warn "curl: $(cat "$TMP/err")"; echo "$EMPTY" >"$out"; return 1; fi
  jq -e '.status=="success"' "$out" >/dev/null 2>&1 || { warn "zapytanie odrzucone: $(head -c 300 "$out")"; echo "$EMPTY" >"$out"; return 1; }
}
fdate() { date -d "@$1" '+%F %H:%M' 2>/dev/null || date -r "$1" '+%F %H:%M'; }
getj() { # $1=plik, reszta: argumenty 'oc get' ; przy bledzie pusta lista
  local out=$1; shift
  oc_ro get "$@" -o json >"$out" 2>"$TMP/err.get" || { echo '{"items":[]}' >"$out"; return 1; }
}
if [[ -n $SCOPE_NS ]]; then SC=(-n "$SCOPE_NS"); else SC=(-A); fi

JQDEF='
  def ts: if . == null or . == "" then null else (sub("\\.[0-9]+"; "") | fromdateiso8601) end;
  def mem: if . == null then 0 else tostring |
      if test("Ki$") then (.[:-2]|tonumber)*1024 elif test("Mi$") then (.[:-2]|tonumber)*1048576
      elif test("Gi$") then (.[:-2]|tonumber)*1073741824 elif test("Ti$") then (.[:-2]|tonumber)*1099511627776
      elif test("k$") then (.[:-1]|tonumber)*1000 elif test("M$") then (.[:-1]|tonumber)*1000000
      elif test("G$") then (.[:-1]|tonumber)*1000000000 elif test("m$") then (.[:-1]|tonumber)/1000 else tonumber end end;
  def cpu: if . == null then 0 else tostring | if test("m$") then (.[:-1]|tonumber)/1000 else tonumber end end;
  def gi: (. / 1073741824 * 10 | round) / 10;
  def age: if . == null then "-" elif . >= 86400 then "\(. / 86400 | floor)d\(. % 86400 / 3600 | floor)h"
           elif . >= 3600 then "\(. / 3600 | floor)h\(. % 3600 / 60 | floor)m" else "\(. / 60 | floor)m" end;
  def podreq(f): [(.spec.containers // [])[] | .resources.requests[f] // null] ;
  def podmem: ([(.spec.containers // [])[] | .resources.requests.memory | mem] | add // 0);
  def podcpu: ([(.spec.containers // [])[] | .resources.requests.cpu | cpu] | add // 0);
  def active: . == "Scheduling" or . == "Scheduled" or . == "PreparingTarget" or . == "TargetReady" or . == "Running";
  def pending: . == null or . == "" or . == "Pending";
  def origin: if test("^kubevirt-evacuation-") then "drain/ewakuacja" elif test("^kubevirt-workload-update-") then "aktualizacja CNV"
              else "reczna/inna" end;'

NOW=$(date +%s)
echo "$LINE"
echo "DIAGNOSTYKA MIGRACJI VM - OpenShift Virtualization  (tylko odczyt)"
echo "Klaster : $(oc_ro whoami --show-server)   uzytkownik: $(oc_ro whoami)"
echo "Czas    : $(date '+%F %T %Z')   zakres: ${SCOPE_NS:-wszystkie namespace}"
cat <<'EOF'

Jak czytac: sekcja 1 - konfiguracja i stan platformy (limity kolejki, virt-handler, siec
migracyjna, MCP), sekcja 2 - ile migracji i w jakich fazach, sekcja 3 - PRZYCZYNA dla kazdej
oczekujacej migracji, sekcja 4 - czy trwajace migracje zdaza sie skonczyc, sekcja 5 - dlaczego
migracje koncza sie bledem i jak dlugo trwaja udane, sekcje 6-9 - dowody (miejsce na nodach,
blokady i cechy VM, historia, logi). Wnioski i dzialania: PODSUMOWANIE na koncu.
EOF

# =============================================================================
# Zbieranie danych
# =============================================================================
getj "$TMP/hco.json"   hyperconverged -n "$CNV_NS"
getj "$TMP/kv.json"    kubevirt -n "$CNV_NS"
getj "$TMP/csv.json"   csv -n "$CNV_NS"
getj "$TMP/mp.json"    migrationpolicies.migrations.kubevirt.io
getj "$TMP/vmim.json"  virtualmachineinstancemigrations.kubevirt.io "${SC[@]}" || warn "nie mozna odczytac VMIM ($(head -c 200 "$TMP/err.get"))"
# limity kolejki sa globalne - aktywne migracje liczone zawsze w calym klastrze
if [[ -n $SCOPE_NS ]]; then getj "$TMP/vmimall.json" virtualmachineinstancemigrations.kubevirt.io -A || cp "$TMP/vmim.json" "$TMP/vmimall.json"
else cp "$TMP/vmim.json" "$TMP/vmimall.json"; fi
getj "$TMP/vmi.json"   virtualmachineinstances.kubevirt.io "${SC[@]}"           || warn "nie mozna odczytac VMI ($(head -c 200 "$TMP/err.get"))"
getj "$TMP/vm.json"    virtualmachines.kubevirt.io "${SC[@]}"
getj "$TMP/launch.json" pods "${SC[@]}" -l kubevirt.io=virt-launcher
getj "$TMP/nodes.json" nodes
getj "$TMP/mcp.json"   machineconfigpools
getj "$TMP/handler.json" pods -n "$CNV_NS" -l kubevirt.io=virt-handler
getj "$TMP/pdb.json"   pdb "${SC[@]}"
getj "$TMP/quota.json" resourcequota "${SC[@]}"
getj "$TMP/pvcall.json" pvc "${SC[@]}"
# eventy: migracje, VMI, problemy z podami (tylko istotne rodzaje - eventy calego klastra bywaja ogromne)
{ getj "$TMP/ev1.json" events "${SC[@]}" --field-selector involvedObject.kind=VirtualMachineInstanceMigration
  getj "$TMP/ev2.json" events "${SC[@]}" --field-selector involvedObject.kind=VirtualMachineInstance
  getj "$TMP/ev3.json" events "${SC[@]}" --field-selector reason=FailedScheduling
  getj "$TMP/ev4.json" events "${SC[@]}" --field-selector reason=FailedCreate
  getj "$TMP/ev5.json" events "${SC[@]}" --field-selector reason=FailedMount
} 2>/dev/null
jq -s '{items: (map(.items) | add | unique_by(.metadata.uid // (.metadata.namespace + .metadata.name)))}' \
  "$TMP"/ev[1-5].json >"$TMP/ev.json"

NVMIM=$(jq '.items | length' "$TMP/vmim.json"); NVMI=$(jq '.items | length' "$TMP/vmi.json")

# PVC i DataVolume w namespace z niezakonczonymi migracjami (gotowosc wolumenow)
: >"$TMP/pvcu.jsonl"; : >"$TMP/dvu.jsonl"; VOLOK=true
for ns in $(jq -r '[.items[] | select((.status.phase // "") | test("^(Succeeded|Failed)$") | not) | .metadata.namespace] | unique[]' "$TMP/vmim.json"); do
  oc_ro get pvc -n "$ns" -o json 2>/dev/null | jq -c '.items[]' >>"$TMP/pvcu.jsonl" || VOLOK=false
  oc_ro get datavolumes.cdi.kubevirt.io -n "$ns" -o json 2>/dev/null | jq -c '.items[]' >>"$TMP/dvu.jsonl" || VOLOK=false
done
jq -s 'map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries' "$TMP/pvcu.jsonl" >"$TMP/pvcu.json"
jq -s 'map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries' "$TMP/dvu.jsonl" >"$TMP/dvu.json"

# requesty na nodach (Prometheus) - do liczenia wolnego miejsca
REQ_ACT='(max by (namespace, pod) (kube_pod_status_phase{phase=~"Pending|Running"}) == 1)'
prom query "$TMP/rqm.json" "query=sum by (node) (kube_pod_container_resource_requests{resource=\"memory\",node!=\"\"} * on (namespace, pod) group_left() $REQ_ACT)" || true
prom query "$TMP/rqc.json" "query=sum by (node) (kube_pod_container_resource_requests{resource=\"cpu\",node!=\"\"} * on (namespace, pod) group_left() $REQ_ACT)" || true
# wolne miejsce per node: {node: {am, ac, rm, rc, fm, fc, ok}}
jq -n --slurpfile n "$TMP/nodes.json" --slurpfile m "$TMP/rqm.json" --slurpfile c "$TMP/rqc.json" "$JQDEF"'
  ([$m[0].data.result[] | {(.metric.node): (.value[1] | tonumber)}] | add // {}) as $rm
  | ([$c[0].data.result[] | {(.metric.node): (.value[1] | tonumber)}] | add // {}) as $rc
  | ($rm | length > 0) as $have
  | [$n[0].items[] | .metadata.name as $nn
     | (.status.allocatable.memory | mem) as $am | (.status.allocatable.cpu | cpu) as $ac
     | {key: $nn, value: {am: $am, ac: $ac, rm: ($rm[$nn] // 0), rc: ($rc[$nn] // 0),
         fm: (if $have then $am - ($rm[$nn] // 0) else null end), fc: (if $have then $ac - ($rc[$nn] // 0) else null end),
         ready: ([.status.conditions[]? | select(.type == "Ready") | .status][0] == "True"),
         cordon: (.spec.unschedulable == true),
         kvs: ((.metadata.labels // {})["kubevirt.io/schedulable"] // "-")}}] | from_entries' >"$TMP/free.json"
FREE_OK=$(jq '[.[] | select(.fm != null)] | length > 0' "$TMP/free.json")

# Efektywne limity migracji (KubeVirt CR; HCO je tam przepisuje). Wartosci domyslne KubeVirt, gdy brak.
read -r LIM_CL LIM_PN LIM_BW LIM_CT LIM_PT LIM_UNS LIM_CATCH < <(jq -r '(.items[0].spec.configuration.migrations // {}) as $m
  | "\($m.parallelMigrationsPerCluster // 5) \($m.parallelOutboundMigrationsPerNode // 2) \($m.bandwidthPerMigration // "bez-limitu") \($m.completionTimeoutPerGiB // "domyslny") \($m.progressTimeout // "domyslny") \($m.unschedulablePendingTimeoutSeconds // "domyslny") \($m.catchAllPendingTimeoutSeconds // "domyslny")"' "$TMP/kv.json")
LIM_SRC=$(jq -r 'if (.items[0].spec.configuration.migrations.parallelMigrationsPerCluster // null) == null then "wartosci domyslne KubeVirt (brak w KubeVirt CR)" else "KubeVirt CR" end' "$TMP/kv.json")

# =============================================================================
# 1. PLATFORMA
# =============================================================================
hdr "1. OPENSHIFT VIRTUALIZATION - KONFIGURACJA I STAN"
jq -r '.items[] | select(.metadata.name | test("kubevirt-hyperconverged")) | "  Operator: \(.metadata.name)   faza: \(.status.phase // "-")"' "$TMP/csv.json"
jq -r '.items[0] // empty | "  HyperConverged: " + ([.status.conditions[]? | "\(.type)=\(.status)"] | join("  "))' "$TMP/hco.json"
jq -r '.items[0] // empty | "  KubeVirt: faza \(.status.phase // "-"), " + ([.status.conditions[]? | select(.type == "Degraded" or .type == "Available" or .type == "Progressing") | "\(.type)=\(.status)"] | join("  "))' "$TMP/kv.json"
[[ $(jq '.items | length' "$TMP/hco.json") == 0 ]] && warn "nie znaleziono HyperConverged w $CNV_NS (inny namespace? opcja -c)"

sub "Limity i ustawienia migracji ($LIM_SRC)"
{ printf 'USTAWIENIE\tWARTOSC\tZNACZENIE\n'
  printf 'parallelMigrationsPerCluster\t%s\tmaks. migracji jednoczesnie w calym klastrze (reszta czeka w Pending)\n' "$LIM_CL"
  printf 'parallelOutboundMigrationsPerNode\t%s\tmaks. migracji wychodzacych z jednego noda\n' "$LIM_PN"
  printf 'bandwidthPerMigration\t%s\tlimit przepustowosci jednej migracji\n' "$LIM_BW"
  printf 'completionTimeoutPerGiB\t%s\tczas na GiB pamieci, po ktorym migracja jest przerywana\n' "$LIM_CT"
  printf 'progressTimeout\t%s\tprzerwanie, gdy brak postepu kopiowania pamieci\n' "$LIM_PT"
  printf 'unschedulablePendingTimeoutSeconds\t%s\tpo tylu s pod docelowy, ktory sie nie miesci, jest usuwany (migracja Failed)\n' "$LIM_UNS"
  printf 'catchAllPendingTimeoutSeconds\t%s\tto samo dla poda docelowego czekajacego z innego powodu\n' "$LIM_CATCH"
  jq -r '.items[0].spec.liveMigrationConfig // {} | to_entries[] | select(.key | test("^(network|allowAutoConverge|allowPostCopy)$")) | "HCO \(.key)\t\(.value | tostring)\t"' "$TMP/hco.json"
  jq -r '.items[0].spec.workloadUpdateStrategy // empty | "workloadUpdateMethods\t\(.workloadUpdateMethods // [] | join(","))\tco po aktualizacji CNV (LiveMigrate = masowe migracje)",
         "batchEvictionSize / Interval\t\(.batchEvictionSize // "-") / \(.batchEvictionInterval // "-")\tile VM naraz i co ile przy aktualizacji"' "$TMP/hco.json"
} | table
MIGNET=$(jq -r '.items[0].spec.liveMigrationConfig.network // empty' "$TMP/hco.json")
# adresy virt-handlera w sieci migracyjnej (adnotacja Multus network-status); null = brak adnotacji
MIGIPS='def migips($net; $ns): ((.metadata.annotations // {})["k8s.v1.cni.cncf.io/network-status"] // null) as $a
  | if $a == null then null else ($a | fromjson? // [])
    | [.[] | select(.name == "\($ns)/\($net)" or .name == $net or .interface == "migration0") | .ips[]?] end;'
NMIG_NOIP=0; NMA_MIG=0; NMA_POD=0; NMA_UNK=0
sub "Siec migracyjna"
if [[ -z $MIGNET ]]; then
  echo "  Brak dedykowanej sieci migracyjnej (HyperConverged spec.liveMigrationConfig.network). Pamiec VM jest"
  echo "  przesylana siecia podow i dzieli lacze z ruchem aplikacji - przy duzych VM lub VM mocno zmieniajacych"
  echo "  pamiec migracje moga sie nie zbiegac (sekcja 4) i konczyc timeoutem (sekcja 5)."
else
  if oc_ro get network-attachment-definitions.k8s.cni.cncf.io "$MIGNET" -n "$CNV_NS" -o json >"$TMP/nad.json" 2>/dev/null; then
    jq -r '(.spec.config // "{}" | fromjson? // {}) as $c | ($c.plugins[0]? // $c) as $p
      | "  Dedykowana siec migracyjna: \(.metadata.name) (NetworkAttachmentDefinition istnieje)",
        "    typ \($p.type // "-"), interfejs na nodzie \($p.master // $p.bridge // $p.device // "-"), MTU \($p.mtu // "domyslne interfejsu"),"
        + " IPAM \($p.ipam.type // "-")\(if ($p.ipam.range // "") != "" then ", pula /\($p.ipam.range | split("/")[1] // "?")" else "" end)"' "$TMP/nad.json"
  else
    echo "  Dedykowana siec migracyjna: $MIGNET - NIE ZNALEZIONO NetworkAttachmentDefinition w $CNV_NS!"
    finding 1 "HyperConverged wskazuje siec migracyjna '$MIGNET', ale nie ma takiej NetworkAttachmentDefinition w $CNV_NS - migracje nie moga zestawic polaczenia."
  fi
  { printf 'NODE\tVIRT_HANDLER\tADRES_W_SIECI_MIGRACYJNEJ\n'
    jq -r --arg net "$MIGNET" --arg ns "$CNV_NS" "$MIGIPS"'.items[] | migips($net; $ns) as $ip
      | [(.spec.nodeName // "-" | split(".")[0]), (.status.phase // "-"),
         (if $ip == null then "? (brak adnotacji network-status)" elif ($ip | length) > 0 then "tak" else "BRAK" end)] | @tsv' "$TMP/handler.json"
  } | table
  NMIG_NOIP=$(jq --arg net "$MIGNET" --arg ns "$CNV_NS" "$MIGIPS"'[.items[] | migips($net; $ns) | select(. != null and length == 0)] | length' "$TMP/handler.json")
  # ktora siecia poszly migracje: adres celu (migrationState.targetNodeAddress) vs adresy virt-handlera na nodzie docelowym
  read -r NMA_MIG NMA_POD NMA_UNK < <(jq -r --slurpfile h "$TMP/handler.json" --arg net "$MIGNET" --arg ns "$CNV_NS" "$MIGIPS"'
    ([$h[0].items[] | {key: (.spec.nodeName // "-"), value: {mig: (migips($net; $ns) // []),
        pod: ([.status.podIPs[]?.ip, .status.podIP] | map(select(. != null)))}}] | from_entries) as $hm
    | [.items[] | .status.migrationState // empty | select((.targetNodeAddress // "") != "")
       | (.targetNodeAddress | if test("^[0-9.]+:[0-9]+$") then sub(":[0-9]+$"; "") else . end) as $ip
       | $hm[.targetNode // ""] as $x
       | if $x == null then "u" elif ($x.mig | index($ip)) != null then "m" elif ($x.pod | index($ip)) != null then "p" else "u" end]
    | "\(map(select(. == "m")) | length) \(map(select(. == "p")) | length) \(map(select(. == "u")) | length)"' "$TMP/vmimall.json")
  if (( NMA_MIG + NMA_POD + NMA_UNK > 0 )); then
    echo "  Migracje widoczne w obiektach VMIM - adres celu: w sieci migracyjnej $NMA_MIG, w sieci podow $NMA_POD, nieustalony $NMA_UNK."
  fi
  (( NMIG_NOIP > 0 )) && finding 1 "$NMIG_NOIP podow virt-handler nie ma adresu w sieci migracyjnej '$MIGNET' (sekcja 1) - migracje z udzialem tych nodow nie zestawia polaczenia. Sprawdz NAD (interfejs na nodzie, IPAM/pula adresow) i eventy podow virt-handler."
  (( NMA_POD > 0 )) && finding 1 "Skonfigurowano siec migracyjna '$MIGNET', ale $NMA_POD migracji uzylo adresu z sieci podow (sekcja 1) - siec migracyjna nie dziala na czesci nodow albo virt-handler nie zostal zrestartowany po zmianie konfiguracji."
fi

sub "MigrationPolicy (nadpisuja limity dla wybranych VM)"
{ printf 'POLITYKA\tBANDWIDTH\tCOMPLETION/GiB\tAUTOCONVERGE\tPOSTCOPY\tSELEKTORY\n'
  jq -r '.items[] | [.metadata.name, (.spec.bandwidthPerMigration // "-"), (.spec.completionTimeoutPerGiB // "-" | tostring),
     (.spec.allowAutoConverge // "-" | tostring), (.spec.allowPostCopy // "-" | tostring),
     ((.spec.selectors // {}) | tostring | .[0:80])] | @tsv' "$TMP/mp.json"
} | table

sub "virt-handler (agent na kazdym nodzie z VM) i nody dla VM"
jq -r --slurpfile n "$TMP/nodes.json" '
  ([.items[] | select(.status.phase == "Running" and all(.status.containerStatuses[]?; .ready)) | .spec.nodeName]) as $ok
  | ([$n[0].items[] | select((.metadata.labels // {})["kubevirt.io/schedulable"] != null)]) as $kv
  | "  Nody z etykieta kubevirt.io/schedulable: \($kv | length)  (true: \([$kv[] | select(.metadata.labels["kubevirt.io/schedulable"] == "true")] | length), false: \([$kv[] | select(.metadata.labels["kubevirt.io/schedulable"] == "false")] | length))",
    "  Pody virt-handler gotowe: \($ok | length) z \(.items | length)",
    ($kv[] | select(.metadata.labels["kubevirt.io/schedulable"] == "false") | .metadata.name as $nn
      | "  ! \($nn | split(".")[0]): kubevirt.io/schedulable=false (VM nie trafia tu ani nie migruja tutaj)\(if ($ok | index($nn)) == null then " - virt-handler NIEGOTOWY" else "" end)")' \
  "$TMP/handler.json"
NKVF=$(jq '[.items[] | select((.metadata.labels // {})["kubevirt.io/schedulable"] == "false")] | length' "$TMP/nodes.json")
NHNR=$(jq '[.items[] | select(.status.phase != "Running" or any(.status.containerStatuses[]?; .ready | not))] | length' "$TMP/handler.json")
(( NHNR > 0 )) && finding 1 "$NHNR podow virt-handler nie jest gotowych - nody bez dzialajacego virt-handlera nie przyjmuja ani nie oddaja VM (sekcja 1). Sprawdz: oc get pods -n $CNV_NS -l kubevirt.io=virt-handler -o wide"
(( NKVF > 0 )) && finding 2 "$NKVF nodow ma kubevirt.io/schedulable=false - nie sa celem migracji (virt-handler niegotowy, brak heartbeatu albo node wylaczony dla VM)."

sub "Aktualizacje / drain nodow (MachineConfigPool)"
{ printf 'MCP\tNODY\tZAKTUALIZOWANE\tAKTUALIZOWANE_TERAZ\tZDEGRADOWANE\tUPDATING\n'
  jq -r '.items[] | [.metadata.name, (.status.machineCount // 0 | tostring), (.status.updatedMachineCount // 0 | tostring),
     ((.status.machineCount // 0) - (.status.updatedMachineCount // 0) | tostring), (.status.degradedMachineCount // 0 | tostring),
     ([.status.conditions[]? | select(.type == "Updating") | .status][0] // "-")] | @tsv' "$TMP/mcp.json"
} | table
{ printf 'NODE\tCORDON\tSTAN_MCO\tDRAIN\tVM_NA_NODZIE\n'
  jq -r --slurpfile v "$TMP/vmi.json" '.items[] | (.metadata.annotations // {}) as $a | .metadata.name as $nn
    | select(.spec.unschedulable == true or ($a["machineconfiguration.openshift.io/state"] // "Done") != "Done"
             or ($a["machineconfiguration.openshift.io/desiredDrain"] // "") != ($a["machineconfiguration.openshift.io/lastAppliedDrain"] // ""))
    | [($nn | split(".")[0]), (if .spec.unschedulable then "TAK" else "-" end), ($a["machineconfiguration.openshift.io/state"] // "-"),
       (if ($a["machineconfiguration.openshift.io/desiredDrain"] // "") != ($a["machineconfiguration.openshift.io/lastAppliedDrain"] // "")
        then "W TOKU (" + ($a["machineconfiguration.openshift.io/desiredDrain"] // "" | split("-")[0]) + ")" else "-" end),
       ([$v[0].items[] | select(.status.nodeName == $nn)] | length | tostring)] | @tsv' "$TMP/nodes.json"
} | table
NDRAIN=$(jq '[.items[] | (.metadata.annotations // {}) as $a | select(($a["machineconfiguration.openshift.io/desiredDrain"] // "") != ($a["machineconfiguration.openshift.io/lastAppliedDrain"] // "") and (($a["machineconfiguration.openshift.io/desiredDrain"] // "") | startswith("drain")))] | length' "$TMP/nodes.json")

# =============================================================================
# 2. INWENTARZ MIGRACJI
# =============================================================================
hdr "2. MIGRACJE - ILE I W JAKICH FAZACH"
if (( NVMIM == 0 )); then
  echo "  Brak obiektow VirtualMachineInstanceMigration${SCOPE_NS:+ w $SCOPE_NS}."
fi
sub "Migracje wg fazy i zrodla"
{ printf 'FAZA\tLICZBA\tdrain/ewakuacja\taktualizacja CNV\treczna/inna\tNAJSTARSZA\n'
  jq -r --argjson now "$NOW" "$JQDEF"'.items | map({ph: (.status.phase // "Pending" | if . == "" then "Pending" else . end), o: (.metadata.name | origin),
       a: ($now - (.metadata.creationTimestamp | ts))})
    | group_by(.ph)[] | [.[0].ph, (length | tostring),
       ([.[] | select(.o == "drain/ewakuacja")] | length | tostring), ([.[] | select(.o == "aktualizacja CNV")] | length | tostring),
       ([.[] | select(.o == "reczna/inna")] | length | tostring), (map(.a) | max | age)] | @tsv' "$TMP/vmim.json"
} | table
read -r NPEND NFAIL NSUCC < <(jq -r "$JQDEF"'[.items[] | .status.phase] as $p
  | "\([$p[] | select(pending)] | length) \([$p[] | select(. == "Failed")] | length) \([$p[] | select(. == "Succeeded")] | length)"' "$TMP/vmim.json")
NACT=$(jq "$JQDEF"'[.items[] | select(.status.phase | active)] | length' "$TMP/vmimall.json")
echo
echo "  Oczekujace (Pending): $NPEND   aktywne w calym klastrze (Scheduling..Running): $NACT / limit $LIM_CL   nieudane: $NFAIL   zakonczone: $NSUCC"

sub "Kolejka: aktywne migracje wychodzace z nodow (limit na node: $LIM_PN)"
jq -r --slurpfile v "$TMP/vmi.json" "$JQDEF"'
  ([$v[0].items[] | {key: "\(.metadata.namespace)/\(.metadata.name)", value: (.status.nodeName // "-")}] | from_entries) as $vn
  | [.items[] | {ph: .status.phase, src: (.status.migrationState.sourceNode // $vn["\(.metadata.namespace)/\(.spec.vmiName)"] // "-")}] as $m
  | ($m | map(select(.ph | active)) | group_by(.src) | map({key: .[0].src, value: length}) | from_entries) as $act
  | ($m | map(select(.ph | pending)) | group_by(.src) | map({key: .[0].src, value: length}) | from_entries) as $pen
  | (["NODE_ZRODLOWY", "AKTYWNE", "OCZEKUJACE"] | @tsv),
    ((($act | keys) + ($pen | keys)) | unique[] | [(split(".")[0]), ($act[.] // 0 | tostring), ($pen[.] // 0 | tostring)] | @tsv)' \
  "$TMP/vmim.json" | table

sub "VMI (dzialajace VM) - zdolnosc do migracji"
{ printf 'STAN\tLICZBA\n'
  jq -r '.items | ("Wszystkie VMI\t\(length)"),
     ("Faza inna niz Running\t\([.[] | select(.status.phase != "Running")] | length)"),
     ("LiveMigratable=False (nie da sie migrowac)\t\([.[] | select(any(.status.conditions[]?; .type == "LiveMigratable" and .status == "False"))] | length)"),
     ("Czekaja na ewakuacje z noda (evacuationNodeName)\t\([.[] | select(.status.evacuationNodeName != null)] | length)"),
     ("evictionStrategy=LiveMigrate\t\([.[] | select((.spec.evictionStrategy // "") == "LiveMigrate")] | length)"),
     ("Oczekuja na restart po zmianie (RestartRequired)\t\([.[] | select(any(.status.conditions[]?; .type == "RestartRequired" and .status == "True"))] | length)")' "$TMP/vmi.json"
} | table
{ printf 'POWOD_NIEMIGROWALNOSCI\tLICZBA\tPRZYKLADOWY_KOMUNIKAT\n'
  jq -r '[.items[] | .status.conditions[]? | select(.type == "LiveMigratable" and .status == "False")] | group_by(.reason)[]
    | [(.[0].reason // "-"), (length | tostring), (.[0].message // "" | gsub("[\n\t]"; " ") | .[0:110])] | @tsv' "$TMP/vmi.json"
} | table
NEVAC=$(jq '[.items[] | select(.status.evacuationNodeName != null)] | length' "$TMP/vmi.json")
NEVAC_NOMIG=$(jq --slurpfile m "$TMP/vmim.json" '[.items[] | select(.status.evacuationNodeName != null)
   | "\(.metadata.namespace)/\(.metadata.name)" as $k
   | select([$m[0].items[] | select(("\(.metadata.namespace)/\(.spec.vmiName)") == $k and ((.status.phase // "") | test("Succeeded|Failed") | not))] | length == 0)] | length' "$TMP/vmi.json")

# =============================================================================
# 3. PRZYCZYNA DLA KAZDEJ OCZEKUJACEJ MIGRACJI
# =============================================================================
hdr "3. DLACZEGO CZEKAJA - KLASYFIKACJA KAZDEJ NIEZAKONCZONEJ MIGRACJI"
{ printf '{"vmim":'; cat "$TMP/vmim.json"; printf ',"vmimall":'; cat "$TMP/vmimall.json"; printf ',"vmi":'; cat "$TMP/vmi.json"; printf ',"pods":'; cat "$TMP/launch.json"
  printf ',"ev":'; cat "$TMP/ev.json"; printf ',"nodes":'; cat "$TMP/nodes.json"; printf ',"free":'; cat "$TMP/free.json"
  printf ',"quota":'; cat "$TMP/quota.json"; printf ',"pvc":'; cat "$TMP/pvcu.json"; printf ',"dv":'; cat "$TMP/dvu.json"; printf '}'; } >"$TMP/all.json"

jq -c --argjson now "$NOW" --argjson lcl "$LIM_CL" --argjson lpn "$LIM_PN" --argjson freeok "$FREE_OK" --argjson volok "$VOLOK" "$JQDEF"'
  def tol($t): (.effect == null or .effect == "" or .effect == $t.effect) and
     (((.operator // "Equal") == "Exists" and (.key == null or .key == "" or .key == $t.key))
      or ((.operator // "Equal") == "Equal" and .key == $t.key and (.value // "") == ($t.value // "")));
  def taintok($tols): all((.spec.taints // [])[] | select(.effect == "NoSchedule" or .effect == "NoExecute"); . as $t | any($tols[]; tol($t)));
  def mexp($l): .key as $k | $l[$k] as $v |
     if .operator == "In" then ($v != null and any(.values[]; . == $v))
     elif .operator == "NotIn" then ($v == null or all(.values[]; . != $v))
     elif .operator == "Exists" then $v != null
     elif .operator == "DoesNotExist" then $v == null
     else true end;
  def selok($p): (.metadata.labels // {}) as $l
     | all(($p.spec.nodeSelector // {}) | to_entries[]; $l[.key] == .value)
       and (($p.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms // null) as $terms
            | $terms == null or any($terms[]; all((.matchExpressions // [])[]; mexp($l))));
  def evmsg($ev; $ns; $names): [$ev[] | .involvedObject.name as $on | select(.involvedObject.namespace == $ns and ($names | index($on)) != null)
       | {t: ((.lastTimestamp // .eventTime // .firstTimestamp // .metadata.creationTimestamp) | ts), type, reason, msg: ((.message // "") | gsub("[\n\t]"; " "))}]
     | sort_by(.t);
  . as $a | $a.ev.items as $ev | $a.free as $free
  | ($a.vmi.items | map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $vmis
  | ([$a.vmimall.items[] | select(.status.phase | active)] | length) as $nact
  | ([$a.vmimall.items[] | select(.status.phase | active)
      | (.status.migrationState.sourceNode // $vmis["\(.metadata.namespace)/\(.spec.vmiName)"].status.nodeName // "-")]
     | group_by(.) | map({key: .[0], value: length}) | from_entries) as $outb
  | ([$a.vmim.items[] | select((.status.phase // "") | test("^(Succeeded|Failed)$") | not) | "\(.metadata.namespace)/\(.spec.vmiName)"]
     | group_by(.) | map({key: .[0], value: length}) | from_entries) as $perVmi
  | $a.vmim.items[] | select((.status.phase // "") | test("^(Succeeded|Failed)$") | not)
  | . as $m | .metadata.namespace as $ns | .spec.vmiName as $vn | (.status.phase // "Pending" | if . == "" then "Pending" else . end) as $ph
  | $vmis["\($ns)/\($vn)"] as $vmi
  | ($vmi.status.nodeName // .status.migrationState.sourceNode // "-") as $src
  | ([$a.pods.items[] | select(.metadata.namespace == $ns and (.metadata.labels // {})["kubevirt.io/migrationJobUID"] == $m.metadata.uid)][0]) as $tp
  | ([$a.pods.items[] | select(.metadata.namespace == $ns and (.metadata.labels // {})["kubevirt.io/created-by"] == ($vmi.metadata.uid // "x")
        and .spec.nodeName == $src and .status.phase == "Running")][0]) as $sp
  | ($tp // $sp) as $tmpl
  | (if $tmpl then ($tmpl | podmem) else ($vmi.spec.domain.resources.requests.memory // $vmi.spec.domain.memory.guest | mem) end) as $rqm
  | (if $tmpl then ($tmpl | podcpu) else 0 end) as $rqc
  | ([$a.nodes.items[] | select(.metadata.name != $src and (.spec.unschedulable | not)
        and ([.status.conditions[]? | select(.type == "Ready") | .status][0] == "True")
        and (if $tmpl then (selok($tmpl) and taintok($tmpl.spec.tolerations // [])) else ((.metadata.labels // {})["kubevirt.io/schedulable"] == "true") end))
      | .metadata.name]) as $cand
  | ([$cand[] | select($free[.].fm != null and $free[.].fm >= $rqm and ($rqc == 0 or $free[.].fc >= $rqc))]) as $fit
  | ([$vmi.spec.volumes[]? | (.dataVolume.name // .persistentVolumeClaim.claimName // empty) as $c
       | $a.pvc["\($ns)/\($c)"] as $p | $a.dv["\($ns)/\($c)"] as $d
       | ([$p.metadata.ownerReferences[]? | select(.kind == "DataVolume")][0]) as $own
       | ($p.metadata.deletionTimestamp != null) as $term
       | if $p == null and $d == null then {t: false, x: "brak PVC i DataVolume \($c)"}
         elif $own != null and $a.dv["\($ns)/\($own.name)"] == null then
           {t: $term, x: "PVC \($c) ma wlasciciela DataVolume \($own.name), ktorego NIE MA\(if $term then "; PVC JEST USUWANY (Terminating)" else "" end)"}
         elif $own != null and ($a.dv["\($ns)/\($own.name)"].status.phase // "") != "Succeeded" then
           {t: $term, x: "DataVolume \($own.name) w fazie \($a.dv["\($ns)/\($own.name)"].status.phase // "-") (wymagana Succeeded)"}
         elif $term then {t: true, x: "PVC \($c) jest usuwany (Terminating)"}
         else empty end]) as $volp
  | ([$vmi.status.conditions[]? | select(.type == "LiveMigratable")][0]) as $lm
  | ([$tp.status.conditions[]? | select(.type == "PodScheduled" and .status == "False")][0].message // "") as $sched
  | (evmsg($ev; $ns; [$m.metadata.name, $vn] + (if $tp then [$tp.metadata.name] else [] end))) as $evs
  | ([$evs[] | select(.type == "Warning")] | last // null) as $lastw
  | ([$evs[] | select(.msg | test("quota|LimitRange|forbidden|denied the request|admission webhook"; "i"))] | last // null) as $adm
  | ([$evs[] | select(.msg | test("unable to find datavolume|determining if volume is ready|volume.*not ready"; "i"))] | last // null) as $vev
  | ([$evs[] | select(.reason == "FailedMount" or .reason == "FailedAttachVolume" or .reason == "FailedCreatePodSandBox")] | last // null) as $mnt
  | ($now - ($m.metadata.creationTimestamp | ts)) as $age
  | (if $vmi == null then {c: "VMI_BRAK", d: "VMI nie istnieje (VM wylaczona/usunieta) - migracja jest osierocona"}
     elif $vmi.status.phase != "Running" then {c: "VMI_NIE_DZIALA", d: "VMI w fazie \($vmi.status.phase // "-")"}
     elif $lm != null and $lm.status == "False" then {c: "NIEMIGROWALNA", d: "\($lm.reason // "-"): \($lm.message // "" | .[0:150])"}
     elif $tp == null and (($volok and ($volp | length) > 0) or $vev != null) then
       {c: "WOLUMEN_NIEGOTOWY", d: (if ($volp | length) > 0 then ($volp | map(.x) | join("; ")) else "\($vev.reason): \($vev.msg[0:150])" end)}
     elif ($perVmi["\($ns)/\($vn)"] // 0) > 1 and $tp == null then {c: "DUPLIKAT", d: "dla tej VMI istnieje \($perVmi["\($ns)/\($vn)"]) niezakonczonych migracji - aktywna moze byc tylko jedna"}
     elif $tp != null and $tp.status.phase == "Pending" and $tp.spec.nodeName == null then
       (if ($sched | test("Insufficient (memory|cpu|devices\\.kubevirt\\.io)")) then {c: "BRAK_MIEJSCA", d: $sched[0:170]}
        elif ($sched | test("affinity|selector|taint|didn.t match|untolerated")) then {c: "BRAK_PASUJACEGO_NODA", d: $sched[0:170]}
        elif ($sched | test("volume|persistentvolumeclaim"; "i")) then {c: "STORAGE", d: $sched[0:170]}
        elif $sched != "" then {c: "NIESCHEDULOWALNY", d: $sched[0:170]}
        else {c: "CZEKA_NA_SCHEDULER", d: "pod docelowy \($tp.metadata.name) czeka na przydzial noda"} end)
     elif $tp != null and $tp.status.phase == "Pending" then
       {c: "POD_DOCELOWY_STARTUJE", d: "pod na \($tp.spec.nodeName | split(".")[0]) nie wystartowal\(if $mnt then ": \($mnt.reason) \($mnt.msg[0:120])" else "" end)"}
     elif $ph == "Running" then {c: "W_TOKU", d: "przesyla pamiec od \(($now - ($m.status.migrationState.startTimestamp | ts // $now)) | age) do \($m.status.migrationState.targetNode // $tp.spec.nodeName // "-" | split(".")[0]) (tryb \($m.status.migrationState.mode // "PreCopy"))"}
     elif $tp != null and $tp.status.phase == "Running" then {c: "HANDSHAKE", d: "pod docelowy dziala na \($tp.spec.nodeName | split(".")[0]), migracja w fazie \($ph) - sprawdz virt-handler zrodla/celu i siec migracyjna"}
     elif $tp != null and ($tp.status.phase == "Failed") then {c: "POD_DOCELOWY_PADL", d: "pod docelowy w fazie Failed: \($tp.status.reason // "") \($tp.status.message // "" | .[0:120])"}
     elif $adm != null then {c: "ODRZUCONE_PRZY_TWORZENIU", d: "\($adm.reason): \($adm.msg[0:170])"}
     elif ($ph | pending) and $nact >= $lcl then {c: "KOLEJKA_KLASTER", d: "aktywnych migracji \($nact) >= limit \($lcl) (parallelMigrationsPerCluster)"}
     elif ($ph | pending) and ($outb[$src] // 0) >= $lpn then {c: "KOLEJKA_NODE", d: "z noda \($src | split(".")[0]) migruje juz \($outb[$src]) >= limit \($lpn) (parallelOutboundMigrationsPerNode)"}
     elif ($ph | pending) and $freeok and ($cand | length) == 0 then {c: "BRAK_PASUJACEGO_NODA", d: "zaden inny node nie spelnia nodeSelector/affinity/taintow VM (np. model CPU) - przewidywanie skryptu"}
     elif ($ph | pending) and $freeok and ($fit | length) == 0 then {c: "BRAK_MIEJSCA", d: "pasujace nody: \($cand | length), zaden nie ma wolnych \($rqm | gi) GiB pamieci requestu - przewidywanie skryptu"}
     elif ($ph | pending) then {c: "CZEKA_NA_KONTROLER", d: "brak poda docelowego i brak widocznej blokady\(if $lastw then " - ostatni event: \($lastw.reason) \($lastw.msg[0:100])" else "" end) - logi virt-controller (sekcja 9)"}
     else {c: "INNA", d: "faza \($ph)"} end) as $cause
  | {ns: $ns, mig: $m.metadata.name, vmi: $vn, ph: $ph, age: $age, ages: ($age | age), src: ($src | split(".")[0]), srcfull: $src,
     origin: ($m.metadata.name | origin), c: $cause.c, d: $cause.d, rqm: $rqm, rqc: $rqc,
     cand: ($cand | length), fit: ($fit | length), tp: ($tp.metadata.name // "-"), tpnode: ($tp.spec.nodeName // "-"),
     lmr: ($lm.reason // ""), evict: ($vmi.spec.evictionStrategy // "-"), term: any($volp[]; .t)}' "$TMP/all.json" >"$TMP/cls.jsonl" 2>"$TMP/cls.err"
[[ -s $TMP/cls.err ]] && warn "klasyfikacja: $(head -c 300 "$TMP/cls.err")"
jq -s '.' "$TMP/cls.jsonl" >"$TMP/cls.json"
NCLS=$(jq 'length' "$TMP/cls.json")

desc_cause() { case $1 in
  KOLEJKA_KLASTER) echo "kolejka - wyczerpany limit migracji w klastrze";;
  KOLEJKA_NODE) echo "kolejka - wyczerpany limit migracji wychodzacych z noda";;
  BRAK_MIEJSCA) echo "brak wolnej pamieci/CPU na pasujacych nodach (requesty)";;
  BRAK_PASUJACEGO_NODA) echo "zaden node nie pasuje (nodeSelector/affinity/model CPU/tainty)";;
  NIEMIGROWALNA) echo "VM nie da sie migrowac (LiveMigratable=False)";;
  WOLUMEN_NIEGOTOWY) echo "wolumen VM niegotowy (brak/niegotowy DataVolume, PVC usuwany)";;
  ODRZUCONE_PRZY_TWORZENIU) echo "utworzenie poda docelowego odrzucone (quota/LimitRange/webhook)";;
  DUPLIKAT) echo "kilka migracji tej samej VM";;
  VMI_BRAK|VMI_NIE_DZIALA) echo "VM nie dziala - migracja osierocona";;
  POD_DOCELOWY_STARTUJE) echo "pod docelowy przydzielony, ale nie startuje (wolumeny/siec)";;
  POD_DOCELOWY_PADL) echo "pod docelowy zakonczony bledem";;
  HANDSHAKE) echo "cel gotowy, migracja nie rusza (virt-handler/siec migracyjna)";;
  W_TOKU) echo "migracja trwa (przesylanie pamieci)";;
  STORAGE) echo "problem z wolumenami przy schedulingu";;
  NIESCHEDULOWALNY|CZEKA_NA_SCHEDULER) echo "pod docelowy nieprzydzielony (inny powod)";;
  CZEKA_NA_KONTROLER) echo "brak widocznej blokady - patrz logi virt-controller";;
  *) echo "-";; esac; }

sub "Zestawienie przyczyn (niezakonczone migracje: $NCLS)"
{ printf 'PRZYCZYNA\tLICZBA\tOPIS\tNAJSTARSZA\n'
  jq -r "$JQDEF"'group_by(.c) | sort_by(-length)[] | [.[0].c, (length | tostring), (map(.age) | max | age)] | @tsv' "$TMP/cls.json" \
  | while IFS=$'\t' read -r c n a; do printf '%s\t%s\t%s\t%s\n' "$c" "$n" "$(desc_cause "$c")" "$a"; done
} | table

sub "Szczegoly (najstarsze najpierw; maks. $TOPN)"
{ printf 'NAMESPACE\tVM\tFAZA\tWIEK\tZRODLO\tZ_NODA\tREQ_MEM\tPASUJACE/Z_MIEJSCEM\tPRZYCZYNA\tDOWOD\n'
  jq -r --argjson n "$TOPN" "$JQDEF"'sort_by(-.age) | .[:$n][] | (.c | test("^VMI_")) as $o | [.ns, .vmi, .ph, .ages, .origin, .src,
       (if $o then "-" else "\(.rqm | gi)Gi" end), (if $o then "-" else "\(.cand)/\(.fit)" end), .c, (.d | .[0:120])] | @tsv' "$TMP/cls.json"
} | table
echo "  PASUJACE/Z_MIEJSCEM = nody (poza zrodlowym), ktore spelniaja nodeSelector/affinity/tainty poda VM / z nich te,"
echo "  ktore maja wolne requesty pamieci i CPU dla tej VM. Gdy brak danych z Prometheusa, liczba z miejscem = 0."

# Sloty kolejki blokowane przez migracje, ktorych pod docelowy nie miesci sie
NBLOCK=$(jq '[.[] | select(.c == "BRAK_MIEJSCA" or .c == "BRAK_PASUJACEGO_NODA" or .c == "NIESCHEDULOWALNY" or .c == "STORAGE" or .c == "CZEKA_NA_SCHEDULER") | select(.tp != "-")] | length' "$TMP/cls.json")
cnt() { jq --arg c "$1" '[.[] | select(.c == $c)] | length' "$TMP/cls.json"; }

# =============================================================================
# 4. MIGRACJE W TOKU - CZY SIE ZBIEGAJA
# =============================================================================
hdr "4. MIGRACJE W TOKU - CZY ZDAZA SIE SKONCZYC (pamiec do przeslania vs tempo zmian)"
cat <<'TXT'
  Migracja (PreCopy) kopiuje pamiec VM w rundach; w tym czasie VM dalej ja zmienia. Konczy sie, gdy
  przesyl jest szybszy niz zmiany (tempo zmian "dirty rate"). Gdy nie jest - pozostala pamiec nie maleje
  i migracja konczy sie timeoutem: completionTimeoutPerGiB x GiB pamieci VM (albo progressTimeout,
  gdy brak postepu). Ratunek: auto-converge (spowalnia CPU VM), post-copy (VM przechodzi na cel,
  reszta pamieci dociagana na zadanie), wieksze bandwidthPerMigration, dedykowana siec migracyjna.
TXT
NRUN=$(jq '[.items[] | select(.status.phase == "Running")] | length' "$TMP/vmim.json")
: >"$TMP/conv.jsonl"
if (( NRUN == 0 )); then
  echo "  Brak migracji w fazie Running (przesylanie pamieci) - nic do oceny."
else
  NSF=""; [[ -n $SCOPE_NS ]] && NSF="{namespace=\"$SCOPE_NS\"}"
  prom query "$TMP/c_rem.json"   "query=kubevirt_vmi_migration_data_remaining_bytes$NSF" || true
  prom query "$TMP/c_proc.json"  "query=kubevirt_vmi_migration_data_processed_bytes$NSF" || true
  prom query "$TMP/c_dirty.json" "query=kubevirt_vmi_migration_dirty_memory_rate_bytes$NSF" || true
  prom query "$TMP/c_xfer.json"  "query=kubevirt_vmi_migration_memory_transfer_rate_bytes$NSF or kubevirt_vmi_migration_disk_transfer_rate_bytes$NSF" || true
  prom query "$TMP/c_drem.json"  "query=deriv(kubevirt_vmi_migration_data_remaining_bytes${NSF}[5m])" || true
  jq '.items[0].spec.configuration.migrations // {}' "$TMP/kv.json" >"$TMP/kvmig.json"
  jq -c --argjson now "$NOW" --slurpfile v "$TMP/vmi.json" --slurpfile kvm "$TMP/kvmig.json" \
     --slurpfile r "$TMP/c_rem.json" --slurpfile p "$TMP/c_proc.json" --slurpfile d "$TMP/c_dirty.json" \
     --slurpfile x "$TMP/c_xfer.json" --slurpfile dr "$TMP/c_drem.json" "$JQDEF"'
    def pm: [.data.result[]? | {key: "\(.metric.namespace // "")/\(.metric.name // .metric.vmi // "")", value: (.value[1] | tonumber)}] | from_entries;
    def mib: if . == null then "-" else (. / 1048576 | round | tostring) end;
    ($r[0] | pm) as $R | ($p[0] | pm) as $P | ($d[0] | pm) as $D | ($x[0] | pm) as $X | ($dr[0] | pm) as $DR | $kvm[0] as $k
    | ($v[0].items | map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $V
    | .items[] | select(.status.phase == "Running") | "\(.metadata.namespace)/\(.spec.vmiName)" as $key | $V[$key] as $vmi
    | (.status.migrationState // $vmi.status.migrationState // {}) as $s | ($s.migrationConfiguration // {}) as $mc
    | (($vmi.spec.domain.memory.guest // $vmi.spec.domain.resources.requests.memory) | mem) as $mem
    | (($mc.completionTimeoutPerGiB // $k.completionTimeoutPerGiB // 150) | tonumber? // 150) as $ctg
    | (([$mem / 1073741824, 1] | max) * $ctg) as $tmo
    | ($now - (($s.startTimestamp | ts) // $now)) as $el
    | ($mc.allowAutoConverge // $k.allowAutoConverge // false) as $ac | ($mc.allowPostCopy // $k.allowPostCopy // false) as $pc
    | (($mc.bandwidthPerMigration // $k.bandwidthPerMigration // null) | if . == null or . == "0" or . == 0 then null else mem end) as $bw
    | $R[$key] as $rem | $X[$key] as $xf | $D[$key] as $dirty | $DR[$key] as $drem
    | ($bw != null and $xf != null and $xf >= 0.9 * $bw) as $bwlim
    | (if ($s.mode // "PreCopy") == "PostCopy" then {w: "POST_COPY", d: "VM dziala juz na celu, reszta pamieci dociagana na zadanie - zakonczy sie (ryzyko: zerwanie sieci = utrata VM)"}
       elif $rem == null and $xf == null then {w: "BRAK_METRYK", d: "brak metryk kubevirt_vmi_migration_* dla tej VM\(if $el > 0.8 * $tmo then "; trwa juz \($el | age) z ok. \($tmo | age) dozwolonych - blisko timeoutu" else "" end)"}
       elif $xf != null and $dirty != null and $xf > 0 and $dirty >= 0.9 * $xf then
         {w: "NIE_ZBIEGA_SIE", d: "VM zmienia \($dirty | mib) MiB/s pamieci, przesyl \($xf | mib) MiB/s\(if $bwlim then " (= limit bandwidthPerMigration)" else "" end)\(if $ac then "; auto-converge wlaczone - spowalnia CPU VM" else "" end)"}
       elif $drem != null and $drem >= 0 and ($rem // 0) > 0 and $el > 300 then
         {w: "BRAK_SPADKU", d: "pozostala pamiec (\($rem | mib) MiB) nie maleje od 5 min\(if $bwlim then "; przesyl na limicie bandwidthPerMigration" else "" end)"}
       elif $xf != null and $rem != null and $xf > ($dirty // 0) then
         (($rem / ($xf - ($dirty // 0)))) as $eta
         | if $el + $eta > $tmo then {w: "NIE_ZDAZY", d: "szacowany koniec za ok. \($eta | age), a timeout za ok. \(([$tmo - $el, 0] | max) | age)"}
           else {w: "ZBIEGA_SIE", d: "szacowany koniec za ok. \([$eta, 60] | max | age)"} end
       else {w: "BRAK_DANYCH", d: "niepelne metryki (pozostalo \($rem | mib) MiB, przesyl \($xf | mib) MiB/s)"} end) as $verd
    | {ns: .metadata.namespace, vm: .spec.vmiName, src: ($s.sourceNode // $vmi.status.nodeName // "-" | split(".")[0]),
       dst: ($s.targetNode // "-" | split(".")[0]), mode: ($s.mode // "PreCopy"), el: $el, els: ($el | age), tmos: ($tmo | age),
       memg: ($mem | gi), rem: ($rem | mib), xf: ($xf | mib), dirty: ($dirty | mib), ac: $ac, pc: $pc, bwlim: $bwlim, w: $verd.w, d: $verd.d}' \
    "$TMP/vmim.json" >"$TMP/conv.jsonl" 2>"$TMP/conv.err"
  [[ -s $TMP/conv.err ]] && warn "zbieznosc: $(head -c 300 "$TMP/conv.err")"
  { printf 'NAMESPACE\tVM\tZ_NODA->NA\tPAMIEC\tTRYB\tTRWA/TIMEOUT\tPOZOSTALO_MiB\tPRZESYL_MiB/s\tZMIANY_MiB/s\tAUTOCONV/POSTCOPY\tWERDYKT\n'
    jq -s -r --argjson n "$TOPN" 'sort_by(-.el) | .[:$n][] | [.ns, .vm, "\(.src)->\(.dst)", "\(.memg)Gi", .mode, "\(.els)/\(.tmos)",
       .rem, .xf, .dirty, "\(if .ac then "tak" else "nie" end)/\(if .pc then "tak" else "nie" end)", .w] | @tsv' "$TMP/conv.jsonl"
  } | table
  jq -s -r 'sort_by(-.el)[] | select(.w != "ZBIEGA_SIE") | "  \(.ns)/\(.vm): \(.w) - \(.d)"' "$TMP/conv.jsonl" | head -n "$TOPN"
  echo "  TIMEOUT liczony jako completionTimeoutPerGiB x pamiec VM (bez dyskow kopiowanych blokowo) - wartosc orientacyjna."
fi
jq -s '.' "$TMP/conv.jsonl" >"$TMP/conv.json"
cntw() { jq --arg w "$1" '[.[] | select(.w == $w)] | length' "$TMP/conv.json"; }
V_NZ=$(cntw NIE_ZBIEGA_SIE); V_BS=$(cntw BRAK_SPADKU); V_ND=$(cntw NIE_ZDAZY); V_NM=$(cntw BRAK_METRYK); V_PC=$(cntw POST_COPY)
V_DATA=$(jq '[.[] | select(.w != "BRAK_METRYK" and .w != "POST_COPY")] | length' "$TMP/conv.json")
V_BW=$(jq '[.[] | select(.bwlim)] | length' "$TMP/conv.json")
V_NOAC=$(jq '[.[] | select((.w == "NIE_ZBIEGA_SIE" or .w == "BRAK_SPADKU" or .w == "NIE_ZDAZY") and (.ac | not))] | length' "$TMP/conv.json")
V_NOPC=$(jq '[.[] | select((.w == "NIE_ZBIEGA_SIE" or .w == "BRAK_SPADKU" or .w == "NIE_ZDAZY") and (.pc | not))] | length' "$TMP/conv.json")

# =============================================================================
# 5. MIGRACJE ZAKONCZONE - NIEUDANE I CZAS TRWANIA
# =============================================================================
hdr "5. MIGRACJE ZAKONCZONE - DLACZEGO SIE NIE UDAJA I JAK DLUGO TRWAJA UDANE"
echo "  Zrodlo: obiekty VMIM (KubeVirt trzyma tylko kilka ostatnich zakonczonych migracji kazdej VM - to"
echo "  probka ostatnich dni, nie pelna historia) i eventy z ostatnich godzin."
jq -c --argjson now "$NOW" --slurpfile v "$TMP/vmi.json" --slurpfile ev "$TMP/ev.json" "$JQDEF"'
  def fcls($r; $s; $pp):
    if ($r | test("not completed after|completion timeout|acceptable completion"; "i")) then "TIMEOUT_ZAKONCZENIA"
    elif ($r | test("stuck for|no progress|progress timeout"; "i")) then "BRAK_POSTEPU"
    elif ($s.abortRequested == true) or (($s.abortStatus // "") == "Succeeded") or ($r | test("abort|cancel"; "i")) then "PRZERWANA"
    elif ($r | test("unschedul|pending.*timeout|timeout.*pending|insufficient"; "i"))
         or (($s.startTimestamp // null) == null and ($pp | index("Running")) == null and ($pp | index("TargetReady")) == null) then "NIE_WYSTARTOWALA"
    elif ($r | test("connect|network|dial|refused|tls|reset by peer|broken pipe|no route|i/o timeout|unreachable"; "i")) then "SIEC"
    elif ($r | test("target|virt-launcher|pod .*(fail|terminat|delet)|exited|killed"; "i")) then "CEL_PADL"
    elif ($r | test("disk|volume|storage|block|pvc"; "i")) then "STORAGE"
    elif ($r | test("libvirt|qemu|domain|cpu|feature"; "i")) then "QEMU_LIBVIRT"
    elif $r == "" then "BEZ_POWODU" else "INNA" end;
  ($v[0].items | map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $V
  | .items[] | select(.status.phase == "Succeeded" or .status.phase == "Failed") | . as $m
  | (.status.migrationState // {}) as $s | [.status.phaseTransitionTimestamps[]?.phase] as $pp
  | ([$ev[0].items[] | select(.involvedObject.name == $m.metadata.name and .involvedObject.namespace == $m.metadata.namespace and .type == "Warning")
      | (.message // "")] | last // "") as $evw
  | (($s.failureReason // "") | if . == "" then $evw else . end | gsub("[\n\t]"; " ")) as $r
  | ([.status.phaseTransitionTimestamps[]? | select(.phase == $m.status.phase) | .phaseTransitionTimestamp | ts] | last) as $pt
  | (($s.endTimestamp | ts) // $pt // (.metadata.creationTimestamp | ts)) as $t
  | (if ($s.startTimestamp // null) != null and ($s.endTimestamp // null) != null then ($s.endTimestamp | ts) - ($s.startTimestamp | ts) else null end) as $dur
  | $V["\(.metadata.namespace)/\(.spec.vmiName)"] as $vmi
  | {ns: .metadata.namespace, vm: .spec.vmiName, ph: .status.phase, t: $t, dur: $dur, mode: ($s.mode // "-"),
     src: ($s.sourceNode // "-"), dst: ($s.targetNode // "-"), origin: (.metadata.name | origin),
     mem: (if $vmi then (($vmi.spec.domain.memory.guest // $vmi.spec.domain.resources.requests.memory) | mem) else null end),
     c: (if .status.phase == "Failed" then fcls($r; $s; $pp) else "-" end), r: ($r | .[0:160])}' "$TMP/vmim.json" >"$TMP/fin.jsonl" 2>"$TMP/fin.err"
[[ -s $TMP/fin.err ]] && warn "migracje zakonczone: $(head -c 300 "$TMP/fin.err")"
jq -s '.' "$TMP/fin.jsonl" >"$TMP/fin.json"
read -r F_OK F_FAIL < <(jq -r '"\([.[] | select(.ph == "Succeeded")] | length) \([.[] | select(.ph == "Failed")] | length)"' "$TMP/fin.json")
desc_fail() { case $1 in
  TIMEOUT_ZAKONCZENIA) echo "przekroczony czas (completionTimeoutPerGiB) - pamiec zmieniala sie szybciej niz przesyl";;
  BRAK_POSTEPU) echo "brak postepu kopiowania (progressTimeout)";;
  PRZERWANA) echo "przerwana: anulowanie (usuniety VMIM) lub abort";;
  NIE_WYSTARTOWALA) echo "nie ruszyla - pod docelowy nie powstal/nie zmiescil sie (timeout Pending)";;
  SIEC) echo "blad polaczenia miedzy nodami (siec migracyjna/firewall/MTU)";;
  CEL_PADL) echo "pod docelowy (virt-launcher) padl lub zostal usuniety";;
  STORAGE) echo "problem z dyskami/wolumenami";;
  QEMU_LIBVIRT) echo "blad QEMU/libvirt (np. niezgodne CPU/funkcje na celu)";;
  BEZ_POWODU) echo "brak failureReason i eventow - patrz logi virt-handler";;
  *) echo "inny - patrz komunikat";; esac; }
F_TOT=$(( F_OK + F_FAIL ))
if (( F_TOT == 0 )); then
  echo "  Brak zakonczonych migracji w obiektach VMIM${SCOPE_NS:+ w $SCOPE_NS}."
else
  echo
  echo "  Zakonczone: $F_TOT   udane: $F_OK   nieudane: $F_FAIL ($(( F_FAIL * 100 / F_TOT ))%)"
fi
if (( F_FAIL > 0 )); then
  sub "Nieudane wg przyczyny"
  { printf 'PRZYCZYNA\tLICZBA\tOPIS\tOSTATNIA\n'
    jq -r 'map(select(.ph == "Failed")) | group_by(.c) | sort_by(-length)[] | [.[0].c, (length | tostring), (map(.t) | max | strftime("%Y-%m-%d %H:%M"))] | @tsv' "$TMP/fin.json" \
    | while IFS=$'\t' read -r c n t; do printf '%s\t%s\t%s\t%s\n' "$c" "$n" "$(desc_fail "$c")" "$t"; done
  } | table
  sub "Nody w migracjach: nieudane / udane (zrodlo i cel)"
  { printf 'NODE\tNIEUDANE_ZRODLO\tNIEUDANE_CEL\tUDANE_ZRODLO\tUDANE_CEL\n'
    jq -r '[.[] | select(.ph == "Failed" or .ph == "Succeeded")] as $a
      | ([$a[] | .src, .dst] | map(select(. != "-")) | unique) as $nodes
      | [$nodes[] as $n | {n: $n, fs: ([$a[] | select(.ph == "Failed" and .src == $n)] | length), fd: ([$a[] | select(.ph == "Failed" and .dst == $n)] | length),
          os: ([$a[] | select(.ph == "Succeeded" and .src == $n)] | length), od: ([$a[] | select(.ph == "Succeeded" and .dst == $n)] | length)}]
      | sort_by(-(.fs + .fd))[] | [(.n | split(".")[0]), (.fs | tostring), (.fd | tostring), (.os | tostring), (.od | tostring)] | @tsv' "$TMP/fin.json" | head -n "$TOPN"
  } | table
  sub "VM z powtarzajacymi sie porazkami (>= 2)"
  { printf 'NAMESPACE\tVM\tNIEUDANE\tUDANE\tPAMIEC\tOSTATNIA_PRZYCZYNA\n'
    jq -r --argjson n "$TOPN" "$JQDEF"'group_by("\(.ns)/\(.vm)") | map({ns: .[0].ns, vm: .[0].vm, f: [.[] | select(.ph == "Failed")], o: ([.[] | select(.ph == "Succeeded")] | length), mem: .[0].mem})
      | map(select((.f | length) >= 2)) | sort_by(-(.f | length)) | .[:$n][]
      | [.ns, .vm, (.f | length | tostring), (.o | tostring), (if .mem then "\(.mem | gi)Gi" else "-" end), (.f | sort_by(.t) | last | .c)] | @tsv' "$TMP/fin.json"
  } | table
  sub "Ostatnie nieudane (maks. $TOPN)"
  { printf 'KIEDY\tNAMESPACE\tVM\tZRODLO\tZ_NODA->NA\tTRYB\tTRWALA\tPRZYCZYNA\tKOMUNIKAT\n'
    jq -r --argjson n "$TOPN" "$JQDEF"'map(select(.ph == "Failed")) | sort_by(-.t) | .[:$n][]
      | [(.t | strftime("%m-%d %H:%M")), .ns, .vm, .origin, (if .src == "-" and .dst == "-" then "-" else "\(.src | split(".")[0])->\(.dst | split(".")[0])" end), .mode,
         (if .dur then (.dur | age) else "-" end), .c, (if .r == "" then "-" else .r[0:90] end)] | @tsv' "$TMP/fin.json"
  } | table
fi
if (( F_OK > 0 )); then
  sub "Czas trwania udanych migracji"
  jq -r "$JQDEF"'[.[] | select(.ph == "Succeeded" and .dur != null) | .dur] | sort
    | if length == 0 then "  (brak znacznikow startu/konca w migrationState)"
      else "  Udanych z czasem: \(length)   mediana: \(.[length / 2 | floor] | age)   90%: \(.[(length * 0.9 | floor)] // .[-1] | age)   maks.: \(.[-1] | age)" end' "$TMP/fin.json"
  { printf 'NAMESPACE\tVM\tPAMIEC\tCZAS\tGiB/min\tTRYB\tZ_NODA->NA\tKIEDY\n'
    jq -r "$JQDEF"'map(select(.ph == "Succeeded" and .dur != null)) | sort_by(-.dur) | .[:10][]
      | [.ns, .vm, (if .mem then "\(.mem | gi)Gi" else "-" end), (.dur | age),
         (if .mem and .dur > 0 then (.mem / 1073741824 / (.dur / 60) * 10 | round / 10 | tostring) else "-" end), .mode,
         "\(.src | split(".")[0])->\(.dst | split(".")[0])", (.t | strftime("%m-%d %H:%M"))] | @tsv' "$TMP/fin.json"
  } | table
  echo "  Najwolniejsze 10. GiB/min = pamiec VM / czas; znacznie nizsze niz u innych VM = VM intensywnie zmienia pamiec"
  echo "  albo lacze jest wspoldzielone/ograniczone (bandwidthPerMigration)."
fi
cntf() { jq --arg c "$1" '[.[] | select(.ph == "Failed" and .c == $c)] | length' "$TMP/fin.json"; }

# =============================================================================
# 6. MIEJSCE NA NODACH DLA VM
# =============================================================================
hdr "6. MIEJSCE DLA VM NA NODACH (requesty vs allocatable)"
{ printf 'NODE\tREADY\tCORDON\tKV_SCHED\tALLOC_MEM\tREQ_MEM\tWOLNE_MEM\tALLOC_CPU\tREQ_CPU\tWOLNE_CPU\tVM\tMIGRACJE_WYCH\n'
  jq -r --slurpfile v "$TMP/vmi.json" --slurpfile cl "$TMP/cls.json" "$JQDEF"'
    to_entries | map(select(.value.kvs != "-")) | sort_by(.value.fm // 0) | reverse[] | .key as $n | .value as $x
    | [($n | split(".")[0]), (if $x.ready then "tak" else "NIE" end), (if $x.cordon then "TAK" else "-" end), $x.kvs,
       "\($x.am | gi)Gi", "\($x.rm | gi)Gi", (if $x.fm == null then "?" else "\($x.fm | gi)Gi" end),
       "\($x.ac * 10 | round / 10)", "\($x.rc * 10 | round / 10)", (if $x.fc == null then "?" else "\($x.fc * 10 | round / 10)" end),
       ([$v[0].items[] | select(.status.nodeName == $n)] | length | tostring),
       ([$cl[0][] | select(.srcfull == $n)] | length | tostring)] | @tsv' "$TMP/free.json"
} | table
echo "  Tylko nody z etykieta kubevirt.io/schedulable. WOLNE = allocatable - suma requestow podow (scheduler patrzy na"
echo "  requesty, nie na realne zuzycie). MIGRACJE_WYCH = niezakonczone migracje VM z tego noda."
if [[ $FREE_OK == true && $NCLS -gt 0 ]]; then
  read -r MAXREQ MAXFREE < <(jq -r --slurpfile f "$TMP/free.json" '[(map(.rqm) | max // 0),
     ([$f[0][] | select(.ready and (.cordon | not) and .kvs == "true") | .fm] | max // 0)] | map(tostring) | join(" ")' "$TMP/cls.json")
  echo "  Najwieksza oczekujaca VM potrzebuje $(awk -v b="$MAXREQ" 'BEGIN{printf "%.1f", b/1073741824}') GiB requestu;"
  echo "  najwiecej wolnego na jednym dostepnym nodzie: $(awk -v b="$MAXFREE" 'BEGIN{printf "%.1f", b/1073741824}') GiB."
  SUMREQ=$(jq '[.[] | select(.c == "BRAK_MIEJSCA") | .rqm] | add // 0' "$TMP/cls.json")
  SUMFREE=$(jq '[.[] | select(.ready and (.cordon | not) and .kvs == "true" and .fm > 0) | .fm] | add // 0' "$TMP/free.json")
  ge "$SUMREQ" 1 && echo "  VM czekajace na miejsce potrzebuja razem $(awk -v b="$SUMREQ" 'BEGIN{printf "%.0f", b/1073741824}') GiB, wolne na wszystkich dostepnych nodach: $(awk -v b="$SUMFREE" 'BEGIN{printf "%.0f", b/1073741824}') GiB."
fi

# =============================================================================
# 7. BLOKADY: QUOTA, PDB, VM NIEMIGROWALNE PRZY DRAINIE, DYSKI RWO
# =============================================================================
hdr "7. BLOKADY: KWOTY, PDB, VM NIEMIGROWALNE, DYSKI"
sub "ResourceQuota w namespace z niezakonczonymi migracjami (pod docelowy tez sie wlicza!)"
{ printf 'NAMESPACE\tQUOTA\tZASOB\tUZYTE\tLIMIT\tPROCENT\n'
  jq -r --slurpfile cl "$TMP/cls.json" "$JQDEF"'([$cl[0][].ns] | unique) as $nss
    | .items[] | select(.metadata.namespace as $x | $nss | index($x)) | . as $q
    | (.status.hard // {}) | to_entries[] | .key as $r | .value as $h | ($q.status.used[$r] // "0") as $u
    | (if ($r | test("memory|storage")) then [($u | mem), ($h | mem)] elif ($r | test("cpu")) then [($u | cpu), ($h | cpu)] else [($u | tonumber? // 0), ($h | tonumber? // 0)] end) as $v
    | select($v[1] > 0)
    | [$q.metadata.namespace, $q.metadata.name, $r, $u, $h, "\($v[0] / $v[1] * 100 | round)%"] | @tsv' "$TMP/quota.json"
} | table
NQFULL=$(jq -r --slurpfile cl "$TMP/cls.json" "$JQDEF"'([$cl[0][].ns] | unique) as $nss
  | [.items[] | select(.metadata.namespace as $x | $nss | index($x)) | . as $q | (.status.hard // {}) | to_entries[] | .key as $r
     | ($q.status.used[$r] // "0") as $u
     | (if ($r | test("memory|storage")) then [($u | mem), (.value | mem)] elif ($r | test("cpu")) then [($u | cpu), (.value | cpu)] else [($u | tonumber? // 0), (.value | tonumber? // 0)] end)
     | select(.[1] > 0 and .[0] / .[1] >= 0.9)] | length' "$TMP/quota.json")

sub "PodDisruptionBudget blokujace (disruptionsAllowed=0) w namespace z VM"
{ printf 'NAMESPACE\tPDB\tMIN_AVAILABLE\tMAX_UNAVAILABLE\tPODY_OCZEKIWANE\tZDROWE\tTYP\n'
  jq -r --slurpfile v "$TMP/vmi.json" '([$v[0].items[].metadata.namespace] | unique) as $nss
    | .items[] | select((.metadata.namespace as $x | $nss | index($x)) and (.status.disruptionsAllowed // 0) == 0)
    | [.metadata.namespace, .metadata.name, (.spec.minAvailable // "-" | tostring), (.spec.maxUnavailable // "-" | tostring),
       (.status.expectedPods // 0 | tostring), (.status.currentHealthy // 0 | tostring),
       (if (.metadata.name | startswith("kubevirt-disruption-budget-")) then "KubeVirt (chroni migrowana VM)" else "uzytkownika" end)] | @tsv' "$TMP/pdb.json"
} | table
NPDBUSR=$(jq --slurpfile v "$TMP/vmi.json" '([$v[0].items[].metadata.namespace] | unique) as $nss
  | [.items[] | select((.metadata.namespace as $x | $nss | index($x)) and (.status.disruptionsAllowed // 0) == 0 and (.metadata.name | startswith("kubevirt-disruption-budget-") | not))] | length' "$TMP/pdb.json")
echo "  PDB KubeVirt (kubevirt-disruption-budget-*) z 0 jest normalne w trakcie migracji; zle, gdy zostaje po migracji"
echo "  albo dotyczy VM, ktorej nie da sie migrowac (wtedy drain noda stoi)."

sub "VM blokujace drain: evictionStrategy=LiveMigrate, a LiveMigratable=False"
{ printf 'NAMESPACE\tVM\tNODE\tNODE_CORDON\tPOWOD\n'
  jq -r --slurpfile n "$TMP/nodes.json" '([$n[0].items[] | select(.spec.unschedulable == true) | .metadata.name]) as $cord
    | .items[] | select((.spec.evictionStrategy // "") == "LiveMigrate" and any(.status.conditions[]?; .type == "LiveMigratable" and .status == "False"))
    | [.metadata.namespace, .metadata.name, (.status.nodeName // "-" | split(".")[0]), (.status.nodeName as $nn | if ($cord | index($nn)) then "TAK" else "-" end),
       ([.status.conditions[] | select(.type == "LiveMigratable") | .reason][0] // "-")] | @tsv' "$TMP/vmi.json" | head -n "$TOPN"
} | table
NBLKDRAIN=$(jq --slurpfile n "$TMP/nodes.json" '([$n[0].items[] | select(.spec.unschedulable == true) | .metadata.name]) as $cord
  | [.items[] | select((.spec.evictionStrategy // "") == "LiveMigrate" and any(.status.conditions[]?; .type == "LiveMigratable" and .status == "False") and (.status.nodeName as $nn | $cord | index($nn)))] | length' "$TMP/vmi.json")

sub "Cechy VM blokujace lub ograniczajace migracje (wszystkie dzialajace VM w zakresie)"
# BLOKUJE = migracja niemozliwa; WARUNKOWO = zalezy od wersji CNV / konfiguracji; OGRANICZA = tylko na wybrane nody
jq -c --slurpfile pv "$TMP/pvcall.json" '
  ($pv[0].items | map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $P
  | .items[] | .metadata.namespace as $ns | .spec as $s | ($s.networks // []) as $nets
  | ([$s.volumes[]? | (.persistentVolumeClaim.claimName // .dataVolume.name // empty) as $c | $P["\($ns)/\($c)"] as $p
      | select($p != null and (($p.spec.accessModes // []) | index("ReadWriteMany")) == null) | $c]) as $rwo
  | [ (if (($s.domain.devices.gpus // []) | length) > 0 then {f: "GPU/vGPU", w: "BLOKUJE"} else empty end),
      (if (($s.domain.devices.hostDevices // []) | length) > 0 then {f: "hostDevices (PCI passthrough)", w: "BLOKUJE"} else empty end),
      (if any($s.volumes[]?; .hostDisk != null) then {f: "dysk hostDisk (lokalny na nodzie)", w: "BLOKUJE"} else empty end),
      (if ($rwo | length) > 0 then {f: "dysk PVC bez RWX (\($rwo | .[0:2] | join(",")))", w: "BLOKUJE"} else empty end),
      (if any($s.domain.devices.interfaces[]?; .bridge != null and (.name as $n | any($nets[]; .name == $n and .pod != null)))
       then {f: "interfejs bridge w sieci podow", w: "BLOKUJE"} else empty end),
      (if $s.domain.launchSecurity != null then {f: "launchSecurity (SEV)", w: "BLOKUJE"} else empty end),
      (if any($s.domain.devices.disks[]?; .lun.reservation == true) then {f: "dysk LUN z persistent reservation", w: "BLOKUJE"} else empty end),
      (if any($s.domain.devices.interfaces[]?; .sriov != null) then {f: "SR-IOV", w: "WARUNKOWO"} else empty end),
      (if (($s.domain.devices.filesystems // []) | length) > 0 then {f: "virtiofs (filesystems)", w: "WARUNKOWO"} else empty end),
      (if any(.status.volumeStatus[]?; .hotplugVolume != null) then {f: "dyski hotplug", w: "WARUNKOWO"} else empty end),
      (if ($s.domain.devices.tpm.persistent == true) or ($s.domain.firmware.bootloader.efi.persistent == true)
       then {f: "trwaly vTPM/EFI", w: "WARUNKOWO"} else empty end),
      (if ($s.domain.cpu.model // "") == "host-passthrough" then {f: "CPU host-passthrough", w: "OGRANICZA"} else empty end),
      (if $s.domain.cpu.dedicatedCpuPlacement == true then {f: "dedykowane CPU (CPU manager)", w: "OGRANICZA"} else empty end),
      (if $s.domain.memory.hugepages != null then {f: "hugepages \($s.domain.memory.hugepages.pageSize // "")", w: "OGRANICZA"} else empty end),
      (if (($s.evictionStrategy // "") | test("^(None|External)$")) then {f: "evictionStrategy \($s.evictionStrategy)", w: "DRAIN"} else empty end)
    ] as $f
  | ([.status.conditions[]? | select(.type == "LiveMigratable")][0]) as $lm
  | select(($f | length) > 0 or ($lm.status // "True") == "False")
  | {ns: $ns, vm: .metadata.name, node: (.status.nodeName // "-" | split(".")[0]), ev: ($s.evictionStrategy // "-"),
     lm: ($lm.status // "?"), lmr: ($lm.reason // ""), f: $f}' "$TMP/vmi.json" >"$TMP/feat.jsonl" 2>"$TMP/feat.err"
[[ -s $TMP/feat.err ]] && warn "cechy VM: $(head -c 300 "$TMP/feat.err")"
jq -s '.' "$TMP/feat.jsonl" >"$TMP/feat.json"
feat_todo() { case $1 in
  GPU*|hostDevices*) echo "zatrzymaj VM na czas drainu (evictionStrategy: None/External) albo przenies urzadzenie";;
  "dysk hostDisk"*) echo "przenies dysk na PVC RWX";;
  "dysk PVC bez RWX"*) echo "sklonuj/przenies dysk na StorageClass z trybem RWX";;
  "interfejs bridge"*) echo "w sieci podow uzyj masquerade zamiast bridge";;
  "launchSecurity"*|"dysk LUN"*) echo "migracja niewspierana - zatrzymaj VM na czas drainu";;
  SR-IOV) echo "migracja tylko gdy wersja CNV ja wspiera i na celu sa wolne VF tej samej sieci";;
  virtiofs*) echo "starsze CNV nie migruja VM z virtiofs - sprawdz wersje";;
  "dyski hotplug"*) echo "starsze CNV nie migruja VM z dyskami hotplug - sprawdz wersje";;
  "trwaly vTPM"*) echo "wymaga StorageClass RWX dla stanu VM (HCO spec.vmStateStorageClass)";;
  "CPU host-passthrough") echo "migracja tylko na identyczny CPU - rozwaz host-model lub wspolny model";;
  "dedykowane CPU"*) echo "cel musi miec CPU manager i wolne cale rdzenie";;
  hugepages*) echo "cel musi miec wolne hugepages tego rozmiaru";;
  evictionStrategy*) echo "przy drainie VM nie migruje: None = wylaczenie, External = czeka na zewnetrzny kontroler";;
  *) echo "-";; esac; }
{ printf 'CECHA\tWPLYW\tLICZBA_VM\tPRZYKLAD\tCO_ZROBIC\n'
  jq -r '[.[] | . as $v | .f[] | {f: (.f | sub(" \\(.*"; "")), w, x: "\($v.ns)/\($v.vm)"}] | group_by(.f)
     | sort_by({"BLOKUJE": 0, "WARUNKOWO": 1, "OGRANICZA": 2, "DRAIN": 3}[.[0].w], -length)[] | [.[0].f, .[0].w, (length | tostring), .[0].x] | @tsv' "$TMP/feat.json" \
  | while IFS=$'\t' read -r f w n x; do printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$w" "$n" "$x" "$(feat_todo "$f")"; done
} | table
{ printf 'NAMESPACE\tVM\tNODE\tEVICTION\tLIVE_MIGRATABLE\tCECHY_BLOKUJACE_I_WARUNKOWE\n'
  jq -r --argjson n "$TOPN" '[.[] | select(.lm == "False" or any(.f[]; .w == "BLOKUJE" or .w == "WARUNKOWO"))]
     | sort_by(.lm != "False", .ns, .vm) | .[:$n][]
     | [.ns, .vm, .node, .ev, "\(.lm)\(if .lmr != "" then " (\(.lmr))" else "" end)",
        ([.f[] | select(.w == "BLOKUJE" or .w == "WARUNKOWO") | .f] | if length == 0 then "- (powod tylko w warunku LiveMigratable)" else join("; ") end)] | @tsv' "$TMP/feat.json"
} | table
echo "  WPLYW: BLOKUJE - migracja niemozliwa; WARUNKOWO - zalezy od wersji CNV/konfiguracji; OGRANICZA - tylko na"
echo "  czesc nodow (moze dawac BRAK_PASUJACEGO_NODA); DRAIN - przy drainie VM nie migruje (wylaczenie/zewnetrzny kontroler)."
N_FBLK=$(jq '[.[] | select(any(.f[]; .w == "BLOKUJE"))] | length' "$TMP/feat.json")
CL_EV=$(jq -r '.items[0].spec.evictionStrategy // "LiveMigrate"' "$TMP/hco.json")
N_FBLK_LM=$(jq --arg cev "$CL_EV" '[.[] | select(any(.f[]; .w == "BLOKUJE") and (.ev == "LiveMigrate" or .ev == "LiveMigrateIfPossible" or (.ev == "-" and $cev != "None")))] | length' "$TMP/feat.json")
N_FHPT=$(jq '[.[] | select(any(.f[]; .f == "CPU host-passthrough"))] | length' "$TMP/feat.json")
N_FNOEV=$(jq '[.[] | select(any(.f[]; .w == "DRAIN"))] | length' "$TMP/feat.json")

sub "Dyski VM niemigrowalnych (PVC i tryb dostepu)"
{ printf 'NAMESPACE\tVM\tPVC\tTRYB\tSTORAGECLASS\tVOLUMEMODE\n'
  jq -s -r --slurpfile v "$TMP/vmi.json" '(map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $p
    | $v[0].items[] | select(any(.status.conditions[]?; .type == "LiveMigratable" and .status == "False" and ((.reason // "") | test("Disk|Volume|Storage"; "i"))))
    | .metadata.namespace as $ns | .metadata.name as $vm
    | .spec.volumes[]? | (.persistentVolumeClaim.claimName // .dataVolume.name // empty) as $c | $p["\($ns)/\($c)"] as $pc
    | [$ns, $vm, $c, ($pc.spec.accessModes // ["?"] | join(",")), ($pc.spec.storageClassName // "-"), ($pc.spec.volumeMode // "-")] | @tsv' <(jq -c '.items[]' "$TMP/pvcall.json") | head -n "$TOPN"
} | table

# =============================================================================
# 8. HISTORIA I ALERTY (Prometheus)
# =============================================================================
hdr "8. HISTORIA MIGRACJI I ALERTY (Prometheus, $HDAYS dni)"
STEP=3600; T1=$(( NOW / STEP * STEP )); T0=$(( T1 - HDAYS * 86400 ))
for p in pending scheduling running; do
  prom query_range "$TMP/h_$p.json" "query=sum(kubevirt_vmi_migrations_in_${p}_phase) or vector(0)" "start=$T0" "end=$T1" "step=$STEP" || true
done
{ printf 'DZIEN\tMAX_PENDING\tMAX_SCHEDULING\tMAX_RUNNING\n'
  jq -s -r 'map([.data.result[0].values[]? | {t: (.[0] | floor), v: (.[1] | tonumber)}]) as [$p, $s, $r]
    | ([$p[], $s[], $r[]] | map(.t | strftime("%Y-%m-%d")) | unique)[] as $d
    | [$d, ([$p[] | select((.t | strftime("%Y-%m-%d")) == $d) | .v] | max // 0 | tostring),
       ([$s[] | select((.t | strftime("%Y-%m-%d")) == $d) | .v] | max // 0 | tostring),
       ([$r[] | select((.t | strftime("%Y-%m-%d")) == $d) | .v] | max // 0 | tostring)] | @tsv' \
    "$TMP/h_pending.json" "$TMP/h_scheduling.json" "$TMP/h_running.json"
} | table
SINCE=$(jq -r '[.data.result[0].values[]? | {t: (.[0] | floor), v: (.[1] | tonumber)}] | . as $a
  | ([range(0; length) as $j | select($a[$j].v > 0 and ($a[$j:] | map(.v) | all(. > 0))) | $j] | first) as $i
  | if $i == null or $i == 0 then empty else $a[$i].t end' "$TMP/h_pending.json")
if [[ -n $SINCE ]]; then echo "  Migracje Pending sa obecne bez przerwy od ok.: $(fdate "$SINCE")"; fi
echo "  (metryki kubevirt_vmi_migrations_in_*_phase; w starszych wersjach CNV moga nie istniec - wtedy zera)"

sub "Aktywne alerty OpenShift Virtualization"
prom query "$TMP/al.json" "query=ALERTS{alertstate=\"firing\",namespace=\"$CNV_NS\"} or ALERTS{alertstate=\"firing\",alertname=~\"VMCannotBeEvicted|KubeVirt.*|LowKVM.*|LowVirt.*|Virt.*|OutdatedVirtualMachineInstanceWorkloads|KubeVirtNoAvailableNodesToRunVMs\"}" || true
{ printf 'ALERT\tWAGA\tLICZBA\tPRZYKLAD\n'
  jq -r '.data.result | group_by(.metric.alertname)[] | [.[0].metric.alertname, (.[0].metric.severity // "-"), (length | tostring),
     ([.[0].metric | (.namespace // ""), (.name // .vmi // .node // .pod // "")] | map(select(. != "")) | join("/"))] | @tsv' "$TMP/al.json"
} | table
NVMCBE=$(jq '[.data.result[] | select(.metric.alertname == "VMCannotBeEvicted")] | length' "$TMP/al.json")

# =============================================================================
# 9. LOGI virt-controller / virt-handler
# =============================================================================
hdr "9. LOGI virt-controller / virt-handler (ostatnie ${LOGH}h)"
if (( ! LOGS )); then echo "  Pominiete (-L)."
else
  norm() { sed -E 's/"(ts|timestamp|time)":"[^"]*",?//g; s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uid>/g;
                   s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/<ip>/g; s/[0-9]{2,}/N/g' | cut -c1-220; }
  sub "virt-controller - bledy i ostrzezenia o migracjach (najczestsze)"
  : >"$TMP/vc.log"
  for p in $(oc_ro get pods -n "$CNV_NS" -l kubevirt.io=virt-controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc_ro logs -n "$CNV_NS" "$p" --since="${LOGH}h" 2>/dev/null >>"$TMP/vc.log"
  done
  grep -iE 'migrat|evacuat|throttl' "$TMP/vc.log" | grep -iE '"level":"(error|warning)"|level=(error|warn)|[^a-z](E|W)[0-9]{4} |fail|unable|denied|exceed|timeout' \
    | sed -E 's/.*"msg":"([^"]*)".*/\1/; s/.*"reason":"([^"]*)".*/\1/' | norm | sort | uniq -c | sort -rn | head -12 | sed -E 's/^ *([0-9]+) /    \1x  /'
  [[ -s $TMP/vc.log ]] || echo "  (brak logow virt-controller - brak uprawnien?)"
  # virt-handler na nodach zrodlowych z najwieksza liczba oczekujacych migracji
  for n in $(jq -r 'group_by(.srcfull) | sort_by(-length) | .[:3][] | .[0].srcfull' "$TMP/cls.json"); do
    hp=$(jq -r --arg n "$n" '.items[] | select(.spec.nodeName == $n) | .metadata.name' "$TMP/handler.json" | head -1)
    [[ -z $hp ]] && continue
    sub "virt-handler na ${n%%.*} (zrodlo migracji) - bledy"
    oc_ro logs -n "$CNV_NS" "$hp" -c virt-handler --since="${LOGH}h" 2>/dev/null \
      | grep -iE '"level":"error"|level=error|migrat.*(fail|error)|failed' \
      | sed -E 's/.*"msg":"([^"]*)".*/\1/' | norm | sort | uniq -c | sort -rn | head -6 | sed -E 's/^ *([0-9]+) /    \1x  /'
  done
fi

# =============================================================================
# 10. PODSUMOWANIE
# =============================================================================
hdr "10. PODSUMOWANIE - DLACZEGO MIGRACJE STOJA I CO ZROBIC"
C_QCL=$(cnt KOLEJKA_KLASTER); C_QN=$(cnt KOLEJKA_NODE); C_MEM=$(cnt BRAK_MIEJSCA); C_NODE=$(cnt BRAK_PASUJACEGO_NODA)
C_NM=$(cnt NIEMIGROWALNA); C_ADM=$(cnt ODRZUCONE_PRZY_TWORZENIU); C_DUP=$(cnt DUPLIKAT); C_ORF=$(( $(cnt VMI_BRAK) + $(cnt VMI_NIE_DZIALA) ))
C_TS=$(( $(cnt POD_DOCELOWY_STARTUJE) + $(cnt POD_DOCELOWY_PADL) + $(cnt STORAGE) )); C_HS=$(cnt HANDSHAKE); C_UNK=$(cnt CZEKA_NA_KONTROLER)
C_VOL=$(cnt WOLUMEN_NIEGOTOWY); C_TERM=$(jq '[.[] | select(.term)] | length' "$TMP/cls.json")
C_RUN=$(cnt W_TOKU); C_RUNOLD=$(jq '[.[] | select(.c == "W_TOKU" and .age > 3600)] | length' "$TMP/cls.json")

if (( C_QCL + C_QN > 0 )); then
  msg="$(( C_QCL + C_QN )) migracji czeka w KOLEJCE (limit klastra $LIM_CL: $C_QCL, limit na node $LIM_PN: $C_QN). To normalne przy drainie lub aktualizacji, problemem jest dopiero kolejka, ktora nie maleje."
  (( NBLOCK > 0 )) && msg+=" UWAGA: $NBLOCK z $NACT aktywnych slotow zajmuja migracje, ktorych pod docelowy NIE MIESCI SIE na zadnym nodzie - blokuja kolejke do czasu timeoutu (unschedulablePendingTimeoutSeconds: $LIM_UNS), po czym ponawiaja probe. Najpierw usun przyczyne braku miejsca (ponizej)."
  msg+=" Gdy nody maja zapas, a siec przepustowosc, mozna podniesc parallelMigrationsPerCluster / parallelOutboundMigrationsPerNode w HyperConverged (spec.liveMigrationConfig)."
  finding 1 "$msg"
fi
(( C_MEM > 0 )) && finding 1 "$C_MEM migracji nie ma DOKAD pojsc - pasujace nody nie maja wolnych requestow pamieci/CPU dla VM (sekcja 6). Pod docelowy wymaga tyle samo co zrodlowy (pamiec VM + narzut virt-launchera); przy drainie ubywa calego noda pojemnosci. Dzialania: dodaj/odblokuj nody (uncordon zakonczonych), zatrzymaj zbedne VM, migruj mniejszymi partiami, rozwaz overcommit pamieci VM (memoryOvercommitPercentage w HCO) zgodnie z dokumentacja."
(( C_NODE > 0 )) && finding 1 "$C_NODE migracji nie ma PASUJACEGO noda (nodeSelector/affinity/tainty z poda VM; najczesciej model CPU - etykiety cpu-model-migration.node.kubevirt.io/* lub host-model). VM z cpu.model: host-passthrough albo konkretnym modelem moga migrowac tylko na identyczny sprzet. Porownaj nodeSelector poda virt-launcher z etykietami nodow; dla heterogenicznych nodow ustaw wspolny model CPU (HCO spec.defaultCPUModel lub w VM)."
(( C_NM > 0 )) && finding 1 "$C_NM migracji dotyczy VM, ktorych NIE DA SIE MIGROWAC (LiveMigratable=False; powody w sekcji 2 i 3). Typowo: dysk PVC RWO (potrzebny RWX/ block z RWX), interfejs bridge w sieci podow (uzyj masquerade), urzadzenia PCI/GPU/vGPU, SR-IOV bez obslugi migracji. Te migracje nie przejda nigdy - VM trzeba zatrzymac na czas drainu albo zmienic jej konfiguracje."
(( C_TERM > 0 )) && finding 1 "UWAGA - RYZYKO UTRATY DYSKU: $C_TERM VM ma dysk PVC w stanie Terminating (usuniety np. kaskadowo razem z DataVolume; trzyma go tylko finalizer pvc-protection, bo VM dziala). NIE zatrzymuj, nie restartuj i nie migruj tych VM - po zniknieciu poda virt-launcher dysk zostanie skasowany. Najpierw zabezpiecz dane (snapshot/klon PVC, backup z wnetrza VM) i zaplanuj odtworzenie dysku; szczegoly w sekcji 3."
(( C_VOL > 0 )) && finding 1 "$C_VOL migracji stoi, bo wolumen VM nie jest gotowy (sekcja 3). virt-controller przed utworzeniem poda docelowego sprawdza kazdy dysk: PVC z wlascicielem DataVolume wymaga istniejacego DataVolume w fazie Succeeded; komunikat 'unable to find datavolume' = PVC wskazuje na DataVolume, ktorego nie ma (usuniety albo PVC odtworzony z backupu z ownerReference). Gdy PVC NIE jest Terminating: odtworz obiekt DataVolume o tej nazwie dla istniejacego PVC (adopcja PVC przez CDI) albo usun z PVC ownerReference na nieistniejacy DataVolume - po weryfikacji z dokumentacja/supportem. Gdy DataVolume istnieje (oc get dv), a blad trwa - nieaktualny cache virt-controller (logi sekcja 9)."
(( C_ADM > 0 )) && finding 1 "$C_ADM migracji ma odrzucone utworzenie poda docelowego (komunikat w sekcji 3, kwoty w sekcji 7). Najczesciej ResourceQuota w namespace: pod docelowy liczy sie do kwoty RAZEM ze zrodlowym, wiec namespace potrzebuje zapasu na czas migracji (requests/limits pamieci i CPU, liczba podow)."
(( NQFULL > 0 && C_ADM == 0 )) && finding 2 "W namespace z oczekujacymi migracjami $NQFULL pozycji ResourceQuota jest wykorzystanych w >=90% - pod docelowy migracji moze nie zmiescic sie w kwocie (sekcja 7)."
(( C_DUP > 0 )) && finding 2 "$C_DUP migracji to duplikaty dla tej samej VM - aktywna moze byc tylko jedna, pozostale czekaja (np. reczna migracja + ewakuacja). Zbedne obiekty VMIM mozna usunac po weryfikacji."
(( C_ORF > 0 )) && finding 2 "$C_ORF migracji jest osieroconych (VM nie dziala lub nie istnieje) - nie zakoncza sie; do usuniecia po weryfikacji."
(( C_TS > 0 )) && finding 2 "$C_TS migracji ma pod docelowy, ktory nie wystartowal (wolumeny, siec, sandbox - komunikat w sekcji 3). Sprawdz eventy poda docelowego: oc describe pod <pod> -n <ns>."
(( C_HS > 0 )) && finding 2 "$C_HS migracji ma gotowy pod docelowy, ale nie rusza dalej - sprawdz logi virt-handler na zrodle i celu (sekcja 9) oraz siec migracyjna (NAD$([[ -n $MIGNET ]] && echo " $MIGNET"), MTU, firewall miedzy nodami)."
(( C_RUNOLD > 0 && V_DATA == 0 )) && finding 2 "$C_RUNOLD migracji przesyla pamiec dluzej niz 1h, a brak metryk postepu (sekcja 4) - prawdopodobnie VM zmienia pamiec szybciej, niz siec ja przesyla. Rozwaz allowAutoConverge / allowPostCopy (MigrationPolicy), wieksze bandwidthPerMigration albo dedykowana siec migracyjna; inaczej skonczy sie timeoutem (completionTimeoutPerGiB)."
(( C_UNK > 0 )) && finding 2 "$C_UNK migracji czeka bez widocznej przyczyny w obiektach - kluczowe sa logi virt-controller (sekcja 9); uruchom skrypt z -H 6."
(( NEVAC_NOMIG > 0 )) && finding 2 "$NEVAC_NOMIG VMI ma ustawione evacuationNodeName (node do opuszczenia), a nie ma dla nich migracji - virt-controller jeszcze ich nie utworzyl (kolejka) albo VM nie moga migrowac."
(( NBLKDRAIN > 0 )) && finding 1 "$NBLKDRAIN VM na nodach w cordonie ma evictionStrategy=LiveMigrate, a nie da sie ich migrowac - drain tych nodow (aktualizacja MCO) bedzie stal w nieskonczonosc (alert VMCannotBeEvicted)."
(( NVMCBE > 0 && NBLKDRAIN == 0 )) && finding 2 "Aktywny alert VMCannotBeEvicted ($NVMCBE) - sa VM, ktore zablokuja drain noda."
(( NPDBUSR > 0 )) && finding 2 "$NPDBUSR PDB uzytkownika z disruptionsAllowed=0 w namespace z VM - blokuja ewakuacje podow przy drainie (sekcja 7)."
(( NDRAIN > 0 )) && finding 3 "Drain w toku na $NDRAIN nodach (MCO) - stad migracje typu drain/ewakuacja. MCP aktualizuje nody po kolei (maxUnavailable); kazdy drain to nowa fala migracji."
(( NHNR == 0 && NKVF == 0 )) && finding 3 "virt-handler gotowy na wszystkich nodach, brak nodow z kubevirt.io/schedulable=false."
(( NCLS == 0 && NVMIM > 0 )) && finding 3 "Wszystkie migracje sa zakonczone (Succeeded/Failed) - nic nie czeka."
(( NVMIM == 0 )) && finding 3 "Brak obiektow migracji. Jesli VM pokazuja status Pending/Scheduling (a nie migracja), to problem ze startem VM - sprawdz pody virt-launcher w fazie Pending: oc get pods -A -l kubevirt.io=virt-launcher --field-selector=status.phase=Pending"
# --- migracje w toku (sekcja 4)
if (( V_NZ + V_BS + V_ND > 0 )); then
  msg="$(( V_NZ + V_BS + V_ND )) trwajacych migracji sie NIE ZBIEGA (sekcja 4: tempo zmian pamieci >= przesyl: $V_NZ, pozostala pamiec nie maleje: $V_BS, nie zdazy przed timeoutem: $V_ND) - skoncza sie bledem po completionTimeoutPerGiB i beda ponawiane."
  (( V_BW > 0 )) && msg+=" $V_BW z nich przesyla dokladnie z limitem bandwidthPerMigration ($LIM_BW) - podnies limit, jesli lacze ma zapas."
  (( V_NOAC > 0 )) && msg+=" $V_NOAC bez auto-converge: wlacz allowAutoConverge (MigrationPolicy dla tych VM lub HCO) - KubeVirt spowolni CPU VM, az migracja sie zbiegnie."
  (( V_NOPC > 0 )) && msg+=" Post-copy (allowPostCopy) konczy migracje zawsze, ale zerwanie sieci w tej fazie oznacza utrate VM - tylko przy stabilnej, dedykowanej sieci."
  [[ -z $MIGNET ]] && msg+=" Migracje ida siecia podow - dedykowana siec migracyjna (osobny interfejs) zwykle rozwiazuje problem."
  msg+=" Doraznie: przenies migracje na czas mniejszego obciazenia VM."
  finding 1 "$msg"
fi
(( V_PC > 0 )) && finding 3 "$V_PC migracji jest w fazie post-copy - VM dziala juz na nodzie docelowym; nie przerywaj sieci miedzy nodami do ich konca."
(( V_NM > 0 )) && finding 3 "Dla $V_NM trwajacych migracji brak metryk postepu (kubevirt_vmi_migration_*) - zbieznosci nie da sie ocenic; sprawdz: oc get vmim <nazwa> -n <ns> -o yaml i logi virt-handler zrodla."
# --- nieudane (sekcja 5)
if (( F_FAIL > 0 )); then
  F_TO=$(( $(cntf TIMEOUT_ZAKONCZENIA) + $(cntf BRAK_POSTEPU) )); F_NW=$(cntf NIE_WYSTARTOWALA); F_NET=$(cntf SIEC)
  F_CEL=$(cntf CEL_PADL); F_AB=$(cntf PRZERWANA); F_ST=$(cntf STORAGE); F_QE=$(cntf QEMU_LIBVIRT)
  pr=2; (( F_FAIL * 100 / (F_TOT > 0 ? F_TOT : 1) >= 20 )) && pr=1
  msg="Nieudanych migracji: $F_FAIL z $F_TOT zakonczonych widocznych w obiektach (sekcja 5)."
  (( F_TO > 0 )) && msg+=" $F_TO przez TIMEOUT / brak postepu - VM zmienia pamiec szybciej niz przesyl: auto-converge, post-copy, wieksze bandwidthPerMigration, dedykowana siec migracyjna, ewentualnie wiekszy completionTimeoutPerGiB."
  (( F_NW > 0 )) && msg+=" $F_NW nie wystartowalo - pod docelowy nie zmiescil sie na zadnym nodzie do timeoutu Pending (miejsce w sekcji 6, dopasowanie nodow w sekcji 3)."
  (( F_NET > 0 )) && msg+=" $F_NET z bledem sieci - polaczenie miedzy virt-handlerami (siec migracyjna, MTU, firewall; sekcja 1 i logi w sekcji 9)."
  (( F_CEL > 0 )) && msg+=" $F_CEL - pod docelowy padl (eventy/logi virt-launcher na nodzie docelowym; czesto brak pamieci noda lub zabicie przez OOM)."
  (( F_AB > 0 )) && msg+=" $F_AB przerwanych (usuniety obiekt VMIM, anulowanie drainu/aktualizacji albo abort) - zwykle nie blad platformy."
  (( F_ST > 0 )) && msg+=" $F_ST z bledem dyskow - sprawdz PVC/DataVolume VM (sekcja 7)."
  (( F_QE > 0 )) && msg+=" $F_QE z bledem QEMU/libvirt - czesto niezgodny model/funkcje CPU na celu (sekcja 7: host-passthrough)."
  finding "$pr" "$msg"
  BADNODE=$(jq -r --argjson f "$F_FAIL" '[.[] | select(.ph == "Failed") | [.src, .dst] | unique[] | select(. != "-")]
     | group_by(.) | map({n: .[0], c: length}) | sort_by(-.c) | .[0] // empty
     | select(.c >= 3 and .c * 2 >= $f) | "\(.n | split(".")[0]) \(.c)"' "$TMP/fin.json")
  [[ -n $BADNODE ]] && finding 1 "Node ${BADNODE% *} uczestniczy w ${BADNODE#* } z $F_FAIL nieudanych migracji (jako zrodlo lub cel) - co najmniej polowa porazek: sprawdz jego siec (interfejs migracyjny, MTU), virt-handler i obciazenie (sekcja 5)."
fi
# --- cechy VM (sekcja 7)
(( N_FBLK_LM > 0 )) && finding 1 "$N_FBLK_LM VM ma ceche BLOKUJACA migracje (GPU/PCI, dysk bez RWX, bridge w sieci podow...) a strategie eviction LiveMigrate - przy najblizszym drainie noda (aktualizacja klastra) zablokuja go. Lista i co zrobic: sekcja 7."
(( N_FBLK > N_FBLK_LM )) && finding 3 "$(( N_FBLK - N_FBLK_LM )) VM z cecha blokujaca migracje ma evictionStrategy None/External - przy drainie zostana wylaczone albo czekaja na zewnetrzny kontroler (sekcja 7)."
(( N_FHPT > 0 && C_NODE > 0 )) && finding 2 "$N_FHPT VM uzywa CPU host-passthrough - moga migrowac tylko na nody z identycznym CPU; to moze tlumaczyc BRAK_PASUJACEGO_NODA (sekcja 3, 7)."
(( N_FNOEV > 0 )) && finding 3 "$N_FNOEV VM ma evictionStrategy None/External - przy drainie nie migruja (sekcja 7)."
(( F_TOT > 0 && F_FAIL == 0 )) && finding 3 "Wszystkie $F_TOT zakonczone migracje widoczne w obiektach VMIM sie udaly."

for p in 1 2 3; do
  case $p in 1) t="NAJWAZNIEJSZE";; 2) t="DO SPRAWDZENIA";; 3) t="INFORMACYJNIE";; esac
  n=$(awk -F'\t' -v p="$p" '$1==p' "$TMP/findings" | wc -l); (( n == 0 )) && continue
  sub "$t ($n)"
  awk -F'\t' -v p="$p" '$1==p {print $2}' "$TMP/findings" | while IFS= read -r l; do say "$l"; echo; done
done
echo "Koniec diagnostyki. Nic nie zostalo zmienione w klastrze."
