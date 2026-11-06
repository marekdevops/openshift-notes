#!/usr/bin/env bash
# =============================================================================
# dotnet-coreclr-test.sh
# Testuje hipotezy dla "Failed to create CoreCLR, HRESULT: 0x8007054F"
# na KOPIACH deploymentu (oryginał nie jest ruszany).
#
# Tworzy równolegle 4 kopie (replicas=1, ten sam obraz, SA, SCC, zasoby):
#   base  - tylko COREHOST_TRACE (próba kontrolna)
#   wx    - + DOTNET_EnableWriteXorExecute=0
#   gc    - + DOTNET_gcServer=0
#   wxgc  - obie zmienne
# Kopie mają wyczyszczone etykiety/adnotacje (ArgoCD ich nie przejmie,
# Service nie skieruje na nie ruchu) i usunięte liveness/startup probe.
# Po teście kopie są usuwane (chyba że KEEP=1).
#
# Użycie:
#   ./dotnet-coreclr-test.sh <namespace> <deployment> [container]
# Zmienne:
#   TIMEOUT=180  maks. czas czekania na wynik (s)
#   STABLE=45    ile sekund kontener musi działać, by uznać start za udany
#   KEEP=1       nie usuwaj kopii po teście
# Wymaga: oc, jq
# =============================================================================
set -uo pipefail

NS="${1:-}"; D="${2:-}"; CTR="${3:-}"
TIMEOUT="${TIMEOUT:-180}"; STABLE="${STABLE:-45}"; KEEP="${KEEP:-0}"
ERR='Failed to create CoreCLR'

[[ -z "$NS" || -z "$D" ]] && { echo "Użycie: $0 <namespace> <deployment> [container]"; exit 1; }
command -v jq >/dev/null || { echo "Brak jq"; exit 1; }
oc get deploy "$D" -n "$NS" >/dev/null 2>&1 || { echo "Nie ma deploymentu $NS/$D"; exit 1; }

SRC=$(oc get deploy "$D" -n "$NS" -o json)
[[ -z "$CTR" ]] && CTR=$(jq -r '.spec.template.spec.containers[0].name' <<<"$SRC")
IMAGE=$(jq -r --arg c "$CTR" '.spec.template.spec.containers[]|select(.name==$c).image' <<<"$SRC")
SA=$(jq -r '.spec.template.spec.serviceAccountName // "default"' <<<"$SRC")

# Ostrzeżenie: wolumeny RWO mogą zablokować kopie (Multi-Attach)
PVCS=$(jq -r '[.spec.template.spec.volumes[]?|select(.persistentVolumeClaim)|.persistentVolumeClaim.claimName]|join(",")' <<<"$SRC")

VARIANTS=(base wx gc wxgc)
declare -A ENVS=(
  [base]='[]'
  [wx]='[{"name":"DOTNET_EnableWriteXorExecute","value":"0"}]'
  [gc]='[{"name":"DOTNET_gcServer","value":"0"}]'
  [wxgc]='[{"name":"DOTNET_EnableWriteXorExecute","value":"0"},{"name":"DOTNET_gcServer","value":"0"}]'
)
TRACE='[{"name":"COREHOST_TRACE","value":"1"},{"name":"COREHOST_TRACEVERBOSITY","value":"4"}]'

name_of() { echo "${D:0:40}-ct-$1"; }

cleanup() {
  [[ "$KEEP" == "1" ]] && { echo "KEEP=1 - kopie zostają (label coreclr-test=$D)"; return; }
  oc delete deploy -n "$NS" -l coreclr-test="$D" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

echo "Deployment: $NS/$D  kontener: $CTR"
echo "Obraz:      $IMAGE"
echo "SA:         $SA"
[[ -n "$PVCS" ]] && echo "UWAGA: deployment montuje PVC ($PVCS) - przy RWO kopie mogą utknąć w ContainerCreating."
echo

# --- utworzenie kopii --------------------------------------------------------
for v in "${VARIANTS[@]}"; do
  n=$(name_of "$v")
  jq --arg n "$n" --arg d "$D" --arg v "$v" --arg c "$CTR" \
     --argjson e "${ENVS[$v]}" --argjson t "$TRACE" '
    del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,
        .metadata.generation,.metadata.managedFields,.metadata.ownerReferences,.status)
    | .metadata.name=$n
    | .metadata.annotations={}
    | .metadata.labels={"coreclr-test":$d,"coreclr-variant":$v}
    | .spec.replicas=1
    | .spec.selector={"matchLabels":{"coreclr-test-pod":$n}}
    | .spec.template.metadata.labels={"coreclr-test-pod":$n}
    | .spec.template.spec.containers |= map(
        if .name==$c then
          .env = (((.env // []) | map(select(.name as $x |
                   ($e+$t|map(.name)) | index($x) | not))) + $e + $t)
          | del(.livenessProbe,.startupProbe)
        else . end)
  ' <<<"$SRC" | oc apply -n "$NS" -f - >/dev/null \
    && echo "Utworzono kopię: $n" || echo "BŁĄD tworzenia kopii: $n"
done
echo

# --- ocena wyniku ------------------------------------------------------------
declare -A RES NODE TRACED TAIL
for v in "${VARIANTS[@]}"; do RES[$v]="PENDING"; done

pod_of() { oc get pod -n "$NS" -l coreclr-test-pod="$(name_of "$1")" \
             -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

evaluate() {
  local v=$1 p logs started now age restarts running
  p=$(pod_of "$v"); [[ -z "$p" ]] && return
  NODE[$v]=$(oc get pod "$p" -n "$NS" -o jsonpath='{.spec.nodeName}')
  logs="$(oc logs "$p" -n "$NS" -c "$CTR" 2>/dev/null; oc logs "$p" -n "$NS" -c "$CTR" --previous 2>/dev/null)"
  grep -qiE 'Tracing enabled|hostfxr|--- Invoked' <<<"$logs" && TRACED[$v]=1
  if grep -q "$ERR" <<<"$logs"; then
    RES[$v]="FAIL"
    TAIL[$v]=$(grep -B8 "$ERR" <<<"$logs" | tail -9)
    return
  fi
  running=$(oc get pod "$p" -n "$NS" -o jsonpath="{.status.containerStatuses[?(@.name==\"$CTR\")].state.running.startedAt}")
  restarts=$(oc get pod "$p" -n "$NS" -o jsonpath="{.status.containerStatuses[?(@.name==\"$CTR\")].restartCount}")
  if [[ -n "$running" ]]; then
    started=$(date -d "$running" +%s 2>/dev/null || echo 0); now=$(date +%s); age=$((now-started))
    (( age >= STABLE )) && RES[$v]="PASS"
  elif [[ "${restarts:-0}" -gt 0 ]]; then
    RES[$v]="OTHER"   # pada, ale nie na CoreCLR - runtime wstał, problem w aplikacji
    TAIL[$v]=$(tail -9 <<<"$logs")
  fi
}

echo "Czekam na wyniki (max ${TIMEOUT}s)..."
END=$(( $(date +%s) + TIMEOUT ))
while (( $(date +%s) < END )); do
  pending=0
  for v in "${VARIANTS[@]}"; do
    [[ "${RES[$v]}" == "PENDING" ]] && { evaluate "$v"; [[ "${RES[$v]}" == "PENDING" ]] && pending=1; }
  done
  (( pending == 0 )) && break
  sleep 5
done
for v in "${VARIANTS[@]}"; do [[ "${RES[$v]}" == "PENDING" ]] && RES[$v]="TIMEOUT"; done

# --- wyniki ------------------------------------------------------------------
echo
echo "=== WYNIKI ==="
printf "%-6s %-8s %-7s %s\n" WARIANT WYNIK TRACE NODE
for v in "${VARIANTS[@]}"; do
  printf "%-6s %-8s %-7s %s\n" "$v" "${RES[$v]}" "$([[ -n "${TRACED[$v]:-}" ]] && echo tak || echo NIE)" "${NODE[$v]:-?}"
done
for v in "${VARIANTS[@]}"; do
  [[ -n "${TAIL[$v]:-}" ]] && { echo; echo "--- końcówka logu: $v ---"; echo "${TAIL[$v]}"; }
done

ok() { [[ "${RES[$1]}" == "PASS" || "${RES[$1]}" == "OTHER" ]]; }

# Repo GitOps (jeśli deployment jest zarządzany przez ArgoCD)
APP=$(jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // .metadata.labels["app.kubernetes.io/instance"] // empty' <<<"$SRC" | cut -d: -f1)
REPO=""
if [[ -n "$APP" ]]; then
  REPO=$(oc get applications.argoproj.io -A -o json 2>/dev/null | jq -r --arg a "$APP" '
    .items[]|select(.metadata.name==$a)|(.spec.source // .spec.sources[0])|"\(.repoURL) ścieżka: \(.path // .chart) (\(.targetRevision // "HEAD"))"' | head -1)
fi
WHERE="w Dockerfile (ENV ...) albo w env kontenera '$CTR' w manifeście Deploymentu${REPO:+ - repo: $REPO}"

# --- wniosek -----------------------------------------------------------------
echo
echo "=== WNIOSEK ==="
CAUSE=""; FIXENV=""
if [[ -z "${TRACED[base]:-}" && -z "${TRACED[wx]:-}" && "${RES[base]}" == "FAIL" ]]; then
  CAUSE="envdrop"
elif ok base; then
  CAUSE="norepro"
elif ok wx && ! ok gc; then
  CAUSE="wx"; FIXENV="DOTNET_EnableWriteXorExecute=0"
elif ok gc && ! ok wx; then
  CAUSE="gc"; FIXENV="DOTNET_gcServer=0"
elif ok wx && ok gc; then
  CAUSE="wx"; FIXENV="DOTNET_EnableWriteXorExecute=0"
elif ok wxgc; then
  CAUSE="both"; FIXENV="DOTNET_EnableWriteXorExecute=0 oraz DOTNET_gcServer=0"
elif [[ " ${RES[*]} " == *" TIMEOUT "* ]]; then
  CAUSE="timeout"
else
  CAUSE="none"
fi

case $CAUSE in
  wx)   echo "Przyczyna: W^X (Write-XOR-Execute) w .NET blokowany w środowisku kontenera."
        echo "Fix: $FIXENV" ;;
  gc)   echo "Przyczyna: inicjalizacja Server GC (heap per rdzeń) przy limicie pamięci kontenera."
        echo "Fix: $FIXENV" ;;
  both) echo "Przyczyna: potrzebne obie zmiany (W^X i Server GC)."
        echo "Fix: $FIXENV" ;;
  envdrop) echo "Zmienne z Deploymentu NIE docierają do procesu dotnet (brak jakiegokolwiek trace)."
        echo "Skrypt startowy obrazu najpewniej gubi środowisko (su/runuser/env -i)."
        echo "Testy przez env Deploymentu są niewiarygodne - sprawdź skrypt w obrazie (oc debug deploy/$D)." ;;
  norepro) echo "Kopia BEZ zmian startuje poprawnie - problemu nie da się odtworzyć."
        echo "Porównaj node oryginalnego poda z nodem kopii (${NODE[base]:-?}) - możliwy problem zależny od noda." ;;
  timeout) echo "Część kopii nie dała wyniku w ${TIMEOUT}s (Pending/ContainerCreating?)."
        echo "Sprawdź: quota, PVC RWO, eventy: oc get events -n $NS --sort-by=.lastTimestamp | tail" ;;
  none) echo "Żaden wariant nie pomógł - przyczyna inna niż W^X/GC."
        echo "Przeanalizuj końcówki trace powyżej (ostatnie linie przed błędem)." ;;
esac

# --- wiadomość dla zespołu aplikacji -----------------------------------------
if [[ -n "$FIXENV" || "$CAUSE" == "envdrop" ]]; then
  echo
  echo "=== WIADOMOŚĆ DLA ZESPOŁU APLIKACJI ==="
  if [[ -n "$FIXENV" ]]; then cat <<EOF
Deployment $NS/$D nie startuje - runtime .NET pada na inicjalizacji
("Failed to create CoreCLR, HRESULT: 0x8007054F"), zanim uruchomi się kod aplikacji.

Diagnoza: test na kopiach deploymentu (ten sam obraz, SA, SCC i zasoby):
EOF
    for v in "${VARIANTS[@]}"; do printf "  - %-5s %s\n" "$v:" "${RES[$v]}"; done
    cat <<EOF
Start runtime jest możliwy po ustawieniu: $FIXENV

Prośba o dodanie tej zmiennej po Waszej stronie,
$WHERE.
Zmiana dotyczy wyłącznie konfiguracji runtime .NET, nie wymaga zmian w kodzie
ani wyjątków bezpieczeństwa na klastrze.
EOF
  else cat <<EOF
Deployment $NS/$D nie startuje ("Failed to create CoreCLR, HRESULT: 0x8007054F").
W trakcie diagnozy okazało się, że zmienne środowiskowe ustawione w Deploymencie
nie docierają do procesu dotnet - skrypt startowy obrazu najpewniej je gubi
(su/runuser/env -i lub nadpisanie środowiska).

Prośba o weryfikację skryptu startowego w obrazie $IMAGE, tak aby przekazywał
zmienne środowiskowe do procesu dotnet. Po poprawce przetestujemy
DOTNET_EnableWriteXorExecute=0, które jest głównym podejrzanym.
EOF
  fi
fi
echo
