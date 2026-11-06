#!/usr/bin/env bash
# =============================================================================
# node-compare.sh
# Porównuje dwa nody pod kątem tego, co wpływa na start runtime .NET,
# i uruchamia aplikację testowo na każdym z nich (oc debug --node-name).
#
# Użycie:
#   ./node-compare.sh <node-dobry> <node-zly> <namespace> <deployment> [app.dll]
#   app.dll domyślnie: /opt/app-root/app/api.dll
# Wymaga: oc (cluster-admin). Niczego nie zmienia.
# =============================================================================
set -uo pipefail
GOOD="${1:-}"; BAD="${2:-}"; NS="${3:-}"; D="${4:-}"
APP="${5:-/opt/app-root/app/api.dll}"
[[ -z "$GOOD" || -z "$BAD" || -z "$NS" || -z "$D" ]] && {
  echo "Użycie: $0 <node-dobry> <node-zly> <namespace> <deployment> [app.dll]"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

read -r -d '' NODESCRIPT <<'EOS'
kv() { printf '%-28s %s\n' "$1" "$2"; }
. /etc/os-release; kv os "$VERSION"
kv kernel "$(uname -r)"
kv cmdline "$(cat /proc/cmdline | tr ' ' '\n' | grep -vE '^(BOOT_IMAGE|root|ostree)=' | sort | tr '\n' ' ')"
lscpu | grep -E '^(Model name|CPU\(s\)|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|NUMA node\(s\)|L1d|L2|L3|Hypervisor vendor|Virtualization type)' \
  | sed -E 's/: +/|/' | while IFS='|' read -r k v; do kv "lscpu.$k" "$v"; done
for f in /sys/devices/system/cpu/cpu0/cache/index*/; do
  [ -d "$f" ] && kv "cache.$(cat $f/level)$(cat $f/type | cut -c1)" "$(cat $f/size 2>/dev/null)"
done
[ -d /sys/devices/system/cpu/cpu0/cache ] || kv cache "BRAK /sys/.../cache"
grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2 | tr ' ' '\n' | grep -v '^$' | sort | sed 's/^/cpuflag /'
kv mem_total "$(grep MemTotal /proc/meminfo | awk '{print $2" kB"}')"
kv hugepages "$(grep -E 'HugePages_Total|Hugepagesize' /proc/meminfo | awk '{print $2}' | tr '\n' ' ')"
kv thp.enabled "$(cat /sys/kernel/mm/transparent_hugepage/enabled)"
kv thp.defrag "$(cat /sys/kernel/mm/transparent_hugepage/defrag)"
for s in vm.overcommit_memory vm.max_map_count vm.mmap_min_addr kernel.pid_max kernel.randomize_va_space user.max_user_namespaces; do
  kv "sysctl.$s" "$(sysctl -n $s 2>/dev/null)"
done
getsebool -a 2>/dev/null | grep -E 'execmem|execheap|execstack|container_' | while read -r b _ v; do kv "sebool.$b" "$v"; done
kv selinux "$(getenforce 2>/dev/null)"
kv crio.seccomp "$(grep -rhE '^\s*seccomp' /etc/crio/crio.conf /etc/crio/crio.conf.d/ 2>/dev/null | tr -s ' ' | tr '\n' ';')"
for k in cpuManagerPolicy topologyManagerPolicy memoryManagerPolicy reservedSystemCPUs; do
  kv "kubelet.$k" "$(grep -oE "\"?$k\"?: *\"?[^\",]*" /etc/kubernetes/kubelet.conf 2>/dev/null | head -1 | sed -E 's/.*: *"?//')"
done
EOS

collect() {
  local n=$1 out=$2
  {
    printf '%-28s %s\n' capacity.cpu "$(oc get node "$n" -o jsonpath='{.status.capacity.cpu}')"
    printf '%-28s %s\n' capacity.memory "$(oc get node "$n" -o jsonpath='{.status.capacity.memory}')"
    printf '%-28s %s\n' mcp "$(oc get node "$n" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}' | sed -E 's/-[0-9a-f]{32}$//')"
    printf '%-28s %s\n' roles "$(oc get node "$n" -o json | grep -oE 'node-role.kubernetes.io/[a-z0-9-]+' | sort -u | sed 's#.*/##' | tr '\n' ',')"
    oc debug node/"$n" -- chroot /host bash -c "$NODESCRIPT" 2>/dev/null
  } > "$out"
}

apptest() {
  local n=$1 r
  r=$(oc debug deploy/"$D" -n "$NS" --node-name="$n" -- sh -c \
      "cd \"\$(dirname '$APP')\"; timeout 20 dotnet '$APP' 2>&1 | head -5" 2>/dev/null)
  if grep -q 'Failed to create CoreCLR' <<<"$r"; then echo FAIL; else echo PASS; fi
}

echo "Zbieram dane z $GOOD i $BAD (oc debug node, ok. 1 min)..."
collect "$GOOD" "$WORK/good" & collect "$BAD" "$WORK/bad" & wait

echo "Test aplikacji na obu nodach..."
RG=$(apptest "$GOOD"); RB=$(apptest "$BAD")
echo; echo "=== TEST APLIKACJI ==="
echo "$GOOD: $RG"; echo "$BAD: $RB"

# Różnice (bez flag CPU - te osobno)
echo; echo "=== RÓŻNICE KONFIGURACJI (< $GOOD | > $BAD) ==="
diff <(grep -v '^cpuflag ' "$WORK/good") <(grep -v '^cpuflag ' "$WORK/bad") | grep -E '^[<>]' || echo "(brak)"

MISSING=$(comm -23 <(grep '^cpuflag ' "$WORK/good" | cut -d' ' -f2) <(grep '^cpuflag ' "$WORK/bad" | cut -d' ' -f2) | tr '\n' ' ')
EXTRA=$(comm -13 <(grep '^cpuflag ' "$WORK/good" | cut -d' ' -f2) <(grep '^cpuflag ' "$WORK/bad" | cut -d' ' -f2) | tr '\n' ' ')
echo; echo "=== FLAGI CPU ==="
echo "Brakuje na $BAD: ${MISSING:-(nic)}"
echo "Tylko na $BAD:   ${EXTRA:-(nic)}"

# Wniosek
g() { grep -m1 "^$1 " "$2" | sed -E "s/^$1 +//"; }
echo; echo "=== WNIOSEK ==="
if [[ "$RG" == "PASS" && "$RB" == "FAIL" ]]; then
  echo "Potwierdzone: aplikacja startuje na $GOOD, pada na $BAD - przyczyna zależy od noda."
  HINT=0
  [[ -n "$MISSING" ]] && { HINT=1
    echo "- $BAD nie udostępnia części instrukcji CPU ($MISSING)."
    echo "  Jeśli to VM: zmień model CPU maszyny (np. host-passthrough / host-model) albo dodaj brakujące flagi."; }
  [[ "$(g lscpu.Hypervisor\ vendor "$WORK/good")" != "$(g lscpu.Hypervisor\ vendor "$WORK/bad")" ]] && { HINT=1
    echo "- Nody różnią się typem (VM vs bare metal) - sprawdź model CPU i topologię VM."; }
  grep -q 'BRAK /sys' "$WORK/bad" && ! grep -q 'BRAK /sys' "$WORK/good" && { HINT=1
    echo "- $BAD nie raportuje cache CPU - GC .NET może źle wyliczyć rozmiary. Test: DOTNET_GCgen0size=0x4000000."; }
  [[ "$(g mcp "$WORK/good")" != "$(g mcp "$WORK/bad")" ]] && { HINT=1
    echo "- Różne MachineConfigPool - sprawdź różnice w MachineConfig/KubeletConfig między poolami."; }
  diff <(grep -E '^(sebool|crio|kernel|cmdline|os|thp|kubelet)' "$WORK/good") \
       <(grep -E '^(sebool|crio|kernel|cmdline|os|thp|kubelet)' "$WORK/bad") >/dev/null || { HINT=1
    echo "- Różnice w kernel/cmdline/SELinux/CRI-O/kubelet - patrz sekcja RÓŻNICE powyżej."; }
  (( HINT == 0 )) && echo "- Brak oczywistej różnicy - uruchom dotnet-coreclr-strace.sh na złym nodzie."
  echo
  echo "Obejście doraźne: przypnij aplikację do działających nodów (nodeSelector/affinity w deploymencie"
  echo "albo adnotacja namespace 'openshift.io/node-selector'). Docelowo: wyrównać konfigurację $BAD."
elif [[ "$RG" == "FAIL" && "$RB" == "FAIL" ]]; then
  echo "Aplikacja pada na OBU nodach - przy ręcznym teście nie potwierdza się zależność od noda."
  echo "Sprawdź, czy działający pod na $GOOD nie ma innej konfiguracji (inny ReplicaSet/obraz)."
elif [[ "$RB" == "PASS" ]]; then
  echo "Aplikacja startuje na obu nodach przy ręcznym teście - problem nie odtwarza się teraz na $BAD."
fi
echo
