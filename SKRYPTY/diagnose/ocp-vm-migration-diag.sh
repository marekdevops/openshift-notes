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
# Skrypt dla kazdej oczekujacej migracji ustala PRZYCZYNE i DOWOD, liczy wolne miejsce
# dla VM na nodach, pokazuje blokady drainu (PDB, VM niemigrowalne, MCP), kwoty
# w namespace, historie z Prometheusa, logi virt-controller / virt-handler
# i na koncu PODSUMOWANIE z dzialaniami.
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

Jak czytac: sekcja 1 - konfiguracja i stan platformy (limity kolejki, virt-handler, MCP),
sekcja 2 - ile migracji i w jakich fazach, sekcja 3 - PRZYCZYNA dla kazdej oczekujacej
migracji, sekcje 4-7 - dowody (miejsce na nodach, blokady, historia, logi).
Wnioski i dzialania: PODSUMOWANIE na koncu.
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
if [[ -n $MIGNET ]]; then
  if oc_ro get network-attachment-definitions.k8s.cni.cncf.io "$MIGNET" -n "$CNV_NS" -o name >/dev/null 2>&1; then
    echo "  Dedykowana siec migracyjna: $MIGNET (NetworkAttachmentDefinition istnieje)"
  else
    echo "  Dedykowana siec migracyjna: $MIGNET - NIE ZNALEZIONO NetworkAttachmentDefinition w $CNV_NS!"
    finding 1 "HyperConverged wskazuje siec migracyjna '$MIGNET', ale nie ma takiej NetworkAttachmentDefinition w $CNV_NS - migracje nie moga zestawic polaczenia."
  fi
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
  printf ',"quota":'; cat "$TMP/quota.json"; printf '}'; } >"$TMP/all.json"

jq -c --argjson now "$NOW" --argjson lcl "$LIM_CL" --argjson lpn "$LIM_PN" --argjson freeok "$FREE_OK" "$JQDEF"'
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
  | ([$vmi.status.conditions[]? | select(.type == "LiveMigratable")][0]) as $lm
  | ([$tp.status.conditions[]? | select(.type == "PodScheduled" and .status == "False")][0].message // "") as $sched
  | (evmsg($ev; $ns; [$m.metadata.name, $vn] + (if $tp then [$tp.metadata.name] else [] end))) as $evs
  | ([$evs[] | select(.type == "Warning")] | last // null) as $lastw
  | ([$evs[] | select(.msg | test("quota|LimitRange|forbidden|denied the request|admission webhook"; "i"))] | last // null) as $adm
  | ([$evs[] | select(.reason == "FailedMount" or .reason == "FailedAttachVolume" or .reason == "FailedCreatePodSandBox")] | last // null) as $mnt
  | ($now - ($m.metadata.creationTimestamp | ts)) as $age
  | (if $vmi == null then {c: "VMI_BRAK", d: "VMI nie istnieje (VM wylaczona/usunieta) - migracja jest osierocona"}
     elif $vmi.status.phase != "Running" then {c: "VMI_NIE_DZIALA", d: "VMI w fazie \($vmi.status.phase // "-")"}
     elif $lm != null and $lm.status == "False" then {c: "NIEMIGROWALNA", d: "\($lm.reason // "-"): \($lm.message // "" | .[0:150])"}
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
     elif ($ph | pending) then {c: "CZEKA_NA_KONTROLER", d: "brak poda docelowego i brak widocznej blokady\(if $lastw then " - ostatni event: \($lastw.reason) \($lastw.msg[0:100])" else "" end) - logi virt-controller (sekcja 7)"}
     else {c: "INNA", d: "faza \($ph)"} end) as $cause
  | {ns: $ns, mig: $m.metadata.name, vmi: $vn, ph: $ph, age: $age, ages: ($age | age), src: ($src | split(".")[0]), srcfull: $src,
     origin: ($m.metadata.name | origin), c: $cause.c, d: $cause.d, rqm: $rqm, rqc: $rqc,
     cand: ($cand | length), fit: ($fit | length), tp: ($tp.metadata.name // "-"), tpnode: ($tp.spec.nodeName // "-"),
     lmr: ($lm.reason // ""), evict: ($vmi.spec.evictionStrategy // "-")}' "$TMP/all.json" >"$TMP/cls.jsonl" 2>"$TMP/cls.err"
[[ -s $TMP/cls.err ]] && warn "klasyfikacja: $(head -c 300 "$TMP/cls.err")"
jq -s '.' "$TMP/cls.jsonl" >"$TMP/cls.json"
NCLS=$(jq 'length' "$TMP/cls.json")

desc_cause() { case $1 in
  KOLEJKA_KLASTER) echo "kolejka - wyczerpany limit migracji w klastrze";;
  KOLEJKA_NODE) echo "kolejka - wyczerpany limit migracji wychodzacych z noda";;
  BRAK_MIEJSCA) echo "brak wolnej pamieci/CPU na pasujacych nodach (requesty)";;
  BRAK_PASUJACEGO_NODA) echo "zaden node nie pasuje (nodeSelector/affinity/model CPU/tainty)";;
  NIEMIGROWALNA) echo "VM nie da sie migrowac (LiveMigratable=False)";;
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
# 4. MIEJSCE NA NODACH DLA VM
# =============================================================================
hdr "4. MIEJSCE DLA VM NA NODACH (requesty vs allocatable)"
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
# 5. BLOKADY: QUOTA, PDB, VM NIEMIGROWALNE PRZY DRAINIE, DYSKI RWO
# =============================================================================
hdr "5. BLOKADY: KWOTY, PDB, VM NIEMIGROWALNE, DYSKI"
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

sub "Dyski VM niemigrowalnych (PVC i tryb dostepu)"
NSL=$(jq -r '[.items[] | select(any(.status.conditions[]?; .type == "LiveMigratable" and .status == "False" and ((.reason // "") | test("Disk|Volume|Storage"; "i")))) | .metadata.namespace] | unique | .[]' "$TMP/vmi.json")
: >"$TMP/pvc.jsonl"
for ns in $NSL; do oc_ro get pvc -n "$ns" -o json 2>/dev/null | jq -c '.items[]' >>"$TMP/pvc.jsonl"; done
{ printf 'NAMESPACE\tVM\tPVC\tTRYB\tSTORAGECLASS\tVOLUMEMODE\n'
  jq -s -r --slurpfile v "$TMP/vmi.json" '(map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $p
    | $v[0].items[] | select(any(.status.conditions[]?; .type == "LiveMigratable" and .status == "False" and ((.reason // "") | test("Disk|Volume|Storage"; "i"))))
    | .metadata.namespace as $ns | .metadata.name as $vm
    | .spec.volumes[]? | (.persistentVolumeClaim.claimName // .dataVolume.name // empty) as $c | $p["\($ns)/\($c)"] as $pc
    | [$ns, $vm, $c, ($pc.spec.accessModes // ["?"] | join(",")), ($pc.spec.storageClassName // "-"), ($pc.spec.volumeMode // "-")] | @tsv' "$TMP/pvc.jsonl" | head -n "$TOPN"
} | table

# =============================================================================
# 6. HISTORIA I ALERTY (Prometheus)
# =============================================================================
hdr "6. HISTORIA MIGRACJI I ALERTY (Prometheus, $HDAYS dni)"
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
# 7. LOGI virt-controller / virt-handler
# =============================================================================
hdr "7. LOGI virt-controller / virt-handler (ostatnie ${LOGH}h)"
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
# 8. PODSUMOWANIE
# =============================================================================
hdr "8. PODSUMOWANIE - DLACZEGO MIGRACJE STOJA I CO ZROBIC"
C_QCL=$(cnt KOLEJKA_KLASTER); C_QN=$(cnt KOLEJKA_NODE); C_MEM=$(cnt BRAK_MIEJSCA); C_NODE=$(cnt BRAK_PASUJACEGO_NODA)
C_NM=$(cnt NIEMIGROWALNA); C_ADM=$(cnt ODRZUCONE_PRZY_TWORZENIU); C_DUP=$(cnt DUPLIKAT); C_ORF=$(( $(cnt VMI_BRAK) + $(cnt VMI_NIE_DZIALA) ))
C_TS=$(( $(cnt POD_DOCELOWY_STARTUJE) + $(cnt POD_DOCELOWY_PADL) + $(cnt STORAGE) )); C_HS=$(cnt HANDSHAKE); C_UNK=$(cnt CZEKA_NA_KONTROLER)
C_RUN=$(cnt W_TOKU); C_RUNOLD=$(jq '[.[] | select(.c == "W_TOKU" and .age > 3600)] | length' "$TMP/cls.json")

if (( C_QCL + C_QN > 0 )); then
  msg="$(( C_QCL + C_QN )) migracji czeka w KOLEJCE (limit klastra $LIM_CL: $C_QCL, limit na node $LIM_PN: $C_QN). To normalne przy drainie lub aktualizacji, problemem jest dopiero kolejka, ktora nie maleje."
  (( NBLOCK > 0 )) && msg+=" UWAGA: $NBLOCK z $NACT aktywnych slotow zajmuja migracje, ktorych pod docelowy NIE MIESCI SIE na zadnym nodzie - blokuja kolejke do czasu timeoutu (unschedulablePendingTimeoutSeconds: $LIM_UNS), po czym ponawiaja probe. Najpierw usun przyczyne braku miejsca (ponizej)."
  msg+=" Gdy nody maja zapas, a siec przepustowosc, mozna podniesc parallelMigrationsPerCluster / parallelOutboundMigrationsPerNode w HyperConverged (spec.liveMigrationConfig)."
  finding 1 "$msg"
fi
(( C_MEM > 0 )) && finding 1 "$C_MEM migracji nie ma DOKAD pojsc - pasujace nody nie maja wolnych requestow pamieci/CPU dla VM (sekcja 4). Pod docelowy wymaga tyle samo co zrodlowy (pamiec VM + narzut virt-launchera); przy drainie ubywa calego noda pojemnosci. Dzialania: dodaj/odblokuj nody (uncordon zakonczonych), zatrzymaj zbedne VM, migruj mniejszymi partiami, rozwaz overcommit pamieci VM (memoryOvercommitPercentage w HCO) zgodnie z dokumentacja."
(( C_NODE > 0 )) && finding 1 "$C_NODE migracji nie ma PASUJACEGO noda (nodeSelector/affinity/tainty z poda VM; najczesciej model CPU - etykiety cpu-model-migration.node.kubevirt.io/* lub host-model). VM z cpu.model: host-passthrough albo konkretnym modelem moga migrowac tylko na identyczny sprzet. Porownaj nodeSelector poda virt-launcher z etykietami nodow; dla heterogenicznych nodow ustaw wspolny model CPU (HCO spec.defaultCPUModel lub w VM)."
(( C_NM > 0 )) && finding 1 "$C_NM migracji dotyczy VM, ktorych NIE DA SIE MIGROWAC (LiveMigratable=False; powody w sekcji 2 i 3). Typowo: dysk PVC RWO (potrzebny RWX/ block z RWX), interfejs bridge w sieci podow (uzyj masquerade), urzadzenia PCI/GPU/vGPU, SR-IOV bez obslugi migracji. Te migracje nie przejda nigdy - VM trzeba zatrzymac na czas drainu albo zmienic jej konfiguracje."
(( C_ADM > 0 )) && finding 1 "$C_ADM migracji ma odrzucone utworzenie poda docelowego (komunikat w sekcji 3, kwoty w sekcji 5). Najczesciej ResourceQuota w namespace: pod docelowy liczy sie do kwoty RAZEM ze zrodlowym, wiec namespace potrzebuje zapasu na czas migracji (requests/limits pamieci i CPU, liczba podow)."
(( NQFULL > 0 && C_ADM == 0 )) && finding 2 "W namespace z oczekujacymi migracjami $NQFULL pozycji ResourceQuota jest wykorzystanych w >=90% - pod docelowy migracji moze nie zmiescic sie w kwocie (sekcja 5)."
(( C_DUP > 0 )) && finding 2 "$C_DUP migracji to duplikaty dla tej samej VM - aktywna moze byc tylko jedna, pozostale czekaja (np. reczna migracja + ewakuacja). Zbedne obiekty VMIM mozna usunac po weryfikacji."
(( C_ORF > 0 )) && finding 2 "$C_ORF migracji jest osieroconych (VM nie dziala lub nie istnieje) - nie zakoncza sie; do usuniecia po weryfikacji."
(( C_TS > 0 )) && finding 2 "$C_TS migracji ma pod docelowy, ktory nie wystartowal (wolumeny, siec, sandbox - komunikat w sekcji 3). Sprawdz eventy poda docelowego: oc describe pod <pod> -n <ns>."
(( C_HS > 0 )) && finding 2 "$C_HS migracji ma gotowy pod docelowy, ale nie rusza dalej - sprawdz logi virt-handler na zrodle i celu (sekcja 7) oraz siec migracyjna (NAD$([[ -n $MIGNET ]] && echo " $MIGNET"), MTU, firewall miedzy nodami)."
(( C_RUNOLD > 0 )) && finding 2 "$C_RUNOLD migracji przesyla pamiec dluzej niz 1h - VM zmienia pamiec szybciej, niz siec ja przesyla (nie zbiega sie). Rozwaz allowAutoConverge / allowPostCopy (MigrationPolicy), wieksze bandwidthPerMigration albo dedykowana siec migracyjna; inaczej skonczy sie timeoutem (completionTimeoutPerGiB)."
(( C_UNK > 0 )) && finding 2 "$C_UNK migracji czeka bez widocznej przyczyny w obiektach - kluczowe sa logi virt-controller (sekcja 7); uruchom skrypt z -H 6."
(( NEVAC_NOMIG > 0 )) && finding 2 "$NEVAC_NOMIG VMI ma ustawione evacuationNodeName (node do opuszczenia), a nie ma dla nich migracji - virt-controller jeszcze ich nie utworzyl (kolejka) albo VM nie moga migrowac."
(( NBLKDRAIN > 0 )) && finding 1 "$NBLKDRAIN VM na nodach w cordonie ma evictionStrategy=LiveMigrate, a nie da sie ich migrowac - drain tych nodow (aktualizacja MCO) bedzie stal w nieskonczonosc (alert VMCannotBeEvicted)."
(( NVMCBE > 0 && NBLKDRAIN == 0 )) && finding 2 "Aktywny alert VMCannotBeEvicted ($NVMCBE) - sa VM, ktore zablokuja drain noda."
(( NPDBUSR > 0 )) && finding 2 "$NPDBUSR PDB uzytkownika z disruptionsAllowed=0 w namespace z VM - blokuja ewakuacje podow przy drainie (sekcja 5)."
(( NDRAIN > 0 )) && finding 3 "Drain w toku na $NDRAIN nodach (MCO) - stad migracje typu drain/ewakuacja. MCP aktualizuje nody po kolei (maxUnavailable); kazdy drain to nowa fala migracji."
(( NHNR == 0 && NKVF == 0 )) && finding 3 "virt-handler gotowy na wszystkich nodach, brak nodow z kubevirt.io/schedulable=false."
(( NCLS == 0 && NVMIM > 0 )) && finding 3 "Wszystkie migracje sa zakonczone (Succeeded/Failed) - nic nie czeka."
(( NVMIM == 0 )) && finding 3 "Brak obiektow migracji. Jesli VM pokazuja status Pending/Scheduling (a nie migracja), to problem ze startem VM - sprawdz pody virt-launcher w fazie Pending: oc get pods -A -l kubevirt.io=virt-launcher --field-selector=status.phase=Pending"
(( NFAIL > 0 )) && finding 3 "Nieudanych migracji (obiekty Failed): $NFAIL - powod w .status.migrationState.failureReason (oc get vmim -A -o yaml); powtarzajace sie porazki przy postepie = VM zmienia pamiec szybciej niz siec przesyla (rozwaz allowAutoConverge / allowPostCopy / wieksze bandwidth)."

for p in 1 2 3; do
  case $p in 1) t="NAJWAZNIEJSZE";; 2) t="DO SPRAWDZENIA";; 3) t="INFORMACYJNIE";; esac
  n=$(awk -F'\t' -v p="$p" '$1==p' "$TMP/findings" | wc -l); (( n == 0 )) && continue
  sub "$t ($n)"
  awk -F'\t' -v p="$p" '$1==p {print $2}' "$TMP/findings" | while IFS= read -r l; do say "$l"; echo; done
done
echo "Koniec diagnostyki. Nic nie zostalo zmienione w klastrze."
