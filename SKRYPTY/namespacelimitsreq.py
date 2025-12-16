import sys
import argparse
import json
import subprocess
from tabulate import tabulate # Wymaga pip install tabulate

# --- Funkcje konwersji (zachowane z poprzednich skryptów) ---

# Używamy MiB i milicore jako jednostek bazowych do obliczeń
MEMORY_MULTIPLIERS = {
    'Ki': 1 / 1024, 'Mi': 1, 'Gi': 1024, 'Ti': 1024 * 1024,
    'K': 1 / 1024, 'M': 1, 'G': 1024, 'T': 1024 * 1024,
}

def convert_memory_to_mib(value_str):
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

def convert_cpu_to_m(value_str):
    if not value_str: return 0.0
    if value_str.endswith('m'):
        try:
            return float(value_str[:-1])
        except ValueError:
            return 0.0
    try:
        num = float(value_str)
        return num * 1000.0
    except ValueError:
        return 0.0

# --- Funkcja pobierania danych z OC ---

def get_oc_json_deployments(namespace):
    """Wywołuje 'oc get deployment,deploymentconfig -n <namespace> -o json' i zwraca sparsowany JSON."""
    
    # Zasoby do audytu
    resources = "deployment.apps,deploymentconfig.apps.openshift.io"
    command = ['oc', 'get', resources, '-n', namespace, '-o', 'json']
    
    print(f"Wykonuję: {' '.join(command)}")
    
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        result.check_returncode()
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"🚨 Błąd wywołania 'oc': Sprawdź, czy jesteś zalogowany i czy namespace '{namespace}' istnieje.")
        print(f"Błąd: {e.stderr.strip()}")
        sys.exit(1)
    except FileNotFoundError:
        print("🚨 Błąd: Nie znaleziono polecenia 'oc'. Upewnij się, że jest w Twoim PATH.")
        sys.exit(1)

# --- Główna logika raportowania ---

def generate_deployment_report(namespace):
    """Generuje szczegółowy raport zasobów dla każdego Deploymentu."""

    # Wymagane
    try:
        from tabulate import tabulate
    except ImportError:
        print("🚨 Błąd: Wymagana biblioteka 'tabulate'. Zainstaluj ją: 'pip install tabulate'")
        sys.exit(1)
        
    data = get_oc_json_deployments(namespace)

    if not data or 'items' not in data:
        print(f"Brak Deploymentów lub DeploymentConfigs w przestrzeni nazw '{namespace}'.")
        return

    report_data = []

    print(f"\n--- 📊 Raport Zasobów Deploymentu dla Namespace: **{namespace}** ---")
    
    for item in data['items']:
        
        name = item['metadata']['name']
        kind = item['kind']
        
        # Pobieranie liczby replik
        replicas = item.get('spec', {}).get('replicas', 0)
        
        # Ścieżka do szablonu Poda jest taka sama
        containers = item.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])

        pod_cpu_request_m = 0.0
        pod_cpu_limit_m = 0.0
        pod_mem_request_mb = 0.0
        pod_mem_limit_mb = 0.0
        
        # Sumowanie zasobów wszystkich kontenerów w ramach JEDNEGO Poda
        for container in containers:
            resources = container.get('resources', {})
            
            # Pobieranie wartości
            cpu_req = resources.get('requests', {}).get('cpu', '')
            mem_req = resources.get('requests', {}).get('memory', '')
            cpu_lim = resources.get('limits', {}).get('cpu', '')
            mem_lim = resources.get('limits', {}).get('memory', '')

            # Konwersja i sumowanie dla pojedynczego Poda
            pod_cpu_request_m += convert_cpu_to_m(cpu_req)
            pod_cpu_limit_m += convert_cpu_to_m(cpu_lim)
            pod_mem_request_mb += convert_memory_to_mib(mem_req)
            pod_mem_limit_mb += convert_memory_to_mib(mem_lim)
        
        # Całkowite zasoby Deploymentu = (Zasoby Poda) * (Liczba replik)
        total_cpu_request_core = round((pod_cpu_request_m * replicas) / 1000, 2)
        total_cpu_limit_core = round((pod_cpu_limit_m * replicas) / 1000, 2)
        total_mem_request_gib = round((pod_mem_request_mb * replicas) / 1024, 2)
        total_mem_limit_gib = round((pod_mem_limit_mb * replicas) / 1024, 2)

        # Dane do raportu
        report_data.append([
            f"{kind}/{name}",
            replicas,
            f"{total_cpu_request_core} Core",
            f"{total_cpu_limit_core} Core",
            f"{total_mem_request_gib} GiB",
            f"{total_mem_limit_gib} GiB",
        ])

    # Nagłówek tabeli
    headers = [
        "ZASÓB (KIND/NAZWA)",
        "REPLIKI",
        "CPU REQUEST (Core)",
        "CPU LIMIT (Core)",
        "MEMORY REQUEST (GiB)",
        "MEMORY LIMIT (GiB)",
    ]

    # Wyświetlanie tabeli
    print(tabulate(report_data, headers=headers, tablefmt="fancy_grid"))

    print("\n--- Analiza Raportu ---")
    print("* **REQUESTS (Żądane):** Pamięć i CPU, które klaster **rezerwuje** dla Podów. To jest kluczowe dla planowania pojemności.")
    print("* **LIMITS (Limity):** Maksymalna ilość zasobów, jaką Pod **może** zużyć. Przekroczenie limitu CPU prowadzi do dławienia (throttlingu), a pamięci do zabicia Poda (OOMKilled).")
    
# --- Uruchomienie skryptu ---

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Deployment Resource Auditor.")
    parser.add_argument("--namespace", required=True, help="Nazwa przestrzeni nazw OpenShift/Kubernetes.")
    
    args = parser.parse_args()
    
    generate_deployment_report(args.namespace)