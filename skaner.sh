#!/usr/bin/env bash
set -euo pipefail

# Kolory dla lepszej czytelności
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funkcja pomocnicza - konwertuje IP na liczbę
ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo "$((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))"
}

# Funkcja pomocnicza - konwertuje liczbę na IP
int_to_ip() {
    local n=$1
    echo "$((n >> 24 & 255)).$((n >> 16 & 255)).$((n >> 8 & 255)).$((n & 255))"
}

# Funkcja obliczająca zakres IP z notacji CIDR
calculate_range() {
    local cidr=$1
    local ip=${cidr%/*}
    local prefix=${cidr#*/}
    
    local ip_int
    ip_int=$(ip_to_int "$ip")
    
    local mask=$((0xFFFFFFFF << (32 - prefix)))
    local network=$((ip_int & mask))
    local broadcast=$((network | ~mask & 0xFFFFFFFF))
    
    echo "$network $broadcast"
}

# Funkcja sprawdzająca pojedynczy IP
check_ip() {
    local ip=$1
    local ping_result=1
    local dig_result=""
    local nslookup_result=""
    
    # Ping test (timeout 1 sekunda, 1 pakiet)
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        ping_result=0
    fi
    
    # Dig - reverse DNS lookup
    dig_result=$(dig +short -x "$ip" 2>/dev/null | head -n1 || echo "")
    
    # Nslookup - reverse DNS lookup (backup)
    if [ -z "$dig_result" ]; then
        nslookup_result=$(nslookup "$ip" 2>/dev/null | grep "name =" | awk '{print $NF}' || echo "")
    fi
    
    local hostname="${dig_result:-${nslookup_result:-}}"
    
    # Zwracamy: IP|ping(0/1)|hostname
    echo "$ip|$ping_result|$hostname"
}

# Funkcja główna
main() {
    if [ $# -eq 0 ]; then
        echo "Użycie: $0 <CIDR>"
        echo "Przykład: $0 10.10.10.0/24"
        exit 1
    fi
    
    local cidr=$1
    
    # Walidacja CIDR
    if ! [[ $cidr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Błąd: Nieprawidłowy format CIDR. Użyj formatu: 10.10.10.0/24"
        exit 1
    fi
    
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Skaner wolnych adresów IP w podsieci                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${YELLOW}Podsieć:${NC} $cidr"
    echo -e "${YELLOW}Start:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    
    # Obliczanie zakresu
    read -r network_int broadcast_int <<< "$(calculate_range "$cidr")"
    
    local first_ip=$((network_int + 1))
    local last_ip=$((broadcast_int - 1))
    local total=$((last_ip - first_ip + 1))
    
    echo -e "${YELLOW}Zakres do skanowania:${NC} $(int_to_ip $first_ip) - $(int_to_ip $last_ip)"
    echo -e "${YELLOW}Liczba adresów:${NC} $total"
    echo
    echo "Skanowanie w toku..."
    echo
    
    # Tablice do przechowywania wyników
    declare -a free_ips
    declare -a used_ips
    declare -a dns_ips
    
    local current=0
    local progress_step=$((total / 20))
    [ $progress_step -eq 0 ] && progress_step=1
    
    # Skanowanie IP
    for ((i=first_ip; i<=last_ip; i++)); do
        local ip
        ip=$(int_to_ip "$i")
        current=$((current + 1))
        
        # Progress bar
        if [ $((current % progress_step)) -eq 0 ] || [ $current -eq $total ]; then
            local percent=$((current * 100 / total))
            printf "\rPostęp: [%-20s] %d%%" $(printf '#%.0s' $(seq 1 $((percent / 5)))) "$percent"
        fi
        
        # Sprawdzanie IP
        result=$(check_ip "$ip")
        IFS='|' read -r check_ip ping_status hostname <<< "$result"
        
        if [ "$ping_status" -eq 0 ]; then
            if [ -n "$hostname" ]; then
                dns_ips+=("$check_ip|$hostname")
            else
                used_ips+=("$check_ip")
            fi
        else
            if [ -n "$hostname" ]; then
                dns_ips+=("$check_ip|$hostname")
            else
                free_ips+=("$check_ip")
            fi
        fi
    done
    
    echo
    echo
    
    # Generowanie raportu
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    RAPORT KOŃCOWY                         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${GREEN}✓ Wolne adresy IP (${#free_ips[@]}):${NC}"
    if [ ${#free_ips[@]} -gt 0 ]; then
        for ip in "${free_ips[@]}"; do
            echo "  • $ip"
        done
    else
        echo "  (brak)"
    fi
    echo
    
    echo -e "${RED}✗ Zajęte adresy IP bez DNS (${#used_ips[@]}):${NC}"
    if [ ${#used_ips[@]} -gt 0 ]; then
        for ip in "${used_ips[@]}"; do
            echo "  • $ip"
        done
    else
        echo "  (brak)"
    fi
    echo
    
    echo -e "${YELLOW}⚠ Adresy z wpisem DNS (${#dns_ips[@]}):${NC}"
    if [ ${#dns_ips[@]} -gt 0 ]; then
        for entry in "${dns_ips[@]}"; do
            IFS='|' read -r ip hostname <<< "$entry"
            echo "  • $ip → $hostname"
        done
    else
        echo "  (brak)"
    fi
    echo
    
    # Podsumowanie
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Podsumowanie:${NC}"
    echo "  Przeskanowano:     $total adresów"
    echo "  Wolne:            ${#free_ips[@]}"
    echo "  Zajęte:           $((${#used_ips[@]} + ${#dns_ips[@]}))"
    echo "  Z wpisem DNS:     ${#dns_ips[@]}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Zakończono:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
}

main "$@"