import sys
import argparse
from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

# Stałe
MEMORY_MULTIPLIERS = {
    'Ki': 1 / 1024,
    'Mi': 1,
    'Gi': 1024,
    'Ti': 1024 * 1024,
}
CPU_MULTIPLIERS = {
    'm': 1,      # milicore
    '': 1000     # core
}

def convert_memory_to_mib(value_str):
    """Konwertuje wartość pamięci (np. '1Gi', '256Mi') na liczbę MiB."""
    if not value_str:
        return 0
        
    for unit, multiplier in MEMORY_MULTIPLIERS.items():
        if value_str.endswith(unit):
            # Używamy try/except dla bezpieczeństwa parsowania liczby
            try:
                num = float(value_str[:-len(unit)])
                return num * multiplier
            except ValueError:
                return 0
    
    # Jeśli jednostka nie została znaleziona, zakładamy MiB lub ignorujemy
    try:
        return float(value_str) # Traktowanie gołych liczb jako MiB
    except ValueError:
        return 0

def convert_cpu_to_m(value_str):
    """Konwertuje wartość CPU (np. '1', '500m') na liczbę milicore (m)."""
    if not value_str:
        return 0

    if value_str.endswith('m'):
        # Wartość jest już w milicore
        try:
            return float(value_str[:-1])
        except ValueError:
            return 0
    
    # Wartość jest w core (np. '0.5' lub '1')
    try:
        num = float(value_str)
        return num * 1000
    except ValueError:
        return 0

def generate_resource_report(namespace):
    """Generuje sumaryczny raport zasobów dla danej przestrzeni nazw."""
    
    print(f"--- 📊 Raport Zasobów OpenShift ---")
    print(f"Namespace: **{namespace}**")
    print("Ładowanie konfiguracji klastra...")

    try:
        # Ładuje konfigurację z ~/.kube/config (lub z wewnątrz Poda)
        config.load_kube_config() 
    except config.ConfigException:
        print("🚨 Błąd: Nie można załadować konfiguracji klastra.")
        print("Upewnij się, że jesteś zalogowany (oc login) lub masz poprawny plik ~/.kube/config.")
        sys.exit(1)

    # API Kubernetes (działa dla OpenShift)
    v1 = client.CoreV1Api()
    apps_v1 = client.AppsV1Api()
    
    # Inicjalizacja sumatorów
    total_cpu_request_m = 0.0
    total_cpu_limit_m = 0.0
    total_mem_request_mb = 0.0
    total_mem_limit_mb = 0.0
    
    # 1. Pobieranie Deploymentów
    try:
        deployments = apps_v1.list_namespaced_deployment(namespace=namespace).items
    except ApiException as e:
        print(f"⚠️ Błąd dostępu do Deploymentów: {e.reason}. Sprawdź uprawnienia.")
        return

    # 2. Pobieranie DeploymentConfigs (typowych dla OpenShift)
    # Wymaga użycia niestandardowego API (Custom Objects API)
    custom_api = client.CustomObjectsApi()
    deployment_configs = []
    try:
        # Grupa: apps.openshift.io, Wersja: v1, Plural: deploymentconfigs
        dc_list = custom_api.list_namespaced_custom_object(
            group="apps.openshift.io",
            version="v1",
            name_plural="deploymentconfigs",
            namespace=namespace
        )
        deployment_configs = dc_list.get('items', [])
    except ApiException as e:
        if e.status != 404: # Ignorujemy błąd 404, jeśli DeploymentConfigs nie istnieją
            print(f"⚠️ Błąd dostępu do DeploymentConfigs: {e.reason}. Sprawdź uprawnienia.")
            
    # Łączenie wszystkich zasobów Deployment (DC i Deployment)
    resources_to_process = deployments + deployment_configs

    if not resources_to_process:
        print("Brak Deploymentów lub DeploymentConfigs w tej przestrzeni nazw.")
        return

    # Przetwarzanie wszystkich zasobów
    print(f"Przetwarzam {len(resources_to_process)} Deploymentów/DeploymentConfigs...")
    
    for item in resources_to_process:
        # Normalizacja dostępu do danych, ponieważ DC (dict) i Deployment (obiekt) są różne
        if isinstance(item, client.V1Deployment):
            # Deployment Kubernetes (obiekt)
            name = item.metadata.name
            replicas = item.spec.replicas if item.spec.replicas is not None else 0
            containers = item.spec.template.spec.containers
        else:
            # DeploymentConfig OpenShift (słownik z Custom Objects API)
            name = item['metadata']['name']
            replicas = item.get('spec', {}).get('replicas', 0)
            containers = item.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])

        if replicas <= 0:
            continue
            
        pod_cpu_request_m = 0.0
        pod_cpu_limit_m = 0.0
        pod_mem_request_mb = 0.0
        pod_mem_limit_mb = 0.0
        
        for container in containers:
            # Normalizacja dostępu do kontenerów (dla DeploymentConfig to dict, dla Deployment to obiekt)
            resources = container.resources if hasattr(container, 'resources') else container.get('resources', {})
            
            # Pobieranie wartości
            cpu_req = resources.requests.get('cpu') if hasattr(resources, 'requests') and resources.requests else resources.get('requests', {}).get('cpu')
            mem_req = resources.requests.get('memory') if hasattr(resources, 'requests') and resources.requests else resources.get('requests', {}).get('memory')
            cpu_lim = resources.limits.get('cpu') if hasattr(resources, 'limits') and resources.limits else resources.get('limits', {}).get('cpu')
            mem_lim = resources.limits.get('memory') if hasattr(resources, 'limits') and resources.limits else resources.get('limits', {}).get('memory')

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

# --- Uruchomienie skryptu ---

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Resource Planner.")
    parser.add_argument("--namespace", required=True, help="Nazwa przestrzeni nazw OpenShift/Kubernetes.")
    
    args = parser.parse_args()
    
    generate_resource_report(args.namespace)