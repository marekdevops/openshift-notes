#!/usr/bin/env bash
# =============================================================================
#  ocp-app-audit.sh — audyt zasobów i zachowania aplikacji w namespace
#                     (TYLKO ODCZYT)
#
#  Odpowiada na pytanie „czy to platforma, czy aplikacja?” liczbami:
#   - requesty/limity vs realne zużycie (p95/maks.) per workload,
#   - throttling CPU, restarty, OOMKilled, zabicia przez liveness,
#   - czas startu podów vs budżet probe,
#   - rozłożenie replik, PDB, probe typu exec,
#   - stan nodów, na których działa aplikacja (pamięć, steal, rezerwacje),
#   - rekomendowane wartości per workload i wnioski z podziałem
#     na stronę aplikacji i platformy.
#
#  Użycie:
#     ./ocp-app-audit.sh <namespace>
#
#  Przykłady:
#     ./ocp-app-audit.sh moja-aplikacja
#     DAYS=3 ./ocp-app-audit.sh moja-aplikacja
#     OUT_DIR=./audyt ANONYMIZE=1 ./ocp-app-audit.sh moja-aplikacja
#
#  Zmienne (opcjonalne):
#     DAYS=7              okres analizy (skracany automatycznie do retencji)
#     MEM_MARGIN=1.2      zapas nad p95 pamięci dla rekomendowanego requestu
#     THROTTLE_WARN=30    % throttlingu CPU uznawany za problem
#     RESTART_WARN=10     restarty workloadu w okresie uznawane za problem
#     START_RISK=50       % budżetu liveness zużyty przez start = ryzyko
#     TOP=10              ile najgorszych workloadów wymieniać we wnioskach
#     OUT_DIR=            katalog lokalny na raport (report.txt) i CSV
#     ANONYMIZE=1         zamaskuj nazwy nodów, domenę, użytkownika
#
#  Nic nie jest zmieniane w klastrze: `oc get`, zapytania do Prometheusa
#  przez `oc exec` do prometheus-k8s-0. Wymaga jq.
# =============================================================================
set -o pipefail

NS=${1:-}
DAYS=${DAYS:-7}
MEM_MARGIN=${MEM_MARGIN:-1.2}
THROTTLE_WARN=${THROTTLE_WARN:-30}
RESTART_WARN=${RESTART_WARN:-10}
START_RISK=${START_RISK:-50}
TOP=${TOP:-10}
OUT_DIR=${OUT_DIR:-}
ANONYMIZE=${ANONYMIZE:-0}

if [[ -t 1 && -z $OUT_DIR ]]; then
  R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[34m'; C=$'\e[36m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=''; Y=''; G=''; B=''; C=''; BOLD=''; N=''
fi

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

declare -a F_OK=() F_APP=() F_PLAT=() F_INFO=()
CRITS=0; WARNS=0
crit()  { CRITS=$((CRITS+1)); printf '  %s[CRIT]%s %s\n' "$R" "$N" "$*"; }
warn()  { WARNS=$((WARNS+1)); printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; }
info()  { printf '  %s[INFO]%s %s\n' "$C" "$N" "$*"; }
ok()    { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$*"; }
line()  { printf '         %s\n' "$*"; }
hdr()   { printf '\n%s== %s ==%s\n' "$BOLD$B" "$*" "$N"; }
die()   { printf 'BŁĄD: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# app/plat: wniosek do podsumowania + wypisanie
app_c()  { F_APP+=("[CRIT] $*");  crit "$*"; }
app_w()  { F_APP+=("[WARN] $*");  warn "$*"; }
plat_c() { F_PLAT+=("[CRIT] $*"); crit "$*"; }
plat_w() { F_PLAT+=("[WARN] $*"); warn "$*"; }
good()   { F_OK+=("$*"); ok "$*"; }
note()   { F_INFO+=("$*"); info "$*"; }

prom() {
  local q=$1 out=$2 key=${3:-'(.metric.node // .metric.instance // "")'}
  oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
     curl -sG --data-urlencode "query=$q" http://localhost:9090/api/v1/query 2>/dev/null \
  | jq -r ".data.result[]? | select(.value[1] != \"NaN\" and .value[1] != \"+Inf\") | \"\($key)|\(.value[1])\"" >"$out" 2>/dev/null
  [[ -s $out ]]
}
getv() { awk -F'|' -v n="$1" '$1==n{print $2; exit}' "$2"; }

# formaty
fmem() { awk -v b="${1:-0}" 'BEGIN{ b+=0; if (b<=0) {print "-"; exit}
  if (b >= 1073741824) printf "%.1fGi", b/1073741824; else printf "%.0fMi", b/1048576 }'; }
fgib() { awk -v b="${1:-0}" 'BEGIN{ printf "%.1f", (b+0)/1073741824 }'; }
fcpu() { awk -v m="${1:-0}" 'BEGIN{ m+=0; if (m<=0) {print "-"; exit} if (m>=1000) printf "%.1f", m/1000; else printf "%.0fm", m }'; }
short(){ local s=${1%%.*}; echo "${s:0:${2:-18}}"; }

# =============================================================================
main() {
  [[ -z $NS || $NS == -h || $NS == --help ]] && usage
  command -v oc >/dev/null 2>&1 || die "brak polecenia oc w PATH"
  command -v jq >/dev/null 2>&1 || die "brak jq w PATH (wymagane)"
  oc whoami >/dev/null 2>&1     || die "brak zalogowania do klastra (oc login)"
  oc get ns "$NS" >/dev/null 2>&1 || die "namespace $NS nie istnieje lub brak dostępu"

  printf '%sAudyt aplikacji w namespace %s%s\n' "$BOLD" "$NS" "$N"
  printf 'Klaster: %s   użytkownik: %s   %s\n' "$(oc whoami --show-server 2>/dev/null)" "$(oc whoami 2>/dev/null)" "$(date '+%F %T')"
  printf 'Tryb tylko do odczytu — nic nie jest zmieniane.\n\nZbieranie danych...\n'

  # ------------------------------------------------------------ API
  oc get pods -n "$NS" -o json >"$TMP/pods.json"   2>/dev/null || die "nie udało się pobrać podów"
  oc get rs   -n "$NS" -o json >"$TMP/rs.json"     2>/dev/null || echo '{"items":[]}' >"$TMP/rs.json"
  oc get pdb  -n "$NS" -o json >"$TMP/pdb.json"    2>/dev/null || echo '{"items":[]}' >"$TMP/pdb.json"
  oc get vpa  -n "$NS" -o json >"$TMP/vpa.json"    2>/dev/null || echo '{"items":[]}' >"$TMP/vpa.json"
  oc get ns "$NS" -o json      >"$TMP/ns.json"     2>/dev/null
  oc get nodes -o json         >"$TMP/nodes.json"  2>/dev/null || die "nie udało się pobrać nodów"
  oc get pods -A -o json       >"$TMP/allpods.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/allpods.json"

  local JQDEF='
    def mem: tostring |
      if test("Ki$") then (.[:-2]|tonumber)*1024
      elif test("Mi$") then (.[:-2]|tonumber)*1048576
      elif test("Gi$") then (.[:-2]|tonumber)*1073741824
      elif test("Ti$") then (.[:-2]|tonumber)*1099511627776
      elif test("k$") then (.[:-1]|tonumber)*1000
      elif test("M$") then (.[:-1]|tonumber)*1000000
      elif test("G$") then (.[:-1]|tonumber)*1000000000
      elif test("m$") then (.[:-1]|tonumber)/1000
      else tonumber end;
    def cpu: tostring | if test("m$") then (.[:-1]|tonumber) else (tonumber*1000) end;
    def ts: if . == null then null else (sub("\\.[0-9]+";"") | fromdateiso8601) end;'

  # ReplicaSet -> Deployment
  jq -r '.items[] | "\(.metadata.name)|\([.metadata.ownerReferences[]? | select(.kind=="Deployment") | .name][0] // "")"' "$TMP/rs.json" >"$TMP/rsmap.txt"

  # Workloady (z bieżących podów)
  # wl|kind|rep|memReq|memLim|cpuReq|cpuLim|best|hasStartup|startBudget|livBudget|livType|execN|startMax|startMed|restartsNow|oom|kill|maxPerNode|nodes|pdb|pdbAllowed
  jq -r --slurpfile rs "$TMP/rs.json" --slurpfile pdb "$TMP/pdb.json" "$JQDEF"'
    ($rs[0].items | map({key: .metadata.name, value: ([.metadata.ownerReferences[]? | select(.kind=="Deployment") | .name][0] // null)}) | from_entries) as $rsmap |
    [ .items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | ((.metadata.ownerReferences // []) | map(select(.controller == true))[0]) as $o
      | select(($o.kind // "") != "Job")
      | { wl: (if $o == null then "pod/" + .metadata.name
               elif $o.kind == "ReplicaSet" then ($rsmap[$o.name] // ($o.name | sub("-[a-z0-9]+$";"")))
               else $o.name end),
          kind: (if $o == null then "Pod" elif $o.kind == "ReplicaSet" then "Deployment" else $o.kind end),
          node: (.spec.nodeName // ""),
          labels: (.metadata.labels // {}),
          memReq: ([.spec.containers[] | .resources.requests.memory // "0" | mem] | add),
          memLim: (if all(.spec.containers[]; .resources.limits.memory != null) then ([.spec.containers[] | .resources.limits.memory | mem] | add) else 0 end),
          cpuReq: ([.spec.containers[] | .resources.requests.cpu // "0" | cpu] | add),
          cpuLim: (if all(.spec.containers[]; .resources.limits.cpu != null) then ([.spec.containers[] | .resources.limits.cpu | cpu] | add) else 0 end),
          best: ((([.spec.containers[] | (.resources.requests // {}) | length] | add) == 0) and (([.spec.containers[] | (.resources.limits // {}) | length] | add) == 0)),
          hasStartup: any(.spec.containers[]; .startupProbe != null),
          startBudget: ([.spec.containers[] | .startupProbe | select(. != null) | (.initialDelaySeconds // 0) + (.periodSeconds // 10) * (.failureThreshold // 3)] | max // 0),
          livBudget: ([.spec.containers[] | .livenessProbe | select(. != null) | (.initialDelaySeconds // 0) + (.periodSeconds // 10) * (.failureThreshold // 3)] | min // 0),
          livType: ([.spec.containers[] | .livenessProbe | select(. != null) | ([keys[] | select(. == "exec" or . == "httpGet" or . == "tcpSocket" or . == "grpc")][0] // "?")][0] // "-"),
          execN: ([.spec.containers[] | (.livenessProbe, .readinessProbe, .startupProbe) | select(. != null and .exec != null)] | length),
          startS: ( ([.status.conditions[]? | select(.type == "Ready" and .status == "True") | .lastTransitionTime | ts][0]) as $r
                   | ([.status.containerStatuses[]? | .state.running.startedAt | select(. != null) | ts] | max) as $s
                   | if $r != null and $s != null and $r >= $s then $r - $s else null end ),
          restarts: ([.status.containerStatuses[]? | .restartCount] | add // 0),
          oom: ([.status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled")] | length),
          kill: ([.status.containerStatuses[]? | select(.lastState.terminated.exitCode == 137 and .lastState.terminated.reason != "OOMKilled")] | length)
        } ] as $p
    | ($pdb[0].items) as $pdbs
    | $p | group_by(.wl)[] | . as $g | .[0] as $f
    | ([ $pdbs[] | select(.spec.selector.matchLabels != null)
         | select(.spec.selector.matchLabels | to_entries | all(.value == $f.labels[.key]))
         | {n: .metadata.name, a: (.status.disruptionsAllowed // 0)} ][0]) as $pd
    | ([$g[] | .startS | select(. != null)] | sort) as $st
    | [ $f.wl, $f.kind, ($g | length),
        ([$g[].memReq] | max), ([$g[].memLim] | max), ([$g[].cpuReq] | max), ([$g[].cpuLim] | max),
        (if $f.best then 1 else 0 end), (if $f.hasStartup then 1 else 0 end), $f.startBudget, $f.livBudget, $f.livType, $f.execN,
        (if ($st | length) > 0 then ($st | max) else -1 end),
        (if ($st | length) > 0 then $st[(($st | length) / 2 | floor)] else -1 end),
        ([$g[].restarts] | add), ([$g[].oom] | add), ([$g[].kill] | add),
        ([$g[] | .node] | group_by(.) | map(length) | max), ([$g[].node] | unique | length),
        ($pd.n // "-"), ($pd.a // -1)
      ] | map(tostring) | join("|")' "$TMP/pods.json" >"$TMP/wl_api.txt" 2>"$TMP/jq.err"
  [[ -s $TMP/wl_api.txt ]] || die "brak działających workloadów w $NS (lub błąd jq: $(head -1 "$TMP/jq.err"))"

  local jobs; jobs=$(jq '[.items[] | select((.metadata.ownerReferences // [])[0].kind == "Job")] | length' "$TMP/pods.json")

  # Nody hostujące aplikację
  jq -r '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | .spec.nodeName // empty] | unique[]' "$TMP/pods.json" >"$TMP/hostnodes.txt"

  # ------------------------------------------------------------ okno danych
  local OWN="max by (namespace, pod, owner_name) (kube_pod_owner{namespace=\"$NS\"})"
  local CSEL="namespace=\"$NS\", container!=\"\", container!=\"POD\""
  local now earliest avail D
  now=$(date +%s)
  prom "min_over_time(timestamp(count(kube_pod_owner{namespace=\"$NS\"}))[${DAYS}d:1h])" "$TMP/earliest.txt" '"x"' || true
  earliest=$(cut -d'|' -f2 "$TMP/earliest.txt" 2>/dev/null)
  if [[ -n $earliest ]]; then avail=$(awk -v n="$now" -v e="$earliest" 'BEGIN{printf "%d", (n-e)/86400}'); else avail=$DAYS; fi
  D=$DAYS; (( avail < D )) && D=$avail; (( D < 1 )) && D=1

  # ------------------------------------------------------------ Prometheus per workload (owner_name)
  local K='(.metric.owner_name // "")'
  prom "max by (owner_name) (quantile_over_time(0.95, (sum by (namespace, pod) (container_memory_working_set_bytes{$CSEL}) * on (namespace, pod) group_left(owner_name) $OWN)[${D}d:10m]))" "$TMP/m_memp95.txt" "$K" \
    || die "brak metryk podów z Prometheusa dla $NS — sprawdź dostęp do prometheus-k8s-0"
  prom "max by (owner_name) (max_over_time((sum by (namespace, pod) (container_memory_working_set_bytes{$CSEL}) * on (namespace, pod) group_left(owner_name) $OWN)[${D}d:10m]))" "$TMP/m_memmax.txt" "$K"
  prom "max by (owner_name) (quantile_over_time(0.95, (sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{$CSEL}[5m])) * on (namespace, pod) group_left(owner_name) $OWN)[${D}d:10m]))" "$TMP/m_cpup95.txt" "$K"
  prom "max by (owner_name) (max_over_time((sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{$CSEL}[5m])) * on (namespace, pod) group_left(owner_name) $OWN)[${D}d:10m]))" "$TMP/m_cpumax.txt" "$K"
  prom "max by (owner_name) (max_over_time(((sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{$CSEL}[5m])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{$CSEL}[5m]))) * on (namespace, pod) group_left(owner_name) $OWN)[${D}d:10m])) * 100" "$TMP/m_thr.txt" "$K"
  prom "sum by (owner_name) (increase(kube_pod_container_status_restarts_total{namespace=\"$NS\"}[${D}d]) * on (namespace, pod) group_left(owner_name) $OWN)" "$TMP/m_rst.txt" "$K"

  # owner_name -> workload
  for f in memp95 memmax cpup95 cpumax thr rst; do
    awk -F'|' -v OFS='|' 'NR==FNR { if ($2!="") m[$1]=$2; next }
      { o=$1; w=(o in m) ? m[o] : o; if (!(o in m) && o ~ /-[a-z0-9]{6,10}$/) { tmp=o; sub(/-[a-z0-9]+$/, "", tmp); w=tmp }
        print w, $2 }' "$TMP/rsmap.txt" "$TMP/m_$f.txt" \
    | awk -F'|' -v f="$f" '{ if (f=="rst") s[$1]+=$2; else if (!($1 in s) || $2+0 > s[$1]+0) s[$1]=$2 } END { for (k in s) print k "|" s[k] }' >"$TMP/w_$f.txt"
  done

  # Nody: metryki
  prom 'node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes' "$TMP/n_used.txt"
  prom "sum by (node) (container_memory_working_set_bytes{$CSEL})" "$TMP/n_nsused.txt"
  prom 'max_over_time((avg by (instance) (rate(node_cpu_seconds_total{mode="steal"}[5m])))[1d:5m]) * 100' "$TMP/n_steal.txt"
  prom 'avg_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))[1d:5m]) * 100' "$TMP/n_cpuavg.txt"
  prom 'max_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))[1d:5m]) * 100' "$TMP/n_cpumax.txt"
  prom 'count by (node) (ALERTS{alertname="SystemMemoryExceedsReservation",alertstate="firing"})' "$TMP/n_alert.txt"

  # ------------------------------------------------------------ złożenie wierszy
  # wiersz: api(22 pola) | memP95 | memMax | cpuP95(m) | cpuMax(m) | thr% | rstWindow
  : >"$TMP/rows.txt"
  while IFS='|' read -r wl rest; do
    local mp mm cp cm th rs
    mp=$(getv "$wl" "$TMP/w_memp95.txt"); mm=$(getv "$wl" "$TMP/w_memmax.txt")
    cp=$(getv "$wl" "$TMP/w_cpup95.txt"); cm=$(getv "$wl" "$TMP/w_cpumax.txt")
    th=$(getv "$wl" "$TMP/w_thr.txt");    rs=$(getv "$wl" "$TMP/w_rst.txt")
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$wl" "$rest" "${mp:-0}" "${mm:-0}" \
      "$(awk -v c="${cp:-0}" 'BEGIN{printf "%.0f", c*1000}')" "$(awk -v c="${cm:-0}" 'BEGIN{printf "%.0f", c*1000}')" \
      "$(awk -v t="${th:--1}" 'BEGIN{ if (t<0) print -1; else printf "%.0f", t }')" "$(awk -v r="${rs:-0}" 'BEGIN{printf "%.0f", r}')" >>"$TMP/rows.txt"
  done <"$TMP/wl_api.txt"

  # flagi + rekomendacje (awk)
  # dodaje: flags|score|recMemReq|recMemLim|recCpuReq|recCpuLim|recStartupFT|memGapTotal
  awk -F'|' -v OFS='|' -v mm="$MEM_MARGIN" -v tw="$THROTTLE_WARN" -v rw="$RESTART_WARN" -v sr="$START_RISK" '
    function ceilto(v, s) { r = int(v / s); if (r * s < v) r++; return r * s }
    {
      rep=$3; memReq=$4; memLim=$5; cpuReq=$6; cpuLim=$7; best=$8; hasSt=$9; stB=$10; livB=$11; livT=$12; execN=$13
      stMax=$14; rstNow=$16; oom=$17; kill=$18; mpn=$19; nodes=$20; pdb=$21; pdbA=$22
      memP=$23; memM=$24; cpuP=$25; cpuM=$26; thr=$27; rstW=$28
      fl=""; sc=0
      if (best==1)                                   { fl=fl "B"; sc+=3 }
      if (oom>0)                                     { fl=fl "O"; sc+=5 }
      if (memP>0 && memReq>0 && memP > memReq*1.1)   { fl=fl "M"; sc+=3 }
      if (memP>0 && memReq==0)                       { fl=fl "M"; sc+=3 }
      if (thr>=tw && cpuLim>0)                       { fl=fl "T"; sc+=2 }
      budget = (hasSt==1) ? stB : livB
      if (stMax>0 && budget>0 && stMax*100/budget >= sr) { fl=fl "S"; sc+= (stMax>=budget ? 5 : 3) }
      if (execN>0)                                   { fl=fl "E"; sc+=1 }
      if (rstW>=rw || (rstW==0 && rstNow>=rw))       { fl=fl "R"; sc+= ((rstW>=rw*10) ? 4 : 2) }
      if (rep>1 && mpn > int((rep+1)/2))             { fl=fl "D"; sc+=2 }
      if (rep>1 && pdb!="-" && pdbA==0)              { fl=fl "P"; sc+=1 }
      # rekomendacje (per pod)
      base = (memP>0) ? memP : memReq
      rmr = ceilto(base*mm, 268435456); if (rmr < 268435456) rmr = 268435456
      top = (memM>0) ? memM*1.15 : rmr; if (top < rmr) top = rmr
      rml = ceilto(top, 268435456)
      rcr = ceilto((cpuP>0 ? cpuP : 50), 50); if (rcr < 50) rcr = 50
      if (cpuLim>0 && thr>=tw) rcl="usuń"; else if (cpuLim>0) rcl=cpuLim "m"; else rcl="-"
      rft = ""; if (stMax>0) { ft = int((stMax*2+9)/10); if (ft < 18) ft = 18; rft = ft }
      gap = (memP>memReq) ? (memP-memReq)*rep : 0
      print $0, (fl=="" ? "-" : fl), sc, rmr, rml, rcr, rcl, rft, gap
    }' "$TMP/rows.txt" | sort -t'|' -k30,30nr -k36,36nr >"$TMP/rowsf.txt"
  # pola: 1..28 jak wyżej, 29 flags, 30 score, 31 recMemReq, 32 recMemLim, 33 recCpuReq, 34 recCpuLim, 35 recFT, 36 memGap

  local nwl npods nnodes
  nwl=$(wc -l <"$TMP/rowsf.txt"); npods=$(awk -F'|' '{s+=$3} END{print s+0}' "$TMP/rowsf.txt"); nnodes=$(wc -l <"$TMP/hostnodes.txt")

  # ================================================ 1. INWENTARZ
  hdr "1. Inwentarz"
  line "Workloady: $nwl   pody: $npods   nody: $nnodes   (pody jobów pominięte: ${jobs:-0})"
  line "Okno metryk: ostatnie $D dni$( (( D < DAYS )) && echo " (retencja Prometheusa ok. $avail dni; żądano $DAYS)")"
  awk -F'|' '{k[$2]++} END{for (x in k) printf "         %s: %d\n", x, k[x]}' "$TMP/rowsf.txt"
  line "Uwaga: konfiguracja (requesty, probe, czasy startu) z bieżących podów; zużycie i restarty z metryk."

  # ================================================ 2. TABELA
  hdr "2. Workloady — konfiguracja vs rzeczywistość (wartości per pod)"
  printf '  %s%-28s %3s %7s %7s %7s %7s %6s %6s %5s %4s %6s %6s %4s %-9s%s\n' "$BOLD" \
    "WORKLOAD" "REP" "MEMreq" "MEMp95" "MEMmax" "MEMlim" "CPUreq" "CPUp95" "CPUlim" "THR%" "STARTs" "BUDŻET" "RST" "FLAGI" "$N"
  while IFS='|' read -r -a f; do
    local budget lb
    if [[ ${f[8]} == 1 ]]; then budget=${f[9]}; lb="${budget}s*"; else budget=${f[10]}; lb=$([[ $budget -gt 0 ]] && echo "${budget}s" || echo "-"); fi
    printf '  %-28s %3s %7s %7s %7s %7s %6s %6s %5s %4s %6s %6s %4s %-9s\n' \
      "${f[0]:0:28}" "${f[2]}" "$(fmem "${f[3]}")" "$(fmem "${f[22]}")" "$(fmem "${f[23]}")" "$(fmem "${f[4]}")" \
      "$(fcpu "${f[5]}")" "$(fcpu "${f[24]}")" "$(fcpu "${f[6]}")" \
      "$([[ ${f[26]} -ge 0 ]] && echo "${f[26]}" || echo -)" \
      "$([[ ${f[13]} -ge 0 ]] && echo "${f[13]}" || echo -)" "$lb" "${f[27]}" "${f[28]}"
  done <"$TMP/rowsf.txt"
  line "STARTs = najdłuższy zmierzony czas od startu kontenera do Ready (bieżące pody). BUDŻET = czas do zabicia przez liveness"
  line "(z * = budżet startupProbe). RST = restarty w okresie. THR% = maks. throttling CPU (zwykle w trakcie startu)."
  line "FLAGI: O=OOMKilled M=zużycie>request S=start blisko/ponad budżet T=throttling R=restarty E=probe exec"
  line "       D=repliki skupione na jednym nodzie P=PDB blokuje drain B=brak requestów (BestEffort)"

  # ================================================ 3. NODY
  hdr "3. Nody, na których działa aplikacja"
  printf '  %s%-18s %5s %7s %7s %7s %7s %7s %7s %6s %5s %4s %-8s%s\n' "$BOLD" \
    "NODE" "PODY" "ALLOC" "REQ" "UŻYCIE" "WOLNE" "WOLNE" "APP" "STEAL" "CPU%" "OBCE" "TAINT" "$N"
  printf '  %-18s %5s %7s %7s %7s %7s %7s %7s %6s %5s %4s %-8s\n' "" "app" "GiB" "GiB" "GiB" "sched" "real" "use/req" "maks%" "śr/mx" "" ""
  : >"$TMP/nodes_rows.txt"
  local n
  while IFS= read -r n; do
    local alloc cap reqall napp nreq nuse used foreign taint stl cpa cpm al
    read -r alloc cap taint < <(jq -r --arg n "$n" "$JQDEF"'.items[] | select(.metadata.name == $n) |
      "\(.status.allocatable.memory | mem) \(.status.capacity.memory | mem) \((.spec.taints // []) | map(select(.effect == "NoSchedule" and (.key | startswith("node.kubernetes.io") | not))) | length)"' "$TMP/nodes.json")
    read -r reqall foreign < <(jq -r --arg n "$n" --arg ns "$NS" "$JQDEF"'
      [.items[] | select(.spec.nodeName == $n and .status.phase != "Succeeded" and .status.phase != "Failed")] |
      "\([.[] | [.spec.containers[] | .resources.requests.memory // "0" | mem] | add] | add // 0) \([.[] | select(.metadata.namespace != $ns and (.metadata.namespace | test("^(openshift|kube)") | not))] | length)"' "$TMP/allpods.json")
    read -r napp nreq < <(jq -r --arg n "$n" "$JQDEF"'
      [.items[] | select(.spec.nodeName == $n and .status.phase != "Succeeded" and .status.phase != "Failed")] |
      "\(length) \([.[] | [.spec.containers[] | .resources.requests.memory // "0" | mem] | add] | add // 0)"' "$TMP/pods.json")
    used=$(getv "$n" "$TMP/n_used.txt"); nuse=$(getv "$n" "$TMP/n_nsused.txt")
    stl=$(getv "$n" "$TMP/n_steal.txt"); cpa=$(getv "$n" "$TMP/n_cpuavg.txt"); cpm=$(getv "$n" "$TMP/n_cpumax.txt"); al=$(getv "$n" "$TMP/n_alert.txt")
    local fsched freal ratio
    fsched=$(awk -v a="$alloc" -v r="$reqall" 'BEGIN{print a-r}')
    freal=$(awk -v a="$alloc" -v u="${used:-0}" 'BEGIN{print a-u}')
    ratio=$(awk -v u="${nuse:-0}" -v r="$nreq" 'BEGIN{ if (r<=0) print "-"; else printf "%.2f", u/r }')
    printf '  %-18s %5s %7s %7s %7s %7s %7s %7s %6s %5s %4s %-8s\n' "$(short "$n")" "$napp" "$(fgib "$alloc")" "$(fgib "$reqall")" \
      "$(fgib "${used:-0}")" "$(fgib "$fsched")" "$(fgib "$freal")" "$ratio" \
      "$([[ -n $stl ]] && printf '%.0f' "$stl" || echo -)" "$([[ -n $cpa ]] && printf '%.0f/%.0f' "$cpa" "${cpm:-0}" || echo -)" \
      "$foreign" "$([[ $taint -gt 0 ]] && echo tak || echo nie)"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$n" "$alloc" "$cap" "$reqall" "${used:-0}" "$fsched" "$freal" "$ratio" "${stl:-0}" "${cpm:-0}" "$foreign" "$taint" "${al:-0}" >>"$TMP/nodes_rows.txt"
  done <"$TMP/hostnodes.txt"
  line "WOLNE sched = allocatable − suma requestów (co widzi scheduler). WOLNE real = allocatable − realne użycie pamięci."
  line "APP use/req = realne zużycie podów aplikacji / ich requesty. OBCE = pody innych aplikacji (bez openshift-*/kube-*)."

  # ================================================ 4. BILANS
  hdr "4. Bilans aplikacji (okno $D dni)"
  local s_req s_lim s_p95 s_max s_creq s_cp95 s_rst s_oom
  read -r s_req s_lim s_p95 s_max s_creq s_cp95 s_rst s_oom < <(awk -F'|' '{
      r+=$4*$3; l+=$5*$3; p+=$23*$3; m+=$24*$3; cr+=$6*$3; cp+=$25*$3; rs+=$28; o+=$17 }
      END { printf "%.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f\n", r, l, p, m, cr, cp, rs, o }' "$TMP/rowsf.txt")
  line "Pamięć — requesty: $(fgib "$s_req") GiB   zużycie p95: $(fgib "$s_p95") GiB   limity: $(fgib "$s_lim") GiB"
  line "CPU    — requesty: $(fcpu "$s_creq")   zużycie p95: $(fcpu "$s_cp95") rdzeni"
  line "Restarty w okresie: $s_rst   OOMKilled (ostatnie zakończenie bieżących podów): $s_oom"

  # ================================================ 5. ANALIZA
  hdr "5. Analiza"
  local cnt list

  topl() { # $1=warunek awk  $2=pole sortowania  $3=format
    awk -F'|' "$1" "$TMP/rowsf.txt" | sort -t'|' -k"$2","$2"nr | head -"$TOP" | awk -F'|' "$3"
  }

  # --- pamięć
  local gap_total pct_under
  gap_total=$(awk -F'|' '{s+=$36} END{printf "%.0f", s}' "$TMP/rowsf.txt")
  cnt=$(awk -F'|' 'index($29,"M")' "$TMP/rowsf.txt" | wc -l)
  if (( cnt > 0 )); then
    app_w "Pamięć: $cnt z $nwl workloadów zużywa więcej niż deklaruje — łącznie $(fgib "$gap_total") GiB poza wiedzą schedulera (requesty $(fgib "$s_req") GiB vs p95 $(fgib "$s_p95") GiB)"
    line "Skutek: scheduler upycha pody, jakby pamięci było więcej; przy braku pamięci te pody są ewakuowane pierwsze."
    topl 'index($29,"M")' 36 '{ printf "         %-32s req %-7s p95 %-7s ×%d replik → brakuje %.1f GiB\n", substr($1,1,32), ($4>0? sprintf("%.1fGi",$4/1073741824):"brak"), sprintf("%.1fGi",$23/1073741824), $3, $36/1073741824 }'
  else
    good "Pamięć: requesty pokrywają realne zużycie (p95) we wszystkich workloadach"
  fi
  cnt=$(awk -F'|' 'index($29,"O")' "$TMP/rowsf.txt" | wc -l)
  (( cnt > 0 )) && { app_c "OOMKilled (workloadów: $cnt): pody zabite za przekroczenie limitu pamięci — limit za niski dla realnego zużycia"
    topl 'index($29,"O")' 17 '{ printf "         %-32s limit %-7s maks. zużycie %s\n", substr($1,1,32), ($5>0? sprintf("%.1fGi",$5/1073741824):"brak"), sprintf("%.1fGi",$24/1073741824) }'; }
  local over_lim
  over_lim=$(awk -F'|' -v l="$s_lim" -v a="$(awk -F'|' '{s+=$2} END{print s+0}' "$TMP/nodes_rows.txt")" 'BEGIN{ if (a>0 && l>a) printf "%.0f", l*100/a }')
  [[ -n $over_lim ]] && note "Suma limitów pamięci aplikacji = ${over_lim}% allocatable jej nodów (overcommit limitów; ostrzeżenie w konsoli wynika z tego)"
  cnt=$(awk -F'|' '$8==1' "$TMP/rowsf.txt" | wc -l)
  local over_n over_g
  over_n=$(awk -F'|' '$23>0 && $4>=1073741824 && $4 > $23*2' "$TMP/rowsf.txt" | wc -l)
  over_g=$(awk -F'|' '$23>0 && $4>=1073741824 && $4 > $23*2 {s+=($4-$23*1.2)*$3} END{printf "%.0f", s}' "$TMP/rowsf.txt")
  (( over_n > 0 )) && note "Przewymiarowane requesty pamięci (workloadów: $over_n): request >2× p95 — ok. $(fgib "$over_g") GiB zarezerwowane bez potrzeby"
  (( cnt > 0 )) && app_w "BestEffort (workloadów: $cnt): brak requestów i limitów — scheduler nie wie o nich nic, pierwsze do ewakuacji"

  # --- CPU / throttling
  cnt=$(awk -F'|' 'index($29,"T")' "$TMP/rowsf.txt" | wc -l)
  if (( cnt > 0 )); then
    app_w "Throttling CPU (workloadów: $cnt): dochodzi do ≥${THROTTLE_WARN}% throttlingu — limit CPU dławi pod (najczęściej przy starcie, wydłużając go)"
    topl 'index($29,"T")' 27 '{ printf "         %-32s limit %-6s maks. zużycie %-6s throttling %d%%\n", substr($1,1,32), ($7>=1000? sprintf("%.1f",$7/1000): $7 "m"), ($26>=1000? sprintf("%.1f",$26/1000): $26 "m"), $27 }'
  else
    good "Throttling CPU poniżej ${THROTTLE_WARN}% (lub brak limitów CPU)"
  fi
  local cpu_ratio
  cpu_ratio=$(awk -v r="$s_creq" -v p="$s_cp95" 'BEGIN{ if (p>0) printf "%.1f", r/p; else print 0 }')
  awk -v x="$cpu_ratio" 'BEGIN{exit !(x>=3)}' && note "CPU: requesty ${cpu_ratio}× wyższe niż zużycie p95 — rezerwują CPU, którego aplikacja w praktyce nie używa (blokuje pojemność)"

  # --- start vs probe
  local s_crit s_risk
  s_crit=$(awk -F'|' '{b=($9==1)?$10:$11} $14>0 && b>0 && $14>=b' "$TMP/rowsf.txt" | wc -l)
  s_risk=$(awk -F'|' -v sr="$START_RISK" '{b=($9==1)?$10:$11} $14>0 && b>0 && $14<b && $14*100/b>=sr' "$TMP/rowsf.txt" | wc -l)
  local nostart; nostart=$(awk -F'|' '$9==0 && $11>0' "$TMP/rowsf.txt" | wc -l)
  if (( s_crit > 0 )); then
    app_c "Start dłuższy niż budżet probe (workloadów: $s_crit) — przy obciążeniu noda kubelet zabija je w trakcie startu (pętla restartów)"
  fi
  if (( s_risk > 0 )); then
    app_w "Start zużywa ≥${START_RISK}% budżetu probe (workloadów: $s_risk) — przy jednoczesnym starcie wielu podów przekroczą budżet"
  fi
  (( s_crit + s_risk > 0 )) && topl '{b=($9==1)?$10:$11} $14>0 && b>0 && $14*100/b>='"$START_RISK" 14 \
     '{ b=($9==1)?$10:$11; printf "         %-32s start %4ds  budżet %4ds (%s)  %d%%\n", substr($1,1,32), $14, b, ($9==1?"startupProbe":"liveness"), $14*100/b }'
  (( s_crit + s_risk == 0 )) && good "Zmierzone czasy startu mieszczą się w budżetach probe z zapasem"
  (( nostart > 0 )) && note "Bez startupProbe (workloadów: $nostart) — czas startu i wykrywanie awarii zależą od tego samego parametru liveness"
  line "Pomiar dotyczy ostatniego startu bieżących podów — przy lawinie startów (reboot noda) czasy są wielokrotnie dłuższe."

  # --- restarty
  cnt=$(awk -F'|' 'index($29,"R")' "$TMP/rowsf.txt" | wc -l)
  if (( cnt > 0 )); then
    local killed; killed=$(awk -F'|' 'index($29,"R") && $18>0' "$TMP/rowsf.txt" | wc -l)
    app_w "Restarty (workloadów: $cnt) ≥${RESTART_WARN} w $D dni (łącznie $s_rst); u $killed z nich ostatnie zakończenie to SIGKILL (exit 137) — typowo zabicie przez liveness"
    topl 'index($29,"R")' 28 '{ printf "         %-32s %5d restartów  (OOM: %d, exit 137: %d)\n", substr($1,1,32), $28, $17, $18 }'
  else
    good "Restarty poniżej ${RESTART_WARN} na workload w $D dni"
  fi

  # --- probe exec
  local ex_n ex_w
  ex_w=$(awk -F'|' '$13>0' "$TMP/rowsf.txt" | wc -l); ex_n=$(awk -F'|' '{s+=$13*$3} END{print s+0}' "$TMP/rowsf.txt")
  (( ex_w > 0 )) && app_w "Probe typu exec: $ex_n (workloadów: $ex_w) — każda uruchamia proces przez crio co kilka sekund (obciąża kubelet/crio)"

  # --- rozłożenie / PDB
  cnt=$(awk -F'|' 'index($29,"D")' "$TMP/rowsf.txt" | wc -l)
  if (( cnt > 0 )); then
    app_w "Rozłożenie replik (workloadów: $cnt): większość replik na jednym nodzie — restart noda zabiera większość instancji"
    topl 'index($29,"D")' 19 '{ printf "         %-32s %d replik, maks. %d na jednym nodzie (%d nodów)\n", substr($1,1,32), $3, $19, $20 }'
  else
    good "Repliki rozłożone na różne nody"
  fi
  local nopdb; nopdb=$(awk -F'|' '$3>1 && $21=="-"' "$TMP/rowsf.txt" | wc -l)
  (( nopdb > 0 )) && note "Brak PDB (workloadów z >1 repliką: $nopdb) — drain może zabrać wszystkie instancje naraz"
  cnt=$(awk -F'|' 'index($29,"P")' "$TMP/rowsf.txt" | wc -l)
  (( cnt > 0 )) && app_w "PDB blokuje drain (workloadów: $cnt): disruptionsAllowed=0 — upgrade/zmiana MCO utknie na ich nodach"

  # --- platforma
  local pn_mem pn_steal pn_alert pn_foreign pn_taint
  pn_mem=$(awk -F'|' '$2>0 && $5/$2 >= 0.9 {split($1,a,"."); printf "%s (%.0f%%) ", a[1], $5*100/$2}' "$TMP/nodes_rows.txt")
  pn_steal=$(awk -F'|' '$9+0 >= 5 {split($1,a,"."); printf "%s (%.0f%%) ", a[1], $9}' "$TMP/nodes_rows.txt")
  pn_alert=$(awk -F'|' '$13+0 > 0 {split($1,a,"."); printf "%s ", a[1]}' "$TMP/nodes_rows.txt")
  pn_foreign=$(awk -F'|' '{s+=$11} END{print s+0}' "$TMP/nodes_rows.txt")
  pn_taint=$(awk -F'|' '$12+0 > 0' "$TMP/nodes_rows.txt" | wc -l)
  if [[ -n $pn_mem ]]; then plat_c "Pamięć nodów ≥90% allocatable: $pn_mem— realny brak miejsca"; else good "Nody mają realny zapas pamięci (<90% allocatable)"; fi
  if [[ -n $pn_steal ]]; then plat_w "Steal time ≥5%: $pn_steal— VM-ki czekają na CPU hosta (warstwa wirtualizacji)"; else good "Steal time <5% — warstwa wirtualizacji nie dławi nodów"; fi
  if [[ -n $pn_alert ]]; then plat_w "SystemMemoryExceedsReservation na: $pn_alert— rezerwacja systemowa do poprawy"; else good "Rezerwacje systemowe nodów wystarczające (brak alertu SystemMemoryExceedsReservation)"; fi
  local sched_vs_real
  sched_vs_real=$(awk -F'|' '{ d=$6-$7; if (d > 10*1073741824) { split($1,a,"."); printf "%s (scheduler: %.0f GiB wolnego, realnie: %.0f) ", a[1], $6/1073741824, $7/1073741824 } }' "$TMP/nodes_rows.txt")
  [[ -n $sched_vs_real ]] && note "Scheduler przecenia wolną pamięć: $sched_vs_real— requesty podów na tych nodach są dużo niższe niż realne zużycie"
  if (( pn_foreign > 0 && pn_taint == 0 )); then
    note "Na nodach aplikacji działa $pn_foreign podów innych aplikacji, nody bez taintu — problemy tej aplikacji dotykają też innych (i odwrotnie)"
  fi
  local nvpa; nvpa=$(jq '.items | length' "$TMP/vpa.json" 2>/dev/null)
  local cro; cro=$(jq -r '.metadata.labels["clusterresourceoverrides.admission.autoscaling.openshift.io/enabled"] // "false"' "$TMP/ns.json" 2>/dev/null)
  [[ ${nvpa:-0} -gt 0 ]] && note "VPA w namespace: $nvpa obiektów — porównaj rekomendacje VPA z tabelą w sekcji 6"
  [[ $cro == true ]] && note "Namespace ma włączony ClusterResourceOverride — requesty podów są wyliczane z limitów"

  # ================================================ 6. REKOMENDACJE
  hdr "6. Rekomendowane wartości per pod (do manifestów aplikacji — nic nie jest wdrażane)"
  printf '  %s%-28s %9s %9s %9s %9s %9s %9s %-14s%s\n' "$BOLD" "WORKLOAD" "MEMreq" "→" "MEMlim" "→" "CPUreq" "CPUlim" "startupProbe" "$N"
  awk -F'|' '$30>0' "$TMP/rowsf.txt" | head -$(( TOP * 3 )) | while IFS='|' read -r -a f; do
    printf '  %-28s %9s %9s %9s %9s %9s %9s %-14s\n' "${f[0]:0:28}" \
      "$(fmem "${f[3]}")" "$(fmem "${f[30]}")" "$(fmem "${f[4]}")" "$(fmem "${f[31]}")" \
      "$(fcpu "${f[32]}")" "${f[33]}" "$([[ -n ${f[34]} ]] && echo "10s × ${f[34]}" || echo -)"
  done
  local nrec; nrec=$(awk -F'|' '$30>0' "$TMP/rowsf.txt" | wc -l)
  (( nrec > TOP * 3 )) && line "… pokazano $(( TOP * 3 )) z $nrec workloadów z problemami (pełna lista w CSV przy OUT_DIR)."
  line "MEMreq = p95 × $MEM_MARGIN (zaokr. do 256Mi); MEMlim = maks. zużycie × 1.15 (≥ request); CPUreq = p95 zużycia;"
  line "CPUlim „usuń” = throttling ≥${THROTTLE_WARN}%; startupProbe = period 10s × failureThreshold ≈ 2× najdłuższy zmierzony start."
  line "Po zmianie requestów suma może przekroczyć pojemność nodów — sprawdź bilans przed wdrożeniem."
  local new_req
  new_req=$(awk -F'|' '{ v=($30>0)?$31:(($23>$4)?$23:$4); s+=v*$3 } END{printf "%.0f", s}' "$TMP/rowsf.txt")
  local alloc_sum; alloc_sum=$(awk -F'|' '{s+=$2} END{print s+0}' "$TMP/nodes_rows.txt")
  line "Suma requestów pamięci po zmianie: ok. $(fgib "$new_req") GiB przy $(fgib "$alloc_sum") GiB allocatable nodów aplikacji ($(awk -v a="$new_req" -v b="$alloc_sum" 'BEGIN{ if (b>0) printf "%.0f%%", a*100/b; else print "?" }'))."
  awk -v a="$new_req" -v b="$alloc_sum" 'BEGIN{exit !(b>0 && a > b*0.85)}' && \
    note "Po urealnieniu requestów aplikacja zajmie >85% pamięci swoich nodów — trzeba dodać noda lub obniżyć zużycie"

  # CSV
  if [[ -n $OUT_DIR ]]; then
    {
      echo "workload;kind;replicas;mem_req_Mi;mem_p95_Mi;mem_max_Mi;mem_lim_Mi;cpu_req_m;cpu_p95_m;cpu_max_m;cpu_lim_m;throttle_max_pct;start_max_s;probe_budget_s;startup_probe;restarts_${D}d;oom;exit137;max_per_node;pdb;flags;rec_mem_req_Mi;rec_mem_lim_Mi;rec_cpu_req_m;rec_cpu_lim;rec_startup_failureThreshold"
      awk -F'|' -v OFS=';' '{ b=($9==1)?$10:$11; M=1048576
        print $1,$2,$3,int($4/M),int($23/M),int($24/M),int($5/M),$6,$25,$26,$7,$27,$14,b,($9==1?"tak":"nie"),$28,$17,$18,$19,$21,$29,int($31/M),int($32/M),$33,$34,$35 }' "$TMP/rowsf.txt"
    } >"$OUT_DIR/workloads.csv"
  fi

  # ================================================ WNIOSKI
  hdr "WNIOSKI"
  printf '%sCo jest w porządku (%d):%s\n' "$BOLD$G" "${#F_OK[@]}" "$N"
  for x in "${F_OK[@]}"; do printf '  • %s\n' "$x"; done
  printf '\n%sPo stronie APLIKACJI (%d):%s\n' "$BOLD$Y" "${#F_APP[@]}" "$N"
  if (( ${#F_APP[@]} )); then for x in "${F_APP[@]}"; do printf '  • %s\n' "$x"; done; else printf '  • brak problemów\n'; fi
  printf '\n%sPo stronie PLATFORMY (%d):%s\n' "$BOLD$Y" "${#F_PLAT[@]}" "$N"
  if (( ${#F_PLAT[@]} )); then for x in "${F_PLAT[@]}"; do printf '  • %s\n' "$x"; done; else printf '  • brak problemów\n'; fi
  if (( ${#F_INFO[@]} )); then
    printf '\n%sInformacje (%d):%s\n' "$BOLD$C" "${#F_INFO[@]}" "$N"
    for x in "${F_INFO[@]}"; do printf '  • %s\n' "$x"; done
  fi

  printf '\n%sOcena:%s\n' "$BOLD" "$N"
  local na=${#F_APP[@]} np=${#F_PLAT[@]}
  if (( na == 0 && np == 0 )); then
    printf '  Aplikacja i jej nody są skonfigurowane poprawnie w świetle zebranych danych.\n'
  elif (( np == 0 )); then
    printf '  Nody i platforma są w dobrym stanie. Wszystkie zidentyfikowane problemy wynikają z konfiguracji\n'
    printf '  aplikacji (zasoby, probe, rozłożenie replik). Zmiany po stronie platformy ich nie usuną.\n'
  elif (( na == 0 )); then
    printf '  Konfiguracja aplikacji jest poprawna — problemy leżą po stronie platformy (patrz wyżej).\n'
  else
    printf '  Problemy są po obu stronach: platforma — %d, aplikacja — %d. Najpierw usuń pozycje KRYTYCZNE,\n' "$np" "$na"
    printf '  potem największe rozbieżności zasobów (sekcja 6).\n'
  fi

  (( CRITS )) && return 2
  (( WARNS )) && return 1
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

run() {
  if [[ $ANONYMIZE == 1 ]]; then
    build_anon_sed
    main | sed -f "$TMP/anon.sed"
    return "${PIPESTATUS[0]}"
  else
    main
  fi
}

if [[ -n $OUT_DIR ]]; then
  mkdir -p "$OUT_DIR" || die "nie mogę utworzyć $OUT_DIR"
  run | tee "$OUT_DIR/report.txt"
  rc=${PIPESTATUS[0]}
  if [[ -f $OUT_DIR/workloads.csv && $ANONYMIZE == 1 && -f $TMP/anon.sed ]]; then
    sed -i -f "$TMP/anon.sed" "$OUT_DIR/workloads.csv"
  fi
  printf '\nZapisano: %s/report.txt, %s/workloads.csv\n' "$OUT_DIR" "$OUT_DIR"
  exit "$rc"
else
  run
  exit $?
fi
