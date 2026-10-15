#!/usr/bin/env bash
# =============================================================================
#  ocp-sysreserved-sizing.sh — analiza alertu SystemMemoryExceedsReservation
#                              i dobór systemReserved per pula MCP (TYLKO ODCZYT)
#
#  Użycie:
#     ./ocp-sysreserved-sizing.sh [pula]
#
#  Przykłady:
#     ./ocp-sysreserved-sizing.sh                 # wszystkie pule
#     ./ocp-sysreserved-sizing.sh worker
#     DAYS=7 MARGIN=2 ./ocp-sysreserved-sizing.sh worker
#     ANONYMIZE=1 ./ocp-sysreserved-sizing.sh
#
#  Zmienne środowiskowe (opcjonalne):
#     DAYS=14          okres analizy w dniach (nie więcej niż retencja Prometheusa)
#     MARGIN=1.5       mnożnik zapasu nad zmierzonym szczytem
#     MIN_MEM_GIB=2    minimalna rekomendowana rezerwacja pamięci
#     MIN_CPU_M=500    minimalna rekomendowana rezerwacja CPU (millicores)
#     GROWTH_PCT=20    od ilu % wzrostu (pierwszy vs ostatni dzień) zgłaszać trend/wyciek
#     ANONYMIZE=1      zamaskuj w wyniku nazwy nodów, domenę klastra, użytkownika
#
#  Skrypt niczego nie zmienia: `oc get` oraz zapytania PromQL przez
#  `oc exec` do prometheus-k8s-0. Proponowany KubeletConfig jest tylko
#  WYPISYWANY na ekran. Wymaga jq.
# =============================================================================
set -o pipefail

POOL_FILTER=${1:-}
DAYS=${DAYS:-14}
MARGIN=${MARGIN:-1.5}
MIN_MEM_GIB=${MIN_MEM_GIB:-2}
MIN_CPU_M=${MIN_CPU_M:-500}
GROWTH_PCT=${GROWTH_PCT:-20}
ANONYMIZE=${ANONYMIZE:-0}
STEP=10m

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
usage() { sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# PromQL -> plik "node|wartość"
prom() {
  local q=$1 out=$2
  oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
     curl -sG --data-urlencode "query=$q" http://localhost:9090/api/v1/query 2>/dev/null \
  | jq -r '.data.result[]? | "\(.metric.node // .metric.instance)|\(.value[1])"' >"$out" 2>/dev/null
}
getv() { awk -F'|' -v n="$1" '$1==n{print $2; exit}' "$2"; }
gib()  { awk -v b="${1:-0}" 'BEGIN{ if (b=="") b=0; printf "%.2f", b/1073741824 }'; }
# rekomendacja pamięci: szczyt*margines, w górę do 0.5 GiB, min MIN_MEM_GIB
rec_mem() { awk -v b="${1:-0}" -v m="$MARGIN" -v min="$MIN_MEM_GIB" 'BEGIN{
  g=b*m/1073741824; r=int(g*2); if (r < g*2) r++; r=r/2; if (r<min) r=min; printf "%g", r }'; }
rec_cpu() { awk -v c="${1:-0}" -v m="$MARGIN" -v min="$MIN_CPU_M" 'BEGIN{
  v=c*1000*m; r=int(v/100); if (r*100 < v) r++; r=r*100; if (r<min) r=min; printf "%d", r }'; }
# formuła autoSizingReserved (pamięć) — dla porównania
auto_mem() { awk -v b="${1:-0}" 'BEGIN{ g=b/1073741824; r=0
  t=(g<4?g:4); r+=t*0.25; g-=t; if (g>0){t=(g<4?g:4); r+=t*0.20; g-=t}
  if (g>0){t=(g<8?g:8); r+=t*0.10; g-=t} if (g>0){t=(g<112?g:112); r+=t*0.06; g-=t}
  if (g>0){r+=g*0.02} printf "%.1f", r }'; }

# =============================================================================
main() {
  [[ $POOL_FILTER == -h || $POOL_FILTER == --help ]] && usage
  command -v oc >/dev/null 2>&1 || die "brak polecenia oc w PATH"
  command -v jq >/dev/null 2>&1 || die "brak jq w PATH (wymagane)"
  oc whoami >/dev/null 2>&1     || die "brak zalogowania do klastra (oc login)"

  printf '%sAnaliza rezerwacji systemowej (SystemMemoryExceedsReservation)%s%s\n' "$BOLD" "$N" "${POOL_FILTER:+ — pula: $POOL_FILTER}"
  printf 'Klaster: %s   użytkownik: %s   %s\n' "$(oc whoami --show-server 2>/dev/null)" "$(oc whoami 2>/dev/null)" "$(date '+%F %T')"
  printf 'Okres: %s dni   margines: ×%s   minimum: %s GiB / %sm CPU\n' "$DAYS" "$MARGIN" "$MIN_MEM_GIB" "$MIN_CPU_M"
  printf '\nZbieranie danych (zapytania za %s dni mogą potrwać do minuty)...\n' "$DAYS"

  oc get nodes -o json >"$TMP/nodes.json" 2>/dev/null || die "nie udało się pobrać nodów"
  oc get kubeletconfig -o json >"$TMP/kc.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/kc.json"
  oc get pods -A -o json >"$TMP/pods.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/pods.json"

  # node|pula|capMem|allocMem|capCpu(m)|allocCpu(m)
  jq -r '
    def mem: tostring |
      if test("Ki$") then (.[:-2]|tonumber)*1024
      elif test("Mi$") then (.[:-2]|tonumber)*1048576
      elif test("Gi$") then (.[:-2]|tonumber)*1073741824
      elif test("Ti$") then (.[:-2]|tonumber)*1099511627776
      elif test("k$") then (.[:-1]|tonumber)*1000
      elif test("M$") then (.[:-1]|tonumber)*1000000
      elif test("G$") then (.[:-1]|tonumber)*1000000000
      else tonumber end;
    def cpu: tostring | if test("m$") then (.[:-1]|tonumber) else (tonumber*1000) end;
    .items[] |
    [ .metadata.name,
      ((.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "none") | sub("^rendered-";"") | sub("-[0-9a-f]+$";"")),
      (.status.capacity.memory | mem), (.status.allocatable.memory | mem),
      (.status.capacity.cpu | cpu), (.status.allocatable.cpu | cpu)
    ] | map(tostring) | join("|")' "$TMP/nodes.json" >"$TMP/nodes.txt"

  # requests pamięci per node (pody nie zakończone)
  jq -r '
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
    [ .items[] | select(.spec.nodeName != null and .status.phase != "Succeeded" and .status.phase != "Failed")
      | {n: .spec.nodeName, r: ([.spec.containers[]?.resources.requests.memory // "0" | mem] | add // 0)} ]
    | group_by(.n)[] | "\(.[0].n)|\(map(.r) | add)"' "$TMP/pods.json" >"$TMP/req.txt" 2>/dev/null

  local SEL='container_memory_rss{id="/system.slice"}'
  local SELC='container_cpu_usage_seconds_total{id="/system.slice"}'
  local D1=$(( DAYS - 1 ))
  prom "sum by (node) ($SEL)" "$TMP/cur.txt"
  prom "max_over_time(sum by (node) ($SEL)[${DAYS}d:$STEP])" "$TMP/peak.txt"
  prom "avg_over_time(sum by (node) ($SEL)[1d:$STEP] offset ${D1}d)" "$TMP/first.txt"
  prom "avg_over_time(sum by (node) ($SEL)[1d:$STEP])" "$TMP/last.txt"
  prom "max_over_time(sum by (node) (rate(${SELC}[5m]))[${DAYS}d:$STEP])" "$TMP/cpupeak.txt"
  prom 'count by (node) (ALERTS{alertname="SystemMemoryExceedsReservation",alertstate="firing"})' "$TMP/alerts.txt"
  # top usługi — osobno, bo potrzebny label id
  oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
     curl -sG --data-urlencode "query=topk(30, max by (node, id) (max_over_time(container_memory_rss{id=~\"/system.slice/[^/]+[.]service\"}[1d])))" \
     http://localhost:9090/api/v1/query 2>/dev/null \
  | jq -r '.data.result[]? | "\(.metric.node)|\(.metric.id | sub("^/system.slice/";""))|\(.value[1])"' >"$TMP/svc.txt" 2>/dev/null

  [[ -s $TMP/peak.txt ]] || die "brak danych z Prometheusa (container_memory_rss dla /system.slice) — sprawdź dostęp do prometheus-k8s-0"
  local have_trend=1
  [[ -s $TMP/first.txt ]] || have_trend=0

  # ================================================ 1. ISTNIEJĄCA KONFIGURACJA
  hdr "1. Obecna konfiguracja rezerwacji"
  local kcs
  kcs=$(jq -r '.items[] | "\(.metadata.name)|\(.spec.machineConfigPoolSelector.matchLabels // {} | to_entries | map(.key | sub("pools.operator.machineconfiguration.openshift.io/";"")) | join(","))|\(.spec.autoSizingReserved // false)|\(.spec.kubeletConfig.systemReserved // {} | tojson)"' "$TMP/kc.json")
  if [[ -z $kcs ]]; then
    info "Brak KubeletConfig w klastrze — wszystkie pule mają domyślną rezerwację (ok. 1 GiB pamięci, 500m CPU)"
  else
    while IFS='|' read -r kn kp ka ksr; do
      line "KubeletConfig $kn → pule: ${kp:-?}   autoSizingReserved=$ka   systemReserved=$ksr"
    done <<<"$kcs"
    line "Przy wdrażaniu zmiany ROZSZERZ istniejący KubeletConfig danej puli zamiast tworzyć drugi."
  fi

  # ================================================ 2. NODY
  hdr "2. Zużycie system.slice względem rezerwacji (per node)"
  printf '  %s%-24s %-10s %7s %7s %7s %7s %6s %7s %6s %6s %3s%s\n' "$BOLD" "NODE" "PULA" "RAM" "REZ" "TERAZ" "SZCZYT" "SZC%" "TREND" "CPUrez" "CPUszc" "AL" "$N"
  printf '  %-24s %-10s %7s %7s %7s %7s %6s %7s %6s %6s %3s\n' "" "" "GiB" "GiB" "GiB" "GiB" "" "" "m" "m" ""
  : >"$TMP/rows.txt"
  local n pool cm am cc ac res resc cur peak first last cpk al pct trend
  while IFS='|' read -r n pool cm am cc ac; do
    [[ -n $POOL_FILTER && $pool != "$POOL_FILTER" ]] && continue
    res=$(awk -v a="$cm" -v b="$am" 'BEGIN{printf "%.0f", a-b}')
    resc=$(awk -v a="$cc" -v b="$ac" 'BEGIN{printf "%.0f", a-b}')
    cur=$(getv "$n" "$TMP/cur.txt");  peak=$(getv "$n" "$TMP/peak.txt")
    first=$(getv "$n" "$TMP/first.txt"); last=$(getv "$n" "$TMP/last.txt")
    cpk=$(getv "$n" "$TMP/cpupeak.txt"); al=$(getv "$n" "$TMP/alerts.txt")
    [[ -z $peak ]] && continue
    pct=$(awk -v p="$peak" -v r="$res" 'BEGIN{ if (r<=0) print 0; else printf "%.0f", p*100/r }')
    if (( have_trend )) && [[ -n $first && -n $last ]]; then
      trend=$(awk -v f="$first" -v l="$last" 'BEGIN{ if (f<=0) print "?"; else printf "%+.0f%%", (l-f)*100/f }')
    else trend="?"; fi
    printf '  %-24s %-10s %7s %7s %7s %7s %5s%% %7s %6s %6s %3s\n' \
      "$(s=${n%%.*}; echo "${s:0:22}")" "${pool:0:10}" "$(gib "$cm")" "$(gib "$res")" "$(gib "$cur")" "$(gib "$peak")" "$pct" "$trend" \
      "$resc" "$(awk -v c="${cpk:-0}" 'BEGIN{printf "%.0f", c*1000}')" "$([[ -n $al ]] && echo '!' || echo '-')"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$n" "$pool" "$cm" "$am" "$res" "$resc" "$peak" "${cpk:-0}" "$pct" "$trend" "${al:+1}" >>"$TMP/rows.txt"
  done <"$TMP/nodes.txt"
  line "SZC% = szczyt RSS system.slice / rezerwacja. Alert odpala przy >95%. TREND = średnia z ostatniej doby vs pierwszej doby okresu. AL = alert aktywny teraz."

  [[ -s $TMP/rows.txt ]] || die "brak nodów z danymi dla wybranej puli"

  # Trend / wyciek
  local growers
  growers=$(awk -F'|' -v g="$GROWTH_PCT" '{t=$10; gsub(/[+%]/,"",t); if (t!="?" && t+0>=g) print $1" ("$10")"}' "$TMP/rows.txt")
  if [[ -n $growers ]]; then
    warn "Rosnące zużycie system.slice (≥${GROWTH_PCT}% w okresie) na: $(tr '\n' ' ' <<<"$growers")"
    line "Rosnący trend to sygnał wycieku (kubelet / crio / ovs). Samo zwiększenie rezerwacji tylko odsunie problem —"
    line "sprawdź top usługi poniżej i errata dla swojej wersji OCP."
  elif (( have_trend )); then
    ok "Zużycie system.slice jest stabilne (brak wzrostu ≥${GROWTH_PCT}%) — to kwestia za małej rezerwacji, nie wycieku"
  else
    info "Brak danych do oceny trendu (za krótka retencja Prometheusa?)"
  fi

  # Top usługi
  if [[ -s $TMP/svc.txt ]]; then
    printf '\n'
    line "${BOLD}Najwięksi konsumenci w system.slice (max z ostatniej doby, średnio po nodach):${N}"
    awk -F'|' 'NR==FNR{ok[$1]=1; next} ok[$1]{s[$2]+=$3; c[$2]++; if ($3>m[$2]) m[$2]=$3}
      END{for (k in s) printf "%.0f|%.0f|%s\n", s[k]/c[k], m[k], k}' "$TMP/rows.txt" "$TMP/svc.txt" \
      | sort -t'|' -k1,1nr | head -6 | while IFS='|' read -r avg mx sv; do
          line "   $(printf '%-34s średnio %6s GiB   max %6s GiB' "$sv" "$(gib "$avg")" "$(gib "$mx")")"
        done
  fi

  # ================================================ 3. REKOMENDACJE PER PULA
  hdr "3. Rekomendacja per pula"
  local pools p
  pools=$(cut -d'|' -f2 "$TMP/rows.txt" | sort -u)
  : >"$TMP/yaml.txt"
  for p in $pools; do
    local cnt maxpeak maxcpu curres curresc maxcap mincap firing over rm rc autom
    cnt=$(awk -F'|' -v p="$p" '$2==p' "$TMP/rows.txt" | wc -l)
    maxpeak=$(awk -F'|' -v p="$p" '$2==p && $7>m{m=$7} END{print m+0}' "$TMP/rows.txt")
    maxcpu=$(awk -F'|' -v p="$p" '$2==p && $8>m{m=$8} END{print m+0}' "$TMP/rows.txt")
    curres=$(awk -F'|' -v p="$p" '$2==p{print $5; exit}' "$TMP/rows.txt")
    curresc=$(awk -F'|' -v p="$p" '$2==p{print $6; exit}' "$TMP/rows.txt")
    maxcap=$(awk -F'|' -v p="$p" '$2==p && $3>m{m=$3} END{print m+0}' "$TMP/rows.txt")
    mincap=$(awk -F'|' -v p="$p" '$2==p && (m==""||$3<m){m=$3} END{print m+0}' "$TMP/rows.txt")
    firing=$(awk -F'|' -v p="$p" '$2==p && $11==1' "$TMP/rows.txt" | wc -l)
    over=$(awk -F'|' -v p="$p" '$2==p && $9>=95' "$TMP/rows.txt" | wc -l)
    rm=$(rec_mem "$maxpeak"); rc=$(rec_cpu "$maxcpu"); autom=$(auto_mem "$maxcap")

    printf '\n  %sPula %s%s (%d nodów)\n' "$BOLD" "$p" "$N" "$cnt"
    line "Obecna rezerwacja:            $(gib "$curres") GiB pamięci, ${curresc}m CPU"
    line "Najwyższy szczyt system.slice: $(gib "$maxpeak") GiB, $(awk -v c="$maxcpu" 'BEGIN{printf "%.0f", c*1000}')m CPU (z $DAYS dni)"
    line "Nody ze szczytem >95% rezerwacji: $over/$cnt   alert aktywny teraz: $firing/$cnt"

    if (( over == 0 )); then
      ok "Pula $p: rezerwacja pamięci wystarcza — alert SystemMemoryExceedsReservation nie powinien tu występować"
      if awk -v c="$maxcpu" -v r="$curresc" 'BEGIN{exit !(c*1000 > r)}'; then
        warn "Pula $p: szczyt CPU system.slice ($(awk -v c="$maxcpu" 'BEGIN{printf "%.0f", c*1000}')m) przekracza rezerwację CPU (${curresc}m) — przy pełnym obciążeniu kubelet/crio mogą zwalniać; rozważ systemReserved.cpu: ${rc}m przy najbliższej zmianie"
      fi
      continue
    fi
    warn "Pula $p: rezerwacja za mała na $over z $cnt nodów — rekomendacja systemReserved: ${rm}Gi pamięci, ${rc}m CPU"
    line "Dla porównania autoSizingReserved dałby ok. $(auto_mem "$mincap")–${autom} GiB (więcej niż potrzeba przy tak dużych nodach)."
    awk -v a="$maxcap" -v b="$mincap" 'BEGIN{exit !(a > b*1.5)}' && \
      info "Pula $p ma nody różnej wielkości ($(gib "$mincap")–$(gib "$maxcap") GiB) — rozważ osobne pule lub wartość dla największego profilu"
    (( rc > curresc )) || line "CPU: obecne ${curresc}m wystarcza; w YAML zostawiam ${rc}m (minimum)."

    # wpływ na allocatable
    local delta tight=()
    delta=$(awk -v r="$rm" -v c="$curres" 'BEGIN{printf "%.0f", r*1073741824 - c}')
    while IFS='|' read -r n _ _ am _; do
      local rq newal
      rq=$(getv "$n" "$TMP/req.txt"); rq=${rq:-0}
      newal=$(awk -v a="$am" -v d="$delta" 'BEGIN{printf "%.0f", a-d}')
      awk -v q="$rq" -v a="$newal" 'BEGIN{exit !(q > a*0.9)}' && tight+=("${n%%.*} ($(gib "$rq")/$(gib "$newal") GiB)")
    done < <(awk -F'|' -v p="$p" '$2==p' "$TMP/rows.txt")
    line "Allocatable każdego noda zmniejszy się o ok. $(gib "$delta") GiB."
    if (( ${#tight[@]} )); then
      warn "Pula $p: po zmianie requests pamięci przekroczą 90% nowego allocatable na: ${tight[*]}"
    else
      ok "Pula $p: requests pamięci zmieszczą się w nowym allocatable na wszystkich nodach"
    fi

    local existing
    existing=$(jq -r --arg p "$p" '.items[] | select((.spec.machineConfigPoolSelector.matchLabels // {}) | has("pools.operator.machineconfiguration.openshift.io/" + $p)) | .metadata.name' "$TMP/kc.json" | head -1)
    {
      printf '# ---- pula %s%s\n' "$p" "${existing:+  (ISTNIEJE KubeletConfig $existing — dopisz systemReserved do niego)}"
      cat <<YAML
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: ${existing:-$p-system-reserved}
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/$p: ""
  kubeletConfig:
    systemReserved:
      memory: ${rm}Gi
      cpu: ${rc}m
YAML
      echo
    } >>"$TMP/yaml.txt"
  done

  # ================================================ 4. YAML
  if [[ -s $TMP/yaml.txt ]]; then
    hdr "4. Proponowany KubeletConfig (NIE jest wgrywany)"
    sed 's/^/    /' "$TMP/yaml.txt"
  fi

  # ================================================ WNIOSKI
  hdr "WNIOSKI"
  if (( ${#F_CRIT[@]} )); then printf '%s%sKRYTYCZNE (%d):%s\n' "$BOLD" "$R" "${#F_CRIT[@]}" "$N"; for f in "${F_CRIT[@]}"; do printf '  • %s\n' "$f"; done; fi
  if (( ${#F_WARN[@]} )); then printf '%s%sOSTRZEŻENIA (%d):%s\n' "$BOLD" "$Y" "${#F_WARN[@]}" "$N"; for f in "${F_WARN[@]}"; do printf '  • %s\n' "$f"; done; fi
  if (( ${#F_INFO[@]} )); then printf '%s%sINFORMACJE (%d):%s\n' "$BOLD" "$C" "${#F_INFO[@]}" "$N"; for f in "${F_INFO[@]}"; do printf '  • %s\n' "$f"; done; fi

  printf '\n%sDalsze kroki:%s\n' "$BOLD" "$N"
  if [[ -n $growers ]]; then
    printf '  1. Najpierw wyjaśnij rosnący trend (wyciek) na wskazanych nodach — zmiana rezerwacji go nie naprawi.\n'
    printf '  2. Potem wdróż rezerwację zgodnie z krokami poniżej.\n'
  fi
  if [[ -s $TMP/yaml.txt ]]; then
    printf '  • Sprawdź pulę: ./ocp-mcp-diag.sh <pula> — musi być Updated=True, bez blokujących PDB.\n'
    printf '  • Przetestuj YAML na jednym nodzie w osobnej puli, potem cała pula w oknie serwisowym\n'
    printf '    (zmiana = rolling reboot nodów puli).\n'
    printf '  • Po wdrożeniu uruchom ten skrypt ponownie po kilku dniach — SZC%% powinno spaść poniżej 95%%.\n'
  else
    printf '  • Rezerwacje są wystarczające — alerty, jeśli się pojawiają, wynikają z chwilowych skoków.\n'
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