#!/usr/bin/env python3
"""
OCP nodeSelector → Worker Pool → Namespace Usage Analyzer

Grupuje workery w pule wedlug labelek/nodeSelector,
nastepnie pokazuje jakie namespacey korzystaja z kazdej puli
i ile zasobow CPU/MEM zuzywa kazdy namespace na danej puli.

Uzycie:
  python3 ns_worker_affinity.py
  python3 ns_worker_affinity.py --min-pods 3
  python3 ns_worker_affinity.py --warn-cpu 60 --warn-mem 60
  python3 ns_worker_affinity.py --html raport.html
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
    print("Pobieranie worker nodow...")
    data = get_oc_json('nodes')
    workers = {}
    for node in data.get('items', []):
        labels = node['metadata'].get('labels', {})
        if 'node-role.kubernetes.io/worker' not in labels:
            continue
        name   = node['metadata']['name']
        status = node.get('status', {})
        # zachowaj tylko "uzytkownicze" labele (pomijaj systemowe)
        custom_labels = {
            k: v for k, v in labels.items()
            if not k.startswith('node-role.kubernetes.io/')
            and not k.startswith('kubernetes.io/')
            and not k.startswith('beta.kubernetes.io/')
            and not k.startswith('node.kubernetes.io/')
        }
        workers[name] = {
            'allocatable_cpu_m': convert_cpu_to_mcores(
                status.get('allocatable', {}).get('cpu', '0')),
            'allocatable_mib': convert_memory_to_mib(
                status.get('allocatable', {}).get('memory', '0Mi')),
            'labels': custom_labels,
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

def get_pods(filter_ns=None):
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

def parse_kv_string(s):
    """'key=val, key2=val2' → dict"""
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
    """
    usage[(ns, node)] = {cpu_m, mem_mib, pods}
    selectors[ns]     = set of "key=value" strings z pod nodeSelector
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

        for k, v in pod['node_selector'].items():
            if (not k.startswith('node-role.kubernetes.io/')
                    and not k.startswith('kubernetes.io/')
                    and not k.startswith('beta.kubernetes.io/')
                    and not k.startswith('node.kubernetes.io/')):
                selectors[ns].add("{}={}".format(k, v) if v else k)

    return usage, selectors


def build_selector_groups(usage, selectors, namespaces, workers):
    """
    Grupuje namespacey po ich efektywnym nodeSelector.
    Priorytet: ns annotation > pod nodeSelector > domyslny scheduler.

    Zwraca posortowana liste grup:
    [{ label, type, selector_dict, workers, pool_cpu_m, pool_mem_mib, namespaces }]
    """
    ns_set = sorted({ns for ns, _ in usage.keys()})
    group_map = {}   # frozenset(kv_strings) -> group dict

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
                # workery pasujace do selectora (musza miec WSZYSTKIE labelki)
                matching = sorted(
                    wn for wn, wi in workers.items()
                    if all(wi['labels'].get(k) == v for k, v in sel_dict.items())
                )
            else:
                matching = []   # uzupelniamy po petli

            group_map[key] = {
                'label':        sel_label,
                'type':         sel_type,
                'selector_dict': sel_dict,
                'workers':      matching,
                'namespaces':   [],
            }

        group_map[key]['namespaces'].append(ns)

    # Dla grupy "default" — workery ktore sa faktycznie uzywane przez te namespacey
    default_key = frozenset()
    if default_key in group_map:
        default_ns = set(group_map[default_key]['namespaces'])
        group_map[default_key]['workers'] = sorted({
            node for (ns, node) in usage.keys()
            if ns in default_ns and node in workers
        })

    # Oblicz pojemnosc puli
    for grp in group_map.values():
        grp['pool_cpu_m']   = sum(
            workers[w]['allocatable_cpu_m'] for w in grp['workers'] if w in workers)
        grp['pool_mem_mib'] = sum(
            workers[w]['allocatable_mib']   for w in grp['workers'] if w in workers)

    # Sortuj: annotation, nodeSelector, default
    order = {'annotation': 0, 'nodeSelector': 1, 'default': 2}
    return sorted(group_map.values(), key=lambda g: (order[g['type']], g['label']))


# --- Terminal output ---

def print_report(groups, usage, workers, min_pods, warn_cpu, warn_mem):
    W = 110
    print("\n" + BOLD + CYAN + "=" * W + RESET)
    print(BOLD + CYAN + "  PULE WORKEROW (nodeSelector) → NAMESPACE: ZUZYCIE CPU/MEM" + RESET)
    print(BOLD + CYAN + "=" * W + RESET)

    type_label = {
        'annotation':   'ns annotation (openshift.io/node-selector)',
        'nodeSelector': 'pod nodeSelector',
        'default':      'domyslny scheduler',
    }

    grand_cpu = grand_mem = grand_pods = 0

    for grp in groups:
        pool_cpu = grp['pool_cpu_m']
        pool_mem = grp['pool_mem_mib']

        # filtruj namespacey po min_pods
        ns_active = [
            ns for ns in grp['namespaces']
            if sum(usage.get((ns, w), {}).get('pods', 0)
                   for w in grp['workers']) >= min_pods
        ]
        if not ns_active:
            continue

        print("\n  " + BOLD + "nodeSelector: " + grp['label'] + RESET
              + "  [" + type_label[grp['type']] + "]")
        print("  " + "─" * (W - 2))

        # --- workery w puli ---
        print("  " + CYAN + "Workers w puli ({})  |  pojemnosc puli: CPU {} | MEM {}".format(
            len(grp['workers']), fmt_cpu(pool_cpu), fmt_mib(pool_mem)) + RESET)
        for wname in grp['workers']:
            wi = workers.get(wname)
            if not wi:
                continue
            lbl = ", ".join("{}={}".format(k, v) for k, v in sorted(wi['labels'].items()))
            print("    {:<34}  CPU: {:>8}  MEM: {:>10}  {}".format(
                wname, fmt_cpu(wi['allocatable_cpu_m']), fmt_mib(wi['allocatable_mib']),
                "[" + lbl + "]" if lbl else ""))

        # --- namespacey ---
        print()
        print(BOLD + "  {:<42} {:>5}  {:>8}  {:>8}  {:>9}    {:>9}  {:>8}  {:>9}".format(
            "NAMESPACE", "PODS", "CPU req", "CPU%",
            "CPU% puli", "MEM req", "MEM%",
            "MEM% puli") + RESET)
        print("  " + "─" * (W - 2))

        grp_cpu = grp_mem = grp_pods = 0.0

        for ns in sorted(ns_active):
            ns_cpu  = sum(usage.get((ns, w), {}).get('cpu_m', 0)   for w in grp['workers'])
            ns_mem  = sum(usage.get((ns, w), {}).get('mem_mib', 0) for w in grp['workers'])
            ns_pods = sum(usage.get((ns, w), {}).get('pods', 0)    for w in grp['workers'])
            grp_cpu  += ns_cpu
            grp_mem  += ns_mem
            grp_pods += ns_pods

            # % wzgledem puli (ile workery tej puli "zjada" ten namespace)
            cpu_pool_pct = ns_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
            mem_pool_pct = ns_mem / pool_mem * 100 if pool_mem > 0 else 0

            print("  {:<42} {:>5}  {:>8}  {:>18}  {:>19}".format(
                ns, int(ns_pods),
                fmt_cpu(ns_cpu),
                color_pct(cpu_pool_pct, warn_cpu),
                fmt_mib(ns_mem),
            ) + "  " + color_pct(mem_pool_pct, warn_mem))

        print("  " + "─" * (W - 2))

        tot_cpu_pct = grp_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
        tot_mem_pct = grp_mem / pool_mem * 100 if pool_mem > 0 else 0
        print(BOLD + "  {:<42} {:>5}  {:>8}  {:>18}  {:>19}".format(
            "LAZNIE PULA", int(grp_pods),
            fmt_cpu(grp_cpu),
            color_pct(tot_cpu_pct, warn_cpu),
            fmt_mib(grp_mem),
        ) + "  " + color_pct(tot_mem_pct, warn_mem) + RESET)

        grand_cpu  += grp_cpu
        grand_mem  += grp_mem
        grand_pods += grp_pods

    print("\n" + BOLD + "=" * W + RESET)
    print(BOLD + "  GRAND TOTAL   pods: {}   CPU: {}   MEM: {}".format(
        int(grand_pods), fmt_cpu(grand_cpu), fmt_mib(grand_mem)) + RESET)
    print(BOLD + "=" * W + RESET + "\n")


# --- HTML ---

HTML_CSS = """
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --bg:#0d1117; --bg2:#161b22; --bg3:#1c2128;
  --border:#30363d; --border2:#21262d;
  --text:#e6edf3; --muted:#7d8590;
  --ok:#3fb950; --warn:#d29922; --crit:#f85149;
  --accent:#388bfd; --accent2:#1f6feb;
  --ann:#a371f7; --sel:#f0883e; --def:#7d8590;
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
.legend { display:flex; gap:16px; font-size:11px; color:var(--muted); align-items:center; flex-wrap:wrap; }
.legend-dot { width:8px; height:8px; border-radius:50%; display:inline-block; margin-right:4px; }

.cards { display:flex; gap:12px; padding:20px 32px; border-bottom:1px solid var(--border2); flex-wrap:wrap; }
.card { background:var(--bg2); border:1px solid var(--border); border-radius:8px;
        padding:14px 20px; min-width:130px; }
.card-val { font-family:var(--mono); font-size:24px; font-weight:600; color:var(--text); line-height:1.2; }
.card-val.sm { font-size:17px; }
.card-lbl { font-size:11px; color:var(--muted); margin-top:2px; }

.content { padding:20px 32px; }
.toolbar { margin-bottom:14px; display:flex; gap:8px; }
.btn { background:var(--bg2); color:var(--text); border:1px solid var(--border);
       border-radius:4px; padding:4px 12px; cursor:pointer;
       font-family:var(--mono); font-size:11px; }
.btn:hover { background:var(--bg3); }

.pool-block { margin-bottom:14px; border:1px solid var(--border); border-radius:8px; overflow:hidden; }

.pool-header { background:var(--bg2); padding:12px 16px; cursor:pointer;
               display:flex; align-items:center; gap:10px; flex-wrap:wrap;
               transition:background 0.15s; }
.pool-header:hover { background:var(--bg3); }
.pool-header.open { border-bottom:1px solid var(--border); }
.chevron { font-size:9px; color:var(--muted); transition:transform 0.2s; flex-shrink:0; }
.pool-header.open .chevron { transform:rotate(90deg); }
.sel-label { font-family:var(--mono); font-size:13px; font-weight:600; color:var(--text); flex:1; min-width:200px; }
.pool-stats { font-family:var(--mono); font-size:11px; color:var(--muted); margin-left:auto; white-space:nowrap; }

.badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:10px;
         font-weight:600; font-family:var(--mono); white-space:nowrap; }
.badge-ann  { background:#2a1a3a; color:var(--ann);  border:1px solid #7a3fbe; }
.badge-sel  { background:#2a1a0a; color:var(--sel);  border:1px solid #a0560e; }
.badge-def  { background:var(--bg3); color:var(--muted); border:1px solid var(--border); }
.badge-lbl  { background:#1a2030; color:#79c0ff; border:1px solid #1f4070;
              font-size:9px; padding:1px 6px; margin:1px; }

.pool-body { background:var(--bg); display:none; }
.pool-body.open { display:block; }

.workers-section { padding:12px 16px; border-bottom:1px solid var(--border2);
                   background:var(--bg2); }
.workers-title { font-family:var(--mono); font-size:10px; color:var(--muted);
                 text-transform:uppercase; letter-spacing:1px; margin-bottom:8px; }
.worker-row { display:flex; align-items:center; gap:16px; padding:4px 0;
              font-family:var(--mono); font-size:11px; flex-wrap:wrap; }
.worker-name { color:var(--text); font-weight:600; min-width:220px; }
.worker-cap { color:var(--muted); }
.worker-labels { display:flex; flex-wrap:wrap; gap:2px; }

table { width:100%; border-collapse:collapse; font-size:12px; }
th { background:var(--bg3); color:var(--muted); font-family:var(--mono); font-size:10px;
     font-weight:600; text-transform:uppercase; letter-spacing:0.8px; padding:8px 12px;
     text-align:left; border-bottom:1px solid var(--border); white-space:nowrap; }
th.r { text-align:right; }
td { padding:7px 12px; border-bottom:1px solid var(--border2); vertical-align:middle; }
td.r { text-align:right; font-family:var(--mono); font-size:11px; }
tr:last-child td { border-bottom:none; }
tr:hover td { background:var(--bg3); }
.ns-name { font-family:var(--mono); font-size:12px; font-weight:600; }
.total-row td { font-family:var(--mono); font-weight:600; color:var(--text);
                background:var(--bg3); border-top:2px solid var(--border); }

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
  var body = el.nextElementSibling;
  while (body && !body.classList.contains('pool-body')) body = body.nextElementSibling;
  if (body) body.classList.toggle('open');
}
function expandAll()   { toggle(true);  }
function collapseAll() { toggle(false); }
function toggle(open) {
  document.querySelectorAll('.pool-header').forEach(function(h) {
    open ? h.classList.add('open') : h.classList.remove('open');
    var b = h.nextElementSibling;
    while (b && !b.classList.contains('pool-body')) b = b.nextElementSibling;
    if (b) open ? b.classList.add('open') : b.classList.remove('open');
  });
}
"""


def _pct_cls(pct, warn):
    if pct >= 100: return "crit"
    if pct >= warn: return "warn"
    return "ok"

def _bar_html(pct, warn):
    cls   = _pct_cls(pct, warn)
    width = min(pct, 100)
    return (
        '<div class="bar-wrap"><div class="bar {c}" style="width:{w:.1f}%"></div></div>'
        '<span class="pct {c}">{p:.1f}%</span>'
    ).format(c=cls, w=width, p=pct)

def _type_badge(t):
    if t == 'annotation':
        return '<span class="badge badge-ann">ns annotation</span>'
    if t == 'nodeSelector':
        return '<span class="badge badge-sel">pod nodeSelector</span>'
    return '<span class="badge badge-def">domyslny scheduler</span>'

def _label_badges(labels_dict):
    return "".join(
        '<span class="badge badge-lbl">{}={}</span>'.format(k, v)
        for k, v in sorted(labels_dict.items())
    )


def generate_html(groups, usage, workers, min_pods, warn_cpu, warn_mem):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    total_pools = 0
    total_ns    = set()
    grand_cpu   = grand_mem = grand_pods = 0.0

    pool_blocks = ""

    for grp in groups:
        ns_active = [
            ns for ns in grp['namespaces']
            if sum(usage.get((ns, w), {}).get('pods', 0)
                   for w in grp['workers']) >= min_pods
        ]
        if not ns_active:
            continue

        total_pools += 1
        total_ns.update(ns_active)

        pool_cpu = grp['pool_cpu_m']
        pool_mem = grp['pool_mem_mib']

        # --- workers section ---
        workers_html = ""
        for wname in grp['workers']:
            wi = workers.get(wname)
            if not wi:
                continue
            workers_html += (
                '<div class="worker-row">'
                '<span class="worker-name">{name}</span>'
                '<span class="worker-cap">CPU: {cpu} &nbsp;|&nbsp; MEM: {mem}</span>'
                '<span class="worker-labels">{labels}</span>'
                '</div>'
            ).format(
                name=wname,
                cpu=fmt_cpu(wi['allocatable_cpu_m']),
                mem=fmt_mib(wi['allocatable_mib']),
                labels=_label_badges(wi['labels']),
            )

        # --- namespace rows ---
        ns_rows = ""
        grp_cpu = grp_mem = grp_pods = 0.0

        for ns in sorted(ns_active):
            ns_cpu  = sum(usage.get((ns, w), {}).get('cpu_m', 0)   for w in grp['workers'])
            ns_mem  = sum(usage.get((ns, w), {}).get('mem_mib', 0) for w in grp['workers'])
            ns_pods = sum(usage.get((ns, w), {}).get('pods', 0)    for w in grp['workers'])
            grp_cpu  += ns_cpu
            grp_mem  += ns_mem
            grp_pods += ns_pods

            cpu_pct = ns_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
            mem_pct = ns_mem / pool_mem * 100 if pool_mem > 0 else 0

            ns_rows += (
                '<tr>'
                '<td class="ns-name">{ns}</td>'
                '<td class="r">{pods}</td>'
                '<td class="r">{cpu}</td>'
                '<td>{cpu_bar}</td>'
                '<td class="r">{mem}</td>'
                '<td>{mem_bar}</td>'
                '</tr>'
            ).format(
                ns=ns, pods=int(ns_pods),
                cpu=fmt_cpu(ns_cpu), cpu_bar=_bar_html(cpu_pct, warn_cpu),
                mem=fmt_mib(ns_mem), mem_bar=_bar_html(mem_pct, warn_mem),
            )

        tot_cpu_pct = grp_cpu / pool_cpu * 100 if pool_cpu > 0 else 0
        tot_mem_pct = grp_mem / pool_mem * 100 if pool_mem > 0 else 0

        ns_rows += (
            '<tr class="total-row">'
            '<td>LAZNIE PULA</td>'
            '<td class="r">{pods}</td>'
            '<td class="r">{cpu}</td>'
            '<td>{cpu_bar}</td>'
            '<td class="r">{mem}</td>'
            '<td>{mem_bar}</td>'
            '</tr>'
        ).format(
            pods=int(grp_pods),
            cpu=fmt_cpu(grp_cpu), cpu_bar=_bar_html(tot_cpu_pct, warn_cpu),
            mem=fmt_mib(grp_mem), mem_bar=_bar_html(tot_mem_pct, warn_mem),
        )

        grand_cpu  += grp_cpu
        grand_mem  += grp_mem
        grand_pods += grp_pods

        pool_stats = (
            'workers: {nw} &nbsp;|&nbsp; pula: CPU {cpu} | MEM {mem} '
            '&nbsp;|&nbsp; ns: {nns}'
        ).format(
            nw=len(grp['workers']),
            cpu=fmt_cpu(pool_cpu), mem=fmt_mib(pool_mem),
            nns=len(ns_active),
        )

        pool_blocks += (
            '<div class="pool-block">'
            '<div class="pool-header" onclick="togglePool(this)">'
            '<span class="chevron">&#9654;</span>'
            '<span class="sel-label">{label}</span>'
            '{badge}'
            '<span class="pool-stats">{stats}</span>'
            '</div>'
            '<div class="pool-body">'
            '<div class="workers-section">'
            '<div class="workers-title">Workers w puli &mdash; pojemnosc</div>'
            '{workers}'
            '</div>'
            '<table>'
            '<thead><tr>'
            '<th>Namespace</th><th class="r">Pods</th>'
            '<th class="r">CPU req</th><th>CPU % puli</th>'
            '<th class="r">MEM req</th><th>MEM % puli</th>'
            '</tr></thead>'
            '<tbody>{ns_rows}</tbody>'
            '</table>'
            '</div>'
            '</div>'
        ).format(
            label=grp['label'],
            badge=_type_badge(grp['type']),
            stats=pool_stats,
            workers=workers_html,
            ns_rows=ns_rows,
        )

    # cards
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
        '</div>'
    ).format(
        pools=total_pools, ns=len(total_ns), pods=int(grand_pods),
        cpu=fmt_cpu(grand_cpu), mem=fmt_mib(grand_mem),
    )

    footer = (
        '<footer>OCP NS-Worker Affinity Analyzer'
        ' &bull; CPU warn: {:.0f}%'
        ' &bull; MEM warn: {:.0f}%'
        '</footer>'
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
        '</div>'
        '</header>\n'
        + cards +
        '<div class="content">'
        '<div class="toolbar">'
        '<button class="btn" onclick="expandAll()">Rozwin wszystko</button>'
        '<button class="btn" onclick="collapseAll()">Zwij wszystko</button>'
        '</div>'
        + pool_blocks +
        '</div>\n'
        + footer +
        '<script>' + HTML_JS + '</script>'
        '</body></html>\n'
    )


# --- Main ---

def main():
    parser = argparse.ArgumentParser(
        description="OCP nodeSelector → Worker Pool → Namespace usage analyzer")
    parser.add_argument('--min-pods', type=int, default=1,
                        help="Pomin namespace z mniej niz N podami (domyslnie 1)")
    parser.add_argument('--warn-cpu', type=float, default=70,
                        help="Prog ostrzezenia CPU %% puli (domyslnie 70)")
    parser.add_argument('--warn-mem', type=float, default=70,
                        help="Prog ostrzezenia MEM %% puli (domyslnie 70)")
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

    if args.html:
        html = generate_html(groups, usage, workers,
                             min_pods=args.min_pods,
                             warn_cpu=args.warn_cpu,
                             warn_mem=args.warn_mem)
        with open(args.html, "w", encoding="utf-8") as f:
            f.write(html)
        print(GREEN + BOLD + "Raport HTML: " + RESET + os.path.abspath(args.html))


if __name__ == "__main__":
    main()
