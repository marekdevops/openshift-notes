#!/usr/bin/env bash
# =============================================================================
# dotnet-coreclr-strace.sh
# Etap 3 diagnozy "Failed to create CoreCLR, HRESULT: 0x8007054F":
# pokazuje, KTÓRY syscall kernel odrzuca przy starcie runtime .NET.
#
# 1. Tworzy pod testowy z szablonu deploymentu (ten sam obraz, SA, SCC, env,
#    limity), który czeka na sygnał zamiast startować aplikację.
# 2. Na nodzie, przez 'oc debug node' z obrazem support-tools (zawiera strace),
#    podpina strace do procesu, daje sygnał startu i nagrywa start dotnet.
# 3. Analizuje błędy syscalli i wypisuje wniosek: po stronie klastra
#    (SELinux/seccomp) czy aplikacji (uprawnienia plików/obraz).
# Oryginalny deployment NIE jest zmieniany. Pod testowy jest usuwany.
#
# Wymaga: oc (cluster-admin), jq, dostęp noda do obrazu support-tools.
# Użycie:
#   ./dotnet-coreclr-strace.sh <namespace> <deployment> [container] [app.dll]
# Zmienne:
#   TOOLS=registry.redhat.io/rhel9/support-tools:latest   (lub mirror)
# =============================================================================
set -uo pipefail

NS="${1:-}"; D="${2:-}"; CTR="${3:-}"; APP="${4:-}"
TOOLS="${TOOLS:-registry.redhat.io/rhel9/support-tools:latest}"
[[ -z "$NS" || -z "$D" ]] && { echo "Użycie: $0 <namespace> <deployment> [container] [app.dll]"; exit 1; }
command -v jq >/dev/null || { echo "Brak jq"; exit 1; }
oc get deploy "$D" -n "$NS" >/dev/null 2>&1 || { echo "Nie ma deploymentu $NS/$D"; exit 1; }

SRC=$(oc get deploy "$D" -n "$NS" -o json)
[[ -z "$CTR" ]] && CTR=$(jq -r '.spec.template.spec.containers[0].name' <<<"$SRC")
POD="${D:0:40}-strace-$(date +%s | tail -c 6)"
OUTFILE="strace-${D}-$(date +%Y%m%d-%H%M%S).txt"

cleanup() { oc delete pod "$POD" -n "$NS" --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

# --- 1. pod testowy czekający na sygnał -------------------------------------
LOOP='while [ ! -s /tmp/coreclr-go ]; do sleep 1; done; A=$(cat /tmp/coreclr-go); cd "$(dirname "$A")"; exec dotnet "$A"'
jq --arg p "$POD" --arg c "$CTR" --arg l "$LOOP" '{
  apiVersion:"v1", kind:"Pod",
  metadata:{name:$p, labels:{"coreclr-strace":"true"},
            annotations:(.spec.template.metadata.annotations // {})},
  spec:(.spec.template.spec
        | .restartPolicy="Never"
        | .containers |= map(if .name==$c then
              .command=["sh","-c",$l] | del(.args,.livenessProbe,.readinessProbe,.startupProbe)
            else . end))
}' <<<"$SRC" | oc create -n "$NS" -f - >/dev/null || { echo "Nie udało się utworzyć poda testowego"; exit 1; }

echo "Pod testowy: $POD - czekam na Running..."
oc wait pod/"$POD" -n "$NS" --for=condition=Ready --timeout=180s >/dev/null 2>&1 \
  || { echo "Pod nie wystartował:"; oc get pod "$POD" -n "$NS"; oc get events -n "$NS" --field-selector involvedObject.name="$POD" | tail -5; exit 1; }

NODE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')
CID=$(oc get pod "$POD" -n "$NS" -o jsonpath="{.status.containerStatuses[?(@.name==\"$CTR\")].containerID}" | sed 's#.*://##')
SECCOMP_SPEC=$(oc get pod "$POD" -n "$NS" -o jsonpath="{.spec.securityContext.seccompProfile.type}{' '}{.spec.containers[?(@.name==\"$CTR\")].securityContext.seccompProfile.type}{' '}{.spec.containers[?(@.name==\"$CTR\")].securityContext.seccompProfile.localhostProfile}")
SCC=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/scc}')

if [[ -z "$APP" ]]; then
  APP=$(oc exec "$POD" -n "$NS" -c "$CTR" -- sh -c \
    "find / -maxdepth 5 -name '*.runtimeconfig.json' -not -path '/proc/*' -not -path '/usr/share/dotnet/*' -not -path '/usr/lib64/dotnet/*' -not -path '*/sdk/*' 2>/dev/null | head -1" \
    | sed 's/\.runtimeconfig\.json$/.dll/')
fi
[[ -z "$APP" ]] && { echo "Nie wykryto aplikacji - podaj ścieżkę .dll jako 4. argument"; exit 1; }

echo "Node: $NODE | SCC: $SCC | app: $APP"
echo "Seccomp w specu poda: ${SECCOMP_SPEC// /}" | sed 's/: $/: (brak - domyślny z SCC\/CRI-O)/'
echo "Uruchamiam strace na nodzie (obraz: $TOOLS)..."

# --- 2. strace na nodzie -----------------------------------------------------
read -r -d '' NODESCRIPT <<'EOS'
CID="$1"; APP="$2"
PID=$(chroot /host crictl inspect -o go-template --template '{{.info.pid}}' "$CID" 2>/dev/null)
[ -z "$PID" ] && { echo "##NOPID"; exit 0; }
echo "##SECTION proc"
grep -E '^(Seccomp|NoNewPrivs|CapEff):' /proc/$PID/status
echo "label: $(cat /proc/$PID/attr/current 2>/dev/null)"
echo "##SECTION sebool"
chroot /host getsebool -a 2>/dev/null | grep -E 'execmem|execstack|execheap|container_' || echo "(brak)"
echo "##SECTION kernel"
chroot /host uname -r
grep -m1 'model name' /proc/cpuinfo
timeout 90 strace -f -tt -s 160 -o /tmp/st -p "$PID" &
SP=$!
sleep 3
printf '%s' "$APP" > /proc/$PID/root/tmp/coreclr-go
wait $SP
echo "##SECTION full"
cat /tmp/st
echo "##END"
EOS

RAW=$(oc debug node/"$NODE" --image="$TOOLS" -- bash -c "$NODESCRIPT" bash "$CID" "$APP" 2>&1)

grep -q '##NOPID' <<<"$RAW" && { echo "Nie znaleziono PID kontenera na nodzie."; exit 1; }
grep -q '##END' <<<"$RAW" || { echo "strace nie zakończył się poprawnie (obraz $TOOLS dostępny?). Wyjście:"; tail -20 <<<"$RAW"; exit 1; }

sect() { awk -v s="##SECTION $1" '$0==s{f=1;next} /^##(SECTION|END)/{f=0} f' <<<"$RAW"; }
ST=$(sect full); printf '%s\n' "$ST" > "$OUTFILE"

echo; echo "=== Proces na nodzie ==="; sect proc
echo; echo "=== SELinux booleans ==="; sect sebool
echo; echo "=== Kernel / CPU ==="; sect kernel
echo; echo "Pełny strace zapisany: $OUTFILE ($(wc -l <"$OUTFILE") linii)"

# --- 3. analiza --------------------------------------------------------------
ERRS=$(grep -E ' = -1 E[A-Z]+' "$OUTFILE" \
  | grep -vE ' = -1 (ENOENT|ENOTTY|ECHILD|ESRCH|ENODATA|EEXIST|ETIMEDOUT|EINTR|ERANGE|ENOTDIR|ENXIO) ' \
  | grep -vE '(futex|read|recv|recvfrom|recvmsg|accept4?|epoll_wait|wait4)\(.* = -1 EAGAIN')

echo; echo "=== Odrzucone syscalle (bez typowego szumu) ==="
if [[ -n "$ERRS" ]]; then
  sed -E 's/^[0-9]+ +[0-9:.]+ +//' <<<"$ERRS" | cut -c1-200 | sort | uniq -c | sort -rn | head -25
else
  echo "(brak)"
fi

echo; echo "=== Ostatnie syscalle przed zakończeniem ==="
grep -vE 'futex|clock_gettime|sched_yield|rt_sig' "$OUTFILE" | tail -15 | cut -c1-200

F=()
grep -qE '(mmap|mprotect|pkey_mprotect)\(.*PROT_EXEC.* = -1 (EACCES|EPERM)' <<<"$ERRS" && F+=(execmem)
grep -qE 'memfd_create\(.* = -1 ' <<<"$ERRS" && F+=(memfd)
grep -qE 'clone3\(.* = -1 EPERM' <<<"$ERRS" && F+=(clone3)
grep -qE '(clone|clone3)\(.* = -1 (EAGAIN|ENOMEM)' <<<"$ERRS" && F+=(threads)
grep -qE 'membarrier\(.* = -1 EPERM' <<<"$ERRS" && F+=(membarrier)
grep -qE '(mmap|mremap)\(.* = -1 ENOMEM' <<<"$ERRS" && F+=(nomem)
FILES=$(grep -oE '(open|openat|access|faccessat2?|execve|mkdir)\([^)]*"[^"]+".* = -1 (EACCES|EPERM)' <<<"$ERRS" | grep -oE '"[^"]+"' | sort -u | head -10)
[[ -n "$FILES" ]] && F+=(files)
OTHER_EPERM=$(grep -E ' = -1 EPERM' <<<"$ERRS" | sed -E 's/^[0-9]+ +[0-9:.]+ +//; s/\(.*//' | sort -u | tr '\n' ' ')

echo; echo "=== WNIOSEK ==="
SIDE=""
for f in "${F[@]:-}"; do case $f in
  execmem)  echo "- SELinux blokuje pamięć wykonywalną (execmem) - JIT .NET nie może działać."
            echo "  Strona: KLASTER. Sprawdź boolean deny_execmem i polityki SELinux z MachineConfig;"
            echo "  potwierdzenie: na nodzie 'semodule -DB', powtórz test, 'ausearch -m avc -ts recent', potem 'semodule -B'."
            SIDE+="cluster " ;;
  memfd)    echo "- Odrzucone memfd_create (seccomp/SELinux) - podwójne mapowanie pamięci runtime."
            echo "  Strona: KLASTER (profil seccomp lub polityka SELinux)."; SIDE+="cluster " ;;
  clone3)   echo "- clone3 zwraca EPERM - profil seccomp blokuje clone3 zamiast zwrócić ENOSYS."
            echo "  glibc 2.34+ (UBI9) nie robi wtedy fallbacku na clone - runtime nie może tworzyć wątków."
            echo "  Strona: KLASTER. Sprawdź profil seccomp poda (Security Profiles Operator / localhost profile)."
            SIDE+="cluster " ;;
  threads)  echo "- Tworzenie wątków odrzucone (EAGAIN/ENOMEM) - limit pids/wątków lub pamięci."
            SIDE+="cluster " ;;
  membarrier) echo "- membarrier zwraca EPERM - profil seccomp blokuje membarrier."
            echo "  Strona: KLASTER (profil seccomp)."; SIDE+="cluster " ;;
  nomem)    echo "- mmap zwraca ENOMEM - kernel odmawia rezerwacji pamięci (limity/overcommit/cgroup)."
            SIDE+="cluster " ;;
  files)    echo "- Brak dostępu do plików (EACCES/EPERM):"; sed 's/^/    /' <<<"$FILES"
            echo "  Strona: APLIKACJA (uprawnienia w obrazie dla UID 1001 / grupy 0)."; SIDE+="app " ;;
esac; done

if [[ -z "$SIDE" ]]; then
  if [[ -n "$OTHER_EPERM" ]]; then
    echo "Syscalle odrzucone z EPERM: $OTHER_EPERM"
    echo "EPERM bez uprawnień do plików zwykle oznacza seccomp - sprawdź profil seccomp poda."
  else
    echo "Kernel niczego nie odrzucił - błąd jest wewnątrz runtime (obraz/runtime uszkodzony lub niezgodny)."
    echo "Strona: APLIKACJA/OBRAZ. Test: przebudowa na aktualnym obrazie bazowym dotnet-80."
    echo "Plik $OUTFILE dołącz do zgłoszenia w Red Hat (obraz UBI dotnet)."
    SIDE="image"
  fi
fi

if [[ "$SIDE" == *app* || "$SIDE" == "image" ]]; then
  IMAGE=$(jq -r --arg c "$CTR" '.spec.template.spec.containers[]|select(.name==$c).image' <<<"$SRC")
  echo; echo "=== WIADOMOŚĆ DLA ZESPOŁU APLIKACJI ==="
  cat <<EOF
Deployment $NS/$D nie startuje - runtime .NET pada przy inicjalizacji
("Failed to create CoreCLR, HRESULT: 0x8007054F").
Diagnoza po stronie klastra (konfiguracja runtime, limity, SELinux/seccomp, strace)
wyklucza przyczynę środowiskową.
EOF
  [[ -n "$FILES" ]] && { echo "Runtime nie ma dostępu do plików w obrazie (uruchamiany jako UID 1001, grupa 0):"; sed 's/^/  /' <<<"$FILES"
    echo "Prośba o poprawkę w Dockerfile: chgrp -R 0 <katalogi> && chmod -R g=u <katalogi>."; }
  [[ "$SIDE" == "image" ]] && echo "Prośba o przebudowę obrazu $IMAGE na aktualnym obrazie bazowym .NET 8 i ponowny test. Zapis strace dostępny."
elif [[ "$SIDE" == *cluster* ]]; then
  echo; echo "Przyczyna leży po stronie klastra - zespół aplikacji nie musi nic zmieniać."
fi
echo
