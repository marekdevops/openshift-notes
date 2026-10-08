#!/usr/bin/env bash
# =============================================================================
#  ocp-node-diag.sh — diagnostyka workera OpenShift (TYLKO ODCZYT)
#
#  Użycie:
#     ./ocp-node-diag.sh <node-problematyczny> [node-referencyjny]
#
#  Przykład:
#     ./ocp-node-diag.sh worker-01.cluster.example.com worker-02.cluster.example.com
#
#  Zmienne środowiskowe (opcjonalne):
#     LOG_HOURS=6           ile godzin wstecz przeszukiwać logi kernela i kubeleta
#     RESTART_THRESHOLD=5   od ilu restartów pod jest uznawany za podejrzany
#     DEBUG_IMAGE=<obraz>   obraz dla `oc debug node` (środowiska disconnected)
#     SKIP_ALERTS=1         pomiń odpytywanie Prometheusa o aktywne alerty
#
#  Skrypt niczego nie zmienia na nodzie ani w klastrze. Jedyny efekt uboczny
#  to tymczasowy pod tworzony przez `oc debug node/...` (usuwany automatycznie)
#  oraz `oc exec` do prometheus-k8s-0 w celu odczytu alertów (wymaga jq).
#  Wymaga uprawnień cluster-admin (oc debug node).
# =============================================================================
set -o pipefail

NODE=${1:-}
REF=${2:-}
LOG_HOURS=${LOG_HOURS:-6}
RESTART_THRESHOLD=${RESTART_THRESHOLD:-5}
DEBUG_IMAGE=${DEBUG_IMAGE:-}
SKIP_ALERTS=${SKIP_ALERTS:-0}

# --------------------------------------------------------------------------- UI
if [[ -t 1 ]]; then
  R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[34m'; C=$'\e[36m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=''; Y=''; G=''; B=''; C=''; BOLD=''; N=''
fi

declare -a F_CRIT=() F_WARN=() F_INFO=()
crit() { F_CRIT+=("$*"); printf '  %s[CRIT]%s %s\n' "$R" "$N" "$*"; }
warn() { F_WARN+=("$*"); printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; }
info() { F_INFO+=("$*"); printf '  %s[INFO]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$*"; }
line() { printf '         %s\n' "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$BOLD$B" "$*" "$N"; }
die()  { printf '%sBŁĄD:%s %s\n' "$R" "$N" "$*" >&2; exit 2; }

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---------------------------------------------------------------------- helpery
# Kubernetes quantity (pamięć) -> MiB
to_mib() {
  local v=${1:-0}
  case $v in
    *Ki) echo $(( ${v%Ki} / 1024 )) ;;
    *Mi) echo $(( ${v%Mi} )) ;;
    *Gi) echo $(( ${v%Gi} * 1024 )) ;;
    *Ti) echo $(( ${v%Ti} * 1024 * 1024 )) ;;
    *k)  echo $(( ${v%k} * 1000 / 1048576 )) ;;
    *M)  echo $(( ${v%M} * 1000000 / 1048576 )) ;;
    *G)  echo $(( ${v%G} * 1000000000 / 1048576 )) ;;
    ''|*[!0-9]*) echo 0 ;;
    *)   echo $(( v / 1048576 )) ;;
  esac
}
# Kubernetes quantity (CPU) -> millicores
to_milli() {
  local v=${1:-0}
  case $v in
    *m) echo "${v%m}" ;;
    ''|*[!0-9]*) echo 0 ;;
    *)  echo $(( v * 1000 )) ;;
  esac
}
pct()   { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if (b+0==0) print 0; else printf "%.0f", a*100/b }'; }
fgt()   { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit !(a+0 > b+0) }'; }
gib()   { awk -v m="${1:-0}" 'BEGIN{ printf "%.1f GiB", m/1024 }'; }          # MiB -> GiB
kb_gib(){ awk -v k="${1:-0}" 'BEGIN{ printf "%.1f GiB", k/1048576 }'; }       # kB  -> GiB
num()   { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# ------------------------------------------------------------- skrypt na hoście
# Wykonywany przez `oc debug node/X -- chroot /host bash -c`.
# Tylko odczyt: sysctl -n, /proc, /sys, journalctl, df, systemctl is-active.
# Każda wartość wypisywana jako linia "K:klucz=wartość".
read -r -d '' HOST_SCRIPT <<'EOS'
kv() { printf 'K:%s=%s\n' "$1" "$2"; }
SINCE="-${HOURS:-6}h"

for s in vm.overcommit_memory vm.overcommit_ratio vm.max_map_count kernel.pid_max kernel.threads-max vm.swappiness; do
  kv "$s" "$(sysctl -n "$s" 2>/dev/null)"
done

while read -r k v _; do
  case $k in
    MemTotal:|MemAvailable:|CommitLimit:|Committed_AS:|SwapTotal:|HugePages_Total:) kv "${k%:}" "$v" ;;
  esac
done < /proc/meminfo

kv nproc "$(nproc)"
kv kernel_running "$(uname -r)"
kv loadavg "$(cut -d' ' -f1-3 /proc/loadavg)"
kv threads "$(awk '{split($4,a,"/"); print a[2]}' /proc/loadavg)"
kv uptime_h "$(awk '{printf "%.0f", $1/3600}' /proc/uptime)"

for r in memory cpu io; do
  f=/proc/pressure/$r
  [ -r "$f" ] || continue
  kv "psi_${r}_some" "$(awk '/^some/{split($3,a,"="); print a[2]}' "$f")"
  kv "psi_${r}_full" "$(awk '/^full/{split($3,a,"="); print a[2]}' "$f")"
done

thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
thp=${thp#*\[}; kv thp "${thp%%\]*}"
kv tuned "$(cat /etc/tuned/active_profile 2>/dev/null)"

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  kv cgroup v2
  SS=/sys/fs/cgroup/system.slice
  kv sys_slice_current "$(cat "$SS/memory.current" 2>/dev/null)"
  kv sys_slice_anon "$(awk '$1=="anon"{print $2}' "$SS/memory.stat" 2>/dev/null)"
  for d in "$SS"/*.service; do
    [ -r "$d/memory.current" ] && printf '%s %s\n' "$(cat "$d/memory.current")" "${d##*/}"
  done | sort -rn | head -6 | while read -r b n; do kv svc "$n=$b"; done
  kv kubepods_pids "$(cat /sys/fs/cgroup/kubepods.slice/pids.current 2>/dev/null)"
  kv kubepods_pids_max "$(cat /sys/fs/cgroup/kubepods.slice/pids.max 2>/dev/null)"
else
  kv cgroup v1
  M=/sys/fs/cgroup/memory/system.slice
  kv sys_slice_current "$(cat "$M/memory.usage_in_bytes" 2>/dev/null)"
  kv sys_slice_anon "$(awk '$1=="total_rss"{print $2}' "$M/memory.stat" 2>/dev/null)"
fi

found=0
for f in /etc/node-sizing-enabled.env /etc/node-sizing.env; do
  [ -r "$f" ] || continue
  found=1
  while IFS= read -r l; do [ -n "$l" ] && kv sizing "$l"; done < "$f"
done
[ "$found" = 1 ] || kv sizing "BRAK_PLIKOW_NODE_SIZING"

KLOG=$(journalctl -k --since "$SINCE" --no-pager -q -o short-iso 2>/dev/null)
kv oom_count "$(grep -ci 'invoked oom-killer' <<<"$KLOG")"
grep -i 'killed process' <<<"$KLOG" | tail -5 | while IFS= read -r l; do kv oomline "$l"; done
kv segfault_count "$(grep -ci 'segfault' <<<"$KLOG")"
kv hung_count "$(grep -ci 'blocked for more than' <<<"$KLOG")"

journalctl -u kubelet --since "$SINCE" --no-pager -q -o cat 2>/dev/null | awk '
  /eviction manager: (attempting to reclaim|must evict)/ {e++}
  /PLEG is not healthy/                                  {p++}
  END { printf "K:evict_count=%d\nK:pleg_count=%d\n", e, p }'

kv kubelet_active "$(systemctl is-active kubelet 2>/dev/null)"
kv crio_active "$(systemctl is-active crio 2>/dev/null)"

for m in /var /var/lib/containers; do
  key=$(echo "$m" | tr '/' '_')
  p=$(df -P "$m" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  i=$(df -iP "$m" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  kv "disk${key}" "$p"
  kv "inode${key}" "$i"
done
kv HOST_DONE 1
EOS

# ---------------------------------------------------------- zbieranie danych
declare -A NA=() RA=() NH=() RH=()   # API i host: node problematyczny / referencyjny

load_api() {
  local n=$1; local -n A=$2
  local raw cc cm cp ac am kv os kl us cur des st
  raw=$(oc get node "$n" -o jsonpath='{.status.capacity.cpu}{"|"}{.status.capacity.memory}{"|"}{.status.capacity.pods}{"|"}{.status.allocatable.cpu}{"|"}{.status.allocatable.memory}{"|"}{.status.nodeInfo.kernelVersion}{"|"}{.status.nodeInfo.osImage}{"|"}{.status.nodeInfo.kubeletVersion}{"|"}{.spec.unschedulable}{"|"}{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}{"|"}{.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}{"|"}{.metadata.annotations.machineconfiguration\.openshift\.io/state}') || return 1
  IFS='|' read -r cc cm cp ac am kv os kl us cur des st <<<"$raw"
  A[cap_cpu]=$cc; A[cap_mem]=$cm; A[cap_pods]=$cp; A[alloc_cpu]=$ac; A[alloc_mem]=$am
  A[kernel]=$kv; A[os]=$os; A[kubelet]=$kl; A[unsched]=$us
  A[mc_cur]=$cur; A[mc_des]=$des; A[mc_state]=$st
  A[pool]=$(sed -E 's/^rendered-//; s/-[0-9a-f]+$//' <<<"$cur")
  A[conditions]=$(oc get node "$n" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}')
  A[res_mem_mib]=$(( $(to_mib "$cm") - $(to_mib "$am") ))
  A[res_cpu_m]=$(( $(to_milli "$cc") - $(to_milli "$ac") ))
}

load_host() {
  local n=$1; local -n H=$2
  local out l k v
  local -a img=()
  [[ -n $DEBUG_IMAGE ]] && img=(--image="$DEBUG_IMAGE")
  out=$(oc debug "node/$n" "${img[@]}" -- chroot /host /bin/bash -c "HOURS=$LOG_HOURS; $HOST_SCRIPT" 2>/dev/null)
  while IFS= read -r l; do
    l=${l%$'\r'}
    [[ $l == K:* ]] || continue
    l=${l#K:}; k=${l%%=*}; v=${l#*=}
    case $k in
      svc|sizing|oomline) H[$k]+="${H[$k]:+$'\n'}$v" ;;
      *) H[$k]=$v ;;
    esac
  done <<<"$out"
  [[ ${H[HOST_DONE]:-} == 1 ]]
}

# ------------------------------------------------------------------ preflight
[[ -z $NODE || $NODE == -h || $NODE == --help ]] && usage
command -v oc >/dev/null 2>&1 || die "brak polecenia oc w PATH"
oc whoami >/dev/null 2>&1      || die "brak zalogowania do klastra (oc login)"
oc get node "$NODE" >/dev/null 2>&1 || die "node $NODE nie istnieje"
if [[ -n $REF ]]; then
  oc get node "$REF" >/dev/null 2>&1 || die "node referencyjny $REF nie istnieje"
fi
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

printf '%sDiagnostyka noda:%s %s' "$BOLD" "$N" "$NODE"
[[ -n $REF ]] && printf '   (porównanie z: %s)' "$REF"
printf '\nKlaster: %s   użytkownik: %s   %s\n' "$(oc whoami --show-server 2>/dev/null)" "$(oc whoami 2>/dev/null)" "$(date '+%F %T')"

printf '\nZbieranie danych z API...\n'
load_api "$NODE" NA || die "nie udało się odczytać noda $NODE z API"
[[ -n $REF ]] && { load_api "$REF" RA || die "nie udało się odczytać noda $REF z API"; }

printf 'Zbieranie danych z hosta %s (oc debug)...\n' "$NODE"
HOST_OK=1
load_host "$NODE" NH || HOST_OK=0
REF_HOST_OK=0
if [[ -n $REF ]]; then
  printf 'Zbieranie danych z hosta %s (oc debug)...\n' "$REF"
  load_host "$REF" RH && REF_HOST_OK=1
fi

# =============================================================== 1. STAN NODA
hdr "1. Stan noda (API, MCO)"
line "Kernel: ${NA[kernel]}   OS: ${NA[os]}   kubelet: ${NA[kubelet]}"
line "CPU: ${NA[cap_cpu]}   RAM: $(gib "$(to_mib "${NA[cap_mem]}")")   max podów: ${NA[cap_pods]}"

if [[ ${NA[conditions]} == *"Ready=True"* ]]; then ok "Node Ready"; else crit "Node NIE jest Ready (${NA[conditions]})"; fi
for c in MemoryPressure DiskPressure PIDPressure; do
  if [[ ${NA[conditions]} == *"$c=True"* ]]; then crit "Kondycja $c=True — kubelet sygnalizuje realny brak zasobu"
  else ok "$c=False"; fi
done
[[ ${NA[unsched]} == true ]] && info "Node jest cordoned (SchedulingDisabled)"

if [[ ${NA[mc_state]} != Done ]]; then
  warn "Stan MCO na nodzie: '${NA[mc_state]}' (oczekiwane Done)"
else
  ok "MCO state=Done"
fi
if [[ -n ${NA[mc_cur]} && ${NA[mc_cur]} != "${NA[mc_des]}" ]]; then
  warn "Node w trakcie zmiany konfiguracji MCO: current=${NA[mc_cur]} desired=${NA[mc_des]}"
fi
if [[ -n ${NA[pool]} ]]; then
  read -r deg upd < <(oc get mcp "${NA[pool]}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status} {.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null)
  line "Pula MCP: ${NA[pool]}  (Degraded=${deg:-?} Updating=${upd:-?})"
  [[ $deg == True ]] && warn "Pula MCP ${NA[pool]} jest Degraded"
  [[ $upd == True ]] && info "Pula MCP ${NA[pool]} jest w trakcie aktualizacji"
fi

# =================================================== 2. REZERWACJE I ALOKACJA
hdr "2. Rezerwacje systemowe i alokacja zasobów"
res_mib=${NA[res_mem_mib]}
line "Rezerwacja (capacity − allocatable): pamięć $(gib "$res_mib"), CPU ${NA[res_cpu_m]}m"

if (( HOST_OK )); then
  sizing=${NH[sizing]:-}
  if [[ $sizing == *BRAK_PLIKOW* ]]; then
    info "Brak /etc/node-sizing*.env — rezerwacje ustawione inaczej (sprawdź KubeletConfig)"
  else
    line "node-sizing: $(tr '\n' ' ' <<<"$sizing")"
    [[ $sizing == *NODE_SIZING_ENABLED=true* ]] && info "Auto-sizing rezerwacji WŁĄCZONY"
  fi

  anon=${NH[sys_slice_anon]:-0}; cur=${NH[sys_slice_current]:-0}
  anon_mib=$(( ${anon:-0} / 1048576 )); cur_mib=$(( ${cur:-0} / 1048576 ))
  p=$(pct "$anon_mib" "$res_mib")
  line "system.slice: anon/RSS $(gib "$anon_mib") (z cache: $(gib "$cur_mib")) = ${p}% rezerwacji"
  if (( p >= 95 )); then
    warn "system.slice zużywa ${p}% rezerwacji — warunek alertu SystemMemoryExceedsReservation spełniony; rezerwacja za mała dla tego noda"
  else
    ok "system.slice mieści się w rezerwacji (${p}%)"
  fi
  if [[ -n ${NH[svc]:-} ]]; then
    line "Top usługi w system.slice:"
    while IFS='=' read -r s b; do line "   $(printf '%-32s %s' "$s" "$(gib $(( b / 1048576 )))")"; done <<<"${NH[svc]}"
  fi
fi

alloc=$(oc describe node "$NODE" 2>/dev/null | awk '
  /^Allocated resources:/ {f=1; next}
  f && $1=="cpu"    {gsub(/[()%]/,"",$3); gsub(/[()%]/,"",$5); print "cpu", $2, $3, $4, $5}
  f && $1=="memory" {gsub(/[()%]/,"",$3); gsub(/[()%]/,"",$5); print "memory", $2, $3, $4, $5; exit}')
read -r _ cpu_req cpu_req_p cpu_lim cpu_lim_p < <(grep '^cpu' <<<"$alloc")
read -r _ mem_req mem_req_p mem_lim mem_lim_p < <(grep '^memory' <<<"$alloc")
line "Requests: CPU ${cpu_req:-?} (${cpu_req_p:-?}%)  pamięć ${mem_req:-?} (${mem_req_p:-?}%)"
line "Limits:   CPU ${cpu_lim:-?} (${cpu_lim_p:-?}%)  pamięć ${mem_lim:-?} (${mem_lim_p:-?}%)"
if num "${cpu_req_p:-}"; then (( cpu_req_p >= 90 )) && warn "Requests CPU = ${cpu_req_p}% allocatable — brak miejsca na nowe pody"; fi
if num "${mem_req_p:-}"; then (( mem_req_p >= 90 )) && warn "Requests pamięci = ${mem_req_p}% allocatable — brak miejsca na nowe pody"; fi
if num "${cpu_lim_p:-}"; then (( cpu_lim_p > 100 )) && info "Limity CPU = ${cpu_lim_p}% (overcommit limitów — throttling tylko przy realnym obciążeniu)"; fi
if num "${mem_lim_p:-}"; then
  if (( mem_lim_p > 100 )); then warn "Limity pamięci = ${mem_lim_p}% — przy pełnym zużyciu możliwe OOM/eviction"
  elif (( mem_lim_p >= 75 )); then info "Limity pamięci = ${mem_lim_p}% allocatable (zbliżają się do pojemności)"; fi
fi

# ============================================================== 3. PODY
hdr "3. Pody na nodzie"
declare -A NODE_NS=()
declare -a BAD=() OOMP=() RESTARTP=()
pods_raw=$(oc get pods -A --field-selector "spec.nodeName=$NODE" -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.restartCount}{","}{.state.waiting.reason}{","}{.lastState.terminated.reason}{";"}{end}{"\n"}{end}' 2>/dev/null)
pod_count=0
while IFS='|' read -r name phase cs; do
  [[ -z $name ]] && continue
  pod_count=$((pod_count + 1))
  NODE_NS["${name%%/*}"]=1
  restarts=0; reasons=''
  IFS=';' read -ra arr <<<"$cs"
  for c in "${arr[@]}"; do
    IFS=',' read -r rc wr lr <<<"$c"
    num "$rc" && restarts=$((restarts + rc))
    [[ -n $wr ]] && reasons+="$wr "
    [[ $lr == OOMKilled ]] && OOMP+=("$name")
  done
  if [[ $phase != Running && $phase != Succeeded ]] || [[ -n $reasons ]]; then
    BAD+=("$name [$phase${reasons:+ ${reasons% }}]")
  fi
  (( restarts >= RESTART_THRESHOLD )) && RESTARTP+=("$name (restarty: $restarts)")
done <<<"$pods_raw"

pp=$(pct "$pod_count" "${NA[cap_pods]:-0}")
line "Liczba podów: $pod_count / ${NA[cap_pods]} (${pp}%)"
(( pp >= 90 )) && warn "Liczba podów blisko maxPods (${pp}%)"
if (( ${#BAD[@]} )); then
  warn "Pody w złym stanie: ${#BAD[@]} (np. ${BAD[0]})"
  for b in "${BAD[@]}"; do line "   $b"; done
else ok "Brak podów w stanie błędu"; fi
if (( ${#OOMP[@]} )); then
  crit "Pody z ostatnim zakończeniem OOMKilled (limit pamięci kontenera): ${#OOMP[@]} (np. ${OOMP[0]})"
  for b in "${OOMP[@]}"; do line "   $b"; done
fi
if (( ${#RESTARTP[@]} )); then
  warn "Pody z ≥${RESTART_THRESHOLD} restartami: ${#RESTARTP[@]} (np. ${RESTARTP[0]})"
  for b in "${RESTARTP[@]}"; do line "   $b"; done
fi

# ===================================================== 4. REALNE OBCIĄŻENIE
hdr "4. Realne obciążenie hosta"
if (( HOST_OK )); then
  mt=${NH[MemTotal]:-0}; ma=${NH[MemAvailable]:-0}
  ap=$(pct "$ma" "$mt")
  line "Pamięć dostępna: $(kb_gib "$ma") z $(kb_gib "$mt") (${ap}%)"
  if (( ap < 10 )); then crit "MemAvailable < 10% — realny brak pamięci na hoście"
  elif (( ap < 20 )); then warn "MemAvailable < 20%"
  else ok "Pamięci na hoście wystarcza"; fi

  line "Load avg: ${NH[loadavg]}  (rdzenie: ${NH[nproc]})   uptime: ${NH[uptime_h]} h"
  l1=${NH[loadavg]%% *}
  fgt "$l1" "${NH[nproc]:-1}" && warn "Load avg (1 min) $l1 > liczba rdzeni ${NH[nproc]}"

  line "PSI avg60 — memory some/full: ${NH[psi_memory_some]:-?}/${NH[psi_memory_full]:-?}  cpu some: ${NH[psi_cpu_some]:-?}  io some/full: ${NH[psi_io_some]:-?}/${NH[psi_io_full]:-?}"
  if fgt "${NH[psi_memory_full]:-0}" 1; then crit "PSI memory full > 1% — procesy stoją, czekając na pamięć"
  elif fgt "${NH[psi_memory_some]:-0}" 10; then warn "PSI memory some > 10% — presja pamięci (reclaim)"
  else ok "Brak presji pamięci (PSI)"; fi
  fgt "${NH[psi_cpu_some]:-0}" 25 && warn "PSI cpu some > 25% — procesy czekają na CPU"
  fgt "${NH[psi_io_full]:-0}" 10  && warn "PSI io full > 10% — wąskie gardło I/O"

  for m in _var _var_lib_containers; do
    d=${NH[disk$m]:-}; i=${NH[inode$m]:-}
    num "$d" || continue
    line "Dysk ${m//_//}: ${d}% zajęte, inody ${i:-?}%"
    if (( d >= 95 )); then crit "Dysk ${m//_//} zajęty w ${d}%"
    elif (( d >= 85 )); then warn "Dysk ${m//_//} zajęty w ${d}% (próg image GC / eviction)"; fi
    num "$i" && (( i >= 85 )) && warn "Inody na ${m//_//} zajęte w ${i}%"
  done
else
  crit "Nie udało się zebrać danych z hosta (oc debug). Sprawdź uprawnienia lub ustaw DEBUG_IMAGE."
fi

# ======================================================= 5. LIMITY KERNELA
hdr "5. Limity kernela (pamięć wirtualna, wątki, PID)"
if (( HOST_OK )); then
  om=${NH[vm.overcommit_memory]:-?}
  cl=${NH[CommitLimit]:-0}; ca=${NH[Committed_AS]:-0}; cp=$(pct "$ca" "$cl")
  line "vm.overcommit_memory=$om  overcommit_ratio=${NH[vm.overcommit_ratio]}  Committed_AS/CommitLimit=$(kb_gib "$ca")/$(kb_gib "$cl") (${cp}%)"
  case $om in
    1) ok "vm.overcommit_memory=1 (domyślne dla OCP)" ;;
    0) warn "vm.overcommit_memory=0 (heurystyka) — różne od domyślnego OCP (1); duże rezerwacje pamięci wirtualnej mogą być odrzucane" ;;
    2) crit "vm.overcommit_memory=2 (ścisły commit) — procesy rezerwujące dużo pamięci wirtualnej dostaną ENOMEM"
       (( cp >= 90 )) && crit "Committed_AS = ${cp}% CommitLimit — nowe alokacje będą odrzucane przez kernel" ;;
    *) warn "Nie udało się odczytać vm.overcommit_memory" ;;
  esac

  th=${NH[threads]:-0}; tm=${NH[kernel.threads-max]:-0}; pm=${NH[kernel.pid_max]:-0}
  tp=$(pct "$th" "$tm"); pp2=$(pct "$th" "$pm")
  line "Wątki: $th   threads-max: $tm (${tp}%)   pid_max: $pm (${pp2}%)"
  if (( tp >= 80 || pp2 >= 80 )); then crit "Liczba wątków blisko limitu kernela — nowe wątki/procesy nie powstaną"
  elif (( tp >= 60 || pp2 >= 60 )); then warn "Liczba wątków powyżej 60% limitu kernela"
  else ok "Zapas wątków/PID-ów w kernelu"; fi

  kp=${NH[kubepods_pids]:-}; kpm=${NH[kubepods_pids_max]:-}
  if num "$kp" && num "$kpm"; then
    kpp=$(pct "$kp" "$kpm")
    line "PID-y w kubepods.slice: $kp / $kpm (${kpp}%)"
    (( kpp >= 80 )) && crit "kubepods.slice blisko limitu PID-ów"
  else
    line "PID-y w kubepods.slice: ${kp:-?} (limit: ${kpm:-?})"
  fi

  line "vm.max_map_count=${NH[vm.max_map_count]}  swappiness=${NH[vm.swappiness]}  swap=$(kb_gib "${NH[SwapTotal]:-0}")  THP=${NH[thp]}  hugepages=${NH[HugePages_Total]}  tuned=${NH[tuned]:-?}  cgroup=${NH[cgroup]}"
  num "${NH[SwapTotal]:-0}" && (( ${NH[SwapTotal]:-0} > 0 )) && info "Na nodzie jest włączony swap"
  num "${NH[HugePages_Total]:-0}" && (( ${NH[HugePages_Total]:-0} > 0 )) && info "Zarezerwowane hugepages: ${NH[HugePages_Total]} (pomniejszają pamięć dostępną dla zwykłych procesów)"
fi

# =========================================================== 6. LOGI
hdr "6. Logi kernela i kubeleta (ostatnie ${LOG_HOURS} h)"
if (( HOST_OK )); then
  line "kubelet: ${NH[kubelet_active]}   crio: ${NH[crio_active]}"
  [[ ${NH[kubelet_active]} != active ]] && crit "kubelet nie jest active"
  [[ ${NH[crio_active]} != active ]] && crit "crio nie jest active"

  oc_=${NH[oom_count]:-0}
  if num "$oc_" && (( oc_ > 0 )); then
    crit "Kernel OOM-killer uruchomiony $oc_ razy"
    [[ -n ${NH[oomline]:-} ]] && while IFS= read -r l; do line "   $l"; done <<<"${NH[oomline]}"
  else ok "Brak zdarzeń OOM-killer w kernelu"; fi
  num "${NH[segfault_count]:-0}" && (( ${NH[segfault_count]:-0} > 0 )) && warn "Segfaulty w logu kernela: ${NH[segfault_count]}"
  num "${NH[hung_count]:-0}"     && (( ${NH[hung_count]:-0} > 0 ))     && warn "Zawieszone zadania (hung task): ${NH[hung_count]}"
  num "${NH[evict_count]:-0}"    && (( ${NH[evict_count]:-0} > 0 ))    && warn "Kubelet eviction manager działał: ${NH[evict_count]} wpisów"
  num "${NH[pleg_count]:-0}"     && (( ${NH[pleg_count]:-0} > 0 ))     && warn "PLEG is not healthy: ${NH[pleg_count]} wpisów (kubelet/crio nie nadąża)"
fi

ev=$(oc get events -A --field-selector "involvedObject.kind=Node,involvedObject.name=$NODE,type=Warning" --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -8)
if [[ -n $ev ]]; then
  warn "Eventy Warning dla noda: $(grep -c . <<<"$ev") ostatnich (lista w sekcji 6)"
  while IFS= read -r l; do line "   ${l:0:160}"; done <<<"$ev"
else ok "Brak eventów Warning dla noda"; fi

# =========================================================== 7. PDB
hdr "7. PodDisruptionBudget (wpływ na drain)"
pdb_raw=$(oc get pdb -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.disruptionsAllowed}{"|"}{.status.currentHealthy}{"|"}{.status.desiredHealthy}{"|"}{.status.expectedPods}{"\n"}{end}' 2>/dev/null)
pdb_zero=0
while IFS='|' read -r ns nm da chh dh ep; do
  [[ -z $ns ]] && continue
  [[ $da == 0 ]] || continue
  pdb_zero=$((pdb_zero + 1))
  tag=''; [[ -n ${NODE_NS[$ns]:-} ]] && tag=' ← namespace ma pody na tym nodzie'
  if (( ${chh:-0} < ${dh:-0} )); then
    warn "PDB $ns/$nm: healthy ${chh}/${dh} (expected $ep) — aplikacja poniżej minimum$tag"
  else
    info "PDB $ns/$nm: disruptionsAllowed=0 (healthy ${chh}/${dh}) — zablokuje drain$tag"
  fi
done <<<"$pdb_raw"
(( pdb_zero == 0 )) && ok "Wszystkie PDB pozwalają na disruption"

# =========================================================== 8. ALERTY
hdr "8. Aktywne alerty dotyczące noda"
if [[ $SKIP_ALERTS == 1 ]]; then
  line "pominięte (SKIP_ALERTS=1)"
elif (( ! HAVE_JQ )); then
  line "pominięte (brak jq)"
else
  json=$(oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- curl -s http://localhost:9090/api/v1/alerts 2>/dev/null)
  short=${NODE%%.*}
  alerts=$(jq -r --arg n "$NODE" --arg s "$short" '
    .data.alerts[]? | select(.state=="firing")
    | select(((.labels.node // "") == $n) or ((.labels.instance // "") | startswith($s)))
    | "\(.labels.severity // "-")|\(.labels.alertname)|\(.labels.namespace // "")"' <<<"$json" 2>/dev/null | sort -u)
  if [[ -z $json ]]; then
    line "nie udało się odczytać alertów z Prometheusa"
  elif [[ -z $alerts ]]; then
    ok "Brak aktywnych alertów przypiętych do noda"
  else
    while IFS='|' read -r sev an ans; do
      case $sev in
        critical) crit "Alert $an${ans:+ ($ans)}" ;;
        warning)  warn "Alert $an${ans:+ ($ans)}" ;;
        *)        info "Alert $an${ans:+ ($ans)} [$sev]" ;;
      esac
    done <<<"$alerts"
  fi
fi

# =========================================================== 9. PORÓWNANIE
if [[ -n $REF ]]; then
  hdr "9. Porównanie z nodem referencyjnym"
  printf '  %s%-26s %-34s %-34s%s\n' "$BOLD" "parametr" "${NODE%%.*}" "${REF%%.*}" "$N"
  declare -a DIFFS=()
  cmp_row() {
    local label=$1 a=$2 b=$3 important=${4:-0} mark=' '
    if [[ "$a" != "$b" ]]; then
      mark='≠'
      (( important )) && DIFFS+=("$label: $a vs $b")
    fi
    printf '  %-26s %-34s %-34s %s\n' "$label" "${a:0:33}" "${b:0:33}" "$mark"
  }
  # wiersze z API
  rows_api=(
    "CPU (capacity)|${NA[cap_cpu]}|${RA[cap_cpu]}|1"
    "RAM (capacity)|$(gib "$(to_mib "${NA[cap_mem]}")")|$(gib "$(to_mib "${RA[cap_mem]}")")|1"
    "Rezerwacja RAM|$(gib "${NA[res_mem_mib]}")|$(gib "${RA[res_mem_mib]}")|1"
    "Rezerwacja CPU|${NA[res_cpu_m]}m|${RA[res_cpu_m]}m|1"
    "Kernel|${NA[kernel]}|${RA[kernel]}|1"
    "Pula MCP|${NA[pool]}|${RA[pool]}|0"
    "Rendered config|${NA[mc_cur]}|${RA[mc_cur]}|1"
    "MCO state|${NA[mc_state]}|${RA[mc_state]}|1"
  )
  for r in "${rows_api[@]}"; do IFS='|' read -r a b c d <<<"$r"; cmp_row "$a" "$b" "$c" "$d"; done
  if (( HOST_OK && REF_HOST_OK )); then
    rows_host=(
      "vm.overcommit_memory|${NH[vm.overcommit_memory]}|${RH[vm.overcommit_memory]}|1"
      "vm.overcommit_ratio|${NH[vm.overcommit_ratio]}|${RH[vm.overcommit_ratio]}|1"
      "vm.max_map_count|${NH[vm.max_map_count]}|${RH[vm.max_map_count]}|1"
      "kernel.pid_max|${NH[kernel.pid_max]}|${RH[kernel.pid_max]}|1"
      "kernel.threads-max|${NH[kernel.threads-max]}|${RH[kernel.threads-max]}|0"
      "Watki (teraz)|${NH[threads]}|${RH[threads]}|0"
      "Commit %|$(pct "${NH[Committed_AS]}" "${NH[CommitLimit]}")%|$(pct "${RH[Committed_AS]}" "${RH[CommitLimit]}")%|0"
      "MemAvailable|$(kb_gib "${NH[MemAvailable]}")|$(kb_gib "${RH[MemAvailable]}")|0"
      "Swap|$(kb_gib "${NH[SwapTotal]}")|$(kb_gib "${RH[SwapTotal]}")|1"
      "THP|${NH[thp]}|${RH[thp]}|1"
      "Hugepages|${NH[HugePages_Total]}|${RH[HugePages_Total]}|1"
      "Tuned profile|${NH[tuned]}|${RH[tuned]}|1"
      "cgroup|${NH[cgroup]}|${RH[cgroup]}|1"
      "kubepods pids.max|${NH[kubepods_pids_max]}|${RH[kubepods_pids_max]}|1"
      "node-sizing|$(tr '\n' ' ' <<<"${NH[sizing]}")|$(tr '\n' ' ' <<<"${RH[sizing]}")|1"
      "PSI memory some|${NH[psi_memory_some]}|${RH[psi_memory_some]}|0"
      "OOM (${LOG_HOURS}h)|${NH[oom_count]}|${RH[oom_count]}|0"
    )
    for r in "${rows_host[@]}"; do IFS='|' read -r a b c d <<<"$r"; cmp_row "$a" "$b" "$c" "$d"; done
  else
    line "(brak danych hosta dla jednego z nodów — porównanie tylko z API)"
  fi
  echo
  if (( ${#DIFFS[@]} )); then
    for d in "${DIFFS[@]}"; do warn "Różnica względem ${REF%%.*} — $d"; done
  else
    ok "Brak istotnych różnic konfiguracyjnych względem ${REF%%.*}"
  fi
fi

# =========================================================== WNIOSKI
hdr "WNIOSKI"
if (( ${#F_CRIT[@]} )); then
  printf '%s%sKRYTYCZNE (%d):%s\n' "$BOLD" "$R" "${#F_CRIT[@]}" "$N"
  for f in "${F_CRIT[@]}"; do printf '  • %s\n' "$f"; done
fi
if (( ${#F_WARN[@]} )); then
  printf '%s%sOSTRZEŻENIA (%d):%s\n' "$BOLD" "$Y" "${#F_WARN[@]}" "$N"
  for f in "${F_WARN[@]}"; do printf '  • %s\n' "$f"; done
fi
if (( ${#F_INFO[@]} )); then
  printf '%s%sINFORMACJE (%d):%s\n' "$BOLD" "$C" "${#F_INFO[@]}" "$N"
  for f in "${F_INFO[@]}"; do printf '  • %s\n' "$f"; done
fi

printf '\n%sInterpretacja:%s\n' "$BOLD" "$N"
real_pressure=0
for f in "${F_CRIT[@]}"; do
  case $f in *MemAvailable*|*PSI*|*OOM-killer*|*Pressure=True*|*wątków*|*PID*|*overcommit*|*Committed_AS*) real_pressure=1 ;; esac
done
if (( real_pressure )); then
  printf '  Node ma REALNY problem z zasobami na poziomie kernela/hosta — to dobry kandydat na przyczynę awarii\n'
  printf '  aplikacji startujących tylko na tym nodzie. Zacznij od pozycji KRYTYCZNE powyżej.\n'
elif (( ${#F_CRIT[@]} )); then
  printf '  Są problemy KRYTYCZNE niezwiązane bezpośrednio z wyczerpaniem zasobów hosta\n'
  printf '  (usługi, pody, alerty). Zacznij od nich; potem przejrzyj różnice ≠ w sekcji 9.\n'
elif (( ${#F_WARN[@]} == 0 )); then
  printf '  Node wygląda zdrowo. Jeśli aplikacja nie startuje tylko tutaj, szukaj różnic w sekcji porównania\n'
  printf '  albo przyczyny po stronie samego workloadu (limity kontenera, wersja runtime).\n'
else
  printf '  Brak oznak realnego wyczerpania zasobów hosta. Ostrzeżenia dotyczą głównie konfiguracji\n'
  printf '  (rezerwacje, limity, różnice względem noda referencyjnego) — różnice oznaczone ≠ w sekcji 9\n'
  printf '  to najlepsze tropy, jeśli problem występuje wyłącznie na tym nodzie.\n'
fi

(( ${#F_CRIT[@]} )) && exit 2
(( ${#F_WARN[@]} )) && exit 1
exit 0