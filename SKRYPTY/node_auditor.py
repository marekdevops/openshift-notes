import sys
import argparse
import json
import subprocess
from tabulate import tabulate  # pip install tabulate
from collections import defaultdict

# --- Konwersja jednostek ---

MEMORY_MULTIPLIERS = {
    'Ki': 1/1024, 'Mi': 1, 'Gi': 1024, 'Ti': 1024*1024,
    'K':  1/1024, 'M':  1, 'G':  1024, 'T':  1024*1024,
}

def convert_memory_to_mib(value_str):
    if not value_str: return 0.0
    temp = value_str.replace('i', '')
    for unit, mult in MEMORY_MULTIPLIERS.items():
        if temp.endswith(unit):
            try:
                return float(temp[:-len(unit)]) * mult
            except ValueError:
                return 0.0
    try:
        return float(value_str)
    except ValueError:
        return 0.0

def convert_cpu_to_mcores(value_str):
    if not value_str: return 0.0
    s = str(value_str).strip()
    try:
        if s.endswith('m'):
            return float(s[:-1])
        return float(s) * 1000
    except ValueError:
        return 0.0

# --- Pobieranie danych z OC ---

def get_oc_json(resource, all_namespaces=False):
    command = ['oc', 'get', resource]
    if all_namespaces:
        command.append('--all-namespaces')
    command.extend(['-o', 'json'])
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError:
        print(f"Blad 'oc get {resource}': Sprawdz uprawnienia.")
        if 'pods' in resource:
            return {'items': []}
        sys.exit(1)
    except FileNotFoundError:
        print("Blad: Brak polecenia 'oc' w PATH.")
        sys.exit(1)

def get_nodes_data():
    print("Pobieranie danych o nodach...")
    nodes_data = get_oc_json('nodes')
    node_metrics = {}
    for node in nodes_data.get('items', []):
        name   = node['metadata']['name']
        status = node.get('status', {})
        node_metrics[name] = {
            'allocatable_mib':   convert_memory_to_mib(status.get('allocatable', {}).get('memory', '0Mi')),
            'allocatable_cpu_m': convert_cpu_to_mcores(status.get('allocatable', {}).get('cpu', '0')),
            'requested_mib':     0.0,
            'requested_cpu_m':   0.0,
        }
    return node_metrics

def get_pods_requests(node_metrics):
    print("Sumowanie requests z podow (CPU + MEM)...")
    pods_data = get_oc_json('pods', all_namespaces=True)
    for pod in pods_data.get('items', []):
        node_name = pod.get('spec', {}).get('nodeName')
        if not node_name or node_name not in node_metrics:
            continue
        for container in pod.get('spec', {}).get('containers', []):
            req = container.get('resources', {}).get('requests', {})
            node_metrics[node_name]['requested_mib']   += convert_memory_to_mib(req.get('memory', ''))
            node_metrics[node_name]['requested_cpu_m'] += convert_cpu_to_mcores(req.get('cpu', ''))
    return node_metrics

# --- Raport ---

def generate_report(target_unit='GiB', migration_buffer_pct=20):
    try:
        from tabulate import tabulate
    except ImportError:
        print("Wymagana biblioteka 'tabulate': pip install tabulate")
        sys.exit(1)

    node_metrics = get_nodes_data()
    node_metrics = get_pods_requests(node_metrics)

    unit_div  = 1024.0 if target_unit.upper() in ('GIB', 'GI') else 1.0
    unit_name = "GiB"  if target_unit.upper() in ('GIB', 'GI') else "MiB"

    print(f"\n{'='*78}")
    print(f"   RAPORT NODOW: ALOKACJA VS COMMIT  (RAM: {unit_name} | CPU: cores)")
    print(f"{'='*78}")

    report_data = []
    tot_alloc_mem = tot_req_mem = 0.0
    tot_alloc_cpu = tot_req_cpu = 0.0

    for node_name, m in node_metrics.items():
        alloc_mem = m['allocatable_mib']
        req_mem   = m['requested_mib']
        alloc_cpu = m['allocatable_cpu_m']
        req_cpu   = m['requested_cpu_m']
        free_mem  = max(alloc_mem - req_mem, 0.0)
        free_cpu  = max(alloc_cpu - req_cpu, 0.0)
        pct_mem   = (req_mem / alloc_mem * 100) if alloc_mem > 0 else 0.0
        pct_cpu   = (req_cpu / alloc_cpu * 100) if alloc_cpu > 0 else 0.0

        tot_alloc_mem += alloc_mem
        tot_req_mem   += req_mem
        tot_alloc_cpu += alloc_cpu
        tot_req_cpu   += req_cpu

        report_data.append([
            node_name,
            f"{alloc_cpu/1000:.1f}",
            f"{req_cpu/1000:.2f}",
            f"{free_cpu/1000:.2f}",
            f"{pct_cpu:.1f}%",
            f"{alloc_mem/unit_div:.1f}",
            f"{req_mem/unit_div:.1f}",
            f"{free_mem/unit_div:.1f}",
            f"{pct_mem:.1f}%",
        ])

    # wiersz TOTAL
    tot_free_mem = max(tot_alloc_mem - tot_req_mem, 0.0)
    tot_free_cpu = max(tot_alloc_cpu - tot_req_cpu, 0.0)
    tot_pct_mem  = (tot_req_mem / tot_alloc_mem * 100) if tot_alloc_mem > 0 else 0.0
    tot_pct_cpu  = (tot_req_cpu / tot_alloc_cpu * 100) if tot_alloc_cpu > 0 else 0.0

    report_data.append([
        "=== TOTAL ===",
        f"{tot_alloc_cpu/1000:.1f}",
        f"{tot_req_cpu/1000:.2f}",
        f"{tot_free_cpu/1000:.2f}",
        f"{tot_pct_cpu:.1f}%",
        f"{tot_alloc_mem/unit_div:.1f}",
        f"{tot_req_mem/unit_div:.1f}",
        f"{tot_free_mem/unit_div:.1f}",
        f"{tot_pct_mem:.1f}%",
    ])

    headers = [
        "WEZEL",
        "CPU alloc\n(cores)", "CPU req\n(cores)", "CPU wolne\n(cores)", "CPU%",
        f"MEM alloc\n({unit_name})", f"MEM req\n({unit_name})", f"MEM wolne\n({unit_name})", "MEM%",
    ]

    print(tabulate(report_data, headers=headers, tablefmt="fancy_grid", numalign="right"))

    # --- Sekcja planowania migracji ---
    buf         = migration_buffer_pct / 100.0
    rec_cpu     = tot_req_cpu * (1 + buf)
    rec_mem     = tot_req_mem * (1 + buf)
    tight_cpu   = tot_req_cpu * 1.10
    tight_mem   = tot_req_mem * 1.10

    print(f"\n{'='*78}")
    print(f"   PLAN MIGRACJI NA NOWY KLASTER")
    print(f"{'='*78}")
    print(f"\n  Minimum (same requests — zero headroom):")
    print(f"    CPU : {tot_req_cpu/1000:.2f} cores")
    print(f"    RAM : {tot_req_mem/unit_div:.1f} {unit_name}")
    print(f"\n  Bezpieczne minimum (+10% bufor na uruchamianie/restart podow):")
    print(f"    CPU : {tight_cpu/1000:.2f} cores")
    print(f"    RAM : {tight_mem/unit_div:.1f} {unit_name}")
    print(f"\n  Rekomendacja migracyjna (+{migration_buffer_pct}% headroom na nowym klastrze):")
    print(f"    CPU : {rec_cpu/1000:.2f} cores")
    print(f"    RAM : {rec_mem/unit_div:.1f} {unit_name}")
    print(f"\n  Uwagi:")
    print(f"    - Powyzsze liczby bazuja na pod REQUESTS (gwarantowane), nie na")
    print(f"      rzeczywistym zuzyciu. Aktualny narzut klastra (system pods,")
    print(f"      monitoring, ingress) juz jest wliczony w te sumy.")
    print(f"    - Dla VM-ek (KubeVirt/OCP Virt) requests VMI moga roznic sie od")
    print(f"      spec CPU/RAM. Uzyj node-over-capacity.py dla dokladniejszych danych.")
    print(f"    - Jesli planujesz migracje etapami, mozesz startowac od 'bezpiecznego")
    print(f"      minimum' i skalowac w gore po weryfikacji obciazenia.")
    print()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenShift Node Capacity Auditor.")
    parser.add_argument("--memory-unit", default="GiB",
                        help="Jednostka pamieci (MiB, GiB — domyslnie GiB)")
    parser.add_argument("--buffer", type=int, default=20,
                        help="Bufor migracji w %% (domyslnie 20)")
    args = parser.parse_args()

    print("--- Audyt nodow: CPU + MEM ---")
    generate_report(args.memory_unit, args.buffer)
