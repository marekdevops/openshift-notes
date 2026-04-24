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
         justify-content:space-between; gap:16px; }
.header-left h1 { font-family:var(--mono); font-size:18px; font-weight:600; color:var(--accent); }
.header-left h1 span { color:var(--muted); }
.header-meta { margin-top:6px; font-size:11px; color:var(--muted); font-family:var(--mono); }
.legend { display:flex; gap:16px; font-size:11px; color:var(--muted); align-items:center; flex-wrap:wrap; }
.legend-dot { width:8px; height:8px; border-radius:50%; display:inline-block; margin-right:4px; }

.cards { display:flex; gap:12px; padding:20px 32px; border-bottom:1px solid var(--border2); flex-wrap:wrap; }
.card { background:var(--bg2); border:1px solid var(--border); border-radius:8px;
        padding:14px 20px; min-width:130px; }
.card-val { font-family:var(--mono); font-size:24px; font-weight:600; color:var(--text); line-height:1.2; }
.card-lbl { font-size:11px; color:var(--muted); margin-top:2px; }

.content { padding:24px 32px; }
.ns-block { margin-bottom:12px; border:1px solid var(--border); border-radius:8px; overflow:hidden; }
.ns-header { background:var(--bg2); padding:12px 16px; cursor:pointer; display:flex;
             align-items:center; gap:10px; flex-wrap:wrap; transition:background 0.15s; }
.ns-header:hover { background:var(--bg3); }
.ns-header.open { border-bottom:1px solid var(--border); }
.chevron { font-size:9px; color:var(--muted); transition:transform 0.2s; flex-shrink:0; }
.ns-header.open .chevron { transform:rotate(90deg); }
.ns-name { font-family:var(--mono); font-size:13px; font-weight:600; color:var(--text); flex:1; min-width:180px; }
.ns-stats { font-family:var(--mono); font-size:11px; color:var(--muted); margin-left:auto; white-space:nowrap; }
.ns-body { background:var(--bg); display:none; }
.ns-body.open { display:block; }

.badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:10px;
         font-weight:600; font-family:var(--mono); white-space:nowrap; }
.badge-ann  { background:#2a1a3a; color:var(--ann);  border:1px solid #7a3fbe; }
.badge-sel  { background:#2a1a0a; color:var(--sel);  border:1px solid #a0560e; }
.badge-def  { background:var(--bg3); color:var(--muted); border:1px solid var(--border); }
.badge-lbl  { background:#1a2030; color:#79c0ff; border:1px solid #1f4070;
              font-size:9px; padding:1px 6px; margin:1px; }

.binding-row { padding:8px 16px; font-size:11px; color:var(--muted); font-family:var(--mono);
               border-bottom:1px solid var(--border2); background:var(--bg2); }
.binding-row span { color:var(--text); }

table { width:100%; border-collapse:collapse; font-size:12px; }
th { background:var(--bg3); color:var(--muted); font-family:var(--mono); font-size:10px;
     font-weight:600; text-transform:uppercase; letter-spacing:0.8px; padding:8px 12px;
     text-align:left; border-bottom:1px solid var(--border); white-space:nowrap; }
td { padding:7px 12px; border-bottom:1px solid var(--border2); vertical-align:middle; }
tr:last-child td { border-bottom:none; }
tr:hover td { background:var(--bg3); }

.node-name { font-family:var(--mono); font-size:12px; font-weight:600; white-space:nowrap; }
.mono { font-family:var(--mono); font-size:11px; }
.labels-cell { min-width:140px; }

.bar-wrap { display:inline-block; width:60px; height:6px; background:var(--bg3);
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

.total-row td { font-family:var(--mono); font-weight:600; color:var(--text);
                background:var(--bg3); border-top:2px solid var(--border); }

footer { padding:16px 32px; border-top:1px solid var(--border2);
         font-size:11px; color:var(--muted); font-family:var(--mono); }
"""

HTML_JS = """
function toggleNs(el) {
  el.classList.toggle('open');
  var body = el.nextElementSibling;
  while (body && !body.classList.contains('ns-body')) {
    body = body.nextElementSibling;
  }
  if (body) body.classList.toggle('open');
}
function expandAll() {
  document.querySelectorAll('.ns-header').forEach(function(h) {
    h.classList.add('open');
    var b = h.nextElementSibling;
    while (b && !b.classList.contains('ns-body')) b = b.nextElementSibling;
    if (b) b.classList.add('open');
  });
}
function collapseAll() {
  document.querySelectorAll('.ns-header').forEach(function(h) {
    h.classList.remove('open');
    var b = h.nextElementSibling;
    while (b && !b.classList.contains('ns-body')) b = b.nextElementSibling;
    if (b) b.classList.remove('open');
  });
}
"""


def _pct_cls(pct, warn, crit=100):
    if pct >= crit: return "crit"
    if pct >= warn: return "warn"
    return "ok"

def _bar(pct, warn):
    cls   = _pct_cls(pct, warn)
    width = min(pct, 100)
    return (
        '<div class="bar-wrap"><div class="bar {cls}" style="width:{w:.1f}%"></div></div>'
        '<span class="pct {cls}">{p:.1f}%</span>'
    ).format(cls=cls, w=width, p=pct)

def _binding_badges(ns_ann, ns_sel):
    badges = []
    if ns_ann:
        badges.append('<span class="badge badge-ann">ns annotation</span>')
    if ns_sel:
        badges.append('<span class="badge badge-sel">pod nodeSelector</span>')
    if not ns_ann and not ns_sel:
        badges.append('<span class="badge badge-def">domyslny scheduler</span>')
    return " ".join(badges)

def _label_badges(labels_dict):
    return "".join(
        '<span class="badge badge-lbl">{}={}</span>'.format(k, v)
        for k, v in sorted(labels_dict.items())
    )


def generate_html(usage, selectors, workers, namespaces,
                  min_pods, warn_cpu, warn_mem, filter_ns):
    now    = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    all_ns = sorted({ns for ns, _ in usage.keys()})
    if filter_ns:
        all_ns = [n for n in all_ns if n == filter_ns]

    grand_cpu = grand_mem = grand_pods = 0
    ns_blocks = ""

    for ns in all_ns:
        nodes_for_ns = sorted(node for (n, node) in usage.keys() if n == ns)
        total_pods   = sum(usage[(ns, node)]['pods']    for node in nodes_for_ns)
        if total_pods < min_pods:
            continue

        total_cpu = sum(usage[(ns, node)]['cpu_m']   for node in nodes_for_ns)
        total_mem = sum(usage[(ns, node)]['mem_mib'] for node in nodes_for_ns)
        grand_cpu  += total_cpu
        grand_mem  += total_mem
        grand_pods += total_pods

        ns_ann  = namespaces.get(ns, {}).get('node_selector', '')
        ns_sel  = selectors.get(ns, set())
        binding = _binding_badges(ns_ann, ns_sel)

        stats = (
            '<span class="ns-stats">pods: {p} &nbsp;|&nbsp; '
            'CPU: {c} &nbsp;|&nbsp; MEM: {m}</span>'
        ).format(p=total_pods, c=fmt_cpu(total_cpu), m=fmt_mib(total_mem))

        # binding detail row
        detail_parts = []
        if ns_ann:
            detail_parts.append(
                'openshift.io/node-selector: <span>{}</span>'.format(ns_ann))
        if ns_sel:
            detail_parts.append(
                'pod nodeSelector: <span>{}</span>'.format(
                    ", ".join(sorted(ns_sel))))
        binding_row = ""
        if detail_parts:
            binding_row = (
                '<div class="binding-row">' +
                " &nbsp;&bull;&nbsp; ".join(detail_parts) +
                '</div>'
            )

        # worker rows
        worker_rows = ""
        for node in nodes_for_ns:
            nd = usage[(ns, node)]
            wi = workers.get(node)
            if not wi:
                continue
            cpu_pct = (nd['cpu_m']   / wi['allocatable_cpu_m'] * 100) if wi['allocatable_cpu_m'] > 0 else 0
            mem_pct = (nd['mem_mib'] / wi['allocatable_mib']   * 100) if wi['allocatable_mib']   > 0 else 0
            worker_rows += (
                '<tr>'
                '<td class="node-name">{node}</td>'
                '<td class="labels-cell">{labels}</td>'
                '<td class="mono">{pods}</td>'
                '<td class="mono">{cpu_req}</td>'
                '<td class="mono">{cpu_alloc}</td>'
                '<td>{cpu_bar}</td>'
                '<td class="mono">{mem_req}</td>'
                '<td class="mono">{mem_alloc}</td>'
                '<td>{mem_bar}</td>'
                '</tr>'
            ).format(
                node=node,
                labels=_label_badges(wi['labels']),
                pods=nd['pods'],
                cpu_req=fmt_cpu(nd['cpu_m']),
                cpu_alloc=fmt_cpu(wi['allocatable_cpu_m']),
                cpu_bar=_bar(cpu_pct, warn_cpu),
                mem_req=fmt_mib(nd['mem_mib']),
                mem_alloc=fmt_mib(wi['allocatable_mib']),
                mem_bar=_bar(mem_pct, warn_mem),
            )

        ns_blocks += (
            '<div class="ns-block">'
            '<div class="ns-header" onclick="toggleNs(this)">'
            '<span class="chevron">&#9654;</span>'
            '<span class="ns-name">{ns}</span>'
            '{binding}'
            '{stats}'
            '</div>'
            '{binding_row}'
            '<div class="ns-body">'
            '<table>'
            '<thead><tr>'
            '<th>Worker</th><th>Labels</th><th>Pods</th>'
            '<th>CPU req</th><th>CPU alloc</th><th>CPU %</th>'
            '<th>MEM req</th><th>MEM alloc</th><th>MEM %</th>'
            '</tr></thead>'
            '<tbody>{rows}</tbody>'
            '</table>'
            '</div>'
            '</div>'
        ).format(
            ns=ns, binding=binding, stats=stats,
            binding_row=binding_row, rows=worker_rows,
        )

    total_ns = len([ns for ns in all_ns
                    if sum(usage[(ns, node)]['pods']
                           for node in (node for (n, node) in usage.keys() if n == ns))
                    >= min_pods])

    cards = (
        '<div class="cards">'
        '<div class="card"><div class="card-val">{ns}</div>'
        '<div class="card-lbl">Namespace\'ow</div></div>'
        '<div class="card"><div class="card-val">{pods}</div>'
        '<div class="card-lbl">Podow (Running/Pending)</div></div>'
        '<div class="card"><div class="card-val" style="font-size:18px">{cpu}</div>'
        '<div class="card-lbl">CPU commit (requests)</div></div>'
        '<div class="card"><div class="card-val" style="font-size:18px">{mem}</div>'
        '<div class="card-lbl">MEM commit (requests)</div></div>'
        '<div class="card"><div class="card-val">{workers}</div>'
        '<div class="card-lbl">Worker nodow</div></div>'
        '</div>'
    ).format(
        ns=total_ns, pods=grand_pods,
        cpu=fmt_cpu(grand_cpu), mem=fmt_mib(grand_mem),
        workers=len(workers),
    )

    filter_info = (" &bull; ns: " + filter_ns) if filter_ns else ""

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
        '<title>OCP NS-Worker Affinity Report</title>'
        '<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600'
        '&family=Inter:wght@300;400;500;600&display=swap" rel="stylesheet">'
        '<style>' + HTML_CSS + '</style>'
        '</head>\n<body>\n'
        '<header>'
        '<div class="header-left">'
        '<h1>OCP<span>/</span>Namespace &rarr; Worker &mdash; Affinity &amp; Usage</h1>'
        '<div class="header-meta">Wygenerowano: ' + now + filter_info + '</div>'
        '</div>'
        '<div class="legend">'
        '<span><span class="legend-dot" style="background:var(--ann)"></span>ns annotation</span>'
        '<span><span class="legend-dot" style="background:var(--sel)"></span>pod nodeSelector</span>'
        '<span><span class="legend-dot" style="background:var(--def)"></span>domyslny scheduler</span>'
        '<span><span class="legend-dot" style="background:var(--ok)"></span>ok</span>'
        '<span><span class="legend-dot" style="background:var(--warn)"></span>warn</span>'
        '<span><span class="legend-dot" style="background:var(--crit)"></span>crit</span>'
        '</div>'
        '</header>\n'
        + cards +
        '<div class="content">'
        '<div style="margin-bottom:12px;display:flex;gap:8px;">'
        '<button onclick="expandAll()" style="background:var(--bg2);color:var(--text);'
        'border:1px solid var(--border);border-radius:4px;padding:4px 12px;'
        'cursor:pointer;font-family:var(--mono);font-size:11px;">Rozwin wszystko</button>'
        '<button onclick="collapseAll()" style="background:var(--bg2);color:var(--text);'
        'border:1px solid var(--border);border-radius:4px;padding:4px 12px;'
        'cursor:pointer;font-family:var(--mono);font-size:11px;">Zwij wszystko</button>'
        '</div>'
        + ns_blocks +
        '</div>\n'
        + footer +
        '<script>' + HTML_JS + '</script>'
        '</body></html>\n'
    )


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
    parser.add_argument('--html', metavar='PLIK.html',
                        help="Zapisz raport HTML do pliku")
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

    if args.html:
        html = generate_html(usage, selectors, workers, namespaces,
                             min_pods=args.min_pods,
                             warn_cpu=args.warn_cpu,
                             warn_mem=args.warn_mem,
                             filter_ns=args.namespace)
        with open(args.html, "w", encoding="utf-8") as f:
            f.write(html)
        print(GREEN + BOLD + "Raport HTML: " + RESET + os.path.abspath(args.html))


if __name__ == "__main__":
    main()
