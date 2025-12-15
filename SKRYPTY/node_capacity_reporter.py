import sys
import argparse
import json
import subprocess
from collections import defaultdict

# Stałe
# Używamy MiB jako jednostki bazowej do konwersji, aby zachować precyzję
MEMORY_MULTIPLIERS = {
    'Ki': 1 / 1024,
    'Mi': 1,
    'Gi': 1024,
    'Ti': 1024 * 1024,
    # Obsługa standardowych jednostek
    'K': 1 / 1024,
    'M': 1,
    'G': 1024,
    'T': 1024 * 1024,
}

def convert_memory_to_mib(value_str):
    """Konwertuje wartość pamięci (np. '1Gi', '256Mi') na liczbę MiB."""
    if not value_str:
        return 0.0
        
    # Usuń ewentualne jednostki 'i' (np. Gi -> G) dla łatwiejszego parsowania
    temp_value_str = value_str.replace('i', '') 

    for unit, multiplier in MEMORY_MULTIPLIERS.items():
        if temp_value_str.endswith(unit):
            try:
                # Parsowanie liczby
                num = float(temp_value_str[:-len(unit)])
                return num * multiplier
            except ValueError:
                return 0.0
    
    try:
        # Traktowanie gołych liczb jako MiB
        return float(value_str)
    except ValueError:
        return 0.0

def get_oc_json_nodes():
    """Wywołuje 'oc get nodes -o json' i zwraca sparsowany JSON."""
    
    command = ['oc', 'get', 'nodes', '-o', 'json']
    
    print(f"Wykonuję: {' '.join(command)}")
    
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"🚨 Błąd wywołania 'oc': Sprawdź, czy jesteś zalogowany.")
        print(f"Błąd: {e.stderr.strip()}")
        sys.exit(1)
    except FileNotFoundError:
        print("🚨 Błąd: Nie znaleziono polecenia 'oc'. Upewnij się, że jest w Twoim PATH.")
        sys.exit(1)

def generate_node_report(target_unit='GiB'):
    """Generuje raport dostępnej pamięci dla każdego noda."""
    
    data = get_oc_json_nodes()

    if not data or 'items' not in data:
        print("Brak nodów do przetworzenia.")
        return

    # Ustalenie jednostki docelowej
    if target_unit.upper() in ['GIB', 'GI']:
        unit_divisor = 1024.0
        unit_name = "GiB"
    elif target_unit.upper() in ['MIB', 'MI']:
        unit_divisor = 1.0
        unit_name = "MiB"
    else:
        print(f"⚠️ Nieznana jednostka '{target_unit}'. Używam GiB.")
        unit_divisor = 1024.0
        unit_name = "GiB"

    print("\n=====================================================")
    print(f"   📊 RAPORT POJEMNOŚCI PAMIĘCI WĘZŁÓW ({unit_name})")
    print("=====================================================")

    # Wymiary nagłówka
    header = "| {:<30} | {:<10} | {:<10} | {:<10} | {:<10} |".format(
        "WĘZEŁ (NODE)", "CAŁKOWITA", "ALLOCATABLE", "REQUESTED", "WOLNA"
    )
    print(header)
    print("-" * len(header))

    # Pętla przez wszystkie nody
    for node in data['items']:
        node_name = node['metadata']['name']
        
        # 1. Pojemność (Capacity)
        capacity_mem_mib = convert_memory_to_mib(
            node.get('status', {}).get('capacity', {}).get('memory', '0Mi')
        )
        
        # 2. Rezerwacja (Allocatable)
        allocatable_mem_mib = convert_memory_to_mib(
            node.get('status', {}).get('allocatable', {}).get('memory', '0Mi')
        )

        # 3. Wykorzystanie przez Pody (Requested) - wymagałoby dodatkowego zapytania API
        # Pamięć REQUESTED (zaciągnięta przez Pody) to Allocatable - Dostępne
        # UWAGA: Ten skrypt zlicza "Wolną" jako Allocatable, co jest najbezpieczniejszą miarą.
        # Różnica 'Capacity - Allocatable' to zasoby zarezerwowane przez sam system operacyjny/OpenShift
        # Różnica 'Allocatable - Requested' to faktycznie dostępne miejsce na nowe Pody
        
        # Aby uzyskać faktycznie REQUESTED zasoby, musielibyśmy pobrać wszystkie Pody
        # na danym nodzie i zsumować ich requests (co jest skomplikowane bez biblioteki K8s).
        # Uproszczenie: Korzystamy tylko z Capacity i Allocatable.

        # Pamięć Dostępna dla scheduler'a
        available_mem_mib = allocatable_mem_mib 
        
        # Przeliczenie na jednostkę docelową
        capacity_mem_unit = round(capacity_mem_mib / unit_divisor, 2)
        allocatable_mem_unit = round(allocatable_mem_mib / unit_divisor, 2)
        available_mem_unit = round(available_mem_mib / unit_divisor, 2)
        
        # Dla tego raportu, requested ustawiamy na N/A, ponieważ nie zliczamy obciążenia Podami
        # Wersja rozszerzona wymagałaby dostępu do API Podów.
        requested_placeholder = "N/A"

        # Wydruk wiersza
        print("| {:<30} | {:<10.2f} | {:<10.2f} | {:<10} | {:<10.2f} |".format(
            node_name, 
            capacity_mem_unit, 
            allocatable_mem_unit, 
            requested_placeholder, 
            available_mem_unit
        ))

    print("-" * len(header))
    print(f"\nInterpretacja kolumn (w {unit_name}):")
    print(f"* **CAŁKOWITA (Capacity):** Cała pamięć fizyczna noda.")
    print(f"* **ALLOCATABLE:** Pamięć dostępna dla Podów (Capacity - system/rezwerwa OpenShift).")
    print(f"* **WOLNA (Available):** W tym raporcie = Allocatable. Jest to pamięć, którą scheduler Kubernetes/OpenShift **może** przydzielić nowym Podom.")


# --- Uruchomienie skryptu ---

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Node Capacity Reporter.")
    parser.add_argument(
        "--memory-unit", 
        default="GiB", 
        help="Jednostka dla pamięci (np. MiB, GiB, domyślnie GiB)."
    )
    
    args = parser.parse_args()
    
    print("--- ⚙️ Uruchamianie raportu pojemności nodów (Python + oc) ---")
    generate_node_report(args.memory_unit)