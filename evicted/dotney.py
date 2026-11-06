#!/usr/bin/env bash
# =============================================================================
# dotnet-coreclr-check.sh
# Diagnostyka poda .NET w CrashLoopBackOff z błędem:
#   "Failed to create CoreCLR, HRESULT: 0x8007054F"
#
# Skrypt jest TYLKO DO ODCZYTU - niczego nie zmienia w klastrze.
# Wymaga: oc (zalogowany), uprawnień do 'oc debug node' (cluster-admin).
#
# Użycie:
#   ./dotnet-coreclr-check.sh <namespace> <pod> [container]
# =============================================================================
set -uo pipefail

NS="${1:-}"; POD="${2:-}"; CTR="${3:-}"
if [[ -z "$NS" || -z "$POD" ]]; then
  echo "Użycie: $0 <namespace> <pod> [container]"; exit 1
fi

oc get pod "$POD" -n "$NS" >/dev/null 2>&1 || { echo "Nie znaleziono poda $NS/$POD"; exit 1; }
[[ -z "$CTR" ]] && CTR=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.containers[0].name}')

jp() { oc get pod "$POD" -n "$NS" -o jsonpath="$1" 2>/dev/null; }
hdr() { echo; echo "=== $* ==="; }

# Zamiana wartości memory (Gi, Mi, G, M, Ki, bajty) na MiB
to_mi() {
  awk -v v="$1" 'BEGIN{
    if (v=="") {print 0; exit}
    n=v; sub(/[A-Za-z]+$/,"",n); u=v; sub(/^[0-9.]+/,"",u)
    f=1/1048576
    if(u=="Ki")f=1/1024; else if(u=="Mi")f=1; else if(u=="Gi")f=1024; else if(u=="Ti")f=1048576;
    else if(u=="K"||u=="k")f=1000/1048576; else if(u=="M")f=1e6/1048576; else if(u=="G")f=1e9/1048576
    printf "%d", n*f }'
}

# Flagi do wniosku
F_OOM=0; F_WX_STRONG=0; F_WX_SUSPECT=0; F_CGROUP_OLD=0; F_GC=0; F_ROFS=0; F_UID=0; F_NODE=0
DOTNET_MAJOR=""

# -----------------------------------------------------------------------------
hdr "1. Status kontenera '$CTR'"
REASON=$(jp "{.status.containerStatuses[?(@.name==\"$CTR\")].lastState.terminated.reason}")
EXITC=$(jp "{.status.containerStatuses[?(@.name==\"$CTR\")].lastState.terminated.exitCode}")
RESTARTS=$(jp "{.status.containerStatuses[?(@.name==\"$CTR\")].restartCount}")
NODE=$(jp '{.spec.nodeName}')
IMAGE=$(jp "{.status.containerStatuses[?(@.name==\"$CTR\")].imageID}")
[[ -z "$IMAGE" ]] && IMAGE=$(jp "{.spec.containers[?(@.name==\"$CTR\")].image}")
echo "Node:         $NODE"
echo "Obraz:        $IMAGE"
echo "Restarty:     ${RESTARTS:-?}"
echo "Ostatni stop: reason=${REASON:-brak} exitCode=${EXITC:-brak}"
[[ "$REASON" == "OOMKilled" ]] && F_OOM=1

hdr "Log z poprzedniego uruchomienia (fragmenty)"
PREVLOG=$(oc logs "$POD" -n "$NS" -c "$CTR" --previous 2>/dev/null || true)
echo "$PREVLOG" | grep -iE 'coreclr|hresult|0x8007|GC heap|OutOfMemory|W\^X|cgroup' | head -10 \
  || echo "(brak pasujących linii)"
echo "$PREVLOG" | grep -qiE 'GC heap init|0x8007000E|OutOfMemory' && F_GC=1

# -----------------------------------------------------------------------------
hdr "2. Inne repliki tego samego właściciela"
OWNER=$(jp '{.metadata.ownerReferences[0].name}')
if [[ -n "$OWNER" ]]; then
  oc get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].name}{" "}{.spec.nodeName}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | awk -v o="$OWNER" '$2==o {printf "%-55s node=%-30s ready=%s\n",$1,$3,$4}' | tee /tmp/.replicas.$$
  READY_CNT=$(awk '$NF ~ /ready=true/' /tmp/.replicas.$$ | wc -l)
  NOTREADY_CNT=$(awk '$NF ~ /ready=false/' /tmp/.replicas.$$ | wc -l)
  rm -f /tmp/.replicas.$$
  if (( READY_CNT > 0 && NOTREADY_CNT > 0 )); then
    F_NODE=1; echo "-> Część replik działa, część nie - problem zależny od noda."
  fi
else
  echo "(pod bez ownerReference)"
fi

# -----------------------------------------------------------------------------
hdr "3. SCC, securityContext, zasoby, zmienne DOTNET_*"
SCC=$(jp '{.metadata.annotations.openshift\.io/scc}')
RUNAS=$(jp "{.spec.containers[?(@.name==\"$CTR\")].securityContext.runAsUser}")
ROFS=$(jp "{.spec.containers[?(@.name==\"$CTR\")].securityContext.readOnlyRootFilesystem}")
TMPMNT=$(jp "{.spec.containers[?(@.name==\"$CTR\")].volumeMounts[?(@.mountPath==\"/tmp\")].name}")
MEMLIM=$(jp "{.spec.containers[?(@.name==\"$CTR\")].resources.limits.memory}")
MEMLIM_MI=$(to_mi "$MEMLIM")
ENVS=$(jp "{range .spec.containers[?(@.name==\"$CTR\")].env[*]}{.name}={.value}{\"\\n\"}{end}" | grep -E '^(DOTNET|COREHOST|ASPNETCORE)_' || true)
NODE_CPU=$(oc get node "$NODE" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)

echo "SCC:                    ${SCC:-?}"
echo "runAsUser:              ${RUNAS:-(nadany przez SCC)}"
echo "readOnlyRootFilesystem: ${ROFS:-false}   /tmp zamontowany: ${TMPMNT:-nie}"
echo "limit memory:           ${MEMLIM:-brak} (${MEMLIM_MI} MiB)"
echo "CPU na nodzie:          ${NODE_CPU:-?}"
echo "Zmienne DOTNET_* w spec:"; echo "${ENVS:-  (brak)}" | sed 's/^/  /'
echo "(uwaga: zmienne z envFrom/ConfigMap nie są tu pokazane)"

[[ "$ROFS" == "true" && -z "$TMPMNT" ]] && F_ROFS=1
GCSERVER=$(echo "$ENVS" | awk -F= '$1=="DOTNET_gcServer"{print $2}')
if [[ "$GCSERVER" != "0" ]]; then
  (( MEMLIM_MI > 0 && MEMLIM_MI < 256 )) && F_GC=1
  [[ -n "$NODE_CPU" ]] && (( NODE_CPU >= 32 )) && (( MEMLIM_MI > 0 && MEMLIM_MI < 1024 )) && F_GC=1
fi

# -----------------------------------------------------------------------------
hdr "4/5. Node $NODE: obraz (.NET), cgroup, audit (SELinux/seccomp)"
echo "(oc debug node - może potrwać kilkanaście sekund)"
NODEOUT=$(oc debug node/"$NODE" -q -- chroot /host bash -c "
  echo '##CGROUP'; stat -fc %T /sys/fs/cgroup
  echo '##IMAGE';  crictl inspecti '$IMAGE' 2>/dev/null \
      | grep -oE '\"(DOTNET|ASPNET|ASPNETCORE)_[A-Z_]*VERSION=[^\"]*\"|\"User\": *\"[^\"]*\"' | sort -u
  echo '##AUDIT';  grep -E 'type=(AVC|SECCOMP)' /var/log/audit/audit.log 2>/dev/null \
      | grep -E 'execmem|execmod|syscall=319|dotnet' | tail -8
" 2>/dev/null)

sect() { echo "$NODEOUT" | awk -v s="##$1" '$0==s{f=1;next} /^##/{f=0} f'; }
CGROUP=$(sect CGROUP); IMGINFO=$(sect IMAGE); AUDIT=$(sect AUDIT)

echo "cgroup na nodzie: ${CGROUP:-?}  (cgroup2fs = v2)"
echo "Obraz:"; echo "${IMGINFO:-  (nie udało się odczytać - brak obrazu na nodzie?)}" | sed 's/^/  /'
echo "Audit (AVC/SECCOMP związane z exec/memfd/dotnet):"
echo "${AUDIT:-  (brak wpisów)}" | sed 's/^/  /'

DOTNET_VER=$(echo "$IMGINFO" | grep -oE '(DOTNET|ASPNET|ASPNETCORE)_VERSION=[0-9]+' | head -1 | cut -d= -f2)
DOTNET_MAJOR="${DOTNET_VER:-}"
IMG_USER=$(echo "$IMGINFO" | grep -oE '"User": *"[^"]*"' | sed -E 's/.*"User": *"([^"]*)"/\1/')

[[ -n "$AUDIT" ]] && echo "$AUDIT" | grep -qE 'execmem|execmod|syscall=319' && F_WX_STRONG=1
WX_ENV=$(echo "$ENVS" | awk -F= '$1=="DOTNET_EnableWriteXorExecute"{print $2}')
[[ -n "$DOTNET_MAJOR" ]] && (( DOTNET_MAJOR >= 7 )) && [[ "$WX_ENV" != "0" ]] && F_WX_SUSPECT=1
[[ -n "$DOTNET_MAJOR" ]] && (( DOTNET_MAJOR <= 3 )) && [[ "$CGROUP" == "cgroup2fs" ]] && F_CGROUP_OLD=1
if [[ "$SCC" == restricted* && -n "$IMG_USER" && ! "$IMG_USER" =~ ^[0-9]+$ ]]; then F_UID=1; fi
[[ "$SCC" == restricted* && ( "$IMG_USER" == "0" || "$IMG_USER" == "root" ) ]] && F_UID=1

# -----------------------------------------------------------------------------
hdr "WNIOSEK"
echo ".NET major: ${DOTNET_MAJOR:-nieznana} | SCC: ${SCC:-?} | limit: ${MEMLIM:-brak} | node CPU: ${NODE_CPU:-?}"
echo
N=0
say() { N=$((N+1)); echo "$N) $*"; }

(( F_WX_STRONG ))  && say "[PEWNE] W^X zablokowane przez SELinux/seccomp (wpis w audit logu).
   Fix: env DOTNET_EnableWriteXorExecute=0 w deploymencie (zmiana po stronie zespołu aplikacji)."
(( F_CGROUP_OLD )) && say "[PEWNE] .NET ${DOTNET_MAJOR}.x nie obsługuje cgroup v2 - runtime źle widzi limity.
   Fix: przebudowa obrazu na wspierany .NET (8/9/10)."
(( F_OOM ))        && say "[PEWNE] Kontener jest OOMKilled.
   Fix: podnieść limit memory lub ograniczyć heap (DOTNET_GCHeapHardLimit)."
(( F_GC ))         && say "[PRAWDOPODOBNE] Inicjalizacja GC nie mieści się w limicie (Server GC / mały limit / dużo CPU).
   Test: DOTNET_gcServer=0, ewentualnie DOTNET_GCHeapHardLimit=0x10000000."
(( F_WX_SUSPECT && ! F_WX_STRONG )) && say "[PODEJRZANE] .NET ${DOTNET_MAJOR} z domyślnie włączonym W^X, brak denial w audit logu.
   Test: DOTNET_EnableWriteXorExecute=0 na kopii deploymentu."
(( F_ROFS ))       && say "[PRAWDOPODOBNE] readOnlyRootFilesystem bez zapisywalnego /tmp.
   Fix: emptyDir na /tmp albo DOTNET_EnableDiagnostics=0."
(( F_UID ))        && say "[MOŻLIWE] Obraz zakłada użytkownika '${IMG_USER}', a SCC restricted nadaje losowe UID.
   Fix w obrazie: chgrp -R 0 /app && chmod -R g=u /app, HOME=/tmp. anyuid tylko jako test."
(( F_NODE ))       && say "[KONTEKST] Problem zależny od noda - porównaj CPU/MCP/RHCOS nodów z działającymi replikami."

if (( N == 0 )); then
  echo "Brak jednoznacznej przyczyny w automatycznych testach."
  echo "Następny krok: kopia deploymentu z COREHOST_TRACE=1 i COREHOST_TRACEVERBOSITY=4,"
  echo "potem testy po jednej zmiennej: EnableWriteXorExecute=0 -> gcServer=0 -> EnableDiagnostics=0."
fi
echo
echo "Wszystkie zmiany env/obrazu wprowadza zespół aplikacji w swoim repo GitOps."
