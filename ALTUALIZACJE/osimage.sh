#!/usr/bin/env bash
# mco-force-osimage.sh — Wymuszenie pobrania osImageURL z rendered MC przez rpm-ostree
# Nie zmienia wersji — używa dokładnie tego samego obrazu co desiredConfig noda
#
# Użycie: ./mco-force-osimage.sh <node-name>

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

# ─── Odczyt desiredConfig i osImageURL z rendered MC ─────────────────────────
step "Krok 1/4 — Odczyt docelowego osImageURL z rendered MC"

DESIRED=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}' \
2>/dev/null || echo "")

[[ -z "$DESIRED" ]] && error "Brak annotacji desiredConfig na nodzie $NODE"
info "desiredConfig: $DESIRED"

OS_IMAGE=$(oc get mc "$DESIRED" \
  -o jsonpath='{.spec.osImageURL}' 2>/dev/null || echo "")

[[ -z "$OS_IMAGE" ]] && error "Brak osImageURL w rendered MC: $DESIRED"
ok "osImageURL: $OS_IMAGE"

# ─── Weryfikacja aktualnego obrazu na nodzie ──────────────────────────────────
step "Krok 2/4 — Weryfikacja aktualnego stanu rpm-ostree na nodzie"

info "Sprawdzam aktualny obraz na nodzie przez oc debug..."
echo ""

timeout 60 oc debug node/"$NODE" -- chroot /host bash -c '
echo "=== rpm-ostree status ==="
rpm-ostree status
echo ""
echo "=== DNS test ==="
nslookup quay.io 2>/dev/null | grep -E "Server|Address|Name" || echo "<brak nslookup>"
echo ""
echo "=== Connectivity quay.io ==="
curl -sk --max-time 10 https://quay.io/v2/ \
  -o /dev/null -w "HTTP status: %{http_code}\n" || echo "<curl failed>"
' 2>/dev/null || warn "oc debug timeout lub błąd — kontynuuję mimo to"

echo ""

# ─── Potwierdzenie przed operacją ────────────────────────────────────────────
echo -e "${BOLD}Docelowy obraz do pobrania:${NC}"
echo -e "  ${YELLOW}${OS_IMAGE}${NC}"
echo ""
warn "Operacja wykona rpm-ostree rebase na dokładnie ten sam obraz co desiredConfig."
warn "Nod zostanie zrestartowany po pobraniu obrazu."
echo ""
read -rp "Czy chcesz kontynuować? (wpisz 'tak' aby potwierdzić): " CONFIRM
[[ "$CONFIRM" != "tak" ]] && { info "Anulowano."; exit 0; }

# ─── Wymuszenie rpm-ostree rebase przez oc debug ─────────────────────────────
step "Krok 3/4 — Wymuszenie rpm-ostree rebase na nodzie $NODE"

info "Uruchamiam oc debug — to może potrwać kilka minut (pobieranie obrazu)..."
echo ""

# Eksportuj zmienną żeby była dostępna w heredoc
export OS_IMAGE

timeout 1800 oc debug node/"$NODE" -- chroot /host bash -c "
set -uo pipefail

TARGET=\"${OS_IMAGE}\"

echo '[node] Aktualny stan rpm-ostree przed operacją:'
rpm-ostree status --booted 2>/dev/null || true
echo ''

echo '[node] Sprawdzam połączenie z registry...'
REGISTRY=\$(echo \"\$TARGET\" | cut -d'/' -f1)
curl -sk --max-time 15 \"https://\${REGISTRY}/v2/\" \
  -o /dev/null -w 'HTTP status registry: %{http_code}\n' || true
echo ''

echo '[node] Rozpoczynam rpm-ostree rebase na:'
echo \"  \$TARGET\"
echo ''

# Wymuś rebase na dokładny obraz z rendered MC
if rpm-ostree rebase --experimental \"\$TARGET\"; then
  echo ''
  echo '[node] ✓ rpm-ostree rebase zakończony sukcesem'
  echo '[node] Nod zostanie teraz zrestartowany przez MCD lub ręcznie'
  echo ''
  echo '[node] Stan po rebase:'
  rpm-ostree status
else
  echo ''
  echo '[node] ✗ rpm-ostree rebase zakończył się błędem'
  echo '[node] Sprawdź logi:'
  journalctl -u rpm-ostreed --no-pager -n 30 2>/dev/null || true
  exit 1
fi
" 2>/dev/null
REBASE_RC=$?

echo ""
if [[ $REBASE_RC -eq 0 ]]; then
  ok "rpm-ostree rebase zakończony sukcesem"
else
  error "rpm-ostree rebase zakończył się błędem (exit code: $REBASE_RC) — sprawdź logi MCD na nodzie"
fi

# ─── Obserwacja powrotu noda ──────────────────────────────────────────────────
step "Krok 4/4 — Obserwacja restartu i powrotu noda do Ready"

echo ""
warn "Nod $NODE powinien się teraz restartować..."
warn "Czekam na powrót do stanu Ready (timeout 20 min)..."
echo ""

# Poczekaj chwilę na start restartu
sleep 30

TIMEOUT=1200
INTERVAL=20
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  NODE_STATUS=$(oc get node "$NODE" \
    --no-headers 2>/dev/null \
    | awk '{print $2}' || echo "unknown")

  MCO_STATE=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/state}' \
    2>/dev/null || echo "unknown")

  MCP_DEGRADED=$(oc get mcp worker --no-headers 2>/dev/null \
    | awk '{print $5}' || echo "?")

  echo -e "  [${ELAPSED}s] Node: ${YELLOW}${NODE_STATUS}${NC}" \
          "| MCO state: ${YELLOW}${MCO_STATE}${NC}" \
          "| MCP degraded: ${YELLOW}${MCP_DEGRADED}${NC}"

  if [[ "$NODE_STATUS" == "Ready" ]] && [[ "$MCO_STATE" == "Done" ]]; then
    echo ""
    ok "Nod $NODE wrócił do Ready i MCO state = Done!"
    ok "osImageURL mismatch powinien być naprawiony"
    break
  fi

  # Nod Ready ale jeszcze SchedulingDisabled (w trakcie MCP update flow)
  if [[ "$NODE_STATUS" == "Ready,SchedulingDisabled" ]] && \
     [[ "$MCO_STATE" == "Done" ]]; then
    echo ""
    ok "Nod $NODE Ready — MCO zakończył pracę (SchedulingDisabled to normalny stan w trakcie MCP rolling update)"
    info "MCP sam zrobi uncordon gdy przyjdzie pora"
    break
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo ""
  warn "Timeout 20 min — nod nie wrócił do Ready+Done."
  warn "Sprawdź ręcznie:"
  echo ""
  echo "  oc get node $NODE"
  echo "  oc get mcp"
  echo ""
  MCD_POD=$(oc get pod -n openshift-machine-config-operator \
    -l k8s-app=machine-config-daemon \
    --field-selector "spec.nodeName=${NODE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [[ -n "$MCD_POD" ]] && \
    echo "  oc logs -n openshift-machine-config-operator ${MCD_POD} --tail=100 -f"
fi

echo ""
echo "─────────────────────────────────────────────────────────"
info "Stan końcowy:"
echo ""
oc get node "$NODE"
echo ""
oc get mcp
echo "─────────────────────────────────────────────────────────"