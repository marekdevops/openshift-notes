#!/usr/bin/env python3
"""
worker_requests_limits.py
=========================
Raport REQUESTS i LIMITS (CPU + RAM) per worker / namespace, z rozbiciem na
poszczegolne Deploymenty (a scislej: workloady wlascicielskie podow), ktore
skladaja sie na sume zarezerwowanych zasobow.

Jak liczy:
    Bierze RUNNING pody (te faktycznie zajmuja miejsce na node),
    filtruje po --node i/lub --namespace, sumuje resources.requests/limits
    ze WSZYSTKICH kontenerow (initContainers pomijane) i grupuje wynik po
    workloadzie wlascicielskim (Deployment / StatefulSet / DaemonSet / itp.).
    Pod -> ReplicaSet -> Deployment jest rozwiazywany po ownerReferences.

Wymagania:
    - oc (zalogowany: oc login)
    - pip install tabulate

Przyklady:
    python3 worker_requests_limits.py --node worker-03
    python3 worker_requests_limits.py --namespace my-app
    python3 worker_requests_limits.py --node worker-03 --namespace my-app
    python3 worker_requests_limits.py                      # caly klaster
"""

import sys
import json
import argparse
import subprocess
from collections import defaultdict

try:
    from tabulate import tabulate
except ImportError:
    sys.exit("Brak modulu 'tabulate'. Zainstaluj: pip install tabulate")

# --- Konwersja jednostek ---

MEMORY_MULTIPLIERS = {  # do MiB
    'Ki': 1 / 1024, 'Mi': 1, 'Gi': 1024, 'Ti': 1024 * 1024,
    'K': 1 / 1024, 'M': 1, 'G': 1024, 'T': 1024 * 1024,
}


def mem_to_mib(value):
    """Wartosc pamieci (np. '256Mi', '1Gi', bajty) -> MiB."""
    if not value:
        return 0.0
    value = str(value)
    for unit, mult in MEMORY_MULTIPLIERS.items():
        if value.endswith(unit):
            try:
                return float(value[:-len(unit)]) * mult
            except ValueError:
                return 0.0
    try:  # gole bajty
        return float(value) / (1024 * 1024)
    except ValueError:
        return 0.0


def cpu_to_millicores(value):
    """Wartosc CPU (np. '500m', '2', '100n', '2u') -> milicore."""
    if not value:
        return 0.0
    value = str(value)
    try:
        if value.endswith('n'):
            return float(value[:-1]) / 1_000_000
        if value.endswith('u'):
            return float(value[:-1]) / 1_000
        if value.endswith('m'):
            return float(value[:-1])
        return float(value) * 1000  # rdzenie -> milicore
    except ValueError:
        return 0.0


# --- Wywolania oc ---

def oc_json(args):
    cmd = ['oc'] + args + ['-o', 'json']
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        sys.exit("Nie znaleziono 'oc'. Zainstaluj CLI OpenShift.")
    except subprocess.CalledProcessError as e:
        sys.exit(f"Blad 'oc {' '.join(args)}':\n{e.stderr.strip()}")
    return json.loads(out)


def build_rs_to_deploy_map(namespace):
    """Mapa nazwa-ReplicaSet -> nazwa-Deployment (aby zwinac pody do Deploymentu)."""
    args = ['get', 'replicasets']
    if namespace:
        args += ['-n', namespace]
    else:
        args += ['--all-namespaces']
    data = oc_json(args)
    mapping = {}
    for rs in data.get('items', []):
        rs_name = rs['metadata']['name']
        rs_ns = rs['metadata']['namespace']
        for owner in rs['metadata'].get('ownerReferences', []):
            if owner.get('kind') == 'Deployment':
                mapping[(rs_ns, rs_name)] = owner['name']
    return mapping


def resolve_workload(pod, rs_map):
    """Zwraca (kind, nazwa) workloadu wlascicielskiego dla poda."""
    ns = pod['metadata']['namespace']
    owners = pod['metadata'].get('ownerReferences', [])
    if not owners:
        return ('Pod', pod['metadata']['name'])
    owner = owners[0]
    kind, name = owner.get('kind'), owner.get('name')
    if kind == 'ReplicaSet':
        deploy = rs_map.get((ns, name))
        if deploy:
            return ('Deployment', deploy)
        return ('ReplicaSet', name)
    return (kind, name)


# --- Sumowanie ---

def sum_pod_resources(pod):
    """Zwraca (req_cpu_m, lim_cpu_m, req_mem_mib, lim_mem_mib) dla poda."""
    req_cpu = lim_cpu = req_mem = lim_mem = 0.0
    for c in pod['spec'].get('containers', []):
        res = c.get('resources', {})
        req = res.get('requests', {})
        lim = res.get('limits', {})
        req_cpu += cpu_to_millicores(req.get('cpu'))
        lim_cpu += cpu_to_millicores(lim.get('cpu'))
        req_mem += mem_to_mib(req.get('memory'))
        lim_mem += mem_to_mib(lim.get('memory'))
    return req_cpu, lim_cpu, req_mem, lim_mem


def fmt_cpu(m):
    return f"{m/1000:.2f}"      # rdzenie


def fmt_mem(mib):
    return f"{mib/1024:.2f}"    # GiB


def main():
    parser = argparse.ArgumentParser(
        description="Requests/Limits CPU+RAM per worker/namespace z rozbiciem na Deploymenty.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument('-n', '--namespace', help="Ogranicz do jednego namespace.")
    parser.add_argument('--node', help="Ogranicz do jednego workera (nazwa node'a).")
    parser.add_argument('--sort', choices=['lim-cpu', 'req-cpu', 'lim-mem', 'req-mem', 'name'],
                        default='lim-mem', help="Sortowanie tabeli (domyslnie: lim-mem).")
    args = parser.parse_args()

    # Pobierz Running pody z filtrami
    field_selectors = ['status.phase=Running']
    if args.node:
        field_selectors.append(f"spec.nodeName={args.node}")
    pod_args = ['get', 'pods', '--field-selector', ','.join(field_selectors)]
    if args.namespace:
        pod_args += ['-n', args.namespace]
    else:
        pod_args += ['--all-namespaces']

    pods = oc_json(pod_args).get('items', [])
    if not pods:
        scope = []
        if args.namespace:
            scope.append(f"namespace={args.namespace}")
        if args.node:
            scope.append(f"node={args.node}")
        print(f"Brak Running podow dla: {', '.join(scope) or 'caly klaster'}.")
        return

    rs_map = build_rs_to_deploy_map(args.namespace)

    # Agregacja per workload: (ns, kind, name) -> sumy + liczba podow
    agg = defaultdict(lambda: {'req_cpu': 0.0, 'lim_cpu': 0.0,
                               'req_mem': 0.0, 'lim_mem': 0.0, 'pods': 0})
    for pod in pods:
        ns = pod['metadata']['namespace']
        kind, name = resolve_workload(pod, rs_map)
        rc, lc, rm, lm = sum_pod_resources(pod)
        key = (ns, kind, name)
        agg[key]['req_cpu'] += rc
        agg[key]['lim_cpu'] += lc
        agg[key]['req_mem'] += rm
        agg[key]['lim_mem'] += lm
        agg[key]['pods'] += 1

    sort_key = {
        'lim-cpu': lambda x: x[1]['lim_cpu'],
        'req-cpu': lambda x: x[1]['req_cpu'],
        'lim-mem': lambda x: x[1]['lim_mem'],
        'req-mem': lambda x: x[1]['req_mem'],
        'name': lambda x: (x[0][0], x[0][2]),
    }[args.sort]
    rows_sorted = sorted(agg.items(), key=sort_key,
                         reverse=(args.sort != 'name'))

    # Naglowek zakresu
    scope = []
    if args.node:
        scope.append(f"node={args.node}")
    if args.namespace:
        scope.append(f"namespace={args.namespace}")
    print(f"\n=== Requests / Limits per workload  ({', '.join(scope) or 'caly klaster'}) ===\n")

    table = []
    tot = {'req_cpu': 0.0, 'lim_cpu': 0.0, 'req_mem': 0.0, 'lim_mem': 0.0, 'pods': 0}
    for (ns, kind, name), v in rows_sorted:
        table.append([
            ns, f"{kind}/{name}", v['pods'],
            fmt_cpu(v['req_cpu']), fmt_cpu(v['lim_cpu']),
            fmt_mem(v['req_mem']), fmt_mem(v['lim_mem']),
        ])
        for k in tot:
            tot[k] += v[k]

    table.append(['—', 'SUMA', tot['pods'],
                  fmt_cpu(tot['req_cpu']), fmt_cpu(tot['lim_cpu']),
                  fmt_mem(tot['req_mem']), fmt_mem(tot['lim_mem'])])

    headers = ['NAMESPACE', 'WORKLOAD', 'PODY',
               'REQ_CPU(rdz)', 'LIM_CPU(rdz)', 'REQ_MEM(GiB)', 'LIM_MEM(GiB)']
    print(tabulate(table, headers=headers, tablefmt='github'))
    print()


if __name__ == '__main__':
    main()
