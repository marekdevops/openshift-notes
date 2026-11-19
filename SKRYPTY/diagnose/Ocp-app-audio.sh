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
#     HTML=audyt-$(date +%F_%H%M).html ./ocp-app-audit.sh moja-aplikacja
#
#  Zmienne (opcjonalne):
#     DAYS=7              okres analizy (skracany automatycznie do retencji)
#     MEM_MARGIN=1.2      zapas nad p95 pamięci dla rekomendowanego requestu
#     THROTTLE_WARN=30    % throttlingu CPU uznawany za problem
#     RESTART_WARN=10     restarty workloadu w okresie uznawane za problem
#     START_RISK=50       % budżetu liveness zużyty przez start = ryzyko
#     TOP=10              ile najgorszych workloadów wymieniać we wnioskach
#     OUT_DIR=            katalog lokalny na raport (report.txt) i CSV
#     ANONYMIZE=1         zamaskuj nazwy nodów, domenę, użytkownika (także w HTML)
#     HTML=plik.html      dodatkowo zapisz raport HTML: wykresy z okresu DAYS
#                         (pamięć/CPU per workload, bilans namespace vs requesty
#                         i limity, restarty, throttling, pamięć nodów), tabele,
#                         wnioski, rekomendacje i pełny raport tekstowy
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
HTML=${HTML:-}

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
usage() { sed -n '3,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1; }

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
  local na=${#F_APP[@]} np=${#F_PLAT[@]} ocena
  if (( na == 0 && np == 0 )); then
    ocena="Aplikacja i jej nody są skonfigurowane poprawnie w świetle zebranych danych."
  elif (( np == 0 )); then
    ocena="Nody i platforma są w dobrym stanie. Wszystkie zidentyfikowane problemy wynikają z konfiguracji aplikacji (zasoby, probe, rozłożenie replik). Zmiany po stronie platformy ich nie usuną."
  elif (( na == 0 )); then
    ocena="Konfiguracja aplikacji jest poprawna — problemy leżą po stronie platformy (patrz wyżej)."
  else
    ocena="Problemy są po obu stronach: platforma — $np, aplikacja — $na. Najpierw usuń pozycje KRYTYCZNE, potem największe rozbieżności zasobów (sekcja 6)."
  fi
  fold -s -w 100 <<<"$ocena" | sed 's/^/  /'

  # dane dla raportu HTML (main moze dzialac w podpowloce - przez pliki)
  if [[ -n $HTML ]]; then
    printf '%s\n' "${F_OK[@]}"   >"$TMP/f_ok.txt"
    printf '%s\n' "${F_APP[@]}"  >"$TMP/f_app.txt"
    printf '%s\n' "${F_PLAT[@]}" >"$TMP/f_plat.txt"
    printf '%s\n' "${F_INFO[@]}" >"$TMP/f_info.txt"
    printf '%s\n' "$ocena" >"$TMP/ocena.txt"
    printf '%s\n' "D=$D" "AVAIL=$avail" "NWL=$nwl" "NPODS=$npods" "NNODES=$nnodes" "S_REQ=$s_req" "S_LIM=$s_lim" "S_P95=$s_p95" \
      "S_MAX=$s_max" "S_CREQ=$s_creq" "S_CP95=$s_cp95" "S_RST=$s_rst" "S_OOM=$s_oom" "NEW_REQ=$new_req" "ALLOC_SUM=$alloc_sum" \
      "SERVER=$(oc whoami --show-server 2>/dev/null)" "JOBS=${jobs:-0}" >"$TMP/meta.txt"
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

# ------------------------------------------------------------- raport HTML (HTML=plik.html)
prom_range() { # $1=zapytanie $2=plik.json $3=start $4=koniec $5=krok(s)
  oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
     curl -sG --data-urlencode "query=$1" --data-urlencode "start=$3" --data-urlencode "end=$4" --data-urlencode "step=$5" \
     http://localhost:9090/api/v1/query_range >"$2" 2>/dev/null
  jq -e '.status == "success"' "$2" >/dev/null 2>&1 || echo '{"data":{"result":[]}}' >"$2"
}

build_html() {
  [[ -s $TMP/meta.txt ]] || { printf 'Raport HTML: brak danych z audytu - pomijam.\n' >&2; return 1; }
  local D SERVER k v
  while IFS='=' read -r k v; do case $k in D) D=$v;; SERVER) SERVER=$v;; esac; done <"$TMP/meta.txt"
  printf 'Raport HTML: pobieram przebiegi z %s dni...\n' "$D" >&2
  local T1 ST T0
  T1=$(date +%s); ST=$(( D * 86400 / 700 / 600 * 600 )); (( ST < 600 )) && ST=600
  T1=$(( T1 / ST * ST )); T0=$(( T1 - D * 86400 ))
  local OWN="max by (namespace, pod, owner_name) (kube_pod_owner{namespace=\"$NS\"})"
  local CSEL="namespace=\"$NS\", container!=\"\", container!=\"POD\""
  local J="* on (namespace, pod) group_left(owner_name) $OWN"
  oc get rs -n "$NS" -o json 2>/dev/null | jq -c '[.items[]? | {key: .metadata.name, value: ([.metadata.ownerReferences[]? | select(.kind == "Deployment") | .name][0] // null)}
     | select(.value != null)] | from_entries' >"$TMP/rsmap.json" 2>/dev/null || echo '{}' >"$TMP/rsmap.json"
  [[ -s $TMP/rsmap.json ]] || echo '{}' >"$TMP/rsmap.json"
  : >"$TMP/charts.jsonl"
  # hchart ID JEDNOSTKA TYTUL OPIS ZAPYTANIE [maks_serii]
  hchart() {
    local id=$1 unit=$2 title=$3 desc=$4 q=$5 top=${6:-7}
    prom_range "$q" "$TMP/h_$id.json" "$T0" "$T1" "$ST"
    jq -c --arg id "$id" --arg unit "$unit" --arg title "$title" --arg desc "$desc" --argjson top "$top" --slurpfile rs "$TMP/rsmap.json" '
      def num: if type == "number" then . elif type == "string" and test("^[-+]?[0-9.]+([eE][-+]?[0-9]+)?$") then tonumber else null end;
      def wl: if $rs[0][.] then $rs[0][.] elif test("-[a-z0-9]{6,10}$") then sub("-[a-z0-9]+$"; "") else . end;
      { id: $id, unit: $unit, title: $title, desc: $desc,
        series: ([.data.result[]
                  | {name: (.metric.s // (.metric.owner_name | if . then wl else null end) // .metric.instance // .metric.node // $title),
                     pts: [.values[] | [(.[0] | floor), (.[1] | num)] | select(.[1] | type == "number")]}]
                 | group_by(.name)
                 | map({name: .[0].name, pts: ([.[].pts[]] | group_by(.[0]) | map([.[0][0], ([.[][1]] | add)]))})
                 | map(select(.pts | length > 0) | . + {peak: ([.pts[][1]] | max)})
                 | (map(select(.name | test("^(REQUESTY|LIMITY)")))) as $ref
                 | (map(select(.name | test("^(REQUESTY|LIMITY)") | not)) | sort_by(-.peak)) as $s
                 | (if ($s | length) > $top then $s[:($top - 1)] + [{name: "pozostałe \(($s | length) - $top + 1) (max z nich)",
                       pts: ([$s[($top - 1):][].pts[]] | group_by(.[0]) | map([.[0][0], ([.[][1]] | max)]))} | . + {peak: ([.pts[][1]] | max)}]
                    else $s end) + $ref) }' "$TMP/h_$id.json" >>"$TMP/charts.jsonl" 2>/dev/null || true
  }
  local SR="[${ST}s]"
  local SQ="[${ST}s:5m]"
  hchart ns_mem bytes "Pamięć namespace: zużycie vs requesty vs limity" \
    "Suma working set wszystkich podów (maksimum w kroku) na tle sumy requestów i limitów. Zużycie powyżej requestów = pamięć, o której scheduler nie wie." \
    "label_replace(max_over_time(sum(container_memory_working_set_bytes{$CSEL})$SQ), \"s\", \"zużycie\", \"\", \"\") or label_replace(max_over_time(sum(kube_pod_container_resource_requests{namespace=\"$NS\",resource=\"memory\"})$SQ), \"s\", \"REQUESTY\", \"\", \"\") or label_replace(max_over_time(sum(kube_pod_container_resource_limits{namespace=\"$NS\",resource=\"memory\"})$SQ), \"s\", \"LIMITY\", \"\", \"\")"
  hchart ns_cpu cores "CPU namespace: zużycie vs requesty vs limity" \
    "Suma zużycia CPU podów (rate 5m, maksimum w kroku) na tle sumy requestów i limitów CPU." \
    "label_replace(max_over_time(sum(rate(container_cpu_usage_seconds_total{$CSEL}[5m]))$SQ), \"s\", \"zużycie\", \"\", \"\") or label_replace(max_over_time(sum(kube_pod_container_resource_requests{namespace=\"$NS\",resource=\"cpu\"})$SQ), \"s\", \"REQUESTY\", \"\", \"\") or label_replace(max_over_time(sum(kube_pod_container_resource_limits{namespace=\"$NS\",resource=\"cpu\"})$SQ), \"s\", \"LIMITY\", \"\", \"\")"
  hchart wl_mem bytes "Pamięć per workload (suma podów)" \
    "Working set wszystkich replik workloadu (maksimum w kroku). Linia rosnąca do restartu i spadająca = wyciek lub cache; skoki = obciążenie." \
    "sum by (owner_name) (max_over_time(container_memory_working_set_bytes{$CSEL}$SR) $J)"
  hchart wl_cpu cores "CPU per workload (suma podów)" \
    "Zużycie CPU wszystkich replik workloadu (rate 5m, maksimum w kroku)." \
    "max_over_time((sum by (owner_name) (rate(container_cpu_usage_seconds_total{$CSEL}[5m]) $J))$SQ)"
  hchart wl_rst int "Restarty kontenerów per workload (na krok)" \
    "Ile razy kontenery workloadu zostały uruchomione ponownie w każdym kroku." \
    "sum by (owner_name) (increase(kube_pod_container_status_restarts_total{namespace=\"$NS\"}$SR) $J) > 0"
  hchart wl_thr pct "Throttling CPU per workload (maks. %)" \
    "Najwyższy w kroku % okresów CPU zdławionych przez limit (najgorszy pod workloadu). Powyżej ~${THROTTLE_WARN}% aplikacja zwalnia, start się wydłuża." \
    "max_over_time((max by (owner_name) ((sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{$CSEL}[5m])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{$CSEL}[5m]))) $J))$SQ) * 100"
  if [[ -s $TMP/hostnodes.txt ]]; then
    local NRE; NRE=$(sed 's/\./\\\\./g' "$TMP/hostnodes.txt" | paste -sd'|')
    hchart node_mem pct "Pamięć nodów, na których działa aplikacja (%)" \
      "100% minus najniższa MemAvailable w kroku. Przy ~100% kernel zabija procesy (OOM noda), kubelet ewakuuje pody." \
      "100 * (1 - min_over_time(node_memory_MemAvailable_bytes{instance=~\"$NRE\"}$SR) / max_over_time(node_memory_MemTotal_bytes{instance=~\"$NRE\"}$SR))"
  fi

  sed 's/\x1b\[[0-9;]*m//g' "$TMP/report.txt" >"$TMP/report.clean.txt" 2>/dev/null || : >"$TMP/report.clean.txt"
  jq -nc --arg ns "$NS" --arg server "$SERVER" --arg gen "$(date '+%F %T %Z')" --argjson t0 "$T0" --argjson t1 "$T1" --argjson st "$ST" \
    --rawfile meta "$TMP/meta.txt" --rawfile fok "$TMP/f_ok.txt" --rawfile fapp "$TMP/f_app.txt" --rawfile fplat "$TMP/f_plat.txt" \
    --rawfile finfo "$TMP/f_info.txt" --rawfile ocena "$TMP/ocena.txt" --rawfile rows "$TMP/rowsf.txt" --rawfile nodes "$TMP/nodes_rows.txt" \
    --rawfile report "$TMP/report.clean.txt" --slurpfile charts "$TMP/charts.jsonl" \
    --argjson tw "$THROTTLE_WARN" --argjson rw "$RESTART_WARN" --arg mm "$MEM_MARGIN" '
    def lines($s): $s | split("\n") | map(select(length > 0));
    { meta: ({ns: $ns, server: $server, generated: $gen, start: $t0, end: $t1, stepS: $st, tw: $tw, rw: $rw, mm: $mm}
             + (lines($meta) | map(capture("^(?<k>[A-Z_0-9]+)=(?<v>.*)$")) | map({key: .k, value: .v}) | from_entries)),
      findings: ([lines($fapp)[] | {l: (if startswith("[CRIT]") then "KRYT" else "OSTR" end), s: "APLIKACJA", t: sub("^\\[(CRIT|WARN)\\] "; "")}]
               + [lines($fplat)[] | {l: (if startswith("[CRIT]") then "KRYT" else "OSTR" end), s: "PLATFORMA", t: sub("^\\[(CRIT|WARN)\\] "; "")}]
               + [lines($finfo)[] | {l: "INFO", s: "-", t: .}] + [lines($fok)[] | {l: "OK", s: "-", t: .}]),
      ocena: ($ocena | rtrimstr("\n")),
      rows: [lines($rows)[] | split("|")], nodes: [lines($nodes)[] | split("|")],
      charts: $charts, report: $report }' | sed 's#</#<\\/#g' >"$TMP/data.json" \
    || { printf 'Raport HTML: nie udało się złożyć danych (jq).\n' >&2; return 1; }
  [[ $ANONYMIZE == 1 && -f $TMP/anon.sed ]] && sed -i -f "$TMP/anon.sed" "$TMP/data.json"
  html_template | awk -v f="$TMP/data.json" '$0=="__DATA__"{ while ((getline l < f) > 0) print l; next } { print }' >"$HTML"
  printf 'Raport HTML zapisany: %s (%s). Zawiera nazwy z klastra - nie wrzucaj go do repozytorium.\n' "$HTML" "$(du -h "$HTML" | cut -f1)" >&2
}

html_template() { cat <<'HTMLEOF'
<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Audyt aplikacji</title>
<style>
:root {
  color-scheme: light;
  --page:#f9f9f7; --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,0.10);
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a; --s4:#eda100; --s5:#e87ba4; --s6:#008300; --s7:#6250d6;
  --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --page:#0d0d0d; --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10);
    --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; --s6:#0ca30c; --s7:#9085e9;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page:#0d0d0d; --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10);
  --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; --s6:#0ca30c; --s7:#9085e9;
}
* { box-sizing: border-box; }
body { margin:0; background:var(--page); color:var(--ink);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 1240px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 22px; margin: 0 0 4px; overflow-wrap:anywhere; }
h2 { font-size: 16px; margin: 0 0 2px; }
.meta { color: var(--ink2); font-size: 13px; }
.meta code { font-size: 12px; overflow-wrap:anywhere; }
.tiles { display:grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap:12px; margin:20px 0; }
.tile, .card { background:var(--surface); border:1px solid var(--border); border-radius:10px; }
.tile { padding:14px 16px; }
.tile .lbl { color:var(--ink2); font-size:12px; }
.tile .val { font-size:26px; font-weight:650; font-variant-numeric: tabular-nums; margin:2px 0; }
.tile .sub { color:var(--muted); font-size:12px; overflow-wrap:anywhere; }
.card { padding:16px; margin:0 0 16px; min-width:0; }
.card .desc { color:var(--ink2); font-size:13px; margin:0 0 10px; max-width:100ch; }
.cause { border-left:4px solid var(--warning); }
.cause.ok { border-left-color: var(--good); } .cause.bad { border-left-color: var(--critical); }
.cause .t { font-size:16px; font-weight:600; margin:4px 0; max-width:110ch; }
.findings { list-style:none; padding:0; margin:0; }
.findings li { display:flex; gap:10px; padding:8px 0; border-top:1px solid var(--grid); }
.findings li:first-child { border-top:0; }
.badge { flex:none; display:inline-flex; align-items:center; gap:5px; font-size:11px; font-weight:650;
  padding:2px 8px; border-radius:999px; height:20px; margin-top:1px; color:#0b0b0b; white-space:nowrap; }
.badge.KRYT { background:var(--critical); color:#fff; } .badge.OSTR { background:var(--warning); }
.badge.INFO { background:var(--grid); color:var(--ink); } .badge.OK { background:var(--good); color:#fff; }
.side { color:var(--muted); font-size:12px; margin-right:4px; }
.legend { display:flex; flex-wrap:wrap; gap:4px 14px; margin:0 0 6px; }
.legend button { all:unset; cursor:pointer; display:inline-flex; align-items:center; gap:6px; font-size:12px;
  color:var(--ink2); padding:2px 0; overflow-wrap:anywhere; }
.legend button[aria-pressed="false"] { opacity:.4; text-decoration: line-through; }
.legend button:focus-visible { outline:2px solid var(--s1); outline-offset:2px; border-radius:3px; }
.key { width:14px; height:0; border-top:2px solid; border-radius:2px; flex:none; }
.key.dash { border-top-style:dashed; }
.plot { position:relative; }
.plot svg { display:block; width:100%; overflow:visible; }
.plot svg text { fill: var(--muted); font-size:11px; font-variant-numeric: tabular-nums; }
.plot svg .peak-label { fill: var(--ink); font-weight:600; }
.tip { position:absolute; pointer-events:none; background:var(--surface); border:1px solid var(--border);
  border-radius:8px; padding:8px 10px; font-size:12px; box-shadow:0 4px 16px rgba(0,0,0,.12);
  min-width:180px; max-width:380px; display:none; z-index:2; }
.tip .t { color:var(--ink2); margin-bottom:4px; }
.tip .row { display:flex; align-items:center; gap:8px; }
.tip .row b { font-variant-numeric: tabular-nums; min-width:72px; }
.tip .row span:last-child { color:var(--ink2); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.empty { color:var(--muted); padding:24px 0; }
details { margin-top:10px; }
summary { cursor:pointer; color:var(--ink2); font-size:13px; }
.tbl { overflow-x:auto; }
table { border-collapse:collapse; font-size:12px; margin-top:8px; width:100%; }
th, td { text-align:left; padding:4px 10px 4px 0; border-bottom:1px solid var(--grid); white-space:nowrap; }
th { color:var(--ink2); font-weight:600; position:sticky; top:0; background:var(--surface); }
th.sort { cursor:pointer; } th.sort:hover { color:var(--ink); }
td.n, th.n { text-align:right; font-variant-numeric: tabular-nums; }
td.hot { color:var(--critical); font-weight:650; }
td.warm { font-weight:650; }
td.rec { font-weight:650; }
tr.crit td:first-child { box-shadow: inset 3px 0 0 var(--critical); padding-left:8px; }
tr.warn td:first-child { box-shadow: inset 3px 0 0 var(--warning); padding-left:8px; }
.flag { display:inline-block; min-width:16px; text-align:center; font-size:11px; font-weight:650; border-radius:4px; padding:0 3px; margin-right:2px; background:var(--grid); color:var(--ink); }
.flag.c { background:var(--critical); color:#fff; } .flag.w { background:var(--warning); color:#0b0b0b; }
#charts { display:grid; grid-template-columns: 1fr 1fr; gap:0 16px; }
#charts > .card { grid-column: 1 / -1; }
#charts > .card.half { grid-column: auto; }
@media (max-width: 760px) { #charts { grid-template-columns: 1fr; } #charts > .card.half { grid-column: 1 / -1; } }
pre.report { background:var(--page); border:1px solid var(--border); border-radius:8px; padding:12px;
  overflow:auto; font-size:12px; line-height:1.35; max-height:80vh; margin:8px 0 0; }
.sec summary { font-size:14px; color:var(--ink); font-weight:600; }
.note { color:var(--ink2); font-size:12px; margin:8px 0 0; max-width:120ch; }
</style>
</head>
<body>
<main>
  <h1 id="h1">Audyt aplikacji</h1>
  <div class="meta" id="meta"></div>
  <section class="tiles" id="tiles"></section>
  <section class="card cause" id="ocena"></section>
  <section class="card"><h2>Wnioski</h2><ul class="findings" id="findings"></ul></section>
  <div id="charts"></div>
  <section class="card"><h2>Workloady: konfiguracja vs rzeczywistość (na pod)</h2>
    <p class="desc">Kliknij nagłówek kolumny, aby posortować. Kolorem: zużycie ponad request, OOM, throttling i start blisko budżetu probe.</p>
    <div class="tbl"><table id="wl"></table></div>
    <p class="note" id="flags"></p></section>
  <section class="card"><h2>Rekomendowane wartości na pod</h2><p class="desc" id="recdesc"></p>
    <div class="tbl"><table id="rec"></table></div><p class="note" id="recsum"></p></section>
  <section class="card"><h2>Nody, na których działa aplikacja</h2>
    <p class="desc">Wolne sched = allocatable − suma requestów (co widzi scheduler). Wolne real = allocatable − realne użycie. Obce = pody innych aplikacji.</p>
    <div class="tbl"><table id="nodes"></table></div></section>
  <section class="card"><h2>Pełny raport tekstowy</h2><p class="desc">To samo, co skrypt wypisał w terminalu, podzielone na sekcje.</p><div id="report"></div></section>
</main>
<script id="data" type="application/json">
__DATA__
</script>
<script>
(function () {
  const D = JSON.parse(document.getElementById('data').textContent);
  const M = D.meta;
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const svgEl = (tag, attrs) => { const e = document.createElementNS('http://www.w3.org/2000/svg', tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; };
  const pad = n => String(n).padStart(2, '0');
  const fday = t => { const d = new Date(t * 1000); return pad(d.getDate()) + '.' + pad(d.getMonth() + 1); };
  const fhm = t => { const d = new Date(t * 1000); return pad(d.getHours()) + ':' + pad(d.getMinutes()); };
  const fdt = t => fday(t) + ' ' + fhm(t);
  const GI = 1073741824, MI = 1048576;
  function fmt(v, u) {
    if (v == null || isNaN(v)) return '-';
    if (v === 0) return '0';
    if (u === 'pct') return v.toFixed(v >= 10 ? 0 : 1) + '%';
    if (u === 'cores') return v >= 1 ? v.toFixed(2) : Math.round(v * 1000) + 'm';
    if (u === 'bytes') { const a = Math.abs(v);
      if (a >= GI) return (v / GI).toFixed(a >= 10 * GI ? 0 : 1) + ' GiB';
      if (a >= MI) return (v / MI).toFixed(0) + ' MiB';
      return (v / 1024).toFixed(0) + ' KiB'; }
    return String(Math.round(v * 10) / 10);
  }
  const fm = b => { b = +b; return b > 0 ? (b >= GI ? (b / GI).toFixed(1) + 'Gi' : Math.round(b / MI) + 'Mi') : '-'; };
  const fcm = m => { m = +m; return m > 0 ? (m >= 1000 ? (m / 1000).toFixed(1) : Math.round(m) + 'm') : '-'; };
  function niceMax(v, u) {
    if (u === 'pct' && v <= 100) return 100;
    if (!(v > 0)) return u === 'int' ? 4 : 1;
    if (u === 'int' && v <= 4) return 4;
    if (u === 'bytes') { const base = v >= GI ? GI : MI;
      const s = [1, 2, 4, 5, 8, 10, 16, 20, 25, 32, 40, 50, 64, 80, 100, 128, 160, 200, 256, 320, 400, 512, 640, 768, 1024];
      for (const x of s) if (x * base >= v * 1.05) return x * base; }
    const e = Math.pow(10, Math.floor(Math.log10(v * 1.05))); const f = v * 1.05 / e;
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * e;
  }

  // --- naglowek ---
  document.getElementById('h1').textContent = 'Audyt aplikacji w namespace ' + M.ns;
  document.title = 'Audyt ' + M.ns;
  const meta = document.getElementById('meta');
  meta.append('Klaster ', el('code', null, M.server), ' · okres ' + M.D + ' dni (' + fdt(M.start) + ' – ' + fdt(M.end) + ')' +
    (+M.D < +M.AVAIL || !M.AVAIL ? '' : '') + ' · wygenerowano ' + M.generated + ' · tylko odczyt, nic nie zmieniono w klastrze.');

  // --- kafelki ---
  const nApp = D.findings.filter(f => f.s === 'APLIKACJA').length, nPlat = D.findings.filter(f => f.s === 'PLATFORMA').length;
  const tiles = document.getElementById('tiles');
  [['Workloady / pody', M.NWL + ' / ' + M.NPODS, 'na ' + M.NNODES + ' nodach' + (+M.JOBS ? ' · pody jobów pominięte: ' + M.JOBS : '')],
   ['Pamięć: requesty → p95', fm(M.S_REQ) + ' → ' + fm(M.S_P95), 'limity ' + fm(M.S_LIM) + ' · maks. ' + fm(M.S_MAX)],
   ['CPU: requesty → p95', fcm(M.S_CREQ) + ' → ' + fcm(M.S_CP95), 'rdzeni, suma replik'],
   ['Restarty', M.S_RST || '0', 'w ' + M.D + ' dni · OOMKilled teraz: ' + (M.S_OOM || 0)],
   ['Problemy aplikacji', String(nApp), 'krytyczne: ' + D.findings.filter(f => f.s === 'APLIKACJA' && f.l === 'KRYT').length],
   ['Problemy platformy', String(nPlat), 'krytyczne: ' + D.findings.filter(f => f.s === 'PLATFORMA' && f.l === 'KRYT').length]]
  .forEach(([l, v, s]) => { const t = el('div', 'tile'); t.append(el('div', 'lbl', l), el('div', 'val', v), el('div', 'sub', s)); tiles.append(t); });

  // --- ocena ---
  const oc = document.getElementById('ocena');
  oc.classList.add(nApp + nPlat === 0 ? 'ok' : D.findings.some(f => f.l === 'KRYT') ? 'bad' : 'warn');
  oc.append(el('h2', null, 'Ocena: aplikacja czy platforma?'), el('div', 't', D.ocena || '-'));

  // --- wnioski ---
  const fl = document.getElementById('findings');
  const lvn = { KRYT: 'KRYTYCZNE', OSTR: 'UWAGA', INFO: 'INFO', OK: 'OK' }, ord = { KRYT: 0, OSTR: 1, INFO: 2, OK: 3 };
  if (!D.findings.length) fl.append(el('li', null, 'Brak wniosków.'));
  D.findings.slice().sort((a, b) => (ord[a.l] ?? 9) - (ord[b.l] ?? 9)).forEach(f => {
    const li = el('li'), tx = el('span');
    if (f.s && f.s !== '-') tx.append(el('span', 'side', f.s));
    tx.append(f.t); li.append(el('span', 'badge ' + f.l, lvn[f.l] || f.l), tx); fl.append(li); });

  // --- wykresy ---
  const host = document.getElementById('charts');
  const charts = [];
  for (const c of D.charts) {
    const card = el('section', 'card' + (/^(wl_rst|wl_thr)$/.test(c.id) ? ' half' : ''));
    card.append(el('h2', null, c.title), el('p', 'desc', c.desc)); host.append(card);
    if (!c.series.length) { card.append(el('div', 'empty', 'Brak danych w Prometheusie dla tego zapytania (albo brak zdarzeń w okresie).')); continue; }
    let ci = 0;
    c.series.forEach(s => { s.ref = /^(REQUESTY|LIMITY)/.test(s.name); s.color = s.ref ? (s.name.startsWith('LIMITY') ? 'var(--critical)' : 'var(--ink2)') : 'var(--s' + (++ci) + ')';
      s.on = true; s.map = new Map(s.pts.map(p => [p[0], p[1]])); });
    const lg = el('div', 'legend');
    if (c.series.length > 1) c.series.forEach(s => { const b = el('button'); b.type = 'button'; b.setAttribute('aria-pressed', 'true');
      const k = el('span', 'key' + (s.ref ? ' dash' : '')); k.style.borderTopColor = s.color;
      b.append(k, el('span', null, s.name + ' · max ' + fmt(s.peak, c.unit))); b.title = 'Pokaż/ukryj serię';
      b.onclick = () => { s.on = !s.on; b.setAttribute('aria-pressed', String(s.on)); draw(c); }; lg.append(b); });
    if (lg.childNodes.length) card.append(lg);
    const plot = el('div', 'plot'); card.append(plot); c.plot = plot;
    const det = el('details'); det.append(el('summary', null, 'Tabela: maksimum, kiedy, średnia, ostatnia wartość'));
    const wrap = el('div', 'tbl'), tb = el('table'), hr = el('tr');
    [['Seria', ''], ['Maksimum', 'n'], ['Kiedy', ''], ['Średnia', 'n'], ['Ostatnia', 'n']].forEach(([h, k]) => hr.append(el('th', k, h)));
    tb.append(hr);
    for (const s of c.series) { const tr = el('tr'); let pk = s.pts[0], sum = 0;
      for (const p of s.pts) { if (p[1] > pk[1]) pk = p; sum += p[1]; }
      tr.append(el('td', null, s.name), el('td', 'n', fmt(pk[1], c.unit)), el('td', null, fdt(pk[0])),
        el('td', 'n', fmt(sum / s.pts.length, c.unit)), el('td', 'n', fmt(s.pts[s.pts.length - 1][1], c.unit)));
      tb.append(tr); }
    wrap.append(tb); det.append(wrap); card.append(det);
    charts.push(c);
  }

  function draw(c) {
    const plot = c.plot; plot.textContent = '';
    const half = plot.parentNode.classList.contains('half');
    const W = Math.max(300, plot.clientWidth), H = W < 600 || half ? 220 : 280;
    const m = { l: 62, r: 14, t: 22, b: 26 }, iw = W - m.l - m.r, ih = H - m.t - m.b;
    const vis = c.series.filter(s => s.on);
    const vmax = niceMax(Math.max(0, ...vis.map(s => s.peak)), c.unit);
    const X = t => m.l + (t - M.start) / (M.end - M.start) * iw;
    const Y = v => m.t + ih - Math.min(Math.max(v, 0), vmax) / vmax * ih;
    const svg = svgEl('svg', { viewBox: '0 0 ' + W + ' ' + H, height: H, role: 'img', 'aria-label': c.title });
    for (let i = 0; i <= 4; i++) { const v = vmax * i / 4, y = Y(v);
      svg.append(svgEl('line', { x1: m.l, x2: W - m.r, y1: y, y2: y, stroke: i ? 'var(--grid)' : 'var(--axis)', 'stroke-width': 1 }));
      const tx = svgEl('text', { x: m.l - 8, y: y + 4, 'text-anchor': 'end' }); tx.textContent = fmt(v, c.unit); svg.append(tx); }
    // os X: polnoce (lub co 6/12h przy krotkim okresie)
    const span = (M.end - M.start) / 3600, maxTicks = Math.max(3, Math.floor(iw / 70));
    const hstep = [6, 12, 24, 48, 72, 168].find(h => span / h <= maxTicks) || 336;
    const d0 = new Date(M.start * 1000); d0.setMinutes(0, 0, 0);
    for (let t = d0.getTime() / 1000 + 3600; t < M.end; t += 3600) {
      const dd = new Date(t * 1000), hr = dd.getHours();
      if (hstep < 24 ? hr % hstep : (hr || Math.round((t - d0.getTime() / 1000) / 86400) % (hstep / 24))) continue;
      const x = X(t); svg.append(svgEl('line', { x1: x, x2: x, y1: m.t, y2: m.t + ih, stroke: 'var(--grid)', 'stroke-width': 1, 'stroke-dasharray': '2 3' }));
      const tx = svgEl('text', { x: x, y: H - 6, 'text-anchor': 'middle' }); tx.textContent = hr === 0 ? fday(t) : fhm(t); svg.append(tx); }
    const gap = M.stepS * 1.5;
    for (const s of vis) { let d = '', prev = null;
      for (const p of s.pts) { d += (prev === null || p[0] - prev > gap ? 'M' : 'L') + X(p[0]).toFixed(1) + ' ' + Y(p[1]).toFixed(1); prev = p[0]; }
      svg.append(svgEl('path', { d: d, fill: 'none', stroke: s.color, 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round', 'stroke-dasharray': s.ref ? '6 4' : 'none' })); }
    let pk = null; for (const s of vis) if (!s.ref) for (const p of s.pts) if (!pk || p[1] > pk.v) pk = { t: p[0], v: p[1], s: s };
    if (pk) { const x = X(pk.t), y = Y(pk.v);
      svg.append(svgEl('circle', { cx: x, cy: y, r: 4.5, fill: pk.s.color, stroke: 'var(--surface)', 'stroke-width': 2 }));
      const tx = svgEl('text', { x: Math.min(Math.max(x, m.l + 60), W - m.r - 60), y: Math.max(y - 9, 12), 'text-anchor': 'middle', class: 'peak-label' });
      tx.textContent = 'max ' + fmt(pk.v, c.unit) + ' · ' + fdt(pk.t); svg.append(tx); }
    const cross = svgEl('line', { y1: m.t, y2: m.t + ih, stroke: 'var(--muted)', 'stroke-width': 1, visibility: 'hidden' });
    const dots = svgEl('g', {}); svg.append(cross, dots);
    const hit = svgEl('rect', { x: m.l, y: 0, width: iw, height: H, fill: 'transparent' }); svg.append(hit);
    const tip = el('div', 'tip'); plot.append(svg, tip);
    const hide = () => { cross.setAttribute('visibility', 'hidden'); dots.textContent = ''; tip.style.display = 'none'; };
    hit.addEventListener('pointerleave', hide);
    hit.addEventListener('pointermove', ev => {
      const r = svg.getBoundingClientRect(), px = (ev.clientX - r.left) * W / r.width;
      const t = M.start + Math.round(((px - m.l) / iw * (M.end - M.start)) / M.stepS) * M.stepS;
      if (t < M.start || t > M.end) return hide();
      const x = X(t); cross.setAttribute('x1', x); cross.setAttribute('x2', x); cross.setAttribute('visibility', 'visible');
      dots.textContent = '';
      const rows = vis.map(s => ({ s: s, v: s.map.get(t) })).filter(o => o.v != null).sort((a, b) => b.v - a.v);
      for (const o of rows) dots.append(svgEl('circle', { cx: x, cy: Y(o.v), r: 4, fill: o.s.color, stroke: 'var(--surface)', 'stroke-width': 2 }));
      tip.textContent = ''; tip.append(el('div', 't', fdt(t)));
      if (!rows.length) tip.append(el('div', null, 'brak danych'));
      for (const o of rows) { const row = el('div', 'row'); const k = el('span', 'key' + (o.s.ref ? ' dash' : '')); k.style.borderTopColor = o.s.color;
        row.append(k, el('b', null, fmt(o.v, c.unit)), el('span', null, o.s.name)); tip.append(row); }
      tip.style.display = 'block';
      const pw = plot.clientWidth, tw = tip.offsetWidth, sx = x * r.width / W;
      tip.style.left = (sx + 14 + tw > pw ? Math.max(0, sx - 14 - tw) : sx + 14) + 'px'; tip.style.top = '8px';
    });
  }
  const redraw = () => charts.forEach(draw);
  redraw();
  let rt; window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(redraw, 150); });

  // --- tabele (sortowalne) ---
  function table(id, cols, rows, rowCls) {
    const t = document.getElementById(id); let sortI = -1, dir = 1;
    function render() {
      t.textContent = ''; const h = el('tr');
      cols.forEach((c, i) => { const th = el('th', (c.n ? 'n ' : '') + 'sort', c.h + (i === sortI ? (dir > 0 ? ' ↑' : ' ↓') : ''));
        if (c.title) th.title = c.title;
        th.onclick = () => { dir = sortI === i ? -dir : (c.n ? -1 : 1); sortI = i; render(); }; h.append(th); });
      t.append(h);
      const rs = rows.slice();
      if (sortI >= 0) { const c = cols[sortI]; rs.sort((a, b) => { const x = c.k(a), y = c.k(b); return (x > y ? 1 : x < y ? -1 : 0) * dir; }); }
      for (const r of rs) { const tr = el('tr', rowCls ? rowCls(r) : '');
        cols.forEach(c => { const td = el('td', (c.n ? 'n ' : '') + (c.cls ? c.cls(r) : '')); const v = c.v(r);
          if (v instanceof Node) td.append(v); else td.textContent = v; tr.append(td); }); t.append(tr); }
      if (!rows.length) { const tr = el('tr'); const td = el('td', null, 'brak danych'); td.colSpan = cols.length; tr.append(td); t.append(tr); }
    }
    render();
  }
  const R = D.rows.map(f => ({ f: f, wl: f[0], kind: f[1], rep: +f[2], memReq: +f[3], memLim: +f[4], cpuReq: +f[5], cpuLim: +f[6],
    hasSt: f[8] === '1', budget: f[8] === '1' ? +f[9] : +f[10], stMax: +f[13], oom: +f[16], kill: +f[17],
    memP: +f[22], memM: +f[23], cpuP: +f[24], cpuM: +f[25], thr: +f[26], rst: +f[27], flags: f[28], score: +f[29],
    rMemReq: +f[30], rMemLim: +f[31], rCpuReq: +f[32], rCpuLim: f[33], rFT: f[34] }));
  const FL = { O: ['c', 'OOMKilled'], S: ['c', 'start blisko/ponad budżet probe'], M: ['w', 'zużycie > request'], T: ['w', 'throttling CPU'],
    R: ['w', 'restarty'], D: ['w', 'repliki skupione na jednym nodzie'], P: ['w', 'PDB blokuje drain'], B: ['w', 'brak requestów (BestEffort)'], E: ['', 'probe exec'] };
  const flagsEl = r => { const s = el('span'); if (r.flags === '-') s.textContent = '-';
    else for (const ch of r.flags) { const x = el('span', 'flag ' + (FL[ch] ? FL[ch][0] : ''), ch); x.title = FL[ch] ? FL[ch][1] : ch; s.append(x); } return s; };
  table('wl', [
    { h: 'Workload', v: r => r.wl, k: r => r.wl },
    { h: 'Typ', v: r => r.kind, k: r => r.kind },
    { h: 'Repl.', n: 1, v: r => r.rep, k: r => r.rep },
    { h: 'Mem req', n: 1, v: r => fm(r.memReq), k: r => r.memReq },
    { h: 'Mem p95', n: 1, v: r => fm(r.memP), k: r => r.memP, cls: r => r.memP > 0 && (r.memReq === 0 || r.memP > r.memReq * 1.1) ? 'warm' : '' },
    { h: 'Mem maks.', n: 1, v: r => fm(r.memM), k: r => r.memM, cls: r => r.memLim > 0 && r.memM >= r.memLim * 0.9 ? 'hot' : '' },
    { h: 'Mem limit', n: 1, v: r => fm(r.memLim), k: r => r.memLim },
    { h: 'CPU req', n: 1, v: r => fcm(r.cpuReq), k: r => r.cpuReq },
    { h: 'CPU p95', n: 1, v: r => fcm(r.cpuP), k: r => r.cpuP },
    { h: 'CPU limit', n: 1, v: r => fcm(r.cpuLim), k: r => r.cpuLim },
    { h: 'Throttling', n: 1, v: r => r.thr >= 0 ? r.thr + '%' : '-', k: r => r.thr, cls: r => r.thr >= M.tw && r.cpuLim > 0 ? 'warm' : '' },
    { h: 'Start', n: 1, v: r => r.stMax >= 0 ? r.stMax + 's' : '-', k: r => r.stMax, title: 'najdłuższy zmierzony start do Ready' },
    { h: 'Budżet', n: 1, v: r => r.budget > 0 ? r.budget + 's' + (r.hasSt ? '*' : '') : '-', k: r => r.budget, cls: r => r.stMax > 0 && r.budget > 0 && r.stMax >= r.budget ? 'hot' : '', title: '* = startupProbe' },
    { h: 'Restarty', n: 1, v: r => r.rst, k: r => r.rst, cls: r => r.rst >= M.rw ? 'warm' : '' },
    { h: 'OOM', n: 1, v: r => r.oom, k: r => r.oom, cls: r => r.oom > 0 ? 'hot' : '' },
    { h: 'Flagi', v: flagsEl, k: r => r.score }
  ], R, r => /[OS]/.test(r.flags) ? 'crit' : r.score > 0 ? 'warn' : '');
  document.getElementById('flags').textContent = 'Flagi: ' + Object.entries(FL).map(([k, v]) => k + ' = ' + v[1]).join(', ') + '. Okres: ' + M.D + ' dni.';

  document.getElementById('recdesc').textContent = 'Tylko workloady z problemami. Mem request = p95 × ' + M.mm + ' (zaokr. do 256Mi); mem limit = maks. × 1.15 (≥ request); CPU request = p95; CPU limit „usuń” = throttling ≥ ' + M.tw + '%; startupProbe = period 10s × failureThreshold ≈ 2× najdłuższy start. Nic nie zostało wdrożone.';
  table('rec', [
    { h: 'Workload', v: r => r.wl, k: r => r.wl },
    { h: 'Mem req', n: 1, v: r => fm(r.memReq), k: r => r.memReq },
    { h: '→ zalecany', n: 1, v: r => fm(r.rMemReq), k: r => r.rMemReq, cls: () => 'rec' },
    { h: 'Mem limit', n: 1, v: r => fm(r.memLim), k: r => r.memLim },
    { h: '→ zalecany', n: 1, v: r => fm(r.rMemLim), k: r => r.rMemLim, cls: () => 'rec' },
    { h: 'CPU req', n: 1, v: r => fcm(r.cpuReq), k: r => r.cpuReq },
    { h: '→ zalecany', n: 1, v: r => fcm(r.rCpuReq), k: r => r.rCpuReq, cls: () => 'rec' },
    { h: 'CPU limit →', n: 1, v: r => r.rCpuLim, k: r => r.rCpuLim, cls: () => 'rec' },
    { h: 'startupProbe', v: r => r.rFT ? '10s × ' + r.rFT : '-', k: r => +r.rFT || 0 },
    { h: 'Flagi', v: flagsEl, k: r => r.score }
  ], R.filter(r => r.score > 0), r => /[OS]/.test(r.flags) ? 'crit' : 'warn');
  const alloc = +M.ALLOC_SUM, nreq = +M.NEW_REQ;
  document.getElementById('recsum').textContent = 'Suma requestów pamięci po zmianie: ok. ' + fm(nreq) + ' (teraz ' + fm(M.S_REQ) + ') przy ' + fm(alloc) +
    ' allocatable nodów aplikacji' + (alloc > 0 ? ' (' + Math.round(nreq * 100 / alloc) + '%)' : '') + '.';

  table('nodes', [
    { h: 'Node', v: r => r[0], k: r => r[0] },
    { h: 'Allocatable', n: 1, v: r => fm(r[1]), k: r => +r[1] },
    { h: 'Requesty', n: 1, v: r => fm(r[3]), k: r => +r[3] },
    { h: 'Użycie', n: 1, v: r => fm(r[4]) + (+r[1] > 0 ? ' (' + Math.round(r[4] * 100 / r[1]) + '%)' : ''), k: r => +r[4] / (+r[1] || 1), cls: r => +r[1] > 0 && r[4] / r[1] >= 0.9 ? 'hot' : '' },
    { h: 'Wolne sched', n: 1, v: r => fm(r[5]), k: r => +r[5] },
    { h: 'Wolne real', n: 1, v: r => fm(r[6]), k: r => +r[6] },
    { h: 'App use/req', n: 1, v: r => r[7], k: r => +r[7] || 0, cls: r => +r[7] > 1.1 ? 'warm' : '' },
    { h: 'Steal maks.', n: 1, v: r => Math.round(+r[8]) + '%', k: r => +r[8], cls: r => +r[8] >= 5 ? 'warm' : '' },
    { h: 'CPU maks.', n: 1, v: r => Math.round(+r[9]) + '%', k: r => +r[9] },
    { h: 'Obce pody', n: 1, v: r => r[10], k: r => +r[10] },
    { h: 'Taint', v: r => +r[11] > 0 ? 'tak' : 'nie', k: r => +r[11] },
    { h: 'Alert rezerwacji', v: r => +r[12] > 0 ? 'tak' : '-', k: r => +r[12], cls: r => +r[12] > 0 ? 'hot' : '' }
  ], D.nodes);

  // --- raport tekstowy w sekcjach ---
  const rp = document.getElementById('report');
  const parts = (D.report || '').split(/\n(?=== )/);
  parts.forEach((p, i) => { const lines = p.split('\n');
    const isSec = /^== /.test(lines[0]);
    const title = isSec ? lines[0].replace(/^== | ==$/g, '') : 'Nagłówek';
    const d = el('details', 'sec'); d.append(el('summary', null, title), el('pre', 'report', (isSec ? lines.slice(1) : lines).join('\n').replace(/^\n+|\s+$/g, '')));
    if (/^WNIOSKI/.test(title)) d.open = true; rp.append(d); });
})();
</script>
</body>
</html>
HTMLEOF
}

if [[ -n $HTML ]]; then
  : >"$HTML" 2>/dev/null || die "nie mogę zapisać pliku $HTML"
fi
REPORT_COPY=/dev/null; [[ -n $HTML ]] && REPORT_COPY=$TMP/report.txt
if [[ -n $OUT_DIR ]]; then
  mkdir -p "$OUT_DIR" || die "nie mogę utworzyć $OUT_DIR"
  run | tee "$OUT_DIR/report.txt" "$REPORT_COPY"
  rc=${PIPESTATUS[0]}
  if [[ -f $OUT_DIR/workloads.csv && $ANONYMIZE == 1 && -f $TMP/anon.sed ]]; then
    sed -i -f "$TMP/anon.sed" "$OUT_DIR/workloads.csv"
  fi
  printf '\nZapisano: %s/report.txt, %s/workloads.csv\n' "$OUT_DIR" "$OUT_DIR"
elif [[ -n $HTML ]]; then
  run | tee "$REPORT_COPY"
  rc=${PIPESTATUS[0]}
else
  run; rc=$?
fi
[[ -n $HTML ]] && build_html
exit "$rc"
