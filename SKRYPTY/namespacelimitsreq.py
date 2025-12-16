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
    """Generuje szczegółowy raport zasobów z sumami dla każdego Deploymentu."""

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

    # Inicjalizacja sumatorów dla całego namespace
    total_cpu_req_m = 0.0
    total_cpu_lim_m = 0.0
    total_mem_req_mb = 0.0
    total_mem_lim_mb = 0.0
    total_replicas = 0

    print(f"\n--- 📊 Raport Zasobów Deploymentu dla Namespace: **{namespace}** ---")
    
    for item in data['items']:
        
        name = item['metadata']['name']
        kind = item['kind']
        
        replicas = item.get('spec', {}).get('replicas', 0)
        containers = item.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])

        pod_cpu_request_m = 0.0
        pod_cpu_limit_m = 0.0
        pod_mem_request_mb = 0.0
        pod_mem_limit_mb = 0.0
        
        # 1. Sumowanie zasobów jednego Poda (wszystkie kontenery)
        for container in containers:
            resources = container.get('resources', {})
            
            cpu_req = resources.get('requests', {}).get('cpu', '')
            mem_req = resources.get('requests', {}).get('memory', '')
            cpu_lim = resources.get('limits', {}).get('cpu', '')
            mem_lim = resources.get('limits', {}).get('memory', '')

            pod_cpu_request_m += convert_cpu_to_m(cpu_req)
            pod_cpu_limit_m += convert_cpu_to_m(cpu_lim)
            pod_mem_request_mb += convert_memory_to_mib(mem_req)
            pod_mem_limit_mb += convert_memory_to_mib(mem_lim)
        
        # 2. Całkowite zasoby Deploymentu = (Zasoby Poda) * (Liczba replik)
        current_cpu_req_m = pod_cpu_request_m * replicas
        current_cpu_lim_m = pod_cpu_limit_m * replicas
        current_mem_req_mb = pod_mem_request_mb * replicas
        current_mem_lim_mb = pod_mem_limit_mb * replicas
        
        # 3. Sumowanie do globalnych zmiennych
        total_cpu_req_m += current_cpu_req_m
        total_cpu_lim_m += current_cpu_lim_m
        total_mem_req_mb += current_mem_req_mb
        total_mem_lim_mb += current_mem_lim_mb
        total_replicas += replicas

        # Formatowanie danych do raportu (przeliczenie na Core/GiB)
        report_data.append([
            f"{kind}/{name}",
            replicas,
            f"{round(current_cpu_req_m / 1000, 2)} Core",
            f"{round(current_cpu_lim_m / 1000, 2)} Core",
            f"{round(current_mem_req_mb / 1024, 2)} GiB",
            f"{round(current_mem_lim_mb / 1024, 2)} GiB",
        ])

    # --- Generowanie wiersza sumy ---
    
    # Przeliczenie sum globalnych na Core/GiB
    sum_cpu_req_core = round(total_cpu_req_m / 1000, 2)
    sum_cpu_lim_core = round(total_cpu_lim_m / 1000, 2)
    sum_mem_req_gib = round(total_mem_req_mb / 1024, 2)
    sum_mem_lim_gib = round(total_mem_lim_mb / 1024, 2)
    
    # Dodanie wiersza sumy do danych raportu
    summary_row = [
        "**SUMA DLA NAMESPACE**",
        total_replicas,
        f"**{sum_cpu_req_core} Core**",
        f"**{sum_cpu_lim_core} Core**",
        f"**{sum_mem_req_gib} GiB**",
        f"**{sum_mem_lim_gib} GiB**",
    ]
    
    # Dodajemy separator, a następnie wiersz sumy
    report_data.append(["---"] * 6)
    report_data.append(summary_row)

    # Nagłówek tabeli
    headers = [
        "ZASÓB (KIND/NAZWA)",
        "REPLIKI",
        "CPU REQUEST",
        "CPU LIMIT",
        "MEMORY REQUEST",
        "MEMORY LIMIT",
    ]

    # Wyświetlanie tabeli
    print(tabulate(report_data, headers=headers, tablefmt="fancy_grid"))

    print("\n--- Analiza Raportu ---")
    print(f"* **SUMY w Wierszu Końcowym:** Reprezentują **całkowite rezerwacje** (REQUESTS) i **maksymalne obciążenie** (LIMITS) dla całego Namespace.")
    print(f"* Aby sprawdzić, czy klaster ma wystarczającą pojemność, porównaj Sumę REQUESTS z raportem Node Capacity.")
    
# --- Uruchomienie skryptu ---

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Deployment Resource Auditor (with Sums).")
    parser.add_argument("--namespace", required=True, help="Nazwa przestrzeni nazw OpenShift/Kubernetes.")
    
    args = parser.parse_args()
    
    generate_deployment_report(args.namespace)