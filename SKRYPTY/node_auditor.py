import sys
import argparse
import json
import subprocess
from tabulate import tabulate # Wymaga pip install tabulate
from collections import defaultdict

# --- Funkcje konwersji jednostek ---

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
        return float(value_str)
    except ValueError:
        return 0.0

# --- Funkcje pobierania danych z OC (Ujednolicone) ---

def get_oc_json(resource, all_namespaces=False):
    """Wywołuje 'oc get <resource> -o json' i zwraca sparsowany JSON."""
    
    command = ['oc', 'get', resource]
    if all_namespaces:
        command.append('--all-namespaces')
    command.extend(['-o', 'json'])
    
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"🚨 Błąd wywołania 'oc get {resource}': Sprawdź uprawnienia.")
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
        
        node_metrics[node_name] = {
            'capacity_mib': convert_memory_to_mib(node.get('status', {}).get('capacity', {}).get('memory', '0Mi')),
            'allocatable_mib': convert_memory_to_mib(node.get('status', {}).get('allocatable', {}).get('memory', '0Mi')),
            'requested_mib': 0.0  # Inicjalizacja dla commitowanej pamięci
        }
    return node_metrics

def get_pods_requests(node_metrics):
    """Pobiera Pody i sumuje ich Memory Requests jako commitowaną pamięć."""
    print("Pobieranie i sumowanie commitowanej pamięci (requests) z Podów...")
    
    pods_data = get_oc_json('pods', all_namespaces=True)
    
    for pod in pods_data.get('items', []):
        
        # Pamięć commituje się tylko dla Podów, które mają już nodeName
        node_name = pod.get('spec', {}).get('nodeName')
        
        if node_name and node_name in node_metrics:
            
            containers = pod.get('spec', {}).get('containers', [])
            pod_total_mem_request_mib = 0.0
            
            for container in containers:
                resources = container.get('resources', {})
                mem_req = resources.get('requests', {}).get('memory', '')
                pod_total_mem_request_mib += convert_memory_to_mib(mem_req)
            
            # Dodanie commitowanej pamięci Poda do sumy dla danego Noda
            node_metrics[node_name]['requested_mib'] += pod_total_mem_request_mib
            
    return node_metrics

# --- Raport końcowy ---

def generate_committed_node_report(target_unit='GiB'):
    """Generuje kompletny raport o obciążeniu pamięcią na węzłach."""
    
    try:
        from tabulate import tabulate
    except ImportError:
        print("🚨 Błąd: Wymagana biblioteka 'tabulate'. Zainstaluj ją: 'pip install tabulate'")
        sys.exit(1)
        
    node_metrics = get_nodes_data()
    node_metrics = get_pods_requests(node_metrics) # Dodanie commitowanej pamięci

    # Ustalenie jednostki docelowej
    unit_divisor = 1024.0 if target_unit.upper() in ['GIB', 'GI'] else 1.0
    unit_name = "GiB" if target_unit.upper() in ['GIB', 'GI'] else "MiB"

    print("\n=====================================================")
    print(f"   📈 RAPORT PAMIĘCI WĘZŁÓW: ALOKACJA VS COMMIT ({unit_name})")
    print("=====================================================")

    report_data = []

    for node_name, metrics in node_metrics.items():
        allocatable = metrics['allocatable_mib']
        requested = metrics['requested_mib'] # Zacommitowana pamięć
        
        # Wolna rezerwa: Ile pamięci ZAREZERWOWANEJ (commitowanej) można jeszcze przydzielić
        free_reserve = allocatable - requested
        
        # Użycie (rezerwacji)
        usage_percent = (requested / allocatable) * 100 if allocatable > 0 else 0.0

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
        f"ZACOMMITOWANA ({unit_name})", 
        f"WOLNA REZERWA ({unit_name})", 
        "UŻYCIE [%]"
    ]
    
    print(tabulate(report_data, headers=headers, tablefmt="fancy_grid", numalign="right"))

    print("\n--- Interpretacja Raportu ---")
    print(f"* **ALLOCATABLE:** Maksymalna pamięć, którą Node **może** przydzielić Podom.")
    print(f"* **ZACOMMITOWANA (REQUESTS):** Pamięć, którą **gwarantujesz** aplikacjom na tym Nodzie.")
    print(f"* **WOLNA REZERWA:** Allocatable - Zacommitowana. Jest to pamięć, którą możesz jeszcze **zarezerwować** dla nowych Deploymentów. Jeśli jest bliska 0, musisz dodać Nody.")
    

# --- Uruchomienie skryptu ---

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Node Capacity Auditor.")
    parser.add_argument(
        "--memory-unit", 
        default="GiB", 
        help="Jednostka dla pamięci (np. MiB, GiB, domyślnie GiB)."
    )
    
    args = parser.parse_args()
    
    print("--- ⚙️ Uruchamianie audytu commitowanej pamięci (Python + oc) ---")
    generate_committed_node_report(args.memory_unit)