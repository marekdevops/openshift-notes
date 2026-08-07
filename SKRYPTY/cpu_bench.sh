#!/usr/bin/env bash
#
# ocp_cpu_perf_diag.sh
#
# Bezpieczny skrypt diagnostyczny do weryfikacji realnej wydajności CPU/vCPU
# w OpenShift (bare-metal nodes + OpenShift Virtualization / KubeVirt).
#
# Zbiera:
#   - steal time na hoście (kontencja hypervisora)
#   - CFS throttling poda (czy limit CPU realnie ogranicza aplikację)
#   - governor i rzeczywisty zegar CPU na hoście pod obciążeniem
#   - model CPU / flagi instrukcji widziane przez gościa VM (KubeVirt)
#   - requests/limits/QoS klasę poda
#   - opcjonalnie (--benchmark): jednowątkowy test porównawczy sysbench,
#     TYLKO jeśli narzędzie jest już zainstalowane w miejscu docelowym
#     (skrypt niczego nie instaluje ani nie modyfikuje w klastrze)
#
# BEZPIECZEŃSTWO / co skrypt NIE robi:
#   - nie cordonuje, nie drainuje, nie restartuje żadnego node'a ani poda
#   - nie tworzy żadnych trwałych obiektów (Deployment/Pod/DaemonSet) w klastrze
#   - jedyne pody jakie powstają to standardowe efemeryczne pody `oc debug`,
#     które OpenShift usuwa automatycznie po zakończeniu sesji
#   - nie instaluje pakietów, nie modyfikuje configów CPU Manager/kubelet
#   - wszystkie operacje to `oc get/describe/exec/debug` (read-only z punktu
#     widzenia stanu klastra); jedyny "zapis" to plik raportu na dysku lokalnym
#
# Wymagania: zalogowany `oc` z uprawnieniami wystarczającymi do:
#   - `oc debug node/<node>` (zwykle cluster-admin lub odpowiednia rola)
#   - `oc exec`/`oc get` w namespace poda który diagnozujesz
#
# Użycie:
#   ./ocp_cpu_perf_diag.sh --node <node-name> \
#       [--pod <namespace>/<pod-name>] \
#       [--vmi <namespace>/<vmi-name>] \
#       [--benchmark] \
#       [--sample-seconds 5]
#
# Przykład:
#   ./ocp_cpu_perf_diag.sh --node worker-03 --pod bank-app/payments-7f9c-abcd --vmi bank-app/payments-vmi
#
set -euo pipefail

# ---------- domyślne wartości ----------
NODE=""
POD_REF=""       # namespace/pod
VMI_REF=""       # namespace/vmi
RUN_BENCHMARK=false
SAMPLE_SECONDS=5
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="ocp_cpu_diag_${TIMESTAMP}.txt"

# ---------- parsowanie argumentów ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --pod) POD_REF="$2"; shift 2 ;;
    --vmi) VMI_REF="$2"; shift 2 ;;
    --benchmark) RUN_BENCHMARK=true; shift ;;
    --sample-seconds) SAMPLE_SECONDS="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Nieznany argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$NODE" ]]; then
  echo "Błąd: wymagany jest --node <node-name>" >&2
  exit 1
fi

# ---------- helpery ----------
log()     { echo -e "$*" | tee -a "$REPORT_FILE" ; }
section() { log "\n========================================\n$*\n========================================" ; }

run_on_node() {
  # Uruchamia komendę na hoście przez efemeryczny pod oc debug (auto-cleanup).
  # chroot /host żeby operować na realnym systemie plików/procesach node'a.
  local cmd="$1"
  oc debug "node/${NODE}" --quiet=true -- chroot /host bash -c "$cmd" 2>/dev/null || \
    log "  [!] Komenda na node nie powiodła się (sprawdź uprawnienia): $cmd"
}

check_prereqs() {
  command -v oc >/dev/null 2>&1 || { echo "Brak 'oc' w PATH" >&2; exit 1; }
  oc whoami >/dev/null 2>&1 || { echo "Nie jesteś zalogowany do klastra (oc login)" >&2; exit 1; }
  oc get node "$NODE" >/dev/null 2>&1 || { echo "Node '$NODE' nie istnieje lub brak dostępu" >&2; exit 1; }
}

# ---------- sekcje diagnostyczne ----------

collect_node_hw() {
  section "1. SPRZĘT FIZYCZNY NODE'A: $NODE"
  log "-- capacity / allocatable --"
  oc get node "$NODE" -o jsonpath='{.status.capacity.cpu} CPU capacity / {.status.allocatable.cpu} CPU allocatable{"\n"}' | tee -a "$REPORT_FILE" >/dev/null
  log "\n-- lscpu (model, taktowanie, cache) --"
  run_on_node "lscpu" | tee -a "$REPORT_FILE" >/dev/null
}

collect_node_governor() {
  section "2. GOVERNOR I RZECZYWISTY ZEGAR (przed/po krótkim obciążeniu)"
  log "-- aktualny governor per-core --"
  run_on_node "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c" | tee -a "$REPORT_FILE" >/dev/null
  log "\n-- zegar w spoczynku (MHz) --"
  run_on_node "grep MHz /proc/cpuinfo | head -8" | tee -a "$REPORT_FILE" >/dev/null
}

collect_node_steal() {
  section "3. STEAL TIME NA HOŚCIE (kontencja hypervisora, ${SAMPLE_SECONDS}s próbka)"
  run_on_node "mpstat -P ALL 1 ${SAMPLE_SECONDS} 2>/dev/null || (echo 'mpstat niedostępny na node — zainstaluj pakiet sysstat lub pomiń' )" | tee -a "$REPORT_FILE" >/dev/null
  log "\nInterpretacja: kolumna %steal > 1-2% konsekwentnie = realna kontencja z innymi tenantami."
}

collect_pod_info() {
  [[ -z "$POD_REF" ]] && return 0
  local ns="${POD_REF%%/*}"
  local pod="${POD_REF##*/}"

  section "4. POD: $POD_REF (requests/limits, QoS, CFS throttling)"
  log "-- requests / limits / QoS class --"
  oc get pod "$pod" -n "$ns" -o jsonpath='QoS: {.status.qosClass}{"\n"}' | tee -a "$REPORT_FILE" >/dev/null
  oc get pod "$pod" -n "$ns" -o jsonpath='{range .spec.containers[*]}{.name}: requests.cpu={.resources.requests.cpu} limits.cpu={.resources.limits.cpu}{"\n"}{end}' | tee -a "$REPORT_FILE" >/dev/null

  log "\n-- CFS throttling (cpu.stat z cgroup) --"
  # Próba dla cgroup v2, potem v1 jako fallback
  oc exec -n "$ns" "$pod" -- sh -c "cat /sys/fs/cgroup/cpu.stat 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null" 2>/dev/null | tee -a "$REPORT_FILE" >/dev/null \
    || log "  [!] Nie udało się odczytać cpu.stat (brak dostępu do cgroup w kontenerze)"
  log "\nInterpretacja: nr_throttled > 0 i rosnące throttled_usec = aplikacja jest realnie duszona limitem CPU."
}

collect_vmi_cpumodel() {
  [[ -z "$VMI_REF" ]] && return 0
  local ns="${VMI_REF%%/*}"
  local vmi="${VMI_REF##*/}"

  section "5. VMI (KubeVirt): $VMI_REF — model CPU i topologia"
  oc get vmi "$vmi" -n "$ns" -o jsonpath='model: {.spec.domain.cpu.model}{"\n"}cores: {.spec.domain.cpu.cores}{"\n"}dedicatedCpuPlacement: {.spec.domain.cpu.dedicatedCpuPlacement}{"\n"}' 2>/dev/null | tee -a "$REPORT_FILE" >/dev/null \
    || log "  [!] Nie udało się pobrać VMI (sprawdź nazwę/namespace lub czy to na pewno VM)"

  log "\n-- flagi CPU widziane wewnątrz gościa --"
  oc get vmi "$vmi" -n "$ns" -o jsonpath='{.metadata.name}' >/dev/null 2>&1 && \
    { oc exec -n "$ns" "$vmi" -c compute -- cat /proc/cpuinfo 2>/dev/null | grep -m1 flags | tee -a "$REPORT_FILE" >/dev/null || \
      log "  [i] Bezpośredni exec do guest CPU niedostępny w tej konfiguracji — sprawdź ręcznie przez virtctl console/ssh: cat /proc/cpuinfo | grep flags"; }
}

run_benchmark() {
  $RUN_BENCHMARK || return 0
  section "6. BENCHMARK PORÓWNAWCZY (jednowątkowy, opt-in)"
  log "Uwaga: benchmark obciąża realnie CPU przez czas trwania testu. Nie instalujemy"
  log "niczego automatycznie — test uruchamia się tylko tam, gdzie sysbench już jest dostępny."

  log "\n-- baseline: bare-metal host --"
  run_on_node "command -v sysbench >/dev/null 2>&1 && sysbench cpu --cpu-max-prime=20000 --threads=1 run | tail -6 || echo 'sysbench niedostępny na hoście — pomiń lub zainstaluj ręcznie do jednorazowego testu'" | tee -a "$REPORT_FILE" >/dev/null

  if [[ -n "$POD_REF" ]]; then
    local ns="${POD_REF%%/*}"
    local pod="${POD_REF##*/}"
    log "\n-- pod pod testem: $POD_REF --"
    oc exec -n "$ns" "$pod" -- sh -c "command -v sysbench >/dev/null 2>&1 && sysbench cpu --cpu-max-prime=20000 --threads=1 run | tail -6 || echo 'sysbench niedostępny w kontenerze — pomiń lub dodaj tymczasowo do obrazu testowego'" 2>/dev/null | tee -a "$REPORT_FILE" >/dev/null
  fi

  log "\nPorównaj 'events per second' / 'total time' między hostem a podem —"
  log "różnica > kilkunastu % przy tym samym wątku wskazuje na overhead wirtualizacji/schedulingu,"
  log "nie na słabszy krzem."
}

# ---------- main ----------
check_prereqs
log "OpenShift CPU Performance Diagnostic"
log "Data: $(date)"
log "Node: $NODE"
[[ -n "$POD_REF" ]] && log "Pod: $POD_REF"
[[ -n "$VMI_REF" ]] && log "VMI: $VMI_REF"
log "Benchmark: $RUN_BENCHMARK"

collect_node_hw
collect_node_governor
collect_node_steal
collect_pod_info
collect_vmi_cpumodel
run_benchmark

section "GOTOWE"
log "Pełny raport zapisany w: $REPORT_FILE"