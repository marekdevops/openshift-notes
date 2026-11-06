#!/usr/bin/env bash
# =============================================================================
# dotnet-coreclr-debug.sh
# Etap 2 diagnozy "Failed to create CoreCLR, HRESULT: 0x8007054F",
# gdy W^X i Server GC zostały wykluczone.
#
# Uruchamia 'oc debug deploy/<deploy>' (pod z tym samym obrazem, SA, SCC, env
# i limitami, ale BEZ skryptu startowego), zbiera z wnętrza kontenera:
#   - zmienne DOTNET_*/COMPlus_* (obraz + deployment + ConfigMapy)
#   - ulimit (pamięć wirtualna, procesy), overcommit, max_map_count, cgroup
# i uruchamia aplikację ręcznie w kilku wariantach.
# Oryginalny deployment NIE jest zmieniany; pod debug jest usuwany po teście.
#
# Użycie:
#   ./dotnet-coreclr-debug.sh <namespace> <deployment> [container] [ścieżka.dll]
#   (ścieżka .dll wykrywana automatycznie po *.runtimeconfig.json)
# Zmienne:
#   RUNTIME=25   ile sekund daje się każdemu wariantowi
# =============================================================================
set -uo pipefail

NS="${1:-}"; D="${2:-}"; CTR="${3:-}"; APP="${4:-}"
RUNTIME="${RUNTIME:-25}"
[[ -z "$NS" || -z "$D" ]] && { echo "Użycie: $0 <namespace> <deployment> [container] [app.dll]"; exit 1; }
oc get deploy "$D" -n "$NS" >/dev/null 2>&1 || { echo "Nie ma deploymentu $NS/$D"; exit 1; }
[[ -z "$CTR" ]] && CTR=$(oc get deploy "$D" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].name}')

echo "=== Zmienne DOTNET_* z deploymentu (z rozwiązanymi ConfigMap/Secret) ==="
DEPLOY_ENV=$(oc set env deploy/"$D" -n "$NS" -c "$CTR" --list --resolve 2>/dev/null | grep -iE '^(DOTNET|COMPlus)_' || true)
echo "${DEPLOY_ENV:-(brak)}"
echo

# -----------------------------------------------------------------------------
# Skrypt wykonywany WEWNĄTRZ kontenera (POSIX sh - obraz może nie mieć bash)
# -----------------------------------------------------------------------------
read -r -d '' INNER <<'EOS'
APP="$1"; RT="$2"
echo "##SECTION env"
env | grep -iE '^(DOTNET|COMPlus)_' || echo "(brak)"

echo "##SECTION limits"
echo "id: $(id)"
echo "ulimit_v=$(ulimit -v)"
echo "ulimit_u=$(ulimit -u 2>/dev/null || ulimit -p 2>/dev/null)"
echo "overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
echo "max_map_count=$(cat /proc/sys/vm/max_map_count 2>/dev/null)"
echo "mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
echo "pids_max=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids/pids.max 2>/dev/null)"
echo "nproc=$(nproc 2>/dev/null)"

# Wykrycie aplikacji
if [ -z "$APP" ]; then
  RC=$(find / -maxdepth 5 -name '*.runtimeconfig.json' \
        -not -path '/proc/*' -not -path '/usr/share/dotnet/*' -not -path '/usr/lib/dotnet/*' \
        -not -path '*/sdk/*' 2>/dev/null | head -1)
  [ -n "$RC" ] && APP="${RC%.runtimeconfig.json}.dll"
fi
echo "##SECTION app"
echo "app=$APP"
if [ -z "$APP" ] || [ ! -f "$APP" ]; then echo "##APPNOTFOUND"; exit 0; fi

if command -v dotnet >/dev/null 2>&1; then RUN="dotnet $APP"
elif [ -x "${APP%.dll}" ]; then RUN="${APP%.dll}"
else echo "##NODOTNET"; exit 0; fi
echo "run=$RUN"
cd "$(dirname "$APP")" 2>/dev/null

run_variant() {
  name="$1"; shift
  out=/tmp/coreclr-$name.log
  if command -v timeout >/dev/null 2>&1; then
    env "$@" timeout "$RT" $RUN >"$out" 2>&1
  else
    env "$@" $RUN >"$out" 2>&1 & p=$!; sleep "$RT"; kill $p 2>/dev/null
  fi
  if grep -q 'Failed to create CoreCLR' "$out"; then r=FAIL; else r=PASS; fi
  echo "##RES $name $r"
  echo "##TAIL $name"; tail -5 "$out"; echo "##ENDTAIL"
}

echo "##SECTION tests"
run_variant base        X_NOOP=1
run_variant heaplimit   DOTNET_GCHeapHardLimit=0x20000000
run_variant regionrange DOTNET_GCRegionRange=0x40000000
run_variant notiered    DOTNET_TieredCompilation=0
run_variant nodiag      DOTNET_EnableDiagnostics=0
run_variant all         DOTNET_EnableWriteXorExecute=0 DOTNET_gcServer=0 \
                        DOTNET_GCHeapHardLimit=0x20000000 DOTNET_GCRegionRange=0x40000000 \
                        DOTNET_TieredCompilation=0 DOTNET_EnableDiagnostics=0
echo "##DONE"
EOS

echo "Uruchamiam pod debug (każdy wariant do ${RUNTIME}s, razem ok. $((RUNTIME*6+30))s)..."
OUT=$(oc debug deploy/"$D" -n "$NS" -c "$CTR" -- sh -c "$INNER" sh "$APP" "$RUNTIME" 2>&1)

sect() { awk -v s="##SECTION $1" '$0==s{f=1;next} /^##SECTION/{f=0} f && !/^##/' <<<"$OUT"; }
val()  { grep -m1 "^$1=" <<<"$OUT" | cut -d= -f2-; }

echo; echo "=== Zmienne DOTNET_* widziane w kontenerze (obraz + deployment) ==="
sect env
echo; echo "=== Limity w kontenerze ==="
sect limits

if grep -q '##APPNOTFOUND' <<<"$OUT"; then
  echo; echo "Nie znaleziono aplikacji (*.runtimeconfig.json). Podaj ścieżkę .dll jako 4. argument."
  echo "Podpowiedź: oc image info <obraz> | grep -iE 'entrypoint|cmd|workdir'"; exit 1
fi
grep -q '##NODOTNET' <<<"$OUT" && { echo "Brak 'dotnet' w PATH i brak apphost - podaj pełną ścieżkę."; exit 1; }
grep -q '##DONE' <<<"$OUT" || { echo; echo "Test nie zakończył się poprawnie. Surowe wyjście:"; tail -30 <<<"$OUT"; exit 1; }

echo; echo "app: $(val app)"
echo; echo "=== WYNIKI (ręczne uruchomienie bez skryptu startowego) ==="
declare -A R
while read -r _ n r; do R[$n]=$r; printf "%-12s %s\n" "$n" "$r"; done < <(grep '^##RES ' <<<"$OUT")

echo; echo "=== Końcówka wyjścia wariantu 'base' ==="
awk '/^##TAIL base$/{f=1;next} /^##ENDTAIL/{f=0} f' <<<"$OUT"

# -----------------------------------------------------------------------------
# Analiza
# -----------------------------------------------------------------------------
ULV=$(val ulimit_v); OVC=$(val overcommit); MMC=$(val max_map_count); PIDS=$(val pids_max)
FLAGS=()
[[ -n "$ULV" && "$ULV" != "unlimited" ]] && FLAGS+=("ulimit -v = $ULV (ograniczona pamięć wirtualna - GC .NET 8 rezerwuje duże zakresy adresów)")
[[ "$OVC" == "2" ]] && FLAGS+=("vm.overcommit_memory = 2 na nodzie (rezerwacje GC mogą być odrzucane)")
[[ -n "$MMC" && "$MMC" =~ ^[0-9]+$ ]] && (( MMC < 65530 )) && FLAGS+=("vm.max_map_count = $MMC (niżej niż domyślne 65530)")
[[ -n "$PIDS" && "$PIDS" =~ ^[0-9]+$ ]] && (( PIDS < 256 )) && FLAGS+=("pids.max = $PIDS (mało wątków dla runtime)")
DN_ENV=$(sect env | grep -v '^(brak)$')
[[ -n "$DN_ENV" ]] && FLAGS+=("w kontenerze ustawione są zmienne DOTNET_* - sprawdź wartości (format hex, limity > memory.max)")

echo; echo "=== WNIOSEK ==="
FIX=""; MSG=""
if [[ "${R[base]:-}" == "PASS" ]]; then
  echo "Runtime STARTUJE przy ręcznym uruchomieniu, a pada tylko przez skrypt startowy obrazu."
  echo "Przyczyna leży w skrypcie startowym (ustawiane przez niego zmienne, ulimit, zmiana użytkownika,"
  echo "albo plik konfiguracyjny/zmienna, którą generuje przed 'Running application')."
  MSG="wrapper"
else
  for v in heaplimit regionrange notiered nodiag; do
    [[ "${R[$v]:-}" == "PASS" ]] && { FIX="$v"; break; }
  done
  case $FIX in
    heaplimit)   FIXENV="DOTNET_GCHeapHardLimit=0x20000000 (512 MiB; dobrać do aplikacji, < limit kontenera)"
                 echo "Przyczyna: GC nie może zarezerwować pamięci przy starcie. Pomaga twardy limit heap." ;;
    regionrange) FIXENV="DOTNET_GCRegionRange=0x40000000 (1 GiB)"
                 echo "Przyczyna: GC (regions) nie może zarezerwować zakresu adresów wirtualnych." ;;
    notiered)    FIXENV="DOTNET_TieredCompilation=0"
                 echo "Przyczyna: inicjalizacja tiered compilation (wątki/JIT) - nietypowe, warto zgłosić do supportu." ;;
    nodiag)      FIXENV="DOTNET_EnableDiagnostics=0"
                 echo "Przyczyna: inicjalizacja diagnostyki runtime (IPC/EventPipe)." ;;
    "")
      if [[ "${R[all]:-}" == "PASS" ]]; then
        FIXENV="kombinacja: DOTNET_EnableWriteXorExecute=0, DOTNET_gcServer=0, DOTNET_GCHeapHardLimit, DOTNET_GCRegionRange"
        echo "Pomaga dopiero kombinacja zmiennych - kilka czynników naraz (najpewniej W^X + rezerwacja GC)."
        FIX="all"
      else
        echo "Żaden wariant nie pomógł. Problem nie leży w konfiguracji runtime ustawianej zmiennymi."
        echo "Następny krok: strace z noda na procesie dotnet (szukać ENOMEM/EPERM przy mmap/clone/memfd)"
        echo "albo zgłoszenie do Red Hat / Microsoft z wynikami tego skryptu."
      fi ;;
  esac
  [[ -n "$FIX" ]] && { echo "Fix: $FIXENV"; MSG="env"; }
fi

if (( ${#FLAGS[@]} )); then
  echo; echo "Ustawienia środowiska warte uwagi:"
  for f in "${FLAGS[@]}"; do echo "  - $f"; done
fi

# Repo GitOps
SRC=$(oc get deploy "$D" -n "$NS" -o json)
APPNAME=$(jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // .metadata.labels["app.kubernetes.io/instance"] // empty' <<<"$SRC" 2>/dev/null | cut -d: -f1)
REPO=""
[[ -n "$APPNAME" ]] && REPO=$(oc get applications.argoproj.io -A -o json 2>/dev/null | jq -r --arg a "$APPNAME" '
  .items[]|select(.metadata.name==$a)|(.spec.source // .spec.sources[0])|"\(.repoURL) ścieżka: \(.path // .chart)"' | head -1)
IMAGE=$(jq -r --arg c "$CTR" '.spec.template.spec.containers[]|select(.name==$c).image' <<<"$SRC" 2>/dev/null)

if [[ -n "$MSG" ]]; then
  echo; echo "=== WIADOMOŚĆ DLA ZESPOŁU APLIKACJI ==="
  echo "Deployment $NS/$D nie startuje - runtime .NET pada przy inicjalizacji"
  echo "(\"Failed to create CoreCLR, HRESULT: 0x8007054F\"), zanim uruchomi się kod aplikacji."
  echo
  if [[ "$MSG" == "wrapper" ]]; then cat <<EOF
Diagnoza: ten sam obraz, uruchomiony ręcznie z tymi samymi uprawnieniami, zmiennymi
i limitami, ale z pominięciem skryptu startowego, startuje poprawnie.
Problem jest więc w skrypcie startowym obrazu $IMAGE - w krokach wykonywanych przed
"Running application" (ustawiane zmienne środowiskowe, ulimit, zmiana użytkownika,
generowany appsettings-container.json lub ustawienia runtime).

Prośba o weryfikację skryptu startowego. Po stronie klastra nie są potrzebne zmiany.
EOF
  else cat <<EOF
Diagnoza: ręczne uruchomienie obrazu w tym samym środowisku z różnymi ustawieniami
runtime. Wyniki:
$(grep '^##RES ' <<<"$OUT" | awk '{printf "  - %-12s %s\n",$2,$3}')

Runtime startuje po ustawieniu: $FIXENV

Prośba o dodanie tej zmiennej w Dockerfile (ENV ...) albo w env kontenera '$CTR'
w manifeście Deploymentu${REPO:+ (repo: $REPO)}.
Zmiana dotyczy wyłącznie konfiguracji runtime .NET, bez zmian w kodzie
i bez wyjątków bezpieczeństwa na klastrze.
EOF
  fi
fi
echo
