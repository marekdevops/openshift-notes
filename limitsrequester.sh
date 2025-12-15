#!/bin/bash

# Nazwa skryptu: noderequester.sh
# Opis: Generuje raport wykorzystania zasobów (CPU/Memory requests/limits)
#        dla wszystkich Podów zarządzanych przez Deploymenty w danej przestrzeni nazw (namespace) OpenShift.
# Użycie: ./noderequester.sh --namespace <NAZWA_NAMESPACE>

# Wymagane narzędzia: oc, jq, bc

# --- Funkcje pomocnicze ---

# Funkcja do konwersji jednostek pamięci na MiB (Mebibajty)
convert_memory_to_mb() {
    local mem_value=$1
    if [[ $mem_value =~ ^([0-9\.]+)([EPTGMK]i?)$ ]]; then
        local value=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[2]}
        
        # Używamy BC do precyzyjnych obliczeń zmiennoprzecinkowych
        case "$unit" in
            "Mi"|"M") echo "$value" ;; # MiB (Mebibajty)
            "Gi"|"G") echo "scale=2; $value * 1024" | bc -l ;;
            "Ti"|"T") echo "scale=2; $value * 1024 * 1024" | bc -l ;;
            "Ki"|"K") echo "scale=2; $value / 1024" | bc -l ;;
            *) echo "0" ;;
        esac
    elif [[ $mem_value =~ ^([0-9\.]+)$ ]]; then
        # Traktujemy gołe liczby jako MiB (częsta konwencja, gdy brakuje jednostki)
        echo "${BASH_REMATCH[1]}"
    else
        echo "0"
    fi
}

# Funkcja do konwersji jednostek CPU na milicore (m)
convert_cpu_to_m() {
    local cpu_value=$1
    if [[ $cpu_value =~ ^([0-9\.]+)m$ ]]; then
        # Wartość jest już w milicore (np. 100m)
        echo "${BASH_REMATCH[1]}"
    elif [[ $cpu_value =~ ^([0-9]*\.?[0-9]+)$ && "$cpu_value" != "0" ]]; then
        # Wartość w core (np. 1, 0.5)
        # Używamy BC do precyzyjnego pomnożenia przez 1000
        echo "scale=0; ${BASH_REMATCH[1]} * 1000 / 1" | bc
    else
        echo "0"
    fi
}


# --- Główna logika skryptu ---

NAMESPACE=""

# Parsowanie argumentów
if [[ "$1" == "--namespace" && -n "$2" ]]; then
    NAMESPACE="$2"
else
    echo "🚨 Błąd: Nieprawidłowe użycie."
    echo "Wymagane: ./noderequester.sh --namespace <NAZWA_NAMESPACE>"
    exit 1
fi

echo "--- 📊 Raport Zasobów OpenShift ---"
echo "Namespace: **$NAMESPACE**"
echo "Pobieranie danych o zasobach. Może to chwilę potrwać..."
echo "---"

# Inicjalizacja sumatorów
TOTAL_CPU_REQUEST_M=0
TOTAL_CPU_LIMIT_M=0
TOTAL_MEM_REQUEST_MB=0
TOTAL_MEM_LIMIT_MB=0

# Zasoby do sprawdzenia: Deployments i DeploymentConfigs
RESOURCES="deployments.apps,deploymentconfigs.apps.openshift.io"

# Pobieranie danych w JSON (przekierowanie wejścia do pętli)
# Użycie "while read" z <(...) zamiast potoku (|) rozwiązuje problem subshelli.
while read -r ITEM; do
    KIND=$(echo "$ITEM" | jq -r '.kind')
    NAME=$(echo "$ITEM" | jq -r '.metadata.name')
    # Używamy // 0, aby bezpiecznie obsłużyć brakujące pole .spec.replicas
    REPLICAS=$(echo "$ITEM" | jq -r '.spec.replicas // 0')
    
    if [[ "$REPLICAS" -lt 1 ]]; then
        continue
    fi

    CONTAINERS=$(echo "$ITEM" | jq -c '.spec.template.spec.containers[]')
    
    POD_CPU_REQUEST_M=0
    POD_CPU_LIMIT_M=0
    POD_MEM_REQUEST_MB=0
    POD_MEM_LIMIT_MB=0

    # Pętla po kontenerach wewnątrz Pod Template
    echo "$CONTAINERS" | while read -r CONTAINER; do
        
        # Pobieranie requestów i limitów
        # Zgodnie ze standardem, używamy 'requests', a nie 'requestes'
        CPU_REQUEST=$(echo "$CONTAINER" | jq -r '.resources.requests.cpu // "0"')
        MEM_REQUEST=$(echo "$CONTAINER" | jq -r '.resources.requests.memory // "0"')
        CPU_LIMIT=$(echo "$CONTAINER" | jq -r '.resources.limits.cpu // "0"')
        MEM_LIMIT=$(echo "$CONTAINER" | jq -r '.resources.limits.memory // "0"')

        # Konwersja (wywołanie funkcji Basha)
        CPU_REQ_M=$(convert_cpu_to_m "$CPU_REQUEST")
        CPU_LIM_M=$(convert_cpu_to_m "$CPU_LIMIT")
        MEM_REQ_MB=$(convert_memory_to_mb "$MEM_REQUEST")
        MEM_LIM_MB=$(convert_memory_to_mb "$MEM_LIMIT")

        # Sumowanie zasobów jednego Pod'a (na kontener) - używamy 'bc' do precyzji
        POD_CPU_REQUEST_M=$(echo "$POD_CPU_REQUEST_M + $CPU_REQ_M" | bc -l)
        POD_CPU_LIMIT_M=$(echo "$POD_CPU_LIMIT_M + $CPU_LIM_M" | bc -l)
        POD_MEM_REQUEST_MB=$(echo "$POD_MEM_REQUEST_MB + $MEM_REQ_MB" | bc -l)
        POD_MEM_LIMIT_MB=$(echo "$POD_MEM_LIMIT_MB + $MEM_LIM_MB" | bc -l)
    done
    
    # Mnożenie zasobów Pod'a przez liczbę replik i dodawanie do sumy globalnej
    TOTAL_CPU_REQUEST_M=$(echo "$TOTAL_CPU_REQUEST_M + ($POD_CPU_REQUEST_M * $REPLICAS)" | bc -l)
    TOTAL_CPU_LIMIT_M=$(echo "$TOTAL_CPU_LIMIT_M + ($POD_CPU_LIMIT_M * $REPLICAS)" | bc -l)
    TOTAL_MEM_REQUEST_MB=$(echo "$TOTAL_MEM_REQUEST_MB + ($POD_MEM_REQUEST_MB * $REPLICAS)" | bc -l)
    TOTAL_MEM_LIMIT_MB=$(echo "$TOTAL_MEM_LIMIT_MB + ($POD_MEM_LIMIT_MB * $REPLICAS)" | bc -l)
    
done < <(oc get $RESOURCES -n $NAMESPACE -o json 2>/dev/null | jq -c '.items[]') # <(...) to kluczowy element!

# Zaokrąglenie do pełnych wartości
FINAL_CPU_REQUEST_M=$(echo "scale=0; ($TOTAL_CPU_REQUEST_M + 0.5) / 1" | bc)
FINAL_CPU_LIMIT_M=$(echo "scale=0; ($TOTAL_CPU_LIMIT_M + 0.5) / 1" | bc)
FINAL_MEM_REQUEST_MB=$(echo "scale=0; ($TOTAL_MEM_REQUEST_MB + 0.5) / 1" | bc)
FINAL_MEM_LIMIT_MB=$(echo "scale=0; ($TOTAL_MEM_LIMIT_MB + 0.5) / 1" | bc)

# --- Wynikowy Raport ---

echo "====================================================="
echo "   📌 PODSUMOWANIE ZASOBÓW DLA $NAMESPACE"
echo "====================================================="
echo "   CPU REQUESTS: ${FINAL_CPU_REQUEST_M}m"
echo "   CPU LIMITS:   ${FINAL_CPU_LIMIT_M}m"
echo "-----------------------------------------------------"
echo "   MEMORY REQUESTS: ${FINAL_MEM_REQUEST_MB} MiB"
echo "   MEMORY LIMITS:   ${FINAL_MEM_LIMIT_MB} MiB"
echo "====================================================="

echo ""
# Konwersja na standardowe jednostki (Cores / GiB) dla czytelności
FINAL_CPU_REQUEST_CORE=$(echo "scale=2; $FINAL_CPU_REQUEST_M / 1000" | bc -l)
FINAL_CPU_LIMIT_CORE=$(echo "scale=2; $FINAL_CPU_LIMIT_M / 1000" | bc -l)
FINAL_MEM_REQUEST_GIB=$(echo "scale=2; $FINAL_MEM_REQUEST_MB / 1024" | bc -l)
FINAL_MEM_LIMIT_GIB=$(echo "scale=2; $FINAL_MEM_LIMIT_MB / 1024" | bc -l)

echo "Wartości dla planowania (zaokrąglone do dwóch miejsc po przecinku):"
echo "   CPU REQUESTS: **${FINAL_CPU_REQUEST_CORE} Core**"
echo "   CPU LIMITS:   **${FINAL_CPU_LIMIT_CORE} Core**"
echo "   MEM REQUESTS: **${FINAL_MEM_REQUEST_GIB} GiB**"
echo "   MEM LIMITS:   **${FINAL_MEM_LIMIT_GIB} GiB**"
echo "-----------------------------------------------------"