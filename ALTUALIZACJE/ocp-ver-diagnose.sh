#!/usr/bin/env bash
# mco-diagnose.sh — Diagnostyka content mismatch MCO
# Użycie: ./mco-diagnose.sh <node-name>
# Wynik zapisuje do pliku mco-diagnose-<node>.txt w bieżącym katalogu

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $# -lt 1 ]] && error "Użycie: $0 <node-name>"
NODE="$1"
REPORT="mco-diagnose-${NODE}-$(date +%Y%m%d-%H%M%S).txt"

command -v oc &>/dev/null || error "Brak 'oc' w PATH"
oc whoami &>/dev/null     || error "Brak aktywnej sesji OCP"
oc get node "$NODE" &>/dev/null || error "Nod '$NODE' nie istnieje"

info "Zbieram dane diagnostyczne dla noda: $NODE"
info "Raport zostanie zapisany do: $REPORT"

{
echo "================================================================"
echo " MCO DIAGNOSE REPORT"
echo " Node    : $NODE"
echo " Date    : $(date)"
echo " Cluster : $(oc whoami --show-server)"
echo "================================================================"
echo ""

# ─── Annotacje noda ───────────────────────────────────────────────────────────
echo "### ANNOTACJE MCO NA NODZIE ###"
echo ""
CURRENT=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}' 2>/dev/null || echo "<brak>")
DESIRED=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}' 2>/dev/null || echo "<brak>")
STATE=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/state}' 2>/dev/null || echo "<brak>")
REASON=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/reason}' 2>/dev/null || echo "<brak>")

echo "  currentConfig : $CURRENT"
echo "  desiredConfig : $DESIRED"
echo "  state         : $STATE"
echo "  reason        : $REASON"
echo ""

# ─── Stan nodów i MCP ────────────────────────────────────────────────────────
echo "### STAN NODÓW ###"
echo ""
oc get nodes -o wide 2>/dev/null || echo "<błąd>"
echo ""

echo "### STAN MCP ###"
echo ""
oc get mcp 2>/dev/null || echo "<błąd>"
echo ""

echo "### CLUSTER OPERATORS ###"
echo ""
oc get co 2>/dev/null || echo "<błąd>"
echo ""

# ─── Logi MCD z noda ─────────────────────────────────────────────────────────
echo "### LOGI MACHINE-CONFIG-DAEMON (mismatch/error) ###"
echo ""
MCD_POD=$(oc get pod -n openshift-machine-config-operator \
  -l k8s-app=machine-config-daemon \
  --field-selector "spec.nodeName=${NODE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$MCD_POD" ]]; then
  echo "Pod MCD: $MCD_POD"
  echo ""
  echo "--- Ostatnie 100 linii logów ---"
  oc logs -n openshift-machine-config-operator "$MCD_POD" \
    --tail=100 2>/dev/null || echo "<błąd pobierania logów>"
  echo ""
  echo "--- Linie zawierające: mismatch|error|fail|unexpected|content ---"
  oc logs -n openshift-machine-config-operator "$MCD_POD" \
    2>/dev/null \
    | grep -iE "mismatch|error|fail|unexpected|content|differ|hash|sha" \
    | tail -50 \
    || echo "<brak pasujących linii>"
else
  echo "UWAGA: Nie znaleziono poda MCD dla noda $NODE"
fi
echo ""

# ─── Rendered MC — lista plików ze ścieżkami ─────────────────────────────────
echo "### PLIKI W RENDERED MC: $DESIRED ###"
echo ""
if [[ "$DESIRED" != "<brak>" ]]; then
  oc get mc "$DESIRED" -o jsonpath=\
'{range .spec.config.storage.files[*]}{.path}{"\t"}{.mode}{"\n"}{end}' \
    2>/dev/null || echo "<błąd pobierania MC>"
else
  echo "Brak desiredConfig — nie można pobrać MC"
fi
echo ""

# ─── Szczegóły kubelet.service z rendered MC ─────────────────────────────────
echo "### KUBELET.SERVICE W RENDERED MC (zdekodowany) ###"
echo ""
if [[ "$DESIRED" != "<brak>" ]]; then
  RAW=$(oc get mc "$DESIRED" -o jsonpath=\
'{.spec.config.storage.files[?(@.path=="/etc/systemd/system/kubelet.service")].contents.source}' \
    2>/dev/null || echo "")
  if [[ -n "$RAW" ]]; then
    echo "$RAW" | python3 -c "
import sys, urllib.parse, base64
raw = sys.stdin.read().strip()
if not raw:
    print('<brak pliku kubelet.service w rendered MC>')
elif raw.startswith('data:'):
    header, encoded = raw.split(',', 1)
    if 'base64' in header:
        print(base64.b64decode(encoded).decode())
    else:
        print(urllib.parse.unquote(encoded))
else:
    print(raw)
" 2>/dev/null || echo "<błąd dekodowania>"
  else
    echo "<kubelet.service nie znaleziony w rendered MC>"
  fi
fi
echo ""

# ─── Stan na nodzie przez debug ───────────────────────────────────────────────
echo "### PLIK KUBELET.SERVICE NA NODZIE (przez oc debug) ###"
echo ""
warn "Próba odczytu przez oc debug node — może chwilę potrwać..."
timeout 60 oc debug node/"$NODE" -- \
  chroot /host sh -c \
  'echo "=stat="; stat /etc/systemd/system/kubelet.service; echo "=sha256="; sha256sum /etc/systemd/system/kubelet.service; echo "=content="; cat /etc/systemd/system/kubelet.service; echo "=mcd-currentconfig="; cat /etc/machine-config-daemon/currentconfig 2>/dev/null || echo "<brak pliku currentconfig>"; echo "=mcd-journal="; journalctl -u machine-config-daemon --no-pager -n 50 2>/dev/null || echo "<brak journald>"' \
  2>/dev/null || echo "<timeout lub błąd oc debug>"
echo ""

echo "================================================================"
echo " KONIEC RAPORTU"
echo "================================================================"
} 2>&1 | tee "$REPORT"

echo ""
ok "Raport zapisany do: $REPORT"
info "Możesz go przesłać lub przejrzeć: cat $REPORT"