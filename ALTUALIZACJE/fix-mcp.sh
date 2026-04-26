#!/usr/bin/env bash
# mco-fix-option1.sh — Force MCO re-apply przez reset currentConfig annotation
# Użycie: ./mco-fix-option1.sh <node-name>

set -euo pipefail

# ─── Kolory ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Walidacja parametru ──────────────────────────────────────────────────────
[[ $# -lt 1 ]] && error "Brak nazwy noda. Użycie: $0 <node-name>"
NODE="$1"

# ─── Walidacja środowiska ─────────────────────────────────────────────────────
command -v oc &>/dev/null || error "Brak komendy 'oc' w PATH"
oc whoami &>/dev/null     || error "Brak aktywnej sesji OCP — zaloguj się przez 'oc login'"

# ─── Sprawdzenie czy nod istnieje ─────────────────────────────────────────────
info "Sprawdzam czy nod '$NODE' istnieje w klastrze..."
oc get node "$NODE" &>/dev/null || error "Nod '$NODE' nie istnieje w klastrze"
ok "Nod '$NODE' znaleziony"

# ─── Odczyt aktualnych annotacji ──────────────────────────────────────────────
info "Odczytuję annotacje MCO z noda '$NODE'..."

CURRENT=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}' 2>/dev/null || true)

DESIRED=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}' 2>/dev/null || true)

STATE=$(oc get node "$NODE" -o jsonpath=\
'{.metadata.annotations.machineconfiguration\.openshift\.io/state}' 2>/dev/null || true)

echo ""
echo -e "  currentConfig : ${YELLOW}${CURRENT:-<brak>}${NC}"
echo -e "  desiredConfig : ${YELLOW}${DESIRED:-<brak>}${NC}"
echo -e "  state         : ${YELLOW}${STATE:-<brak>}${NC}"
echo ""

[[ -z "$DESIRED" ]] && error "Brak annotacji desiredConfig na nodzie — sprawdź stan MCO"

# ─── Krok 1: Usuń currentConfig żeby wymusić re-sync ─────────────────────────
info "Krok 1/3 — Usuwam annotację currentConfig z noda '$NODE'..."
oc annotate node "$NODE" \
  machineconfiguration.openshift.io/currentConfig- \
  --overwrite
ok "Annotacja currentConfig usunięta"

# ─── Krok 2: Re-set desiredConfig (wymusza MCO re-trigger) ───────────────────
info "Krok 2/3 — Wymuszam re-set desiredConfig na '$DESIRED'..."
oc annotate node "$NODE" \
  machineconfiguration.openshift.io/desiredConfig="${DESIRED}" \
  --overwrite
ok "desiredConfig ustawiony na: ${DESIRED}"

# ─── Krok 3: Obserwacja logów MCD ────────────────────────────────────────────
info "Krok 3/3 — Szukam poda machine-config-daemon na nodzie '$NODE'..."

MCD_POD=$(oc get pod -n openshift-machine-config-operator \
  -l k8s-app=machine-config-daemon \
  --field-selector "spec.nodeName=${NODE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

echo ""
if [[ -n "$MCD_POD" ]]; then
  ok "Pod MCD: ${MCD_POD}"
  echo ""
  warn "Tail logów machine-config-daemon (Ctrl+C żeby przerwać):"
  echo "────────────────────────────────────────────────────────"
  oc logs -n openshift-machine-config-operator "${MCD_POD}" \
    --tail=50 -f
else
  warn "Nie znaleziono poda MCD na nodzie '$NODE' — sprawdź ręcznie:"
  echo ""
  echo "  oc get pod -n openshift-machine-config-operator \\"
  echo "    -l k8s-app=machine-config-daemon \\"
  echo "    --field-selector spec.nodeName=${NODE}"
  echo ""
  info "Możesz obserwować stan noda przez:"
  echo "  oc get node ${NODE} -w"
  echo "  oc get mcp -w"
fi