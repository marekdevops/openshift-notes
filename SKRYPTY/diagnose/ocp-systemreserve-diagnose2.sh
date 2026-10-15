#!/usr/bin/env bash
# =============================================================================
#  ocp-sysreserved-sizing.sh  v2
#  Analiza SystemMemoryExceedsReservation, dobór systemReserved per profil
#  nodów oraz kondycja kubeleta/crio i warstwy wirtualizacji.
#
#  TYLKO ODCZYT — skrypt niczego nie wdraża ani nie zmienia w klastrze.
#  Proponowane YAML-e i polecenia są wyłącznie WYPISYWANE (opcjonalnie
#  zapisywane do lokalnego katalogu OUT_DIR).
#
#  Użycie:
#     ./ocp-sysreserved-sizing.sh [pula]
#
#  Przykłady:
#     ./ocp-sysreserved-sizing.sh worker
#     DAYS=7 ./ocp-sysreserved-sizing.sh worker
#     OUT_DIR=./propozycja ./ocp-sysreserved-sizing.sh worker
#     ANONYMIZE=1 ./ocp-sysreserved-sizing.sh
#
#  Zmienne (opcjonalne):
#     DAYS=14            maks. okres analizy (skracany automatycznie do retencji)
#     MARGIN=1.5         zapas nad szczytem pamięci / p99 CPU
#     MIN_MEM_GIB=2      minimalna rekomendowana rezerwacja pamięci
#     MIN_CPU_M=500      minimalna rekomendowana rezerwacja CPU
#     NEAR_PCT=85        próg ostrzeżenia „blisko alertu” (alert: 95%)
#     GROWTH_DAYS=3      okno liczenia trendu (ostatnie N dni)
#     WARMUP_DAYS=2      ile dni po reboocie pomijać (rozgrzewanie kubelet/crio)
#     LEAK_PCT_DAY=5     wzrost %/dobę uznawany za podejrzenie wycieku
#     PROFILE_STEP=1.25  nody różniące się RAM-em o więcej niż ×1.25 trafiają
#                        do różnych profili
#     STEAL_WARN=5       próg steal time (%)
#     PLEG_WARN=0.5      próg p99 PLEG relist (s)
#     RT_WARN=1          próg p99 operacji runtime/crio (s)
#     RESTART_WARN=50    próg restartów kontenerów na nodzie na dobę
#     OUT_DIR=           katalog lokalny na proponowane YAML-e (domyślnie brak)
#     ANONYMIZE=1        zamaskuj nazwy nodów, domenę, użytkownika
#
#  Wymaga: oc (cluster-admin lub cluster-monitoring-view + odczyt nodów/podów),
#          jq, dostęp `oc exec` do prometheus-k8s-0.
# =============================================================================
set -o pipefail

POOL_FILTER=${1:-}
DAYS=${DAYS:-14}
MARGIN=${MARGIN:-1.5}
MIN_MEM_GIB=${MIN_MEM_GIB:-2}
MIN_CPU_M=${MIN_CPU_M:-500}
NEAR_PCT=${NEAR_PCT:-85}
GROWTH_DAYS=${GROWTH_DAYS:-3}
WARMUP_DAYS=${WARMUP_DAYS:-2}
LEAK_PCT_DAY=${LEAK_PCT_DAY:-5}
PROFILE_STEP=${PROFILE_STEP:-1.25}
STEAL_WARN=${STEAL_WARN:-5}
PLEG_WARN=${PLEG_WARN:-0.5}
RT_WARN=${RT_WARN:-1}
RESTART_WARN=${RESTART_WARN:-50}
OUT_DIR=${OUT_DIR:-}
ANONYMIZE=${ANONYMIZE:-0}

if [[ -t 1 ]]; then
  R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[34m'; C=$'\e[36m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=''; Y=''; G=''; B=''; C=''; BOLD=''; N=''
fi

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

declare -a F_CRIT=() F_WARN=() F_INFO=()
crit() { F_CRIT+=("$*"); printf '  %s[CRIT]%s %s\n' "$R" "$N" "$*"; }
warn() { F_WARN+=("$*"); printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; }
info() { F_INFO+=("$*"); printf '  %s[INFO]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$*"; }
line() { printf '         %s\n' "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$BOLD$B" "$*" "$N"; }
die()  { printf '%sBŁĄD:%s %s\n' "$R" "$N" "$*" >&2; exit 2; }
usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ------------------------------------------------------------------ PromQL
# prom "<zapytanie>" <plik> [jq-wyrażenie klucza]
prom() {
  local q=$1 out=$2 key=${3:-'(.metric.node // .metric.instance // "")'}
  oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
     curl -sG --data-urlencode "query=$q" http://localhost:9090/api/v1/query 2>/dev/null \
  | jq -r ".data.result[]? | select(.value[1] != \"NaN\" and .value[1] != \"+Inf\") | \"\($key)|\(.value[1])\"" >"$out" 2>/dev/null
  [[ -s $out ]]
}
getv() { awk -F'|' -v n="$1" '$1==n{print $2; exit}' "$2"; }

# ----------------------------------------------------------------- formaty
gib()  { awk -v b="${1:-0}" 'BEGIN{ printf "%.2f", (b+0)/1073741824 }'; }
mcore(){ awk -v c="${1:-0}" 'BEGIN{ printf "%.0f", (c+0)*1000 }'; }
f1()   { awk -v v="${1:-0}" 'BEGIN{ printf "%.1f", v+0 }'; }
fgt()  { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit !(a+0 > b+0) }'; }
fge()  { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit !(a+0 >= b+0) }'; }
short(){ local s=${1%%.*}; echo "${s:0:${2:-18}}"; }
rec_mem() { awk -v b="${1:-0}" -v m="$MARGIN" -v min="$MIN_MEM_GIB" 'BEGIN{
  g=b*m/1073741824; r=int(g*2); if (r < g*2) r++; r=r/2; if (r<min) r=min; printf "%g", r }'; }
rec_cpu() { awk -v c="${1:-0}" -v m="$MARGIN" -v min="$MIN_CPU_M" 'BEGIN{
  v=c*1000*m; r=int(v/100); if (r*100 < v) r++; r=r*100; if (r<min) r=min; printf "%d", r }'; }

# =============================================================================
main() {
  [[ $POOL_FILTER == -h || $POOL_FILTER == --help ]] && usage
  command -v oc >/dev/null 2>&1 || die "brak polecenia oc w PATH"
  command -v jq >/dev/null 2>&1 || die "brak jq w PATH (wymagane)"
  oc whoami >/dev/null 2>&1     || die "brak zalogowania do klastra (oc login)"

  printf '%sAnaliza rezerwacji systemowej i kondycji nodów (v2)%s%s\n' "$BOLD" "$N" "${POOL_FILTER:+ — pula: $POOL_FILTER}"
  printf 'Klaster: %s   użytkownik: %s   %s\n' "$(oc whoami --show-server 2>/dev/null)" "$(oc whoami 2>/dev/null)" "$(date '+%F %T')"
  printf '%sTryb tylko do odczytu — nic nie jest wdrażane.%s\n' "$BOLD" "$N"
  printf '\nZbieranie danych (kilkadziesiąt zapytań do Prometheusa, do 1–2 minut)...\n'

  # ---------------------------------------------------------------- API
  oc get nodes -o json >"$TMP/nodes.json" 2>/dev/null || die "nie udało się pobrać nodów"
  oc get kubeletconfig -o json >"$TMP/kc.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/kc.json"
  oc get mcp -o json >"$TMP/mcp.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/mcp.json"
  oc get pods -A -o json >"$TMP/pods.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/pods.json"

  local JQMEM='def mem: tostring |
      if test("Ki$") then (.[:-2]|tonumber)*1024
      elif test("Mi$") then (.[:-2]|tonumber)*1048576
      elif test("Gi$") then (.[:-2]|tonumber)*1073741824
      elif test("Ti$") then (.[:-2]|tonumber)*1099511627776
      elif test("k$") then (.[:-1]|tonumber)*1000
      elif test("M$") then (.[:-1]|tonumber)*1000000
      elif test("G$") then (.[:-1]|tonumber)*1000000000
      elif test("m$") then (.[:-1]|tonumber)/1000
      else tonumber end;
    def cpu: tostring | if test("m$") then (.[:-1]|tonumber) else (tonumber*1000) end;'

  # node|pula|capMem|allocMem|capCpu(m)|allocCpu(m)
  jq -r "$JQMEM"'
    .items[] |
    [ .metadata.name,
      ((.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "none") | sub("^rendered-";"") | sub("-[0-9a-f]+$";"")),
      (.status.capacity.memory | mem), (.status.allocatable.memory | mem),
      (.status.capacity.cpu | cpu), (.status.allocatable.cpu | cpu)
    ] | map(tostring) | join("|")' "$TMP/nodes.json" >"$TMP/nodes.txt"

  # requests pamięci per node
  jq -r "$JQMEM"'
    [ .items[] | select(.spec.nodeName != null and .status.phase != "Succeeded" and .status.phase != "Failed")
      | {n: .spec.nodeName, r: ([.spec.containers[]?.resources.requests.memory // "0" | mem] | add // 0)} ]
    | group_by(.n)[] | "\(.[0].n)|\(map(.r) | add)"' "$TMP/pods.json" >"$TMP/req.txt" 2>/dev/null

  # liczba probe typu exec per node
  jq -r '
    [ .items[] | select(.spec.nodeName != null and .status.phase == "Running")
      | {n: .spec.nodeName, e: ([.spec.containers[]? | (.livenessProbe.exec, .readinessProbe.exec, .startupProbe.exec) | select(. != null)] | length)} ]
    | group_by(.n)[] | "\(.[0].n)|\(map(.e) | add)"' "$TMP/pods.json" >"$TMP/exec.txt" 2>/dev/null

  # ---------------------------------------------------------- okno danych
  local SEL='container_memory_rss{id="/system.slice"}'
  local SELC='container_cpu_usage_seconds_total{id="/system.slice"}'
  local SVC='container_memory_rss{id=~"/system.slice/[^/]+[.]service"}'
  local now earliest avail EFF
  now=$(date +%s)
  prom "min_over_time(timestamp(count($SEL))[${DAYS}d:1h])" "$TMP/earliest.txt" '"x"' || true
  earliest=$(cut -d'|' -f2 "$TMP/earliest.txt" 2>/dev/null)
  if [[ -n $earliest ]]; then
    avail=$(awk -v n="$now" -v e="$earliest" 'BEGIN{ printf "%d", (n-e)/86400 }')
  else avail=$DAYS; fi
  EFF=$DAYS; (( avail < EFF )) && EFF=$avail; (( EFF < 1 )) && EFF=1
  local GD=$GROWTH_DAYS; (( GD > EFF )) && GD=$EFF

  # ---------------------------------------------------------- metryki
  prom "sum by (node) ($SEL)" "$TMP/cur.txt" || die "brak danych z Prometheusa (container_memory_rss /system.slice) — sprawdź dostęp do prometheus-k8s-0"
  prom "max_over_time(sum by (node) ($SEL)[${EFF}d:10m])" "$TMP/peak.txt"
  prom "quantile_over_time(0.99, sum by (node) (rate(${SELC}[5m]))[${EFF}d:10m])" "$TMP/cpup99.txt"
  prom "max_over_time(sum by (node) (rate(${SELC}[5m]))[${EFF}d:10m])" "$TMP/cpumax.txt"
  prom 'count by (node) (ALERTS{alertname="SystemMemoryExceedsReservation",alertstate="firing"})' "$TMP/alerts.txt"
  prom '(time() - node_boot_time_seconds) / 86400' "$TMP/uptime.txt"
  prom "deriv(sum by (node) ($SEL)[${GD}d:30m])" "$TMP/deriv.txt"
  prom 'max by (node) (kubelet_running_pods)' "$TMP/pods_now.txt"
  prom "deriv(max by (node) (kubelet_running_pods)[${GD}d:30m])" "$TMP/pods_deriv.txt"
  prom 'max by (node) (kubelet_running_containers{container_state="running"})' "$TMP/cont.txt"
  prom "max by (node, id) ($SVC)" "$TMP/svc_now.txt" '"\(.metric.node)|\(.metric.id | sub("^/system.slice/";""))"'
  prom "deriv(max by (node, id) ($SVC)[${GD}d:30m])" "$TMP/svc_deriv.txt" '"\(.metric.node)|\(.metric.id | sub("^/system.slice/";""))"'
  prom "topk(40, max by (node, id) (rate(container_cpu_usage_seconds_total{id=~\"/system.slice/[^/]+[.]service\"}[1h])))" "$TMP/svc_cpu.txt" '"\(.metric.node)|\(.metric.id | sub("^/system.slice/";""))"'
  # wydajność
  prom 'histogram_quantile(0.99, sum by (node, le) (rate(kubelet_pleg_relist_duration_seconds_bucket[1h])))' "$TMP/pleg.txt"
  prom 'histogram_quantile(0.99, sum by (node, operation_type, le) (rate(kubelet_runtime_operations_duration_seconds_bucket{operation_type!~".*image.*"}[1h])))' "$TMP/rt.txt" '"\(.metric.node)|\(.metric.operation_type)"'
  prom 'histogram_quantile(0.99, sum by (node, le) (rate(kubelet_pod_start_sli_duration_seconds_bucket[1d])))' "$TMP/podstart.txt"
  prom 'sum by (node) (increase(kube_pod_container_status_restarts_total[1d]) * on (namespace, pod) group_left(node) topk by (namespace, pod) (1, kube_pod_info))' "$TMP/restarts.txt"
  prom 'topk(5, sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1d])) > 10)' "$TMP/toprestart.txt" '"\(.metric.namespace)/\(.metric.pod)"'
  prom 'max_over_time((avg by (instance) (rate(node_cpu_seconds_total{mode="steal"}[5m])))[1d:5m]) * 100' "$TMP/steal_max.txt"
  prom 'avg_over_time((avg by (instance) (rate(node_cpu_seconds_total{mode="steal"}[5m])))[1d:5m]) * 100' "$TMP/steal_avg.txt"
  prom 'avg_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))[1d:5m]) * 100' "$TMP/cpu_avg.txt"
  prom 'max_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))[1d:5m]) * 100' "$TMP/cpu_max.txt"

  # najgorsza operacja runtime per node
  awk -F'|' '{ if (!($1 in m) || $3+0 > m[$1]+0) { m[$1]=$3; o[$1]=$2 } } END{ for (k in m) print k "|" m[k] "|" o[k] }' "$TMP/rt.txt" >"$TMP/rt_max.txt"

  # ---------------------------------------------------------- wiersze
  # node|pool|capMem|allocMem|capCpu|allocCpu|resMem|resCpu|cur|peak|p99|cpumax|alert|uptime|growth%d|pods%d|pct
  : >"$TMP/rows.txt"
  local n pool cm am cc ac res resc cur peak p99 cmx al up dv gr pn pd pg pct
  while IFS='|' read -r n pool cm am cc ac; do
    [[ -n $POOL_FILTER && $pool != "$POOL_FILTER" ]] && continue
    peak=$(getv "$n" "$TMP/peak.txt"); [[ -z $peak ]] && continue
    res=$(awk -v a="$cm" -v b="$am" 'BEGIN{printf "%.0f", a-b}')
    resc=$(awk -v a="$cc" -v b="$ac" 'BEGIN{printf "%.0f", a-b}')
    cur=$(getv "$n" "$TMP/cur.txt"); p99=$(getv "$n" "$TMP/cpup99.txt"); cmx=$(getv "$n" "$TMP/cpumax.txt")
    al=$(getv "$n" "$TMP/alerts.txt"); up=$(getv "$n" "$TMP/uptime.txt")
    dv=$(getv "$n" "$TMP/deriv.txt"); pn=$(getv "$n" "$TMP/pods_now.txt"); pd=$(getv "$n" "$TMP/pods_deriv.txt")
    gr="?"; pg="?"
    if [[ -n $up && -n $dv && -n $cur ]] && fge "$up" $((GD + WARMUP_DAYS)); then
      gr=$(awk -v d="$dv" -v c="$cur" 'BEGIN{ if (c<=0) print "?"; else printf "%.1f", d*86400/c*100 }')
      [[ -n $pd && -n $pn ]] && pg=$(awk -v d="$pd" -v c="$pn" 'BEGIN{ if (c<=0) print "?"; else printf "%.1f", d*86400/c*100 }')
    fi
    pct=$(awk -v p="$peak" -v r="$res" 'BEGIN{ if (r<=0) print 0; else printf "%.0f", p*100/r }')
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$n" "$pool" "$cm" "$am" "$cc" "$ac" "$res" "$resc" "${cur:-0}" "$peak" "${p99:-0}" "${cmx:-0}" "${al:+1}" "${up:-?}" "$gr" "$pg" "$pct" >>"$TMP/rows.txt"
  done <"$TMP/nodes.txt"
  [[ -s $TMP/rows.txt ]] || die "brak nodów z danymi dla wybranej puli"
  sort -t'|' -k2,2 -k3,3n -k1,1 "$TMP/rows.txt" -o "$TMP/rows.txt"

  local okno="ostatnie $EFF dni"
  (( EFF < DAYS )) && okno="$okno (retencja Prometheusa: ok. $avail dni; żądano $DAYS)"
  line "Okno danych: $okno   trend: ostatnie $GD dni   margines ×$MARGIN"

  # ================================================ 1. KONFIGURACJA
  hdr "1. Obecna konfiguracja rezerwacji"
  local kcs
  kcs=$(jq -r '.items[] | "\(.metadata.name)|\(.spec.machineConfigPoolSelector.matchLabels // {} | to_entries | map(.key | sub("pools.operator.machineconfiguration.openshift.io/";"")) | join(","))|\(.spec.autoSizingReserved // false)|\(.spec.kubeletConfig.systemReserved // {} | tojson)"' "$TMP/kc.json")
  if [[ -z $kcs ]]; then
    info "Brak KubeletConfig w klastrze — wszystkie pule mają domyślną rezerwację (ok. 1 GiB pamięci, 500m CPU)"
  else
    while IFS='|' read -r kn kp ka ksr; do
      line "KubeletConfig $kn → pule: ${kp:-?}   autoSizingReserved=$ka   systemReserved=$ksr"
    done <<<"$kcs"
  fi

  # ================================================ 2. TABELA
  hdr "2. system.slice względem rezerwacji (per node)"
  printf '  %s%-18s %-9s %4s %7s %5s %6s %6s %5s %5s %5s %5s %5s %6s %2s%s\n' "$BOLD" \
    "NODE" "PULA" "CPU" "RAM" "REZ" "TERAZ" "SZCZYT" "SZC%" "CPUrz" "CPUp99" "CPUmx" "UPd" "TR%/d" "AL" "$N"
  printf '  %-18s %-9s %4s %7s %5s %6s %6s %5s %5s %5s %5s %5s %6s %2s\n' "" "" "" "GiB" "GiB" "GiB" "GiB" "" "m" "m" "m" "" "" ""
  while IFS='|' read -r n pool cm am cc ac res resc cur peak p99 cmx al up gr pg pct; do
    local mark=''
    (( pct >= 95 )) && mark="$R" || { (( pct >= NEAR_PCT )) && mark="$Y"; }
    printf '  %-18s %-9s %4s %7s %5s %6s %6s %s%4s%%%s %5s %5s %5s %5s %6s %2s\n' \
      "$(short "$n")" "${pool:0:9}" "$((cc / 1000))" "$(f1 "$(gib "$cm")")" "$(gib "$res")" "$(gib "$cur")" "$(gib "$peak")" \
      "$mark" "$pct" "$N" "$resc" "$(mcore "$p99")" "$(mcore "$cmx")" "$( [[ $up == "?" ]] && echo '?' || f1 "$up")" \
      "$( [[ $gr == "?" ]] && echo '?' || echo "${gr}")" "$( [[ $al == 1 ]] && echo '!' || echo '-')"
  done <"$TMP/rows.txt"
  line "SZC% = szczyt RSS system.slice / rezerwacja (alert >95%, ostrzeżenie ≥${NEAR_PCT}%). CPUp99/CPUmx = p99/maks. CPU system.slice."
  line "UPd = dni od rebootu. TR%/d = trend pamięci system.slice z ostatnich $GD dni (liczony tylko gdy UPd ≥ $((GD + WARMUP_DAYS)))."

  local n95 nnear nal
  n95=$(awk -F'|' '$17>=95' "$TMP/rows.txt" | wc -l)
  nnear=$(awk -F'|' -v t="$NEAR_PCT" '$17>=t && $17<95' "$TMP/rows.txt" | wc -l)
  nal=$(awk -F'|' '$13==1' "$TMP/rows.txt" | wc -l)
  (( n95 ))   && warn "Szczyt powyżej 95% rezerwacji — nodów: $n95 (alert aktywny teraz: $nal)"
  (( nnear )) && warn "Szczyt w przedziale ${NEAR_PCT}–95% (blisko alertu) — nodów: $nnear"
  (( n95 + nnear == 0 )) && ok "Wszystkie nody poniżej ${NEAR_PCT}% rezerwacji pamięci"

  # ================================================ 3. TREND
  hdr "3. Trend — wyciek czy normalna praca"
  local eligible leak
  eligible=$(awk -F'|' '$15!="?"' "$TMP/rows.txt" | wc -l)
  if (( eligible == 0 )); then
    info "Trend nieoceniony — żaden node nie działa ≥ $((GD + WARMUP_DAYS)) dni od rebootu lub brak danych"
    leak=""
  else
    leak=$(awk -F'|' -v t="$LEAK_PCT_DAY" '$15!="?" && $15+0 >= t { pg=($16=="?"?0:$16+0); if ($15+0 - pg >= t) print $1" (+"$15"%/d, pody "($16=="?"?"?":$16"%/d")")" }' "$TMP/rows.txt")
    local grow_pods
    grow_pods=$(awk -F'|' -v t="$LEAK_PCT_DAY" '$15!="?" && $15+0 >= t { pg=($16=="?"?0:$16+0); if ($15+0 - pg < t) print $1 }' "$TMP/rows.txt")
    if [[ -n $leak ]]; then
      local cnt; cnt=$(grep -c . <<<"$leak")
      warn "Podejrzenie wycieku (nodów: $cnt) — pamięć system.slice rośnie ≥${LEAK_PCT_DAY}%/dobę bez wzrostu liczby podów"
      while IFS= read -r l; do line "   $(short "${l%% *}" 30) ${l#* }"; done <<<"$leak"
    fi
    if [[ -n $grow_pods ]]; then
      info "Wzrost pamięci system.slice (nodów: $(grep -c . <<<"$grow_pods")) wynika ze wzrostu liczby podów — to nie wyciek"
    fi
    [[ -z $leak && -z $grow_pods ]] && ok "Zużycie stabilne (ocenionych nodów: $eligible) — brak oznak wycieku"
    local young; young=$(awk -F'|' '$15=="?"' "$TMP/rows.txt" | wc -l)
    (( young )) && line "Pominięte nody (świeży reboot lub brak danych): $young"
  fi

  # per usługa
  if [[ -s $TMP/svc_now.txt ]]; then
    printf '\n'
    line "${BOLD}Usługi w system.slice${N} (teraz; trend z nodów z uptime ≥ $((GD + WARMUP_DAYS)) d; CPU z ostatniej godziny):"
    printf '         %-30s %9s %9s %9s %9s\n' "usługa" "śr. GiB" "maks GiB" "trend%/d" "CPU maks"
    awk -F'|' -v gd="$((GD + WARMUP_DAYS))" '
      FILENAME==ARGV[1] { up[$1]=$14; next }
      FILENAME==ARGV[2] { k=$1"|"$2; now[k]=$3; if (!($1 in up)) next; s[$2]+=$3; c[$2]++; if ($3>m[$2]) m[$2]=$3; next }
      FILENAME==ARGV[3] { k=$1"|"$2; if (!($1 in up) || up[$1]=="?" || up[$1]+0 < gd || now[k]+0 <= 0) next; g[$2]+=$3*86400/now[k]*100; gc[$2]++; next }
      FILENAME==ARGV[4] { if (!($1 in up)) next; if ($3>cp[$2]) cp[$2]=$3 }
      END { for (k in s) printf "%.0f|%.0f|%s|%s|%s\n", s[k]/c[k], m[k], (gc[k]? sprintf("%+.1f", g[k]/gc[k]) : "?"), (k in cp ? sprintf("%.0fm", cp[k]*1000) : "-"), k }
    ' "$TMP/rows.txt" "$TMP/svc_now.txt" "$TMP/svc_deriv.txt" "$TMP/svc_cpu.txt" 2>/dev/null \
    | sort -t'|' -k1,1nr | head -8 >"$TMP/svc_sum.txt"
    while IFS='|' read -r avg mx tr cp sv; do
      printf '         %-30s %9s %9s %9s %9s\n' "${sv:0:30}" "$(gib "$avg")" "$(gib "$mx")" "$tr" "$cp"
      if [[ $tr != "?" ]] && fge "$tr" "$LEAK_PCT_DAY"; then
        warn "Usługa $sv rośnie średnio ${tr}%/dobę — kandydat na wyciek (sprawdź errata/KCS dla swojej wersji OCP)"
      fi
    done <"$TMP/svc_sum.txt"
    local udev; udev=$(awk -F'|' '$5=="systemd-udevd.service"{print $1}' "$TMP/svc_sum.txt")
    [[ -n $udev ]] && fgt "$udev" 157286400 && \
      info "systemd-udevd zajmuje średnio $(gib "$udev") GiB (typowo kilkadziesiąt MB) — dużo zdarzeń udev: veth podów, wolumeny CSI/multipath"
  fi

  # ================================================ 4. WYDAJNOŚĆ
  hdr "4. Kondycja kubelet/crio i warstwy wirtualizacji (ostatnia doba / godzina)"
  printf '  %s%-18s %5s %5s %5s %7s %7s %-16s %7s %7s %7s%s\n' "$BOLD" "NODE" "PODY" "KONT" "EXEC" "REST/d" "PLEGp99" "RUNTIME p99" "START" "STEAL" "CPU%" "$N"
  printf '  %-18s %5s %5s %5s %7s %7s %-16s %7s %7s %7s\n' "" "" "" "" "" "s" "s (operacja)" "p99 s" "mx/śr%" "śr/mx"
  local -a perf_pleg=() perf_rt=() perf_steal=() perf_rest=()
  while IFS='|' read -r n pool _rest; do
    local pods cont ex rs pl rtv rto ps stm sta cpa cpm
    pods=$(getv "$n" "$TMP/pods_now.txt"); cont=$(getv "$n" "$TMP/cont.txt"); ex=$(getv "$n" "$TMP/exec.txt")
    rs=$(getv "$n" "$TMP/restarts.txt"); pl=$(getv "$n" "$TMP/pleg.txt")
    IFS='|' read -r _ rtv rto < <(awk -F'|' -v n="$n" '$1==n' "$TMP/rt_max.txt")
    ps=$(getv "$n" "$TMP/podstart.txt"); stm=$(getv "$n" "$TMP/steal_max.txt"); sta=$(getv "$n" "$TMP/steal_avg.txt")
    cpa=$(getv "$n" "$TMP/cpu_avg.txt"); cpm=$(getv "$n" "$TMP/cpu_max.txt")
    printf '  %-18s %5s %5s %5s %7s %7s %-16s %7s %7s %7s\n' "$(short "$n")" \
      "${pods:--}" "${cont:--}" "${ex:-0}" "$( [[ -n $rs ]] && printf '%.0f' "$rs" || echo -)" \
      "$( [[ -n $pl ]] && printf '%.2f' "$pl" || echo -)" \
      "$( [[ -n $rtv ]] && printf '%.2f %s' "$rtv" "${rto:0:10}" || echo -)" \
      "$( [[ -n $ps ]] && printf '%.1f' "$ps" || echo -)" \
      "$( [[ -n $stm ]] && printf '%.0f/%.0f' "$stm" "${sta:-0}" || echo -)" \
      "$( [[ -n $cpa ]] && printf '%.0f/%.0f' "$cpa" "${cpm:-0}" || echo -)"
    [[ -n $pl ]]  && fge "$pl" "$PLEG_WARN"   && perf_pleg+=("$(short "$n") ($(printf '%.2f' "$pl") s)")
    [[ -n $rtv ]] && fge "$rtv" "$RT_WARN"    && perf_rt+=("$(short "$n") (${rto} $(printf '%.2f' "$rtv") s)")
    [[ -n $stm ]] && fge "$stm" "$STEAL_WARN" && perf_steal+=("$(short "$n") (maks $(printf '%.0f' "$stm")%, śr $(printf '%.1f' "${sta:-0}")%)")
    [[ -n $rs ]]  && fge "$rs" "$RESTART_WARN" && perf_rest+=("$(short "$n") ($(printf '%.0f' "$rs")/d)")
  done <"$TMP/rows.txt"
  line "EXEC = liczba probe typu exec (każda uruchamia proces przez crio). REST/d = restarty kontenerów z doby."
  line "RUNTIME = najwolniejsza operacja crio (bez pobierania obrazów). START = p99 startu poda bez pobierania obrazu."

  if (( ${#perf_steal[@]} )); then
    warn "Steal time ≥${STEAL_WARN}% na: ${perf_steal[*]} — VM-ki czekają na fizyczne CPU hosta (warstwa wirtualizacji)"
  else ok "Steal time poniżej ${STEAL_WARN}% — warstwa wirtualizacji nie dławi CPU nodów"; fi
  if (( ${#perf_pleg[@]} )); then
    warn "Wolny PLEG relist (p99 ≥ ${PLEG_WARN} s) na: ${perf_pleg[*]} — kubelet nie nadąża z obsługą kontenerów"
  else [[ -s $TMP/pleg.txt ]] && ok "PLEG relist w normie"; fi
  if (( ${#perf_rt[@]} )); then
    warn "Wolne operacje crio (p99 ≥ ${RT_WARN} s) na: ${perf_rt[*]}"
  else [[ -s $TMP/rt_max.txt ]] && ok "Operacje runtime (crio) w normie"; fi
  if (( ${#perf_rest[@]} )); then
    warn "Duża rotacja kontenerów (≥${RESTART_WARN} restartów/dobę) na: ${perf_rest[*]}"
  fi
  if [[ -s $TMP/toprestart.txt ]]; then
    line "Najczęściej restartujące pody (doba):"
    sort -t'|' -k2,2nr "$TMP/toprestart.txt" | while IFS='|' read -r p v; do line "   $(printf '%-60s %5.0f' "${p:0:60}" "$v")"; done
  fi
  local exec_top
  exec_top=$(sort -t'|' -k2,2nr "$TMP/exec.txt" | head -1)
  if [[ -n $exec_top ]] && fge "${exec_top#*|}" 100; then
    info "Dużo probe typu exec (do ${exec_top#*|} na nodzie $(short "${exec_top%%|*}")) — zwiększają CPU crio/kubeleta; httpGet/tcpSocket są tańsze"
  fi
  [[ -s $TMP/podstart.txt ]] || line "(metryka kubelet_pod_start_sli_duration_seconds niedostępna w tej wersji — kolumna START pusta)"

  # ================================================ 5. REKOMENDACJE
  hdr "5. Rekomendacja per pula i profil nodów"
  : >"$TMP/yaml.txt"; : >"$TMP/steps.txt"
  local -a pool_list=()
  mapfile -t pool_list < <(cut -d'|' -f2 "$TMP/rows.txt" | sort -u)
  local any_change=0 p
  for p in "${pool_list[@]}"; do
    # grupowanie po RAM: g|minCap|maxCap|count|nodes|maxPeak|maxP99|n95|nnear|maxCpuCores
    awk -F'|' -v p="$p" -v step="$PROFILE_STEP" '$2==p' "$TMP/rows.txt" | sort -t'|' -k3,3n | awk -F'|' -v step="$PROFILE_STEP" -v near="$NEAR_PCT" '
      { if (NR==1 || $3 > base*step) { g++; base=$3; mn[g]=$3 }
        mx[g]=$3; c[g]++; nodes[g]=nodes[g] (nodes[g]?",":"") $1
        if ($10>pk[g]) pk[g]=$10; if ($11>p9[g]) p9[g]=$11
        if ($17>=95) o[g]++; else if ($17>=near) nr[g]++
        if ($5>cpu[g]) cpu[g]=$5 }
      END { for (i=1;i<=g;i++) printf "%d|%s|%s|%d|%s|%s|%s|%d|%d|%s\n", i, mn[i], mx[i], c[i], nodes[i], pk[i]+0, p9[i]+0, o[i], nr[i], cpu[i] }' >"$TMP/groups_raw.txt"

    # rekomendacje i scalanie sąsiednich grup o tej samej rekomendacji
    : >"$TMP/groups.txt"
    local prev="" gid=0
    while IFS='|' read -r g mn mx c nodes pk p9 o nr cpu; do
      local rm rc
      rm=$(rec_mem "$pk"); rc=$(rec_cpu "$p9")
      if [[ "$rm|$rc" == "$prev" ]]; then
        awk -F'|' -v OFS='|' -v mx="$mx" -v c="$c" -v nodes="$nodes" -v pk="$pk" -v p9="$p9" -v o="$o" -v nr="$nr" -v cpu="$cpu" '
          NR==FNR { last=FNR; next }
          FNR==last { $3=mx; $4=$4+c; $5=$5","nodes; if (pk>$6) $6=pk; if (p9>$7) $7=p9; $8=$8+o; $9=$9+nr; if (cpu>$12) $12=cpu }
          { print }' "$TMP/groups.txt" "$TMP/groups.txt" >"$TMP/g2.txt" && mv "$TMP/g2.txt" "$TMP/groups.txt"
      else
        gid=$((gid + 1))
        printf '%d|%s|%s|%d|%s|%s|%s|%d|%d|%s|%s|%s\n' "$gid" "$mn" "$mx" "$c" "$nodes" "$pk" "$p9" "$o" "$nr" "$rm" "$rc" "$cpu" >>"$TMP/groups.txt"
      fi
      prev="$rm|$rc"
    done <"$TMP/groups_raw.txt"

    local cnt curres curresc pool_o pool_nr pool_cpu_need
    cnt=$(awk -F'|' -v p="$p" '$2==p' "$TMP/rows.txt" | wc -l)
    curres=$(awk -F'|' -v p="$p" '$2==p{print $7; exit}' "$TMP/rows.txt")
    curresc=$(awk -F'|' -v p="$p" '$2==p{print $8; exit}' "$TMP/rows.txt")
    pool_o=$(awk -F'|' '{s+=$8} END{print s+0}' "$TMP/groups.txt")
    pool_nr=$(awk -F'|' '{s+=$9} END{print s+0}' "$TMP/groups.txt")
    pool_cpu_need=$(awk -F'|' -v r="$curresc" '$7*1000 > r' "$TMP/groups.txt" | wc -l)
    local ngroups; ngroups=$(wc -l <"$TMP/groups.txt")

    printf '\n  %sPula %s%s (%d nodów, obecnie %s GiB / %sm)\n' "$BOLD" "$p" "$N" "$cnt" "$(gib "$curres")" "$curresc"
    printf '         %-12s %-14s %5s %9s %9s %6s  %-10s %s\n' "PROFIL" "RAM GiB" "NODY" "szczyt" "CPU p99" ">95/≥$NEAR_PCT" "REKOM." ""
    local base_g base_c=0
    while IFS='|' read -r g mn mx c nodes pk p9 o nr rm rc cpu; do
      if (( c > base_c )); then base_g=$g; base_c=$c; fi
    done <"$TMP/groups.txt"

    # nazwy profili względem bazowej grupy
    declare -A GNAME=()
    local -a up_names=(large xlarge xxlarge) down_names=(small xsmall xxsmall)
    while IFS='|' read -r g _; do
      if (( g == base_g )); then GNAME[$g]=$p
      elif (( g > base_g )); then GNAME[$g]="$p-${up_names[$((g - base_g - 1))]:-g$g}"
      else GNAME[$g]="$p-${down_names[$((base_g - g - 1))]:-g$g}"; fi
    done <"$TMP/groups.txt"

    while IFS='|' read -r g mn mx c nodes pk p9 o nr rm rc cpu; do
      local rng
      rng=$(awk -v a="$mn" -v b="$mx" 'BEGIN{ a/=1073741824; b/=1073741824; if (b-a<1) printf "%.0f", b; else printf "%.0f–%.0f", a, b }')
      printf '         %-12s %-14s %5s %9s %9s %6s  %-10s\n' "${GNAME[$g]#"$p"-}" "$rng" "$c" "$(gib "$pk")" "$(mcore "$p9")m" "$o/$nr" "${rm}Gi/${rc}m"
      if (( ngroups > 1 )); then
        local nl=""; IFS=',' read -ra arr <<<"$nodes"; for x in "${arr[@]}"; do nl+="$(short "$x" 30) "; done
        line "   nody: $nl"
      fi
    done <"$TMP/groups.txt"
    [[ ${GNAME[$base_g]} == "$p" && $ngroups -gt 1 ]] && line "(${p} = profil z największą liczbą nodów, zostaje w puli $p)"

    if (( pool_o + pool_nr == 0 && pool_cpu_need == 0 )); then
      ok "Pula $p: rezerwacje wystarczają (pamięć < ${NEAR_PCT}%, CPU p99 ≤ ${curresc}m) — zmiana niepotrzebna"
      unset GNAME; continue
    fi
    any_change=1
    local why=()
    (( pool_o ))  && why+=("szczyt pamięci >95% — nodów: $pool_o")
    (( pool_nr )) && why+=("blisko progu — nodów: $pool_nr")
    (( pool_cpu_need )) && why+=("CPU p99 system.slice powyżej rezerwacji ${curresc}m")
    warn "Pula $p wymaga zmiany rezerwacji: $(IFS=';'; echo "${why[*]}" | sed 's/;/; /g')"

    local is_worker_based=1
    [[ $p == master || $p == control-plane || $p == arbiter ]] && is_worker_based=0
    if (( ngroups > 1 && is_worker_based == 0 )); then
      warn "Pula $p ma nody różnej wielkości, ale nie da się jej podzielić na pule niestandardowe — użyj wartości dla największego profilu"
      local rmM rcM
      rmM=$(awk -F'|' '{if($10+0>m)m=$10+0} END{print m}' "$TMP/groups.txt"); rcM=$(awk -F'|' '{if($11+0>m)m=$11+0} END{print m}' "$TMP/groups.txt")
      echo "1|0|0|0|all|0|0|0|0|$rmM|$rcM|0" >"$TMP/groups.txt"; base_g=1; GNAME[1]=$p; ngroups=1
    fi
    if (( ngroups > 1 )); then
      info "Pula $p: różne profile nodów potrzebują różnych rezerwacji — propozycja podziału na $ngroups pule (niżej)"
    fi

    # ostrzeżenie o istniejącym KubeletConfig dla puli bazowej
    local existing
    existing=$(jq -r --arg p "$p" '.items[] | select((.spec.machineConfigPoolSelector.matchLabels // {}) | has("pools.operator.machineconfiguration.openshift.io/" + $p)) | .metadata.name' "$TMP/kc.json" | head -1)
    if [[ -n $existing && $ngroups -gt 1 ]]; then
      warn "Pula $p ma KubeletConfig $existing — nody przeniesione do nowych pul go NIE odziedziczą; nowe KubeletConfig muszą zawierać także jego pozostałe ustawienia"
    fi

    # sprawdzenie allocatable + YAML
    local -a tight=()
    while IFS='|' read -r g mn mx c nodes pk p9 o nr rm rc cpu; do
      local pname=${GNAME[$g]}
      IFS=',' read -ra arr <<<"$nodes"
      for x in "${arr[@]}"; do
        [[ $x == all ]] && continue
        local am rs rq newal delta
        am=$(awk -F'|' -v n="$x" '$1==n{print $4}' "$TMP/rows.txt"); rs=$(awk -F'|' -v n="$x" '$1==n{print $7}' "$TMP/rows.txt")
        rq=$(getv "$x" "$TMP/req.txt"); rq=${rq:-0}
        delta=$(awk -v r="$rm" -v c="$rs" 'BEGIN{printf "%.0f", r*1073741824 - c}')
        newal=$(awk -v a="$am" -v d="$delta" 'BEGIN{printf "%.0f", a-d}')
        awk -v q="$rq" -v a="$newal" 'BEGIN{exit !(q > a*0.9)}' && tight+=("$(short "$x") ($(gib "$rq")/$(gib "$newal") GiB)")
      done

      if [[ $pname != "$p" ]]; then
        cat >>"$TMP/yaml.txt" <<YAML
# ---- nowa pula $pname (dziedziczy całą konfigurację puli $p)
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: $pname
  labels:
    pools.operator.machineconfiguration.openshift.io/$pname: ""
spec:
  maxUnavailable: 1
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values: [$p, $pname]
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/$pname: ""
---
YAML
        {
          printf '# pula %s — oznaczenie nodów (przeniesienie bez zmiany konfiguracji = bez rebootu)\n' "$pname"
          for x in "${arr[@]}"; do printf 'oc label node %s node-role.kubernetes.io/%s=""\n' "$x" "$pname"; done
          printf 'oc get mcp %s   # poczekaj na UPDATED=True, MACHINECOUNT=%d\n\n' "$pname" "${#arr[@]}"
        } >>"$TMP/steps.txt"
      fi
      local kcname="${pname}-system-reserved"
      [[ $pname == "$p" && -n $existing ]] && kcname=$existing
      cat >>"$TMP/yaml.txt" <<YAML
# ---- rezerwacja dla puli $pname$( [[ $pname == "$p" && -n $existing ]] && echo "  (ISTNIEJE KubeletConfig $existing — dopisz systemReserved do niego)")
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: $kcname
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/$pname: ""
  kubeletConfig:
    systemReserved:
      memory: ${rm}Gi
      cpu: ${rc}m
---
YAML
    done <"$TMP/groups.txt"
    if (( ${#tight[@]} )); then
      warn "Pula $p: po zmianie requests pamięci przekroczą 90% nowego allocatable na: ${tight[*]}"
    else
      ok "Pula $p: requests pamięci zmieszczą się w nowym allocatable na wszystkich nodach"
    fi
    {
      printf '# rezerwacje — dopiero PO przeniesieniu nodów do nowych pul (inaczej przeniesione nody zrestartują się dwa razy)\n'
      printf '# KAŻDY KubeletConfig wywoła rolling reboot nodów swojej puli\n'
      while IFS='|' read -r g _; do
        printf '#   pula %s: oc patch mcp %s --type merge -p '"'"'{"spec":{"paused":true}}'"'"'  → oc apply -f <KubeletConfig> → odpauzowanie w oknie\n' "${GNAME[$g]}" "${GNAME[$g]}"
      done <"$TMP/groups.txt"
      printf '\n'
    } >>"$TMP/steps.txt"
    unset GNAME
  done

  # ================================================ 6. YAML
  if (( any_change )); then
    hdr "6. Propozycja (NIC nie zostało wdrożone)"
    printf '  %sYAML:%s\n' "$BOLD" "$N"
    sed 's/^/    /' "$TMP/yaml.txt"
    printf '\n  %sKolejność ręcznych kroków (do wykonania samodzielnie, w oknie serwisowym):%s\n' "$BOLD" "$N"
    printf '    # 0. ./ocp-mcp-diag.sh <pula> — pula Updated=True, brak blokujących PDB\n'
    sed 's/^/    /' "$TMP/steps.txt"
    if [[ -n $OUT_DIR ]]; then
      mkdir -p "$OUT_DIR" || die "nie mogę utworzyć $OUT_DIR"
      cp "$TMP/yaml.txt" "$OUT_DIR/proposed-sysreserved.yaml"
      cp "$TMP/steps.txt" "$OUT_DIR/proposed-steps.txt"
      line "Zapisano lokalnie: $OUT_DIR/proposed-sysreserved.yaml, $OUT_DIR/proposed-steps.txt"
    fi
  fi

  # ================================================ WNIOSKI
  hdr "WNIOSKI"
  if (( ${#F_CRIT[@]} )); then printf '%s%sKRYTYCZNE (%d):%s\n' "$BOLD" "$R" "${#F_CRIT[@]}" "$N"; for f in "${F_CRIT[@]}"; do printf '  • %s\n' "$f"; done; fi
  if (( ${#F_WARN[@]} )); then printf '%s%sOSTRZEŻENIA (%d):%s\n' "$BOLD" "$Y" "${#F_WARN[@]}" "$N"; for f in "${F_WARN[@]}"; do printf '  • %s\n' "$f"; done; fi
  if (( ${#F_INFO[@]} )); then printf '%s%sINFORMACJE (%d):%s\n' "$BOLD" "$C" "${#F_INFO[@]}" "$N"; for f in "${F_INFO[@]}"; do printf '  • %s\n' "$f"; done; fi

  printf '\n%sDalsze kroki:%s\n' "$BOLD" "$N"
  local i=1
  if [[ -n $leak ]]; then
    printf '  %d. Wyjaśnij podejrzenie wycieku (sekcja 3) — większa rezerwacja go nie naprawi, tylko odsunie alert.\n' $i; i=$((i+1))
  fi
  if (( ${#perf_steal[@]} )); then
    printf '  %d. Steal time: przyczyna wydajności leży na hostach (gęstość VM-ek, topologia vCPU, profil BIOS) — nie w OpenShifcie.\n' $i; i=$((i+1))
  fi
  if (( ${#perf_pleg[@]} + ${#perf_rt[@]} + ${#perf_rest[@]} )); then
    printf '  %d. Kubelet/crio są przeciążone — ogranicz rotację (pody w CrashLoopBackOff, nieudane joby) i probe typu exec;\n' $i
    printf '     wyższa rezerwacja CPU (sekcja 5) zabezpieczy je przed podami, ale nie usunie źródła obciążenia.\n'; i=$((i+1))
  fi
  if (( any_change )); then
    printf '  %d. Wdróż rezerwacje z sekcji 6: najpierw jeden node / preprod, potem pule w oknie serwisowym.\n' $i; i=$((i+1))
    printf '  %d. Po kilku dniach uruchom skrypt ponownie — SZC%% powinno spaść poniżej %d%%.\n' $i "$NEAR_PCT"
  else
    printf '  %d. Rezerwacje są wystarczające — zmiana KubeletConfig nie jest potrzebna.\n' $i
  fi

  (( ${#F_CRIT[@]} )) && return 2
  (( ${#F_WARN[@]} )) && return 1
  return 0
}

# ------------------------------------------------------------- anonimizacja
build_anon_sed() {
  local api dom user i=0 n role short
  : >"$TMP/anon.map"
  api=$(oc whoami --show-server 2>/dev/null | sed -E 's#^https?://##; s#:[0-9]+$##')
  dom=${api#api.}
  user=$(oc whoami 2>/dev/null)
  while IFS= read -r n; do
    [[ -z $n ]] && continue
    i=$((i + 1)); short=${n%%.*}
    case $short in master*|*control*) role=master;; infra*) role=infra;; worker*|*wrk*) role=worker;; *) role=node;; esac
    printf '%s %s\n' "$n" "$(printf '%s-%02d.cluster.example.com' "$role" "$i")" >>"$TMP/anon.map"
    [[ $short != "$n" ]] && printf '%s %s\n' "$short" "$(printf '%s-%02d' "$role" "$i")" >>"$TMP/anon.map"
  done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  [[ -n $api ]] && printf '%s %s\n' "$api" "api.cluster.example.com" >>"$TMP/anon.map"
  [[ -n $dom && $dom != "$api" ]] && printf '%s %s\n' "$dom" "cluster.example.com" >>"$TMP/anon.map"
  [[ -n $user ]] && printf '%s %s\n' "$user" "user" >>"$TMP/anon.map"
  awk '{print length($1), $0}' "$TMP/anon.map" | sort -rn | cut -d' ' -f2- | while read -r from to; do
    printf 's/\\b%s\\b/%s/g\n' "$(sed 's/[.[\*^$/]/\\&/g' <<<"$from")" "$to"
  done >"$TMP/anon.sed"
}

if [[ $ANONYMIZE == 1 ]]; then
  build_anon_sed
  main | sed -f "$TMP/anon.sed"
  exit "${PIPESTATUS[0]}"
else
  main
  exit $?
fi