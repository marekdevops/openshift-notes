import sys
import argparse
import json
import subprocess
from collections import defaultdict
from tabulate import tabulate # Wymaga pip install tabulate

# --- Funkcje konwersji jednostek ---

# Używamy MiB jako jednostki bazowej do konwersji, aby zachować precyzję
MEMORY_MULTIPLIERS = {
    'Ki': 1 / 1024, 'Mi': 1, 'Gi': 1024, 'Ti': 1024 * 1024,
    'K': 1 / 1024, 'M': 1, 'G': 1024, 'T': 1024 * 1024,
}

def convert_memory_to_mib(value_str):
    """Konwertuje wartość pamięci (np. '1Gi', '256Mi') na liczbę MiB."""
    if not value_str: return 0.0
    temp_value_str = value_str.replace('i', '') 

    for unit, multiplier in MEMORY_MULTIPLIERS.items():
        if temp_value_str.endswith(unit):
            try:
                num = float(temp_value_str[:-len(unit)])
                return num * multiplier
            except ValueError:
                return 0.0
    try:
        # Traktowanie gołych liczb jako MiB
        return float(value_str)
    except ValueError:
        return 0.0

# --- Funkcje pobierania danych z OC (Poprawione dla obsługi błędów) ---

def get_oc_json(resource, all_namespaces=False):
    """Wywołuje 'oc get <resource> -o json' i zwraca sparsowany JSON."""
    
    command = ['oc', 'get', resource]
    if all_namespaces:
        command.append('--all-namespaces')
    command.extend(['-o', 'json'])
    
    # print(f"Wykonuję: {' '.join(command)}") # Odkomentuj dla diagnostyki
    
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"🚨 Błąd wywołania 'oc get {resource}': Sprawdź uprawnienia.")
        # Jeśli błąd dotyczy Podów, zwracamy pusty zestaw, aby reszta raportu działała.
        if 'pods' in resource:
             return {'items': []} 
        sys.exit(1)
    except FileNotFoundError:
        print("🚨 Błąd: Nie znaleziono polecenia 'oc'. Upewnij się, że jest w Twoim PATH.")
        sys.exit(1)

def get_nodes_data():
    """Pobiera i przetwarza dane o pojemności nodów."""
    print("Pobieranie danych o pojemności nodów...")
    nodes_data = get_oc_json('nodes')
    
    node_metrics = {}
    
    for node in nodes_data.get('items', []):
        node_name = node['metadata']['name']
        
        # Pamięć Capacity i Allocatable w MiB
        capacity_mib = convert_memory_to_mib(
            node.get('status', {}).get('capacity', {}).get('memory', '0Mi')
        )
        allocatable_mib = convert_memory_to_mib(
            node.get('status', {}).get('allocatable', {}).get('memory', '0Mi')
        )
        
        node_metrics[node_name] = {
            'capacity_mib': capacity_mib,
            'allocatable_mib': allocatable_mib,
            'requested_mib': 0.0  # Będziemy to sumować z Podów
        }
        
    return node_metrics

def get_pods_requests(node_metrics):
    """Pobiera wszystkie Pody i sumuje ich Memory Requests na nodach."""
    print("Pobieranie i sumowanie Memory Requests z Podów (wszystkie namespaces)...")
    
    # Pobieramy Pody ze wszystkich przestrzeni nazw
    pods_data = get_oc_json('pods', all_namespaces=True)
    
    unmatched_pods_count = 0
    
    for pod in pods_data.get('items', []):
        
        # Filtrujemy Pody: interesują nas tylko te, które są Running lub Pending i mają nodeName
        phase = pod.get('status', {}).get('phase')
        if phase not in ['Running', 'Pending']:
             continue

        node_name = pod.get('spec', {}).get('nodeName')
        
        if node_name and node_name in node_metrics:
            
            containers = pod.get('spec', {}).get('containers', [])
            pod_total_mem_request_mib = 0.0
            
            for container in containers:
                resources = container.get('resources', {})
                mem_req = resources.get('requests', {}).get('memory', '')
                
                pod_total_mem_request_mib += convert_memory_to_mib(mem_req)
            
            # Dodanie requestów Poda do sumy dla danego Noda
            node_metrics[node_name]['requested_mib'] += pod_total_mem_request_mib
            
        elif node_name:
            # NodeName istnieje, ale nie ma go na liście węzłów (może być unknwon lub usunięty)
            unmatched_pods_count += 1
        # Jeśli nodeName jest pusty, Pod jest Pending i jeszcze nie został zaplanowany (nie rezerwuje zasobów noda)
        
    if unmatched_pods_count > 0:
         print(f"   [INFO] Pominięto {unmatched_pods_count} Podów, ponieważ były przypisane do nieznanego/usuniętego Noda.")
         
    return node_metrics

# --- Raport końcowy ---

def generate_full_node_report(target_unit='GiB'):
    """Generuje kompletny raport o obciążeniu pamięcią na węzłach."""
    
    try:
        from tabulate import tabulate
    except ImportError:
        print("🚨 Błąd: Wymagana biblioteka 'tabulate'. Zainstaluj ją: 'pip install tabulate'")
        sys.exit(1)
        
    # 1. Pobierz pojemność nodów
    node_metrics = get_nodes_data()
    
    # 2. Pobierz requesty Podów i przypisz do nodów
    node_metrics = get_pods_requests(node_metrics)

    # Ustalenie jednostki docelowej
    if target_unit.upper() in ['GIB', 'GI']:
        unit_divisor = 1024.0
        unit_name = "GiB"
    elif target_unit.upper() in ['MIB', 'MI']:
        unit_divisor = 1.0
        unit_name = "MiB"
    else:
        unit_divisor = 1024.0
        unit_name = "GiB"

    print("\n=====================================================")
    print(f"   📈 PEŁNY RAPORT REZERWACJI PAMIĘCI NA WĘZŁACH ({unit_name})")
    print("=====================================================")

    report_data = []

    # 

    for node_name, metrics in node_metrics.items():
        allocatable = metrics['allocatable_mib']
        requested = metrics['requested_mib']
        
        # Wolna rezerwa: Ile pamięci ZAREZERWOWANEJ można jeszcze przydzielić
        free_reserve = allocatable - requested
        
        # Użycie (rezerwacji)
        if allocatable > 0:
            usage_percent = (requested / allocatable) * 100
        else:
            usage_percent = 0.0

        # Konwersja na jednostkę docelową
        allocatable_unit = round(allocatable / unit_divisor, 2)
        requested_unit = round(requested / unit_divisor, 2)
        free_reserve_unit = round(free_reserve / unit_divisor, 2)
        
        # Dane do raportu
        report_data.append([
            node_name, 
            f"{allocatable_unit:.2f}", 
            f"{requested_unit:.2f}", 
            f"{free_reserve_unit:.2f}", 
            f"{usage_percent:.1f}%"
        ])
        
    # Nagłówek tabeli
    headers = [
        "WĘZEŁ (NODE)", 
        f"ALLOCATABLE ({unit_name})", 
        f"REQUESTED ({unit_name})", 
        f"WOLNA REZERWA ({unit_name})", 
        "UŻYCIE [%]"
    ]
    
    # Wyświetlanie tabeli
    print(tabulate(report_data, headers=headers, tablefmt="fancy_grid", numalign="right"))

    print("\n--- Analiza Raportu ---")
    print("* **ALLOCATABLE:** Całkowita pamięć dostępna do rezerwacji dla Podów (Capacity - system).")
    print("* **REQUESTED:** Suma żądanej pamięci (requests) przez **wszystkie Pody** na tym nodzie.")
    print("* **WOLNA REZERWA:** Allocatable - Requested. Tyle pamięci **gwarantowanej** możesz jeszcze przydzielić.")


# --- Uruchomienie skryptu ---

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Full Node Capacity Auditor.")
    parser.add_argument(
        "--memory-unit", 
        default="GiB", 
        help="Jednostka dla pamięci (np. MiB, GiB, domyślnie GiB)."
    )
    
    args = parser.parse_args()
    
    print("--- ⚙️ Uruchamianie pełnego audytu nodów (Python + oc) ---")
    generate_full_node_report(args.memory_unit)