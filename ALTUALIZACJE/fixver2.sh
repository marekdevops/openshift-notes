#!/usr/bin/env bash
# mco-force-reapply.sh — Wymuszenie pełnego re-apply rendered MC przez MCD
# Opcja 4: usuwa /etc/machine-config-daemon/currentconfig na nodzie
# Nod zostanie automatycznie zrestartowany przez MCD
#
# Użycie: ./mco-force-reapply.sh <node-name>

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}━━━ $* ${NC}"; }

# ─── Walidacja ────────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && error "Użycie: $0 <node-name>"
NODE="$1"

command -v oc &>/dev/null || error "Brak 'oc' w PATH"
oc whoami &>/dev/null     || error "Brak aktywnej sesji OCP"
oc get node "$NODE" &>/dev/null || error "Nod '$NODE' nie istnieje"

# ─── Ostrzeżenie ──────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  UWAGA: Ten skrypt spowoduje RESTART noda $NODE  ${NC}"
echo -e "${RED}${BOLD}║  MCD wykona pełny re-apply rendered MC od zera.          ║${NC}"
echo -e "${RED}${BOLD}║  Nod będzie niedostępny przez kilka minut.               ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "Czy chcesz kontynuować? (wpisz 'tak' aby potwierdzić): " CONFIRM
[[ "$CONFIRM" != "tak" ]] && { info "Anulowano."; exit 0; }

# ─── Odczyt stanu przed operacją ─────────────────────────────────────────────
step "Krok 1/5 — Odczyt stanu noda"

CURRENT=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}' 2>/dev/null || echo "<brak>")
DESIRED=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}' 2>/dev/null || echo "<brak>")
STATE=$(oc get node "$NODE"   -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/state}' 2>/dev/null || echo "<brak>")

echo ""
echo -e "  currentConfig : ${YELLOW}${CURRENT}${NC}"
echo -e "  desiredConfig : ${YELLOW}${DESIRED}${NC}"
echo -e "  state         : ${YELLOW}${STATE}${NC}"
echo ""

[[ "$DESIRED" == "<brak>" ]] && error "Brak desiredConfig — sprawdź stan MCO przed kontynuacją"

# ─── Cordon noda ─────────────────────────────────────────────────────────────
step "Krok 2/5 — Cordon noda (zapobiegamy schedulowaniu w trakcie)"

oc adm cordon "$NODE"
ok "Nod $NODE jest cordoned"

# ─── Wyrównanie annotacji przed re-apply ─────────────────────────────────────
step "Krok 3/5 — Wyrównanie annotacji MCO"

info "Ustawiam currentConfig = desiredConfig = ${DESIRED}"

oc annotate node "$NODE" \
  machineconfiguration.openshift.io/currentConfig="${DESIRED}" \
  --overwrite
oc annotate node "$NODE" \
  machineconfiguration.openshift.io/desiredConfig="${DESIRED}" \
  --overwrite

ok "Annotacje wyrównane"

# ─── Wymuszenie re-apply przez usunięcie currentconfig na nodzie ──────────────
step "Krok 4/5 — Wymuszenie pełnego re-apply przez MCD na nodzie"

info "Uruchamiam oc debug na nodzie $NODE..."
info "Usuwam /etc/machine-config-daemon/currentconfig i restartuję MCD..."

timeout 120 oc debug node/"$NODE" -- chroot /host sh -c '
  echo "[node] Backup currentconfig..."
  cp /etc/machine-config-daemon/currentconfig \
     /etc/machine-config-daemon/currentconfig.bak-$(date +%s) \
     2>/dev/null && echo "[node] Backup OK" || echo "[node] Brak currentconfig — pomijam backup"

  echo "[node] Usuwam currentconfig..."
  rm -f /etc/machine-config-daemon/currentconfig
  echo "[node] currentconfig usunięty"

  echo "[node] Restartuję machine-config-daemon..."
  systemctl restart machine-config-daemon
  echo "[node] MCD zrestartowany"

  sleep 3
  echo "[node] Status MCD:"
  systemctl is-active machine-config-daemon || true
' 2>/dev/null
echo ""
ok "Operacja na nodzie zakończona"

# ─── Obserwacja restartu i powrotu do Ready ───────────────────────────────────
step "Krok 5/5 — Obserwacja stanu noda"

echo ""
warn "Nod może się teraz restartować — to normalne zachowanie MCD po re-apply."
warn "Czekam na powrót noda do stanu Ready (timeout 15 min)..."
echo ""

TIMEOUT=900
INTERVAL=15
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  NODE_STATUS=$(oc get node "$NODE" \
    --no-headers 2>/dev/null \
    | awk '{print $2}' || echo "unknown")

  MCP_DEGRADED=$(oc get mcp --no-headers 2>/dev/null \
    | awk '{print $5}' \
    | grep -c "True" || echo "0")

  echo -e "  [${ELAPSED}s] Node status: ${YELLOW}${NODE_STATUS}${NC}  |  MCP degraded: ${YELLOW}${MCP_DEGRADED}${NC}"

  # Nod gotowy i nie degraded
  if [[ "$NODE_STATUS" == "Ready,SchedulingDisabled" ]] || \
     [[ "$NODE_STATUS" == "Ready" ]]; then
    echo ""
    ok "Nod $NODE wrócił do stanu Ready!"

    # Uncordon jeśli nod jest Ready
    if [[ "$NODE_STATUS" == "Ready,SchedulingDisabled" ]]; then
      info "Uncordon noda..."
      oc adm uncordon "$NODE"
      ok "Nod $NODE jest uncordoned — aktualizacja MCP powinna ruszyć dalej"
    fi
    break
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  warn "Timeout — nod nie wrócił do Ready w ciągu 15 minut."
  warn "Sprawdź ręcznie:"
  echo ""
  echo "  oc get node $NODE"
  echo "  oc get mcp"
  echo ""
  echo "  # Logi MCD:"
  MCD_POD=$(oc get pod -n openshift-machine-config-operator \
    -l k8s-app=machine-config-daemon \
    --field-selector "spec.nodeName=${NODE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [[ -n "$MCD_POD" ]] && \
    echo "  oc logs -n openshift-machine-config-operator ${MCD_POD} --tail=50 -f"
fi

echo ""
echo "─────────────────────────────────────────────────────────"
info "Stan końcowy:"
oc get node "$NODE"
echo ""
oc get mcp
echo "─────────────────────────────────────────────────────────"