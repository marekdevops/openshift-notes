import sys
import argparse
import json
import subprocess

# Stałe
# Używamy MiB jako jednostki bazowej dla pamięci
MEMORY_MULTIPLIERS = {
    'Ki': 1 / 1024,
    'Mi': 1,
    'Gi': 1024,
    'Ti': 1024 * 1024,
}

def convert_memory_to_mib(value_str):
    """Konwertuje wartość pamięci (np. '1Gi', '256Mi') na liczbę MiB."""
    if not value_str:
        return 0.0
        
    for unit, multiplier in MEMORY_MULTIPLIERS.items():
        if value_str.endswith(unit):
            try:
                num = float(value_str[:-len(unit)])
                return num * multiplier
            except ValueError:
                return 0.0
    
    # Obsługa jednostek specyficznych dla OpenShift (np. '1G' zamiast '1Gi')
    if value_str.endswith('G'):
        value_str = value_str.replace('G', 'Gi')
    elif value_str.endswith('M'):
        value_str = value_str.replace('M', 'Mi')
    elif value_str.endswith('K'):
        value_str = value_str.replace('K', 'Ki')

    # Spróbujmy ponownie z nowymi jednostkami
    for unit, multiplier in MEMORY_MULTIPLIERS.items():
        if value_str.endswith(unit):
            try:
                num = float(value_str[:-len(unit)])
                return num * multiplier
            except ValueError:
                return 0.0

    try:
        # Traktowanie gołych liczb jako MiB (dla bezpieczeństwa)
        return float(value_str)
    except ValueError:
        return 0.0

def convert_cpu_to_m(value_str):
    """Konwertuje wartość CPU (np. '1', '500m') na liczbę milicore (m)."""
    if not value_str:
        return 0.0

    if value_str.endswith('m'):
        # Wartość jest już w milicore
        try:
            return float(value_str[:-1])
        except ValueError:
            return 0.0
    
    # Wartość jest w core (np. '0.5' lub '1')
    try:
        num = float(value_str)
        return num * 1000.0
    except ValueError:
        return 0.0

def get_oc_json(namespace):
    """Wywołuje 'oc get' i zwraca sparsowany JSON."""
    
    # Zasoby do pobrania: Deployments i DeploymentConfigs (DC)
    # Dodanie StateFulSets i DaemonSets, dla pełniejszego planowania
    resources = "deployments.apps,deploymentconfigs.apps.openshift.io,statefulsets.apps,daemonsets.apps"
    
    command = ['oc', 'get', resources, '-n', namespace, '-o', 'json']
    
    print(f"Wykonuję: {' '.join(command)}")
    
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"🚨 Błąd wywołania 'oc': Sprawdź, czy jesteś zalogowany i czy namespace '{namespace}' istnieje.")
        print(f"Błąd: {e.stderr.strip()}")
        sys.exit(1)
    except FileNotFoundError:
        print("🚨 Błąd: Nie znaleziono polecenia 'oc'. Upewnij się, że jest w Twoim PATH.")
        sys.exit(1)

def generate_resource_report(namespace):
    """Generuje sumaryczny raport zasobów dla danej przestrzeni nazw, używając 'oc'."""
    
    data = get_oc_json(namespace)

    if not data or 'items' not in data:
        print("Brak zasobów do przetworzenia.")
        return

    # Inicjalizacja sumatorów
    total_cpu_request_m = 0.0
    total_cpu_limit_m = 0.0
    total_mem_request_mb = 0.0
    total_mem_limit_mb = 0.0
    
    # Przetwarzanie wszystkich zasobów
    
    for item in data['items']:
        
        name = item['metadata']['name']
        kind = item['kind']
        
        # DeploymentConfig i Deployment używają 'spec.replicas'. 
        # DaemonSet ma 'spec.template', ale musimy liczyć Pody inaczej (np. według 'status.numberReady'), 
        # ale dla REQUESTS/LIMITS patrzymy na oczekiwaną liczbę replik.
        
        # Dla DC/Deployment/StatefulSet: używamy .spec.replicas
        # Dla DaemonSet: używamy 1 (jeden szablon Poda) i zakładamy, że będzie na każdym nodzie, 
        # ale dla planowania zasobów musimy wiedzieć, ile nodów klaster ma.
        # Bezpieczniej jest traktować DaemonSet jako 1, chyba że mamy dostęp do API nodów. 
        # Trzymamy się 'spec.replicas' dla bezpieczeństwa i prostoty.
        
        replicas = item.get('spec', {}).get('replicas', 0)
        
        # Wyjątek dla DaemonSet - pomijamy, jeśli nie chcemy zliczać zasobów na nodach.
        # Jeśli chcemy zliczyć zasoby, musielibyśmy pobrać liczbę nodów (oc get nodes).
        # Dla uproszczenia, sprawdzamy, czy to DaemonSet i go pomijamy.
        if kind == 'DaemonSet':
            print(f"   [INFO] Pomijam DaemonSet/{name}. Zasoby na nim powinny być sumowane osobno (mnożąc przez liczbę Nodów).")
            continue

        if replicas <= 0:
            continue
        
        # Ścieżka do szablonu Poda jest taka sama dla Deployment/StatefulSet/DeploymentConfig
        containers = item.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])

        pod_cpu_request_m = 0.0
        pod_cpu_limit_m = 0.0
        pod_mem_request_mb = 0.0
        pod_mem_limit_mb = 0.0
        
        for container in containers:
            resources = container.get('resources', {})
            
            # Pobieranie requestów i limitów
            cpu_req = resources.get('requests', {}).get('cpu', '')
            mem_req = resources.get('requests', {}).get('memory', '')
            cpu_lim = resources.get('limits', {}).get('cpu', '')
            mem_lim = resources.get('limits', {}).get('memory', '')

            # Konwersja i sumowanie dla pojedynczego Poda
            pod_cpu_request_m += convert_cpu_to_m(cpu_req)
            pod_cpu_limit_m += convert_cpu_to_m(cpu_lim)
            pod_mem_request_mb += convert_memory_to_mib(mem_req)
            pod_mem_limit_mb += convert_memory_to_mib(mem_lim)

        # Agregacja do sumy globalnej (mnożenie przez repliki)
        total_cpu_request_m += pod_cpu_request_m * replicas
        total_cpu_limit_m += pod_cpu_limit_m * replicas
        total_mem_request_mb += pod_mem_request_mb * replicas
        total_mem_limit_mb += pod_mem_limit_mb * replicas

    # --- Wynikowy Raport ---
    
    print("\n=====================================================")
    print(f"   📌 SUMARYCZNE ZASOBY DLA {namespace}")
    print("=====================================================")
    
    # Przeliczenie na czytelne jednostki
    final_cpu_req_core = round(total_cpu_request_m / 1000, 2)
    final_cpu_lim_core = round(total_cpu_limit_m / 1000, 2)
    final_mem_req_gib = round(total_mem_request_mb / 1024, 2)
    final_mem_lim_gib = round(total_mem_limit_mb / 1024, 2)
    
    print(f"   CPU REQUESTS: **{final_cpu_req_core} Core** ({round(total_cpu_request_m)}m)")
    print(f"   CPU LIMITS:   **{final_cpu_lim_core} Core** ({round(total_cpu_limit_m)}m)")
    print("-----------------------------------------------------")
    print(f"   MEM REQUESTS: **{final_mem_req_gib} GiB** ({round(total_mem_request_mb)} MiB)")
    print(f"   MEM LIMITS:   **{final_mem_lim_gib} GiB** ({round(total_mem_limit_mb)} MiB)")
    print("=====================================================")
    print("\n*Uwaga: Wartości Request to wymagana rezerwacja zasobów na nodach.")

# --- Uruchomienie skryptu ---

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Resource Planner (OC-Hybrid).")
    parser.add_argument("--namespace", required=True, help="Nazwa przestrzeni nazw OpenShift/Kubernetes.")
    
    args = parser.parse_args()
    
    print("--- ⚙️ Uruchamianie skryptu hybrydowego (Python + oc) ---")
    generate_resource_report(args.namespace)