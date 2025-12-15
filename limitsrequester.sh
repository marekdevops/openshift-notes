#!/bin/bash

# Nazwa skryptu: noderequester.sh
# Opis: Generuje raport wykorzystania zasobów (CPU/Memory requests/limits)
#        dla wszystkich Podów zarządzanych przez Deploymenty w danej przestrzeni nazw (namespace) OpenShift.
# Użycie: ./noderequester.sh --namespace <NAZWA_NAMESPACE>

# --- Funkcje pomocnicze ---

# Funkcja do konwersji jednostek pamięci na milibajty (MB)
# OpenShift używa jednostek: Ki, Mi, Gi, Ti, P, E
convert_memory_to_mb() {
    local mem_value=$1
    if [[ $mem_value =~ ^([0-9]+)Mi$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $mem_value =~ ^([0-9]+)Gi$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 1024 ))"
    elif [[ $mem_value =~ ^([0-9]+)Ti$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 1024 * 1024 ))"
    elif [[ $mem_value =~ ^([0-9]+)Ki$ ]]; then
        # Konwersja Ki do Mi: Ki / 1024
        echo "scale=2; ${BASH_REMATCH[1]} / 1024" | bc -l
    elif [[ $mem_value =~ ^([0-9]+)$ ]]; then
        # Zakładamy, że wartość bez jednostki to bajty lub Ki, ale OpenShift zwykle wymaga jednostek.
        # W praktyce, jeśli nie ma jednostki, jest to traktowane jako bajty, co jest bardzo małe,
        # więc konwertujemy do MiB, ale to może być mylące. Poniżej: traktujemy jako MiB.
        echo "${BASH_REMATCH[1]}"
    else
        echo "0"
    fi
}

# Funkcja do konwersji jednostek CPU na milicore (m)
convert_cpu_to_m() {
    local cpu_value=$1
    if [[ $cpu_value =~ ^([0-9]+)m$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $cpu_value =~ ^([0-9]*\.?[0-9]+)$ ]]; then
        # Wartość w core (np. 1, 0.5)
        echo "$(( (10#${BASH_REMATCH[1]} * 1000) / 1000 ))"
        # Użycie 'bc' dla ułamków
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

# Pusta lista do śledzenia podów, które już przetworzyliśmy, aby uniknąć duplikatów
# (Chociaż poniżej skupiamy się na szablonach Podów, lepiej być pewnym)
# Zmieniamy podejście, aby użyć szablonów Podów (Pod Templates) z DeploymentConfig/Deployment,
# co jest lepszą reprezentacją tego, co "chcemy" mieć (request/limit),
# a nie tylko tego, co "mamy" w danej chwili.

# Używamy `oc get <resource> -o json` i `jq` do parsowania
# Sprawdź Deployments i DeploymentConfigs
RESOURCES="deployments.apps,deploymentconfigs.apps.openshift.io"

RESOURCE_JSON=$(oc get $RESOURCES -n $NAMESPACE -o json 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "⚠️ Błąd: Nie udało się pobrać zasobów dla przestrzeni nazw **$NAMESPACE**."
    echo "Sprawdź, czy jesteś zalogowany do klastra i czy podana przestrzeń nazw istnieje."
    exit 1
fi

# Iteracja po wszystkich elementach (DeploymentConfig i Deployment)
echo "$RESOURCE_JSON" | jq -c '.items[]' | while read -r ITEM; do
    KIND=$(echo "$ITEM" | jq -r '.kind')
    NAME=$(echo "$ITEM" | jq -r '.metadata.name')
    REPLICAS=$(echo "$ITEM" | jq -r '.spec.replicas')
    
    # Upewniamy się, że mamy przynajmniej 1 replikę
    if [[ "$REPLICAS" -lt 1 ]]; then
        echo "   [SKIP] $KIND/$NAME: Replik: $REPLICAS"
        continue
    fi

    # Pobieranie definicji kontenerów z szablonu Pod'a
    CONTAINERS=$(echo "$ITEM" | jq -c '.spec.template.spec.containers[]')
    
    echo "--- $KIND/$NAME (Replik: $REPLICAS) ---"

    # Sumowanie zasobów dla wszystkich kontenerów w ramach jednego szablonu Pod'a
    POD_CPU_REQUEST_M=0
    POD_CPU_LIMIT_M=0
    POD_MEM_REQUEST_MB=0
    POD_MEM_LIMIT_MB=0

    echo "$CONTAINERS" | while read -r CONTAINER; do
        CONTAINER_NAME=$(echo "$CONTAINER" | jq -r '.name')
        
        # Pobieranie requestów
        CPU_REQUEST=$(echo "$CONTAINER" | jq -r '.resources.requests.cpu // "0"')
        MEM_REQUEST=$(echo "$CONTAINER" | jq -r '.resources.requests.memory // "0"')
        
        # Pobieranie limitów
        CPU_LIMIT=$(echo "$CONTAINER" | jq -r '.resources.limits.cpu // "0"')
        MEM_LIMIT=$(echo "$CONTAINER" | jq -r '.resources.limits.memory // "0"')

        # Konwersja i sumowanie
        # CPU
        CPU_REQ_M=$(convert_cpu_to_m "$CPU_REQUEST")
        CPU_LIM_M=$(convert_cpu_to_m "$CPU_LIMIT")
        
        # MEM
        MEM_REQ_MB=$(convert_memory_to_mb "$MEM_REQUEST")
        MEM_LIM_MB=$(convert_memory_to_mb "$MEM_LIMIT")

        # Sumowanie zasobów jednego Pod'a (na kontener)
        POD_CPU_REQUEST_M=$(echo "$POD_CPU_REQUEST_M + $CPU_REQ_M" | bc -l)
        POD_CPU_LIMIT_M=$(echo "$POD_CPU_LIMIT_M + $CPU_LIM_M" | bc -l)
        POD_MEM_REQUEST_MB=$(echo "$POD_MEM_REQUEST_MB + $MEM_REQ_MB" | bc -l)
        POD_MEM_LIMIT_MB=$(echo "$POD_MEM_LIMIT_MB + $MEM_LIM_MB" | bc -l)

        # echo "    - $CONTAINER_NAME: CPU Req: ${CPU_REQ_M}m, CPU Lim: ${CPU_LIM_M}m, Mem Req: ${MEM_REQ_MB}Mi, Mem Lim: ${MEM_LIM_MB}Mi"
    done
    
    # Mnożenie zasobów Pod'a przez liczbę replik i dodawanie do sumy globalnej
    TOTAL_CPU_REQUEST_M=$(echo "$TOTAL_CPU_REQUEST_M + ($POD_CPU_REQUEST_M * $REPLICAS)" | bc -l)
    TOTAL_CPU_LIMIT_M=$(echo "$TOTAL_CPU_LIMIT_M + ($POD_CPU_LIMIT_M * $REPLICAS)" | bc -l)
    TOTAL_MEM_REQUEST_MB=$(echo "$TOTAL_MEM_REQUEST_MB + ($POD_MEM_REQUEST_MB * $REPLICAS)" | bc -l)
    TOTAL_MEM_LIMIT_MB=$(echo "$TOTAL_MEM_LIMIT_MB + ($POD_MEM_LIMIT_MB * $REPLICAS)" | bc -l)
    
done # Koniec pętli po zasobach

# Zaokrąglenie do pełnych wartości
FINAL_CPU_REQUEST_M=$(echo "scale=0; ($TOTAL_CPU_REQUEST_M + 0.5) / 1" | bc)
FINAL_CPU_LIMIT_M=$(echo "scale=0; ($TOTAL_CPU_LIMIT_M + 0.5) / 1" | bc)
FINAL_MEM_REQUEST_MB=$(echo "scale=0; ($TOTAL_MEM_REQUEST_MB + 0.5) / 1" | bc)
FINAL_MEM_LIMIT_MB=$(echo "scale=0; ($TOTAL_MEM_LIMIT_MB + 0.5) / 1" | bc)

# --- Podsumowanie ---

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
# Pomoc w interpretacji
echo "Interpretacja:"
echo "* Wartość REQUESTS to **minimalna gwarancja zasobów**, której klaster będzie używał do planowania."
echo "* Wartość LIMITS to **maksymalna ilość zasobów**, jaką Pod może wykorzystać."
echo "* Wartości te są **pomnożone** przez aktualną liczbę replik."

# Konwersja na standardowe jednostki (Cores / GiB)
FINAL_CPU_REQUEST_CORE=$(echo "scale=2; $FINAL_CPU_REQUEST_M / 1000" | bc -l)
FINAL_CPU_LIMIT_CORE=$(echo "scale=2; $FINAL_CPU_LIMIT_M / 1000" | bc -l)
FINAL_MEM_REQUEST_GIB=$(echo "scale=2; $FINAL_MEM_REQUEST_MB / 1024" | bc -l)
FINAL_MEM_LIMIT_GIB=$(echo "scale=2; $FINAL_MEM_LIMIT_MB / 1024" | bc -l)

echo ""
echo "   CPU REQUESTS: **${FINAL_CPU_REQUEST_CORE} Core**"
echo "   CPU LIMITS:   **${FINAL_CPU_LIMIT_CORE} Core**"
echo "   MEM REQUESTS: **${FINAL_MEM_REQUEST_GIB} GiB**"
echo "   MEM LIMITS:   **${FINAL_MEM_LIMIT_GIB} GiB**"
echo "-----------------------------------------------------"