#!/bin/bash

# Użycie: symuluj_planowanie.sh -pod <NAZWA_PODA> -n <NAMESPACE>

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

# b) Tolerancje (zbieramy wszystkie tainty, które pod może tolerować)
TOLERATIONS=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.tolerations[]? | .key + "=" + .value + ":" + .effect' | tr '\n' ' ')

# c) Wymagania zasobowe (CPU/Pamięć) - (dla pełniejszej symulacji)
CPU_REQUESTS=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.containers[0].resources.requests.cpu // "0"' )
MEM_REQUESTS_RAW=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.containers[0].resources.requests.memory // "0"' )

echo "Node Selector (wymagane etykiety): [ $NODE_SELECTOR ]"
echo "Tolerancje (możliwe do zniesienia tainty): [ $(echo $TOLERATIONS | tr ' ' '\n') ]"
echo "--- ---------------------------------------------------- ---"

# Nagłówek tabeli
printf "%-30s | %-10s | %-10s | %-10s\n" "NAZWA WEZŁA" "SELEKTOR" "TAINTY" "WYNIK"
printf "%-30s | %-10s | %-10s | %-10s\n" "------------------------------" "----------" "----------" "----------"

# Pobranie listy wszystkich węzłów i iteracja
oc get nodes -o json | jq -r '.items[] | .metadata.name' | while read -r NODE_NAME; do

    CAN_RUN_SELECTOR="✅ OK"
    CAN_RUN_TAINT="✅ OK"
    FINAL_RESULT="✅ TAK"

    # --- 2. Sprawdzenie Node Selector (Etykiety) ---
    if [ ! -z "$NODE_SELECTOR" ]; then
        # Sprawdzamy, czy węzeł posiada wszystkie wymagane etykiety.
        # Używamy jq i Grepa do sprawdzenia istnienia.
        SELECTOR_FAIL=0
        for SELECTOR in $NODE_SELECTOR; do
            KEY=${SELECTOR%=*}
            VALUE=${SELECTOR#*=}
            
            # Pobierz etykietę i sprawdź, czy pasuje do wymagania
            NODE_LABEL_VALUE=$(oc get node "$NODE_NAME" -o json | jq -r ".metadata.labels[\"$KEY\"] // \"\"")
            
            if [ "$NODE_LABEL_VALUE" != "$VALUE" ]; then
                SELECTOR_FAIL=1
                break
            fi
        done

        if [ "$SELECTOR_FAIL" -eq 1 ]; then
            CAN_RUN_SELECTOR="❌ NIE"
            FINAL_RESULT="❌ NIE"
        fi
    fi

    # --- 3. Sprawdzenie Taintów i Tolerancji (Taints & Tolerations) ---
    NODE_TAINTS=$(oc get node "$NODE_NAME" -o json | jq -r '.spec.taints[]? | .key + "=" + .value + ":" + .effect' | tr '\n' ' ')

    if [ ! -z "$NODE_TAINTS" ]; then
        # Sprawdzamy, czy każdy Taint na węźle jest tolerowany przez Pod
        for TAINT in $NODE_TAINTS; do
            TAINTS_FAIL=1
            
            # Sprawdzenie, czy Taint znajduje się w liście Tolerancji Podu
            if echo "$TOLERATIONS" | grep -qF "$TAINT"; then
                 TAINTS_FAIL=0
            fi

            if [ "$TAINTS_FAIL" -eq 1 ]; then
                # Jeśli Pod nie toleruje jakiegoś Tainta, to nie może być zaplanowany
                CAN_RUN_TAINT="❌ NIE"
                FINAL_RESULT="❌ NIE"
                break
            fi
        done
    fi

    # Uwaga: Skrypt celowo upraszcza logikę Affinity/Anti-Affinity i zasobów,
    # skupiając się na Node Selectors i Taints/Tolerations, które są najczęściej używane.
    # Pełna symulacja planisty wymagałaby parowania wszystkich Podów na węźle, co jest zbyt złożone dla skryptu Bash.

    # 4. Wydruk wyniku
    printf "%-30s | %-10s | %-10s | %-10s\n" "$NODE_NAME" "$CAN_RUN_SELECTOR" "$CAN_RUN_TAINT" "$FINAL_RESULT"

done

echo ""
echo "--- ✅ Koniec symulacji planowania. ---"
echo "WYNIK '❌ NIE' może wynikać z braku zgodności Node Selectora lub Taintów/Tolerancji."