#!/usr/bin/env python3
"""
OCP nodeSelector → Worker Pool → Namespace Usage Analyzer

Grupuje workery w pule wedlug nodeSelector/labelek,
pokazuje zuzycie CPU/MEM per namespace w kazdej puli.
Opcja --plan-capacity wskazuje ktore nody mozna usunac
zachowujac min 50% wolnych zasobow nad biezacym uzyciem.

Uzycie:
  python3 ns_worker_affinity.py
  python3 ns_worker_affinity.py --min-pods 3
  python3 ns_worker_affinity.py --html raport.html
  python3 ns_worker_affinity.py --plan-capacity
  python3 ns_worker_affinity.py --plan-capacity --min-free-pct 70 --html raport.html
"""

import sys
import argparse
import json
import subprocess
import datetime
import os
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

def color_pct(pct, warn=70, crit=100):
    s = "{:.1f}%".format(pct)
    if pct >= crit:
        return RED + BOLD + s + RESET
    elif pct >= warn:
        return YELLOW + s + RESET
    return GREEN + s + RESET


# ---------------------------------------------------------------------------
# OC helpers
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Pobieranie danych
# ---------------------------------------------------------------------------

SYSTEM_LABEL_PREFIXES = (
    'node-role.kubernetes.io/',
    'kubernetes.io/',
    'beta.kubernetes.io/',
    'node.kubernetes.io/',
    'topology.kubernetes.io/',
    'failure-domain.beta.kubernetes.io/',
)

def is_system_label(key):
    return any(key.startswith(p) for p in SYSTEM_LABEL_PREFIXES)

def get_worker_nodes():
    print("Pobieranie worker nodow...")
    data = get_oc_json('nodes')
    workers = {}
    for node in data.get('items', []):
        labels = node['metadata'].get('labels', {})
        if 'node-role.kubernetes.io/worker' not in labels:
            continue
        name   = node['metadata']['name']
        status = node.get('status', {})
        custom = {k: v for k, v in labels.items() if not is_system_label(k)}
        workers[name] = {
            'allocatable_cpu_m': convert_cpu_to_mcores(
                status.get('allocatable', {}).get('cpu', '0')),
            'allocatable_mib': convert_memory_to_mib(
                status.get('allocatable', {}).get('memory', '0Mi')),
            'labels': custom,
        }
    return workers

def get_namespaces():
    print("Pobieranie namespace'ow...")
    data = get_oc_json('namespaces')
    result = {}
    for item in data.get('items', []):
        name        = item['metadata']['name']
        annotations = item['metadata'].get('annotations', {})
        result[name] = {
            'node_selector': annotations.get('openshift.io/node-selector', '').strip(),
        }
    return result

def get_pods():
    print("Pobieranie podow...")
    data = get_oc_json('pods', all_namespaces=True)
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
            'node_selector': {k: v for k, v in ns_sel.items()
                              if not is_system_label(k)},
        })
    return pods


# ---------------------------------------------------------------------------
# Analiza
# ---------------------------------------------------------------------------

def parse_kv_string(s):
    result = {}
    for part in s.split(','):
        part = part.strip()
        if '=' in part:
            k, v = part.split('=', 1)
            result[k.strip()] = v.strip()
        elif part:
            result[part] = ''
    return result

def analyze(pods, workers):
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

        for k, v in pod['node_selector'].items():
            selectors[ns].add("{}={}".format(k, v) if v else k)

    return usage, selectors


def build_selector_groups(usage, selectors, namespaces, workers):
    """
    Priorytet selectora: ns annotation > pod nodeSelector > default.
    Default = TYLKO workery bez zadnych custom labelek.
    """
    ns_set    = sorted({ns for ns, _ in usage.keys()})
    group_map = {}

    for ns in ns_set:
        ann      = namespaces.get(ns, {}).get('node_selector', '')
        pod_sels = selectors.get(ns, set())

        if ann:
            sel_dict  = parse_kv_string(ann)
            sel_label = ann
            sel_type  = 'annotation'
        elif pod_sels:
            sel_dict = {}
            for kv in pod_sels:
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    sel_dict[k] = v
                else:
                    sel_dict[kv] = ''
            sel_label = ', '.join(sorted(pod_sels))
            sel_type  = 'nodeSelector'
        else:
            sel_dict  = {}
            sel_label = '(domyslny scheduler)'
            sel_type  = 'default'

        key = frozenset("{}={}".format(k, v) for k, v in sel_dict.items())

        if key not in group_map:
            if sel_dict:
                # workery ktore maja WSZYSTKIE labelki z selectora
                matching = sorted(
                    wn for wn, wi in workers.items()
                    if all(wi['labels'].get(k) == v for k, v in sel_dict.items())
                )
            else:
                # domyslny scheduler = workery BEZ zadnych custom labelek
                matching = sorted(
                    wn for wn, wi in workers.items()
                    if not wi['labels']
                )

            group_map[key] = {
                'label':         sel_label,
                'type':          sel_type,
                'selector_dict': sel_dict,
                'workers':       matching,
                'namespaces':    [],
            }

        group_map[key]['namespaces'].append(ns)

    # Pojemnosc puli
    for grp in group_map.values():
        grp['pool_cpu_m']   = sum(
            workers[w]['allocatable_cpu_m'] for w in grp['workers'] if w in workers)
        grp['pool_mem_mib'] = sum(
            workers[w]['allocatable_mib']   for w in grp['workers'] if w in workers)

    order = {'annotation': 0, 'nodeSelector': 1, 'default': 2}
    return sorted(group_map.values(), key=lambda g: (order[g['type']], g['label']))


# ---------------------------------------------------------------------------
# Capacity planning
# ---------------------------------------------------------------------------

def compute_capacity_plan(grp, usage, workers, min_free_pct=50):
    """
    Dla kazdego noda w puli oblicza jego obciazenie,
    nastepnie symuluje usuwanie (od najmniej obciazonych),
    zatrzymujac sie gdy: remaining_capacity < usage * (1 + min_free_pct/100).

    Nie usuwa nodow z unikalna labelka (jedyni nosiciele danej wartosci).
    """
    pool_workers = [w for w in grp['workers'] if w in workers]

    # Sumaryczne zuzycie puli
    total_cpu = sum(
        usage.get((ns, w), {}).get('cpu_m', 0)
        for ns in grp['namespaces'] for w in pool_workers
    )
    total_mem = sum(
        usage.get((ns, w), {}).get('mem_mib', 0)
        for ns in grp['namespaces'] for w in pool_workers
    )

    # Zuzycie per node (pody ze wszystkich ns tej puli)
    node_load = {}
    for wname in pool_workers:
        cpu = sum(usage.get((ns, wname), {}).get('cpu_m', 0)   for ns in grp['namespaces'])
        mem = sum(usage.get((ns, wname), {}).get('mem_mib', 0) for ns in grp['namespaces'])
        node_load[wname] = {'cpu_m': cpu, 'mem_mib': mem}

    # Unikalne labelki — node jest jedynym nosicielem danego key=value w puli
    label_holders = defaultdict(set)
    for wname in pool_workers:
        for k, v in workers[wname]['labels'].items():
            label_holders["{}={}".format(k, v)].add(wname)

    unique_label_nodes = {
        wname for wname in pool_workers
        if any(len(holders) == 1 for holders in label_holders.values()
               if wname in holders)
    }

    # Prog: remaining_capacity >= total_usage * (1 + min_free_pct/100)
    safety = 1.0 + min_free_pct / 100.0
    needed_cpu = total_cpu * safety
    needed_mem = total_mem * safety

    # Sortuj od najmniej obciazonego (metryka: max(cpu%, mem%) wzgledem allokowalnego)
    def load_score(wname):
        wi  = workers[wname]
        nl  = node_load[wname]
        pct_cpu = nl['cpu_m']   / wi['allocatable_cpu_m'] if wi['allocatable_cpu_m'] > 0 else 0
        pct_mem = nl['mem_mib'] / wi['allocatable_mib']   if wi['allocatable_mib']   > 0 else 0
        return max(pct_cpu, pct_mem)

    sorted_nodes = sorted(pool_workers, key=load_score)

    remaining_cpu = grp['pool_cpu_m']
    remaining_mem = grp['pool_mem_mib']
    to_remove     = []
    kept          = []

    for wname in sorted_nodes:
        wi      = workers[wname]
        new_cpu = remaining_cpu - wi['allocatable_cpu_m']
        new_mem = remaining_mem - wi['allocatable_mib']

        if wname in unique_label_nodes:
            kept.append((wname, 'unique-label'))
            continue

        if new_cpu >= needed_cpu and new_mem >= needed_mem:
            to_remove.append(wname)
            remaining_cpu = new_cpu
            remaining_mem = new_mem
        else:
            kept.append((wname, 'needed'))

    freed_cpu = grp['pool_cpu_m'] - remaining_cpu
    freed_mem = grp['pool_mem_mib'] - remaining_mem

    return {
        'total_cpu_m':       total_cpu,
        'total_mem_mib':     total_mem,
        'needed_cpu_m':      needed_cpu,
        'needed_mem_mib':    needed_mem,
        'node_load':         node_load,
        'unique_label_nodes': unique_label_nodes,
        'sorted_nodes':      sorted_nodes,
        'to_remove':         to_remove,
        'kept':              kept,
        'remaining_cpu_m':   remaining_cpu,
        'remaining_mem_mib': remaining_mem,
        'freed_cpu_m':       freed_cpu,
        'freed_mem_mib':     freed_mem,
    }


# ---------------------------------------------------------------------------
# Terminal — raport uzyccia per pula
# ---------------------------------------------------------------------------

def print_report(groups, usage, workers, min_pods, warn_cpu, warn_mem):
    W = 112
    print("\n" + BOLD + CYAN + "=" * W + RESET)
    print(BOLD + CYAN + "  PULE WORKEROW (nodeSelector) → NAMESPACE: ZUZYCIE CPU/MEM" + RESET)
    print(BOLD + CYAN + "=" * W + RESET)

    type_lbl = {
        'annotation':   'ns annotation (openshift.io/node-selector)',
        'nodeSelector': 'pod nodeSelector',
        'default':      'domyslny scheduler (nody bez labelek)',
    }

    grand_cpu = grand_mem = grand_pods = 0

    for grp in groups:
        pool_cpu = grp['pool_cpu_m']
        pool_mem = grp['pool_mem_mib']

        # biezace sumaryczne zuzycie puli
        used_cpu = sum(
            usage.get((ns, w), {}).get('cpu_m', 0)
            for ns in grp['namespaces'] for w in grp['workers']
        )
        used_mem = sum(
            usage.get((ns, w), {}).get('mem_mib', 0)
            for ns in grp['namespaces'] for w in grp['workers']
        )
        used_pods = sum(
            usage.get((ns, w), {}).get('pods', 0)
            for ns in grp['namespaces'] for w in grp['workers']
        )
        util_cpu = used_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
        util_mem = used_mem / pool_mem * 100 if pool_mem > 0 else 0

        ns_active = [
            ns for ns in grp['namespaces']
            if sum(usage.get((ns, w), {}).get('pods', 0)
                   for w in grp['workers']) >= min_pods
        ]
        if not ns_active and not grp['workers']:
            continue

        print("\n  " + BOLD + "nodeSelector: " + grp['label'] + RESET
              + "  [" + type_lbl[grp['type']] + "]")
        print("  " + "─" * (W - 2))

        # workers + pojemnosc + zuzycie
        print("  " + CYAN
              + "Workers: {}  |  Pojemnosc: CPU {} / MEM {}"
                "  |  Zuzycie: CPU {} ({})  MEM {} ({})".format(
                  len(grp['workers']),
                  fmt_cpu(pool_cpu), fmt_mib(pool_mem),
                  fmt_cpu(used_cpu), "{:.1f}%".format(util_cpu),
                  fmt_mib(used_mem), "{:.1f}%".format(util_mem),
              ) + RESET)
        for wname in grp['workers']:
            wi  = workers.get(wname)
            if not wi: continue
            lbl = ", ".join("{}={}".format(k, v) for k, v in sorted(wi['labels'].items()))
            print("    {:<34}  CPU: {:>8}  MEM: {:>10}  {}".format(
                wname,
                fmt_cpu(wi['allocatable_cpu_m']),
                fmt_mib(wi['allocatable_mib']),
                "[" + lbl + "]" if lbl else ""))

        if not ns_active:
            print("  (brak namespace z >= {} podami w tej puli)".format(min_pods))
            print("  " + "─" * (W - 2))
            continue

        # tabela ns
        print()
        print(BOLD + "  {:<42} {:>5}  {:>8}  {:>9}  {:>9}  {:>8}  {:>9}".format(
            "NAMESPACE", "PODS", "CPU req", "CPU% puli",
            "MEM req", "MEM% puli", "") + RESET)
        print("  " + "─" * (W - 2))

        g_cpu = g_mem = g_pods = 0.0
        for ns in sorted(ns_active):
            ns_cpu  = sum(usage.get((ns, w), {}).get('cpu_m', 0)   for w in grp['workers'])
            ns_mem  = sum(usage.get((ns, w), {}).get('mem_mib', 0) for w in grp['workers'])
            ns_pods = sum(usage.get((ns, w), {}).get('pods', 0)    for w in grp['workers'])
            g_cpu  += ns_cpu;  g_mem += ns_mem;  g_pods += ns_pods

            cp = ns_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
            mp = ns_mem / pool_mem * 100 if pool_mem > 0 else 0
            print("  {:<42} {:>5}  {:>8}  {:>19}  {:>9}  {}".format(
                ns, int(ns_pods), fmt_cpu(ns_cpu),
                color_pct(cp, warn_cpu),
                fmt_mib(ns_mem),
                color_pct(mp, warn_mem)))

        print("  " + "─" * (W - 2))
        tp = g_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
        mp = g_mem / pool_mem * 100 if pool_mem > 0 else 0
        print(BOLD + "  {:<42} {:>5}  {:>8}  {:>19}  {:>9}  {}".format(
            "LAZNIE PULA", int(g_pods), fmt_cpu(g_cpu),
            color_pct(tp, warn_cpu),
            fmt_mib(g_mem),
            color_pct(mp, warn_mem)) + RESET)

        grand_cpu += g_cpu;  grand_mem += g_mem;  grand_pods += g_pods

    print("\n" + BOLD + "=" * W + RESET)
    print(BOLD + "  GRAND TOTAL  pods: {}  CPU: {}  MEM: {}".format(
        int(grand_pods), fmt_cpu(grand_cpu), fmt_mib(grand_mem)) + RESET)
    print(BOLD + "=" * W + RESET + "\n")


# ---------------------------------------------------------------------------
# Terminal — plan capacity
# ---------------------------------------------------------------------------

def print_plan_capacity(groups, usage, workers, min_pods, min_free_pct):
    W = 116
    print("\n" + BOLD + CYAN + "=" * W + RESET)
    print(BOLD + CYAN + "  PLAN CAPACITY: REKOMENDACJA USUWANIA NODOW" + RESET)
    print(BOLD + CYAN + "  Cel: wolne zasoby po usunieciu >= {}% biezacego zuzycia".format(
        min_free_pct) + RESET)
    print(BOLD + CYAN + "=" * W + RESET)

    total_to_remove = []
    total_freed_cpu = total_freed_mem = 0.0

    for grp in groups:
        if not grp['workers']:
            continue

        ns_active = [
            ns for ns in grp['namespaces']
            if sum(usage.get((ns, w), {}).get('pods', 0)
                   for w in grp['workers']) >= min_pods
        ]

        plan = compute_capacity_plan(grp, usage, workers, min_free_pct)

        pool_cpu = grp['pool_cpu_m']
        pool_mem = grp['pool_mem_mib']
        used_cpu = plan['total_cpu_m']
        used_mem = plan['total_mem_mib']

        print("\n  " + BOLD + "Pula: " + grp['label'] + RESET
              + "  ({} workerow)".format(len(grp['workers'])))
        print("  " + "─" * (W - 2))
        print("  Pojemnosc puli:  CPU {} | MEM {}".format(
            fmt_cpu(pool_cpu), fmt_mib(pool_mem)))
        print("  Biezace zuzycie: CPU {} ({:.1f}%) | MEM {} ({:.1f}%)".format(
            fmt_cpu(used_cpu),
            used_cpu / pool_cpu * 100 if pool_cpu > 0 else 0,
            fmt_mib(used_mem),
            used_mem / pool_mem * 100 if pool_mem > 0 else 0))
        print("  Min. pozostawic: CPU {} | MEM {}  (zuzycie + {}% headroom)".format(
            fmt_cpu(plan['needed_cpu_m']),
            fmt_mib(plan['needed_mem_mib']),
            min_free_pct))

        # tabela nodow
        print()
        print(BOLD + "  {:<32} {:>9} {:>9} {:>7}  {:>10} {:>10} {:>7}  {:<22}".format(
            "NODE", "CPU load", "CPU alloc", "CPU%",
            "MEM load", "MEM alloc", "MEM%", "STATUS") + RESET)
        print("  " + "─" * (W - 2))

        for wname in plan['sorted_nodes']:
            wi  = workers.get(wname)
            nl  = plan['node_load'].get(wname, {})
            if not wi: continue

            cpu_pct = nl.get('cpu_m', 0)   / wi['allocatable_cpu_m'] * 100 if wi['allocatable_cpu_m'] > 0 else 0
            mem_pct = nl.get('mem_mib', 0) / wi['allocatable_mib']   * 100 if wi['allocatable_mib']   > 0 else 0

            if wname in plan['to_remove']:
                status = GREEN + "MOZNA USUNAC" + RESET
            elif wname in plan['unique_label_nodes']:
                status = YELLOW + "keep (unikalna labelka)" + RESET
            else:
                status = CYAN + "keep (potrzebny)" + RESET

            print("  {:<32} {:>9} {:>9} {:>17}  {:>10} {:>10} {:>17}  {}".format(
                wname,
                fmt_cpu(nl.get('cpu_m', 0)),
                fmt_cpu(wi['allocatable_cpu_m']),
                color_pct(cpu_pct, 50),
                fmt_mib(nl.get('mem_mib', 0)),
                fmt_mib(wi['allocatable_mib']),
                color_pct(mem_pct, 50),
                status))

        print("  " + "─" * (W - 2))

        if plan['to_remove']:
            rem_util_cpu = used_cpu / plan['remaining_cpu_m'] * 100 if plan['remaining_cpu_m'] > 0 else 0
            rem_util_mem = used_mem / plan['remaining_mem_mib'] * 100 if plan['remaining_mem_mib'] > 0 else 0

            print(GREEN + BOLD + "  Mozna usunac ({} nodow): ".format(
                len(plan['to_remove'])) + ", ".join(plan['to_remove']) + RESET)
            print("  Po usunieciu: CPU {} | MEM {}  (zuzycie: {:.1f}% CPU / {:.1f}% MEM)".format(
                fmt_cpu(plan['remaining_cpu_m']),
                fmt_mib(plan['remaining_mem_mib']),
                rem_util_cpu, rem_util_mem))
            print(CYAN + "  Zwolnione zasoby: CPU {} | MEM {}".format(
                fmt_cpu(plan['freed_cpu_m']),
                fmt_mib(plan['freed_mem_mib'])) + RESET)
            total_to_remove.extend(plan['to_remove'])
            total_freed_cpu += plan['freed_cpu_m']
            total_freed_mem += plan['freed_mem_mib']
        else:
            print(YELLOW + "  Brak nodow do usuniecia przy progu {}%.".format(
                min_free_pct) + RESET)

    print("\n" + BOLD + "=" * W + RESET)
    print(BOLD + "  PODSUMOWANIE  |  Kandydaci do usuniecia: {}  |  "
          "Zwolni sie: CPU {} | MEM {}".format(
              len(total_to_remove),
              fmt_cpu(total_freed_cpu),
              fmt_mib(total_freed_mem)) + RESET)
    if total_to_remove:
        print(BOLD + "  Nody: " + ", ".join(total_to_remove) + RESET)
    print(BOLD + "=" * W + RESET + "\n")


# ---------------------------------------------------------------------------
# HTML — CSS + JS
# ---------------------------------------------------------------------------

HTML_CSS = """
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --bg:#0d1117; --bg2:#161b22; --bg3:#1c2128;
  --border:#30363d; --border2:#21262d;
  --text:#e6edf3; --muted:#7d8590;
  --ok:#3fb950; --warn:#d29922; --crit:#f85149;
  --accent:#388bfd; --accent2:#1f6feb;
  --ann:#a371f7; --sel:#f0883e; --def:#7d8590;
  --remove:#3fb950; --unique:#d29922; --keep:#388bfd;
  --mono:'JetBrains Mono',monospace; --sans:'Inter',system-ui,sans-serif;
}
body { background:var(--bg); color:var(--text); font-family:var(--sans);
       font-size:13px; line-height:1.5; }
header { background:var(--bg2); border-bottom:1px solid var(--border);
         padding:20px 32px 16px; display:flex; align-items:flex-start;
         justify-content:space-between; gap:16px; flex-wrap:wrap; }
.header-left h1 { font-family:var(--mono); font-size:18px; font-weight:600; color:var(--accent); }
.header-left h1 span { color:var(--muted); }
.header-meta { margin-top:6px; font-size:11px; color:var(--muted); font-family:var(--mono); }
.legend { display:flex; gap:14px; font-size:11px; color:var(--muted);
          align-items:center; flex-wrap:wrap; }
.legend-dot { width:8px; height:8px; border-radius:50%;
              display:inline-block; margin-right:4px; }
.cards { display:flex; gap:12px; padding:20px 32px;
         border-bottom:1px solid var(--border2); flex-wrap:wrap; }
.card { background:var(--bg2); border:1px solid var(--border); border-radius:8px;
        padding:14px 20px; min-width:120px; }
.card-val { font-family:var(--mono); font-size:22px; font-weight:600;
            color:var(--text); line-height:1.2; }
.card-val.sm { font-size:16px; }
.card-lbl { font-size:11px; color:var(--muted); margin-top:2px; }
.content { padding:20px 32px; }
.toolbar { margin-bottom:14px; display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
.btn { background:var(--bg2); color:var(--text); border:1px solid var(--border);
       border-radius:4px; padding:4px 12px; cursor:pointer;
       font-family:var(--mono); font-size:11px; }
.btn:hover { background:var(--bg3); }
.section-tab { font-family:var(--mono); font-size:11px; font-weight:600;
               padding:4px 14px; border-radius:4px; cursor:pointer;
               border:1px solid var(--border2); color:var(--muted); }
.section-tab.active { background:var(--accent2); color:#fff; border-color:var(--accent); }
.tab-panel { display:none; }
.tab-panel.active { display:block; }
.pool-block { margin-bottom:12px; border:1px solid var(--border);
              border-radius:8px; overflow:hidden; }
.pool-header { background:var(--bg2); padding:12px 16px; cursor:pointer;
               display:flex; align-items:center; gap:10px; flex-wrap:wrap;
               transition:background 0.15s; }
.pool-header:hover { background:var(--bg3); }
.pool-header.open { border-bottom:1px solid var(--border); }
.chevron { font-size:9px; color:var(--muted); transition:transform 0.2s; flex-shrink:0; }
.pool-header.open .chevron { transform:rotate(90deg); }
.sel-label { font-family:var(--mono); font-size:13px; font-weight:600;
             color:var(--text); flex:1; min-width:160px; }
.pool-meta { font-family:var(--mono); font-size:11px; color:var(--muted);
             margin-left:auto; white-space:nowrap; display:flex; gap:16px; flex-wrap:wrap; }
.pool-meta .hi { color:var(--text); font-weight:600; }
.pool-body { background:var(--bg); display:none; }
.pool-body.open { display:block; }
.badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:10px;
         font-weight:600; font-family:var(--mono); white-space:nowrap; }
.badge-ann  { background:#2a1a3a; color:var(--ann);  border:1px solid #7a3fbe; }
.badge-sel  { background:#2a1a0a; color:var(--sel);  border:1px solid #a0560e; }
.badge-def  { background:var(--bg3); color:var(--muted); border:1px solid var(--border); }
.badge-lbl  { background:#1a2030; color:#79c0ff; border:1px solid #1f4070;
              font-size:9px; padding:1px 6px; margin:1px; }
.badge-remove { background:#1a3a1f; color:var(--remove); border:1px solid #2ea043; }
.badge-unique { background:#3a2f1a; color:var(--unique); border:1px solid #9e6a03; }
.badge-keep   { background:#1a2a3a; color:var(--keep);   border:1px solid var(--accent2); }
.workers-section { padding:10px 16px; border-bottom:1px solid var(--border2);
                   background:var(--bg2); }
.workers-title { font-family:var(--mono); font-size:10px; color:var(--muted);
                 text-transform:uppercase; letter-spacing:1px; margin-bottom:6px; }
.worker-row { display:flex; align-items:center; gap:12px; padding:3px 0;
              font-family:var(--mono); font-size:11px; flex-wrap:wrap; }
.worker-name { color:var(--text); font-weight:600; min-width:200px; }
.worker-cap { color:var(--muted); }
.worker-labels { display:flex; flex-wrap:wrap; gap:2px; }
table { width:100%; border-collapse:collapse; font-size:12px; }
th { background:var(--bg3); color:var(--muted); font-family:var(--mono); font-size:10px;
     font-weight:600; text-transform:uppercase; letter-spacing:0.8px; padding:8px 12px;
     text-align:left; border-bottom:1px solid var(--border); white-space:nowrap; }
th.r { text-align:right; }
td { padding:7px 12px; border-bottom:1px solid var(--border2); vertical-align:middle; }
td.r { text-align:right; font-family:var(--mono); font-size:11px; }
td.mono { font-family:var(--mono); font-size:11px; }
tr:last-child td { border-bottom:none; }
tr:hover td { background:var(--bg3); }
tr.can-remove td { background:#0d1f0d; }
tr.can-remove:hover td { background:#122712; }
tr.unique-lbl td { background:#1f1a0d; }
.ns-name { font-family:var(--mono); font-size:12px; font-weight:600; }
.total-row td { font-family:var(--mono); font-weight:600; color:var(--text);
                background:var(--bg3); border-top:2px solid var(--border); }
.sum-box { background:var(--bg2); border:1px solid var(--border); border-radius:6px;
           padding:10px 16px; margin:10px 0; font-family:var(--mono); font-size:12px; }
.sum-box .lbl { color:var(--muted); font-size:10px; text-transform:uppercase; }
.sum-box .val { color:var(--text); font-weight:600; }
.sum-box .good { color:var(--ok); }
.sum-box .warn2 { color:var(--warn); }
.bar-wrap { display:inline-block; width:55px; height:6px; background:var(--bg3);
            border-radius:3px; overflow:hidden; vertical-align:middle; margin-right:5px;
            border:1px solid var(--border2); }
.bar { height:100%; border-radius:3px; }
.bar.ok   { background:var(--ok); }
.bar.warn { background:var(--warn); }
.bar.crit { background:var(--crit); }
.pct { font-family:var(--mono); font-size:11px; font-weight:600; }
.pct.ok   { color:var(--ok); }
.pct.warn { color:var(--warn); }
.pct.crit { color:var(--crit); }
footer { padding:16px 32px; border-top:1px solid var(--border2);
         font-size:11px; color:var(--muted); font-family:var(--mono); }
"""

HTML_JS = """
function togglePool(el) {
  el.classList.toggle('open');
  var b = el.nextElementSibling;
  while (b && !b.classList.contains('pool-body')) b = b.nextElementSibling;
  if (b) b.classList.toggle('open');
}
function expandAll(scope) {
  (scope||document).querySelectorAll('.pool-header').forEach(function(h) {
    h.classList.add('open');
    var b = h.nextElementSibling;
    while (b && !b.classList.contains('pool-body')) b = b.nextElementSibling;
    if (b) b.classList.add('open');
  });
}
function collapseAll(scope) {
  (scope||document).querySelectorAll('.pool-header').forEach(function(h) {
    h.classList.remove('open');
    var b = h.nextElementSibling;
    while (b && !b.classList.contains('pool-body')) b = b.nextElementSibling;
    if (b) b.classList.remove('open');
  });
}
function showTab(id) {
  document.querySelectorAll('.tab-panel').forEach(function(p) {
    p.classList.remove('active');
  });
  document.querySelectorAll('.section-tab').forEach(function(t) {
    t.classList.remove('active');
  });
  document.getElementById(id).classList.add('active');
  document.querySelector('[data-tab="'+id+'"]').classList.add('active');
}
"""


def _pct_cls(pct, warn):
    if pct >= 100: return "crit"
    if pct >= warn: return "warn"
    return "ok"

def _bar(pct, warn):
    cls = _pct_cls(pct, warn)
    w   = min(pct, 100)
    return (
        '<div class="bar-wrap"><div class="bar {c}" style="width:{w:.1f}%"></div></div>'
        '<span class="pct {c}">{p:.1f}%</span>'
    ).format(c=cls, w=w, p=pct)

def _type_badge(t):
    m = {'annotation': ('badge-ann', 'ns annotation'),
         'nodeSelector': ('badge-sel', 'pod nodeSelector'),
         'default': ('badge-def', 'domyslny scheduler')}
    cls, lbl = m[t]
    return '<span class="badge {}">{}</span>'.format(cls, lbl)

def _lbl_badges(d):
    return "".join(
        '<span class="badge badge-lbl">{}={}</span>'.format(k, v)
        for k, v in sorted(d.items()))


# ---------------------------------------------------------------------------
# HTML — generowanie
# ---------------------------------------------------------------------------

def generate_html(groups, usage, workers, min_pods, warn_cpu, warn_mem,
                  plan_capacity=False, min_free_pct=50):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    total_pools = total_ns_set = 0
    grand_cpu = grand_mem = grand_pods = 0.0
    total_ns_all = set()

    usage_blocks = ""
    plan_blocks  = ""

    all_removable = []
    all_freed_cpu = all_freed_mem = 0.0

    for grp in groups:
        ns_active = [
            ns for ns in grp['namespaces']
            if sum(usage.get((ns, w), {}).get('pods', 0)
                   for w in grp['workers']) >= min_pods
        ]
        if not grp['workers']:
            continue

        total_pools += 1
        total_ns_all.update(ns_active)

        pool_cpu  = grp['pool_cpu_m']
        pool_mem  = grp['pool_mem_mib']
        used_cpu  = sum(usage.get((ns, w), {}).get('cpu_m', 0)
                        for ns in grp['namespaces'] for w in grp['workers'])
        used_mem  = sum(usage.get((ns, w), {}).get('mem_mib', 0)
                        for ns in grp['namespaces'] for w in grp['workers'])
        used_pods = sum(usage.get((ns, w), {}).get('pods', 0)
                        for ns in grp['namespaces'] for w in grp['workers'])
        util_cpu  = used_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
        util_mem  = used_mem / pool_mem * 100 if pool_mem > 0 else 0
        grand_cpu += used_cpu;  grand_mem += used_mem;  grand_pods += used_pods

        # --- workers html ---
        workers_html = ""
        for wname in grp['workers']:
            wi = workers.get(wname)
            if not wi: continue
            workers_html += (
                '<div class="worker-row">'
                '<span class="worker-name">{n}</span>'
                '<span class="worker-cap">CPU: {c} &nbsp;|&nbsp; MEM: {m}</span>'
                '<span class="worker-labels">{lbl}</span>'
                '</div>'
            ).format(n=wname, c=fmt_cpu(wi['allocatable_cpu_m']),
                     m=fmt_mib(wi['allocatable_mib']),
                     lbl=_lbl_badges(wi['labels']))

        # --- ns rows ---
        ns_rows = ""
        g_cpu = g_mem = g_pods = 0.0
        for ns in sorted(ns_active):
            nc = sum(usage.get((ns, w), {}).get('cpu_m', 0)   for w in grp['workers'])
            nm = sum(usage.get((ns, w), {}).get('mem_mib', 0) for w in grp['workers'])
            np = sum(usage.get((ns, w), {}).get('pods', 0)    for w in grp['workers'])
            g_cpu += nc;  g_mem += nm;  g_pods += np
            cp = nc / pool_cpu * 100 if pool_cpu > 0 else 0
            mp = nm / pool_mem * 100 if pool_mem > 0 else 0
            ns_rows += (
                '<tr><td class="ns-name">{ns}</td><td class="r">{p}</td>'
                '<td class="r">{c}</td><td>{cb}</td>'
                '<td class="r">{m}</td><td>{mb}</td></tr>'
            ).format(ns=ns, p=int(np), c=fmt_cpu(nc), cb=_bar(cp, warn_cpu),
                     m=fmt_mib(nm), mb=_bar(mp, warn_mem))

        gcp = g_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
        gmp = g_mem / pool_mem * 100 if pool_mem > 0 else 0
        ns_rows += (
            '<tr class="total-row"><td>LAZNIE PULA</td><td class="r">{p}</td>'
            '<td class="r">{c}</td><td>{cb}</td>'
            '<td class="r">{m}</td><td>{mb}</td></tr>'
        ).format(p=int(g_pods), c=fmt_cpu(g_cpu), cb=_bar(gcp, warn_cpu),
                 m=fmt_mib(g_mem), mb=_bar(gmp, warn_mem))

        pool_meta = (
            '<div class="pool-meta">'
            '<span>workers: <span class="hi">{nw}</span></span>'
            '<span>pula: <span class="hi">{pc}</span> CPU / <span class="hi">{pm}</span></span>'
            '<span>zuzycie: <span class="hi">{uc}</span> ({up}) CPU &nbsp;'
            '<span class="hi">{um}</span> ({mp}) MEM</span>'
            '<span>ns: <span class="hi">{nns}</span></span>'
            '</div>'
        ).format(
            nw=len(grp['workers']),
            pc=fmt_cpu(pool_cpu), pm=fmt_mib(pool_mem),
            uc=fmt_cpu(used_cpu),  up="{:.1f}%".format(util_cpu),
            um=fmt_mib(used_mem),  mp="{:.1f}%".format(util_mem),
            nns=len(ns_active),
        )

        usage_blocks += (
            '<div class="pool-block">'
            '<div class="pool-header" onclick="togglePool(this)">'
            '<span class="chevron">&#9654;</span>'
            '<span class="sel-label">{lbl}</span>'
            '{badge}{meta}'
            '</div>'
            '<div class="pool-body">'
            '<div class="workers-section">'
            '<div class="workers-title">Workers w puli</div>{workers}'
            '</div>'
            '<table><thead><tr>'
            '<th>Namespace</th><th class="r">Pods</th>'
            '<th class="r">CPU req</th><th>CPU % puli</th>'
            '<th class="r">MEM req</th><th>MEM % puli</th>'
            '</tr></thead><tbody>{rows}</tbody></table>'
            '</div></div>'
        ).format(lbl=grp['label'], badge=_type_badge(grp['type']),
                 meta=pool_meta, workers=workers_html, rows=ns_rows)

        # --- plan capacity block ---
        if plan_capacity:
            plan = compute_capacity_plan(grp, usage, workers, min_free_pct)
            all_removable.extend(plan['to_remove'])
            all_freed_cpu += plan['freed_cpu_m']
            all_freed_mem += plan['freed_mem_mib']

            node_rows = ""
            for wname in plan['sorted_nodes']:
                wi = workers.get(wname)
                nl = plan['node_load'].get(wname, {})
                if not wi: continue
                cpu_pct = nl.get('cpu_m', 0)   / wi['allocatable_cpu_m'] * 100 if wi['allocatable_cpu_m'] > 0 else 0
                mem_pct = nl.get('mem_mib', 0) / wi['allocatable_mib']   * 100 if wi['allocatable_mib']   > 0 else 0

                if wname in plan['to_remove']:
                    row_cls  = "can-remove"
                    stat_badge = '<span class="badge badge-remove">USUNAC</span>'
                elif wname in plan['unique_label_nodes']:
                    row_cls  = "unique-lbl"
                    stat_badge = '<span class="badge badge-unique">unikalna labelka</span>'
                else:
                    row_cls  = ""
                    stat_badge = '<span class="badge badge-keep">potrzebny</span>'

                node_rows += (
                    '<tr class="{rc}">'
                    '<td class="mono">{n}</td>'
                    '<td class="r">{lc}</td><td class="r">{ac}</td><td>{cb}</td>'
                    '<td class="r">{lm}</td><td class="r">{am}</td><td>{mb}</td>'
                    '<td>{st}</td>'
                    '</tr>'
                ).format(
                    rc=row_cls, n=wname,
                    lc=fmt_cpu(nl.get('cpu_m', 0)), ac=fmt_cpu(wi['allocatable_cpu_m']),
                    cb=_bar(cpu_pct, 50),
                    lm=fmt_mib(nl.get('mem_mib', 0)), am=fmt_mib(wi['allocatable_mib']),
                    mb=_bar(mem_pct, 50),
                    st=stat_badge,
                )

            if plan['to_remove']:
                rem_util_cpu = plan['total_cpu_m'] / plan['remaining_cpu_m'] * 100 if plan['remaining_cpu_m'] > 0 else 0
                rem_util_mem = plan['total_mem_mib'] / plan['remaining_mem_mib'] * 100 if plan['remaining_mem_mib'] > 0 else 0
                summary_cls  = "good"
                summary_html = (
                    '<div class="sum-box">'
                    '<div><span class="lbl">Mozna usunac: </span>'
                    '<span class="val {c}">{nodes}</span></div>'
                    '<div><span class="lbl">Po usunieciu pojemnosc: </span>'
                    '<span class="val">CPU {rc} | MEM {rm}</span></div>'
                    '<div><span class="lbl">Zuzycie po usunieciu: </span>'
                    '<span class="val">{ucp:.1f}% CPU | {ump:.1f}% MEM</span></div>'
                    '<div><span class="lbl">Zwolnione: </span>'
                    '<span class="val {c}">CPU {fc} | MEM {fm}</span></div>'
                    '</div>'
                ).format(
                    c=summary_cls,
                    nodes=", ".join(plan['to_remove']),
                    rc=fmt_cpu(plan['remaining_cpu_m']),
                    rm=fmt_mib(plan['remaining_mem_mib']),
                    ucp=rem_util_cpu, ump=rem_util_mem,
                    fc=fmt_cpu(plan['freed_cpu_m']),
                    fm=fmt_mib(plan['freed_mem_mib']),
                )
            else:
                summary_html = (
                    '<div class="sum-box">'
                    '<span class="warn2">Brak kandydatow do usuniecia '
                    'przy progu {}%.</span></div>'
                ).format(min_free_pct)

            plan_meta = (
                '<div class="pool-meta">'
                '<span>zuzycie: <span class="hi">{uc}</span> CPU | <span class="hi">{um}</span></span>'
                '<span>min pozostawic: <span class="hi">{nc}</span> CPU | <span class="hi">{nm}</span></span>'
                '<span>kandydaci: <span class="hi">{nr}</span></span>'
                '</div>'
            ).format(
                uc=fmt_cpu(plan['total_cpu_m']), um=fmt_mib(plan['total_mem_mib']),
                nc=fmt_cpu(plan['needed_cpu_m']), nm=fmt_mib(plan['needed_mem_mib']),
                nr=len(plan['to_remove']),
            )

            plan_blocks += (
                '<div class="pool-block">'
                '<div class="pool-header" onclick="togglePool(this)">'
                '<span class="chevron">&#9654;</span>'
                '<span class="sel-label">{lbl}</span>'
                '{badge}{meta}'
                '</div>'
                '<div class="pool-body">'
                '{summary}'
                '<table><thead><tr>'
                '<th>Node</th>'
                '<th class="r">CPU load</th><th class="r">CPU alloc</th><th>CPU%</th>'
                '<th class="r">MEM load</th><th class="r">MEM alloc</th><th>MEM%</th>'
                '<th>Status</th>'
                '</tr></thead><tbody>{rows}</tbody></table>'
                '</div></div>'
            ).format(lbl=grp['label'], badge=_type_badge(grp['type']),
                     meta=plan_meta, summary=summary_html, rows=node_rows)

    # karty summary
    cards = (
        '<div class="cards">'
        '<div class="card"><div class="card-val">{pools}</div>'
        '<div class="card-lbl">Pul (nodeSelector)</div></div>'
        '<div class="card"><div class="card-val">{ns}</div>'
        '<div class="card-lbl">Namespace\'ow</div></div>'
        '<div class="card"><div class="card-val">{pods}</div>'
        '<div class="card-lbl">Podow (Running/Pending)</div></div>'
        '<div class="card"><div class="card-val sm">{cpu}</div>'
        '<div class="card-lbl">CPU commit</div></div>'
        '<div class="card"><div class="card-val sm">{mem}</div>'
        '<div class="card-lbl">MEM commit</div></div>'
    ).format(pools=total_pools, ns=len(total_ns_all), pods=int(grand_pods),
             cpu=fmt_cpu(grand_cpu), mem=fmt_mib(grand_mem))

    if plan_capacity:
        cards += (
            '<div class="card"><div class="card-val" style="color:var(--ok)">{nr}</div>'
            '<div class="card-lbl">Nodow do usuniecia</div></div>'
            '<div class="card"><div class="card-val sm" style="color:var(--ok)">{fc} / {fm}</div>'
            '<div class="card-lbl">Zwolnione CPU / MEM</div></div>'
        ).format(nr=len(all_removable),
                 fc=fmt_cpu(all_freed_cpu), fm=fmt_mib(all_freed_mem))

    cards += '</div>'

    # taby
    if plan_capacity:
        tabs_nav = (
            '<div class="toolbar">'
            '<button class="btn" onclick="expandAll()">Rozwin wszystko</button>'
            '<button class="btn" onclick="collapseAll()">Zwij wszystko</button>'
            '&nbsp;'
            '<span class="section-tab active" data-tab="tab-usage" '
            'onclick="showTab(\'tab-usage\')">Zuzycie per pula</span>'
            '<span class="section-tab" data-tab="tab-plan" '
            'onclick="showTab(\'tab-plan\')">Plan capacity</span>'
            '</div>'
            '<div id="tab-usage" class="tab-panel active">' + usage_blocks + '</div>'
            '<div id="tab-plan"  class="tab-panel">' + plan_blocks + '</div>'
        )
    else:
        tabs_nav = (
            '<div class="toolbar">'
            '<button class="btn" onclick="expandAll()">Rozwin wszystko</button>'
            '<button class="btn" onclick="collapseAll()">Zwij wszystko</button>'
            '</div>'
            + usage_blocks
        )

    footer = (
        '<footer>OCP Worker Pool Analyzer'
        ' &bull; CPU warn: {:.0f}%'
        ' &bull; MEM warn: {:.0f}%'
        + (' &bull; min free: {:.0f}%'.format(min_free_pct) if plan_capacity else '')
        + '</footer>'
    ).format(warn_cpu, warn_mem)

    return (
        '<!DOCTYPE html>\n<html lang="pl">\n<head>\n'
        '<meta charset="UTF-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1.0">'
        '<title>OCP Worker Pool Report</title>'
        '<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600'
        '&family=Inter:wght@300;400;500;600&display=swap" rel="stylesheet">'
        '<style>' + HTML_CSS + '</style>'
        '</head>\n<body>\n'
        '<header>'
        '<div class="header-left">'
        '<h1>OCP<span>/</span>Worker Pools &mdash; Namespace Usage</h1>'
        '<div class="header-meta">Wygenerowano: ' + now + '</div>'
        '</div>'
        '<div class="legend">'
        '<span><span class="legend-dot" style="background:var(--ann)"></span>ns annotation</span>'
        '<span><span class="legend-dot" style="background:var(--sel)"></span>pod nodeSelector</span>'
        '<span><span class="legend-dot" style="background:var(--def)"></span>domyslny scheduler</span>'
        '<span><span class="legend-dot" style="background:var(--ok)"></span>mozna usunac</span>'
        '<span><span class="legend-dot" style="background:var(--warn)"></span>unikalna labelka</span>'
        '</div>'
        '</header>\n'
        + cards +
        '<div class="content">'
        + tabs_nav +
        '</div>\n'
        + footer +
        '<script>' + HTML_JS + '</script>'
        '</body></html>\n'
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="OCP nodeSelector → Worker Pool → Namespace usage analyzer")
    parser.add_argument('--min-pods', type=int, default=1,
                        help="Pomin namespace z mniej niz N podami (domyslnie 1)")
    parser.add_argument('--warn-cpu', type=float, default=70,
                        help="Prog ostrzezenia CPU %% puli (domyslnie 70)")
    parser.add_argument('--warn-mem', type=float, default=70,
                        help="Prog ostrzezenia MEM %% puli (domyslnie 70)")
    parser.add_argument('--plan-capacity', action='store_true',
                        help="Dodaj analiz ktore nody mozna usunac")
    parser.add_argument('--min-free-pct', type=int, default=50,
                        help="Min %% wolnych zasobow nad uzyciem po usunieciu (domyslnie 50)")
    parser.add_argument('--html', metavar='PLIK.html',
                        help="Zapisz raport HTML do pliku")
    args = parser.parse_args()

    workers    = get_worker_nodes()
    namespaces = get_namespaces()
    pods       = get_pods()

    print("Znaleziono {} worker nodow, {} podow.\n".format(len(workers), len(pods)))

    usage, selectors = analyze(pods, workers)
    groups           = build_selector_groups(usage, selectors, namespaces, workers)

    print_report(groups, usage, workers,
                 min_pods=args.min_pods,
                 warn_cpu=args.warn_cpu,
                 warn_mem=args.warn_mem)

    if args.plan_capacity:
        print_plan_capacity(groups, usage, workers,
                            min_pods=args.min_pods,
                            min_free_pct=args.min_free_pct)

    if args.html:
        html = generate_html(groups, usage, workers,
                             min_pods=args.min_pods,
                             warn_cpu=args.warn_cpu,
                             warn_mem=args.warn_mem,
                             plan_capacity=args.plan_capacity,
                             min_free_pct=args.min_free_pct)
        with open(args.html, "w", encoding="utf-8") as f:
            f.write(html)
        print(GREEN + BOLD + "Raport HTML: " + RESET + os.path.abspath(args.html))


if __name__ == "__main__":
    main()
