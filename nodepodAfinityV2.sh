#!/bin/bash

# Użycie: symuluj_planowanie_v2.sh -pod <NAZWA_PODA> -n <NAMESPACE>

POD_NAME=""
NAMESPACE=""

# Parsowanie argumentów
while (( "$#" )); do
  case "$1" in
    -pod|--pod)
      if [ "$2" ]; then
        POD_NAME="$2"
        shift 2
      else
        echo "🚨 Błąd: Wymagana nazwa poda po $1." >&2
        exit 1
      fi
      ;;
    -n|--namespace)
      if [ "$2" ]; then
        NAMESPACE="$2"
        shift 2
      else
        echo "🚨 Błąd: Wymagana nazwa przestrzeni nazw po $1." >&2
        exit 1
      fi
      ;;
    *)
      echo "🚨 Nieznany argument: $1" >&2
      exit 1
      ;;
  esac
done

# Walidacja wejścia
if [ -z "$POD_NAME" ] || [ -z "$NAMESPACE" ]; then
    echo "🚨 Użycie: $0 -pod <NAZWA_PODA> -n <NAMESPACE>"
    echo "Przykład: $0 -pod my-app-deploy-xyz -n development"
    exit 1
fi

echo "--- 🔍 Analiza Podu: $POD_NAME w przestrzeni $NAMESPACE ---"

# 1. Ekstrakcja kluczowych reguł Podu za pomocą jq

# a) Node Selector
NODE_SELECTOR=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.nodeSelector | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ' ')

# b) Tolerancje (zbieramy listę Taintów, które pod może tolerować)
TOLERATIONS=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.tolerations[]? | .key + "=" + (.value // "") + ":" + .effect' | tr '\n' ' ')
# Wersja powyżej uwzględnia tainty bez wartości (value), używając // ""

echo "Node Selector (wymagane etykiety): [ $NODE_SELECTOR ]"
echo "Tolerancje (możliwe do zniesienia tainty): [ $(echo $TOLERATIONS | tr ' ' '\n') ]"
echo "--- -------------------------------------------------------------------------- ---"

# Nagłówek tabeli
printf "%-30s | %-10s | %-10s | %-10s | %s\n" "NAZWA WEZŁA" "SELEKTOR" "TAINTY" "WYNIK" "PRZYCZYNA ODRZUCENIA"
printf "%-30s | %-10s | %-10s | %-10s | %s\n" "------------------------------" "----------" "----------" "----------" "----------------------------------------------------------------"

# Pobranie listy wszystkich węzłów i iteracja
oc get nodes -o json | jq -r '.items[] | .metadata.name' | while read -r NODE_NAME; do

    FINAL_RESULT="✅ TAK"
    REASON=""
    
    # --- 2. Sprawdzenie Node Selector (Etykiety) ---
    if [ ! -z "$NODE_SELECTOR" ]; then
        for SELECTOR in $NODE_SELECTOR; do
            KEY=${SELECTOR%=*}
            VALUE=${SELECTOR#*=}
            
            # Pobierz etykietę i sprawdź, czy pasuje do wymagania
            NODE_LABEL_VALUE=$(oc get node "$NODE_NAME" -o json | jq -r ".metadata.labels[\"$KEY\"] // \"\"")
            
            if [ "$NODE_LABEL_VALUE" != "$VALUE" ]; then
                # Znaleziono brakujący selektor
                FINAL_RESULT="❌ NIE"
                REASON="Brak Node Selector: $SELECTOR (Wymagane: $VALUE, Znaleziono: $NODE_LABEL_VALUE)"
                break
            fi
        done
    fi
    
    # Jeśli węzeł został odrzucony z powodu Node Selectora, nie sprawdzamy Taintów (Predicates fail fast)
    if [ "$FINAL_RESULT" == "✅ TAK" ]; then
        # --- 3. Sprawdzenie Taintów i Tolerancji (Taints & Tolerations) ---
        NODE_TAINTS=$(oc get node "$NODE_NAME" -o json | jq -r '.spec.taints[]? | .key + "=" + (.value // "") + ":" + .effect' | tr '\n' ' ')

        if [ ! -z "$NODE_TAINTS" ]; then
            # Sprawdzamy, czy każdy Taint na węźle jest tolerowany przez Pod
            for TAINT in $NODE_TAINTS; do
                
                # Używamy grep -q, aby sprawdzić, czy Taint znajduje się w liście Tolerancji Podu
                if ! echo "$TOLERATIONS" | grep -qF "$TAINT"; then
                    # Taint nie jest tolerowany
                    FINAL_RESULT="❌ NIE"
                    REASON="Nieznoszone Taint: $TAINT"
                    break
                fi
            done
        fi
    fi

    # Zmiana statusu kolumn SELEKTOR i TAINTY tylko na potrzeby ładnego raportowania
    CAN_RUN_SELECTOR=$(echo "$REASON" | grep -q "Node Selector" && echo "❌ NIE" || echo "✅ OK")
    CAN_RUN_TAINT=$(echo "$REASON" | grep -q "Nieznoszone Taint" && echo "❌ NIE" || echo "✅ OK")
    
    # Jeśli wynik jest pozytywny, czyścimy przyczynę
    if [ "$FINAL_RESULT" == "✅ TAK" ]; then
        REASON="Spełnione wymagania"
    fi

    # 4. Wydruk wyniku
    printf "%-30s | %-10s | %-10s | %-10s | %s\n" "$NODE_NAME" "$CAN_RUN_SELECTOR" "$CAN_RUN_TAINT" "$FINAL_RESULT" "$REASON"

done

echo ""
echo "--- ✅ Koniec symulacji planowania. ---"
echo "WYNIK '❌ NIE' wskazuje, dlaczego dany węzeł został odrzucony na podstawie Node Selectors lub Taintów/Tolerancji."