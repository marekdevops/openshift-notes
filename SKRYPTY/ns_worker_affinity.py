#!/usr/bin/env python3
"""
OCP Namespace → Worker Affinity & Resource Usage Analyzer

Grupuje zuzycie CPU/MEM (requests) per namespace × worker node.
Wykrywa mechanizm wiazania:
  - adnotacja openshift.io/node-selector na namespace
  - nodeSelector na podach

Uzycie:
  python3 ns_worker_affinity.py
  python3 ns_worker_affinity.py --namespace produkcja
  python3 ns_worker_affinity.py --min-pods 3
  python3 ns_worker_affinity.py --warn-cpu 60 --warn-mem 60
"""

import sys
import argparse
import json
import subprocess
from collections import defaultdict

RED    = "\033[91m"
YELLOW = "\033[93m"
GREEN  = "\033[92m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

MEMORY_MULTIPLIERS = {
    'Ki': 1/1024, 'Mi': 1, 'Gi': 1024, 'Ti': 1024*1024,
    'K':  1/1024, 'M':  1, 'G':  1024, 'T':  1024*1024,
}

def convert_memory_to_mib(value_str):
    if not value_str: return 0.0
    temp = str(value_str).replace('i', '')
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

def fmt_cpu(mcores):
    if mcores >= 1000:
        return "{:.2f}c".format(mcores / 1000)
    return "{:.0f}m".format(mcores)

def fmt_mib(mib):
    if mib >= 1024:
        return "{:.1f} GiB".format(mib / 1024)
    return "{:.0f} MiB".format(mib)

def color_pct(pct, warn=70, crit=90):
    s = "{:.1f}%".format(pct)
    if pct >= crit:
        return RED + BOLD + s + RESET
    elif pct >= warn:
        return YELLOW + s + RESET
    return GREEN + s + RESET


# --- OC helpers ---

def get_oc_json(resource, all_namespaces=False, namespace=None):
    cmd = ['oc', 'get', resource]
    if all_namespaces:
        cmd.append('--all-namespaces')
    elif namespace:
        cmd += ['-n', namespace]
    cmd += ['-o', 'json']
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        if result.returncode != 0:
            print(RED + "Blad oc: " + result.stderr.strip() + RESET, file=sys.stderr)
            return {'items': []}
        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        print(RED + "Timeout: " + resource + RESET, file=sys.stderr)
        return {'items': []}
    except json.JSONDecodeError as e:
        print(RED + "JSON error: " + str(e) + RESET, file=sys.stderr)
        return {'items': []}
    except FileNotFoundError:
        print(RED + "Blad: brak 'oc' w PATH." + RESET)
        sys.exit(1)


# --- Pobieranie danych ---

def get_worker_nodes():
    """dict: node_name -> {allocatable_cpu_m, allocatable_mib, labels}"""
    print("Pobieranie worker nodow...")
    data = get_oc_json('nodes')
    workers = {}
    for node in data.get('items', []):
        labels = node['metadata'].get('labels', {})
        if 'node-role.kubernetes.io/worker' not in labels:
            continue
        name   = node['metadata']['name']
        status = node.get('status', {})
        workers[name] = {
            'allocatable_cpu_m': convert_cpu_to_mcores(status.get('allocatable', {}).get('cpu', '0')),
            'allocatable_mib':   convert_memory_to_mib(status.get('allocatable', {}).get('memory', '0Mi')),
            'labels': {k: v for k, v in labels.items()
                       if not k.startswith('node-role.kubernetes.io/')
                       and not k.startswith('kubernetes.io/')
                       and not k.startswith('beta.kubernetes.io/')},
        }
    return workers

def get_namespaces():
    """dict: ns_name -> {node_selector (z adnotacji OCP)}"""
    print("Pobieranie namespace'ow...")
    data = get_oc_json('namespaces')
    result = {}
    for item in data.get('items', []):
        name        = item['metadata']['name']
        annotations = item['metadata'].get('annotations', {})
        result[name] = {
            'node_selector': annotations.get('openshift.io/node-selector', ''),
        }
    return result

def get_pods(filter_ns=None):
    """
    Lista podow (tylko Running/Pending na workerach) z polami:
      namespace, node, cpu_req_m, mem_req_mib, node_selector
    """
    print("Pobieranie podow{}...".format(
        " (ns: {})".format(filter_ns) if filter_ns else " (wszystkie ns)"))
    data = get_oc_json('pods',
                       all_namespaces=(filter_ns is None),
                       namespace=filter_ns)
    pods = []
    for pod in data.get('items', []):
        node_name = pod.get('spec', {}).get('nodeName')
        if not node_name:
            continue
        phase = pod.get('status', {}).get('phase', '')
        if phase not in ('Running', 'Pending'):
            continue

        ns     = pod['metadata']['namespace']
        ns_sel = pod.get('spec', {}).get('nodeSelector', {})

        cpu_req = mem_req = 0.0
        for container in pod.get('spec', {}).get('containers', []):
            req      = container.get('resources', {}).get('requests', {})
            cpu_req += convert_cpu_to_mcores(req.get('cpu', ''))
            mem_req += convert_memory_to_mib(req.get('memory', ''))

        pods.append({
            'namespace':     ns,
            'node':          node_name,
            'cpu_req_m':     cpu_req,
            'mem_req_mib':   mem_req,
            'node_selector': ns_sel,
        })
    return pods


# --- Analiza ---

def analyze(pods, workers):
    """
    Zwraca:
      usage[(ns, node)] = {cpu_m, mem_mib, pods}
      selectors[ns]     = set of "key=value" strings (tylko niestandardowe)
    """
    usage     = defaultdict(lambda: {'cpu_m': 0.0, 'mem_mib': 0.0, 'pods': 0})
    selectors = defaultdict(set)

    for pod in pods:
        node = pod['node']
        if node not in workers:
            continue
        ns = pod['namespace']
        usage[(ns, node)]['cpu_m']   += pod['cpu_req_m']
        usage[(ns, node)]['mem_mib'] += pod['mem_req_mib']
        usage[(ns, node)]['pods']    += 1

        # zbieraj tylko niestandardowe nodeSelector (pomijaj node-role i kubernetes.io)
        for k, v in pod['node_selector'].items():
            if (not k.startswith('node-role.kubernetes.io/')
                    and not k.startswith('kubernetes.io/')
                    and not k.startswith('beta.kubernetes.io/')):
                selectors[ns].add("{}={}".format(k, v) if v else k)

    return usage, selectors


# --- Raport ---

SEP = "─" * 108

def print_report(usage, selectors, workers, namespaces,
                 min_pods, warn_cpu, warn_mem, filter_ns):

    all_ns = sorted({ns for ns, _ in usage.keys()})
    if filter_ns:
        all_ns = [n for n in all_ns if n == filter_ns]

    print("\n" + BOLD + CYAN + "=" * 108 + RESET)
    print(BOLD + CYAN + "  NAMESPACE → WORKER: ZUZYCIE CPU/MEM (requests)" + RESET)
    print(BOLD + CYAN + "=" * 108 + RESET)

    grand_cpu = grand_mem = grand_pods = 0

    for ns in all_ns:
        nodes_for_ns = sorted(node for (n, node) in usage.keys() if n == ns)
        total_pods = sum(usage[(ns, node)]['pods'] for node in nodes_for_ns)

        if total_pods < min_pods:
            continue

        total_cpu = sum(usage[(ns, node)]['cpu_m']   for node in nodes_for_ns)
        total_mem = sum(usage[(ns, node)]['mem_mib'] for node in nodes_for_ns)
        grand_cpu  += total_cpu
        grand_mem  += total_mem
        grand_pods += total_pods

        # --- nagłówek namespace ---
        print("\n  " + BOLD + "{:<45}".format(ns) + RESET
              + "  pods: {:>4}   CPU: {:>8}   MEM: {}".format(
                  total_pods, fmt_cpu(total_cpu), fmt_mib(total_mem)))

        # mechanizm bindingu
        ns_ann = namespaces.get(ns, {}).get('node_selector', '')
        ns_sel = selectors.get(ns, set())
        if ns_ann:
            print("  " + CYAN + "  [ns annotation]   openshift.io/node-selector: " + ns_ann + RESET)
        if ns_sel:
            print("  " + CYAN + "  [pod nodeSelector] " + ", ".join(sorted(ns_sel)) + RESET)
        if not ns_ann and not ns_sel:
            print("  " + CYAN + "  [brak explicit bindingu — domyslny scheduler]" + RESET)

        # --- tabela per worker ---
        print("  " + SEP)
        print(BOLD + "  {:<32} {:>5}  {:>8}  {:>9}  {:>7}    {:>9}  {:>9}  {:>7}".format(
            "WORKER", "PODS", "CPU req", "CPU alloc", "CPU%",
            "MEM req", "MEM alloc", "MEM%"
        ) + RESET)
        print("  " + SEP)

        for node in nodes_for_ns:
            nd = usage[(ns, node)]
            wi = workers.get(node)
            if not wi:
                continue

            cpu_pct = (nd['cpu_m']   / wi['allocatable_cpu_m'] * 100) if wi['allocatable_cpu_m'] > 0 else 0
            mem_pct = (nd['mem_mib'] / wi['allocatable_mib']   * 100) if wi['allocatable_mib']   > 0 else 0

            # znane labele workera (z-pominieciem node-role/k8s)
            worker_tags = ", ".join(
                "{}={}".format(k, v) for k, v in sorted(wi['labels'].items())
            )

            print("  {:<32} {:>5}  {:>8}  {:>9}  {:>17}    {:>9}  {:>9}  {:>17}".format(
                node,
                nd['pods'],
                fmt_cpu(nd['cpu_m']),
                fmt_cpu(wi['allocatable_cpu_m']),
                color_pct(cpu_pct, warn_cpu),
                fmt_mib(nd['mem_mib']),
                fmt_mib(wi['allocatable_mib']),
                color_pct(mem_pct, warn_mem),
            ))
            if worker_tags:
                print("  " + " " * 32 + CYAN + "  labels: " + worker_tags + RESET)

        print("  " + SEP)

    # --- TOTAL ---
    print("\n" + BOLD + "─" * 108 + RESET)
    print(BOLD + "  TOTAL   pods: {:>5}   CPU commit: {:>9}   MEM commit: {}".format(
        grand_pods, fmt_cpu(grand_cpu), fmt_mib(grand_mem)) + RESET)
    print(BOLD + "─" * 108 + RESET)
    print()


# --- Main ---

def main():
    parser = argparse.ArgumentParser(
        description="OCP Namespace-Worker affinity & resource usage analyzer")
    parser.add_argument('--namespace', '-n',  help="Filtruj po namespace")
    parser.add_argument('--min-pods',  type=int, default=1,
                        help="Pomin namespace z mniej niz N podami (domyslnie 1)")
    parser.add_argument('--warn-cpu',  type=float, default=70,
                        help="Prog ostrzezenia CPU %% (domyslnie 70)")
    parser.add_argument('--warn-mem',  type=float, default=70,
                        help="Prog ostrzezenia MEM %% (domyslnie 70)")
    args = parser.parse_args()

    workers    = get_worker_nodes()
    namespaces = get_namespaces()
    pods       = get_pods(filter_ns=args.namespace)

    print("Znaleziono {} worker nodow, {} podow.".format(len(workers), len(pods)))

    usage, selectors = analyze(pods, workers)

    print_report(usage, selectors, workers, namespaces,
                 min_pods=args.min_pods,
                 warn_cpu=args.warn_cpu,
                 warn_mem=args.warn_mem,
                 filter_ns=args.namespace)


if __name__ == "__main__":
    main()
