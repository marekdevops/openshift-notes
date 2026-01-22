#!/bin/bash

# Kolory dla lepszej czytelności
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}--- Analiza blokad PDB przed aktualizacją OpenShifta ---${NC}\n"

# Nagłówek tabeli
printf "%-30s %-30s %-20s %-20s\n" "NAMESPACE" "NAME" "MIN AVAILABLE" "ALLOWED DISRUPTIONS"
echo "----------------------------------------------------------------------------------------------------------"

# Pobranie danych z klastra
BLOCKERS_FOUND=0

while read -r ns name min allowed; do
    if [[ "$allowed" == "0" ]]; then
        # Wyświetlanie na czerwono aplikacji, które zablokują drain
        printf "${RED}%-30s %-30s %-20s %-20s${NC}\n" "$ns" "$name" "$min" "$allowed"
        BLOCKERS_FOUND=$((BLOCKERS_FOUND + 1))
    else
        # Wyświetlanie na zielono aplikacji bezpiecznych
        printf "%-30s %-30s %-20s %-20s\n" "$ns" "$name" "$min" "$allowed"
    fi
done < <(oc get pdb -A --no-headers | awk '{print $1, $2, $3, $5}')

echo -e "\n----------------------------------------------------------------------------------------------------------"

if [ $BLOCKERS_FOUND -gt 0 ]; then
    echo -e "${RED}ZNALEZIONO BLOKADY: $BLOCKERS_FOUND aplikacje uniemożliwią automatyczny drain węzłów.${NC}"
    echo -e "${YELLOW}REKOMENDACJA:${NC} Poproś właścicieli powyższych aplikacji o zwiększenie liczby replik"
    echo -e "lub tymczasową edycję PDB (np. zmiana minAvailable z 1 na 0) na czas okna serwisowego."
else
    echo -e "${GREEN}SUKCES: Nie znaleziono blokujących PDB. Klaster powinien zaktualizować się płynnie.${NC}"
fi