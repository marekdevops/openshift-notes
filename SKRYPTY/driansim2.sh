#!/bin/bash

# Sprawdzenie czy podano nazwę noda
NODE_NAME=$1
if [ -z "$NODE_NAME" ]; then
    echo "Użycie: $0 <nazwa_noda>"
    echo "Przykład: $0 worker-0.cluster.example.com"
    exit 1
fi

# Kolory dla czytelności
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

echo -e "${BLUE}======================================================================"
echo -e "SYMULACJA DRAIN DLA WĘZŁA: ${YELLOW}$NODE_NAME${NC}"
echo -e "${BLUE}======================================================================"

# Pobranie danych o podach z noda w formacie JSON
PODS_JSON=$(oc get pods -A --field-selector spec.nodeName=$NODE_NAME -o json)
PDB_JSON=$(oc get pdb -A -o json)

BLOCKER_COUNT=0
WARNING_COUNT=0

# Iteracja po każdym podzie na nodzie
echo "$PODS_JSON" | jq -c '.items[]' | while read -r pod; do
    NAME=$(echo "$pod" | jq -r '.metadata.name')
    NS=$(echo "$pod" | jq -r '.metadata.namespace')
    OWNER_KIND=$(echo "$pod" | jq -r '.metadata.ownerReferences[0].kind // "None"')

    # 1. POMIJANIE DAEMONSETS (One nie blokują draina)
    if [ "$OWNER_KIND" == "DaemonSet" ]; then
        continue
    fi

    echo -e "\n${BLUE}Sprawdzanie poda:${NC} $NAME [NS: $NS]"

    # 2. SPRAWDZANIE PDB (Pod Disruption Budget)
    # Pobieramy labele poda, aby dopasować je do selektora PDB
    LABELS=$(echo "$pod" | jq -r '.metadata.labels | to_entries | map("\(.key)=\(.value)") | join(",")')
    
    # Szukanie pasującego PDB w tym samym namespace
    MATCHING_PDB=$(echo "$PDB_JSON" | jq -c --arg ns "$NS" --arg labels "$LABELS" '.items[] | select(.metadata.namespace == $ns) | select(.spec.selector.matchLabels as $ml | ($ml | to_entries | all(in($labels | split(",") | map(split("=") | {(.[0]): .[1]}) | add))))' 2>/dev/null)

    if [ ! -z "$MATCHING_PDB" ]; then
        ALLOWED=$(echo "$MATCHING_PDB" | jq -r '.status.disruptionsAllowed')
        PDB_NAME=$(echo "$MATCHING_PDB" | jq -r '.metadata.name')
        if [ "$ALLOWED" -eq 0 ]; then
            echo -e "  ${RED}[BLOKADA PDB]${NC} PDB '$PDB_NAME' zabrania usunięcia (Allowed Disruptions: 0)"
            BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
        else
            echo -e "  ${GREEN}[OK]${NC} PDB '$PDB_NAME' pozwala na usunięcie."
        fi
    fi

    # 3. SPRAWDZANIE LOKALNEJ PAMIĘCI (emptyDir)
    HAS_LOCAL=$(echo "$pod" | jq '.spec.volumes // [] | any(.emptyDir)')
    if [ "$HAS_LOCAL" == "true" ]; then
        echo -e "  ${YELLOW}[OSTRZEŻENIE]${NC} Pod używa emptyDir. Wymaga flagi --delete-emptydir-data."
        WARNING_COUNT=$((WARNING_COUNT + 1))
    fi

    # 4. SPRAWDZANIE KONTROLERA (Orphan Pods)
    if [ "$OWNER_KIND" == "None" ]; then
        echo -e "  ${YELLOW}[OSTRZEŻENIE]${NC} Pod nie ma kontrolera (np. ręcznie stworzony). Wymaga flagi --force."
        WARNING_COUNT=$((WARNING_COUNT + 1))
    fi

done

echo -e "\n${BLUE}======================================================================"
echo -e "PODSUMOWANIE DLA $NODE_NAME:"

if [ $BLOCKER_COUNT -gt 0 ]; then
    echo -e "${RED}STAN: KRYTYCZNY${NC}"
    echo -e "Znaleziono $BLOCKER_COUNT twardych blokad PDB. Drain ZOSTANIE PRZERWANY bez interwencji."
elif [ $WARNING_COUNT -gt 0 ]; then
    echo -e "${YELLOW}STAN: WYMAGA FLAG${NC}"
    echo -e "Brak blokad PDB, ale wymagane są flagi --force i --delete-emptydir-data."
else
    echo -e "${GREEN}STAN: GOTOWY${NC}"
    echo -e "Wszystkie pody powinny zostać poprawnie ewakuowane."
fi
echo -e "${BLUE}======================================================================"