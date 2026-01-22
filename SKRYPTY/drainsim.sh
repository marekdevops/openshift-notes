#!/bin/bash

# Użycie: ./simulate-drain.sh <nazwa_noda>
NODE_NAME=$1

if [ -z "$NODE_NAME" ]; then
    echo "Sposób użycia: $0 <nazwa_noda>"
    echo "Przykład: $0 worker-0.cluster.example.com"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}>>> Symulacja procedury DRAIN dla węzła: $NODE_NAME${NC}"
echo "----------------------------------------------------------------------"

# 1. Pobranie wszystkich podów z noda (z pominięciem Static Pods i Mirror Pods)
PODS=$(oc get pods -A --field-selector spec.nodeName=$NODE_NAME -o json)

# 2. Analiza każdego poda pod kątem PDB
echo -e "Sprawdzanie podów pod kątem blokad PDB...\n"

BLOCKER_COUNT=0

# Iteracja po podach (używamy jq do parsowania jsona)
echo "$PODS" | jq -c '.items[]' | while read -r pod; do
    NAMESPACE=$(echo "$pod" | jq -r '.metadata.namespace')
    NAME=$(echo "$pod" | jq -r '.metadata.name')
    OWNER_KIND=$(echo "$pod" | jq -r '.metadata.ownerReferences[0].kind // "Unknown"')

    # Pomiń pody typu DaemonSet (one nie blokują draina, bo są ignorowane)
    if [ "$OWNER_KIND" == "DaemonSet" ]; then
        continue
    fi

    # Znajdź PDB pasujące do labeli tego poda
    LABELS=$(echo "$pod" | jq -r '.metadata.labels | to_entries | map("\(.key)=\(.value)") | join(",")')
    
    # Szukamy PDB w tym samym namespace, które pasuje do labeli poda
    PDB=$(oc get pdb -n "$NAMESPACE" -o json | jq -c --arg labels "$LABELS" '.items[] | select(.spec.selector.matchLabels as $ml | ($ml | to_entries | all(in($labels | split(",") | map(split("=") | {(.[0]): .[1]}) | add))))' 2>/dev/null)

    if [ ! -z "$PDB" ]; then
        ALLOWED=$(echo "$PDB" | jq -r '.status.disruptionsAllowed')
        if [ "$ALLOWED" -eq 0 ]; then
            echo -e "${RED}[BLOKADA]${NC} Pod: $NAME (NS: $NAMESPACE) - PDB nie pozwala na usunięcie (Allowed Disruptions: 0)"
            BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
        else
            echo -e "${GREEN}[OK]${NC} Pod: $NAME (NS: $NAMESPACE) - PDB pozwala na eksmisję."
        fi
    else
        echo -e "${GREEN}[OK]${NC} Pod: $NAME (NS: $NAMESPACE) - Brak przypisanego PDB."
    fi
done

echo "----------------------------------------------------------------------"
if [ "$BLOCKER_COUNT" -gt 0 ]; then
    echo -e "${RED}WYNIK: Drain noda $NODE_NAME zakończyłby się NIEPOWODZENIEM.${NC}"
    echo -e "Znaleziono $BLOCKER_COUNT podów blokujących aktualizację."
else
    echo -e "${GREEN}WYNIK: Drain noda $NODE_NAME powinien przebiec pomyślnie.${NC}"
fi