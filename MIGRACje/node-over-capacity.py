#!/usr/bin/env python3
"""
OCP Virtualization - Memory & CPU Overcommit Analyzer
z analiza drain feasibility i headroom per node.

Uzycie:
  python3 virt_overcommit.py
  python3 virt_overcommit.py --namespace produkcja
  python3 virt_overcommit.py --node worker-03
  python3 virt_overcommit.py --warn-cpu 80 --warn-mem 80
  python3 virt_overcommit.py --html raport.html
"""

import subprocess
import json
import sys
import argparse
import datetime
import os
from collections import defaultdict

RED    = "\033[91m"
YELLOW = "\033[93m"
GREEN  = "\033[92m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"


def color_pct(pct, warn, crit=100):
    if pct >= crit:
        return RED + BOLD + "{:.1f}%".format(pct) + RESET
    elif pct >= warn:
        return YELLOW + "{:.1f}%".format(pct) + RESET
    return GREEN + "{:.1f}%".format(pct) + RESET


def parse_memory_to_mib(raw):
    if not raw or raw in ("0", ""):
        return 0.0
    raw = str(raw).strip()
    try:
        if raw.endswith("Ki"):
            return float(raw[:-2]) / 1024
        elif raw.endswith("Mi"):
            return float(raw[:-2])
        elif raw.endswith("Gi"):
            return float(raw[:-2]) * 1024
        elif raw.endswith("Ti"):
            return float(raw[:-2]) * 1024 * 1024
        elif raw.endswith("K") or raw.endswith("k"):
            return float(raw[:-1]) / 1024
        elif raw.endswith("M"):
            return float(raw[:-1])
        elif raw.endswith("G"):
            return float(raw[:-1]) * 1024
        else:
            return float(raw) / (1024 * 1024)
    except ValueError:
        return 0.0


def parse_cpu_to_mcores(raw):
    if not raw or raw in ("0", ""):
        return 0.0
    raw = str(raw).strip()
    try:
        if raw.endswith("m"):
            return float(raw[:-1])
        else:
            return float(raw) * 1000
    except ValueError:
        return 0.0


def fmt_mib(mib):
    if mib >= 1024:
        return "{:.1f} GiB".format(mib / 1024)
    return "{:.0f} MiB".format(mib)


def fmt_cpu(mcores):
    if mcores >= 1000:
        return "{:.1f} cores".format(mcores / 1000)
    return "{:.0f}m".format(mcores)


def fmt_storage(gib):
    if gib == 0.0:
        return "-"
    if gib >= 1024:
        return "{:.1f} TiB".format(gib / 1024)
    return "{:.0f} GiB".format(gib)


def oc_get(resource, namespace=None):
    cmd = ["oc", "get", resource, "-o", "json"]
    if namespace:
        cmd += ["-n", namespace]
    else:
        cmd += ["-A"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            print(RED + "Blad oc: " + result.stderr.strip() + RESET, file=sys.stderr)
            return None
        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        print(RED + "Timeout: " + resource + RESET, file=sys.stderr)
        return None
    except json.JSONDecodeError as e:
        print(RED + "JSON error: " + str(e) + RESET, file=sys.stderr)
        return None


# ── Pobierz PVC ──────────────────────────────────────────────────────────────

def get_pvcs():
    """Zwraca dict: (namespace, name) -> rozmiar w GiB."""
    data = oc_get("persistentvolumeclaims")
    if not data:
        return {}
    pvcs = {}
    for item in data.get("items", []):
        ns   = item["metadata"]["namespace"]
        name = item["metadata"]["name"]
        cap  = (item.get("status", {}).get("capacity", {}).get("storage")
                or item.get("spec", {}).get("resources", {}).get("requests", {}).get("storage")
                or "0")
        pvcs[(ns, name)] = parse_memory_to_mib(cap) / 1024
    return pvcs


# ── Pobierz overcommit ratio z HyperConverged ────────────────────────────────

def get_overcommit_ratio():
    """
    Pobiera memoryOvercommitPercentage z HyperConverged CR.
    Zwraca float np. 1.2 dla 120%, 1.0 jesli brak konfiguracji.
    """
    data = oc_get("hyperconverged", namespace="openshift-cnv")
    if not data:
        return 1.0
    items = data.get("items", [])
    if not items:
        return 1.0
    pct = (items[0]
           .get("spec", {})
           .get("higherWorkloadDensity", {})
           .get("memoryOvercommitPercentage", 100))
    return float(pct) / 100.0


# ── Pobierz nody ─────────────────────────────────────────────────────────────

def get_nodes():
    data = oc_get("nodes")
    if not data:
        return {}
    nodes = {}
    for item in data.get("items", []):
        name   = item["metadata"]["name"]
        labels = item["metadata"].get("labels", {})
        alloc  = item["status"].get("allocatable", {})
        roles  = [k.split("/")[-1] for k in labels
                  if k.startswith("node-role.kubernetes.io/")]

        # pomijaj mastery i infranody
        if "master" in roles or "control-plane" in roles or "infra" in roles:
            continue

        conditions    = item["status"].get("conditions", [])
        ready         = any(c["type"] == "Ready" and c["status"] == "True"
                            for c in conditions)
        unschedulable = item["spec"].get("unschedulable", False)
        taints        = item["spec"].get("taints", [])

        nodes[name] = {
            "allocatable_cpu_m":   parse_cpu_to_mcores(alloc.get("cpu", "0")),
            "allocatable_mem_mib": parse_memory_to_mib(alloc.get("memory", "0")),
            "roles":               roles,
            "ready":               ready,
            "unschedulable":       unschedulable,
            "taints":              taints,
        }
    return nodes


# ── Pobierz VMI ──────────────────────────────────────────────────────────────

def get_vmis(filter_ns=None, pvcs=None):
    if pvcs is None:
        pvcs = {}
    data = oc_get("virtualmachineinstances", namespace=filter_ns)
    if not data:
        return []
    vmis = []
    for item in data.get("items", []):
        meta      = item["metadata"]
        spec      = item.get("spec", {})
        status    = item.get("status", {})
        domain    = spec.get("domain", {})
        cpu_obj   = domain.get("cpu", {})
        cpu_cores = (cpu_obj.get("cores", 1)
                     * cpu_obj.get("sockets", 1)
                     * cpu_obj.get("threads", 1))
        resources  = domain.get("resources", {})
        memory_raw = (
            domain.get("memory", {}).get("guest")
            or resources.get("requests", {}).get("memory")
            or resources.get("limits", {}).get("memory")
            or "0"
        )
        ns = meta["namespace"]
        storage_gib = 0.0
        for vol in spec.get("volumes", []):
            pvc_name = None
            if "dataVolume" in vol:
                pvc_name = vol["dataVolume"].get("name")
            elif "persistentVolumeClaim" in vol:
                pvc_name = vol["persistentVolumeClaim"].get("claimName")
            if pvc_name:
                storage_gib += pvcs.get((ns, pvc_name), 0.0)
        vmis.append({
            "name":        meta["name"],
            "namespace":   meta["namespace"],
            "node":        status.get("nodeName", "<unscheduled>"),
            "phase":       status.get("phase", "Unknown"),
            "cpu_m":       cpu_cores * 1000,
            "mem_mib":     parse_memory_to_mib(memory_raw),
            "storage_gib": storage_gib,
        })
    return vmis


# ── Analiza overcommit ────────────────────────────────────────────────────────

def analyze(vmis, nodes, filter_node=None):
    node_data = defaultdict(lambda: {"cpu_m": 0.0, "mem_mib": 0.0, "storage_gib": 0.0, "vms": []})
    ns_data   = defaultdict(lambda: {"cpu_m": 0.0, "mem_mib": 0.0, "storage_gib": 0.0, "vms": []})
    for vmi in vmis:
        node = vmi["node"]
        if filter_node and node != filter_node:
            continue
        node_data[node]["cpu_m"]       += vmi["cpu_m"]
        node_data[node]["mem_mib"]     += vmi["mem_mib"]
        node_data[node]["storage_gib"] += vmi["storage_gib"]
        node_data[node]["vms"].append(vmi)
        ns_data[vmi["namespace"]]["cpu_m"]       += vmi["cpu_m"]
        ns_data[vmi["namespace"]]["mem_mib"]     += vmi["mem_mib"]
        ns_data[vmi["namespace"]]["storage_gib"] += vmi["storage_gib"]
        ns_data[vmi["namespace"]]["vms"].append(vmi)
    return node_data, ns_data


# ── Drain feasibility ─────────────────────────────────────────────────────────

def calc_drain_feasibility(target_node, nodes, node_data, overcommit_ratio):
    """
    Symuluje drain target_node:
    Czy VM-ki z tego node'a zmieszcza sie na pozostalych worker nodach
    (z uwzglednieniem overcommit_ratio na pamieci)?

    Zwraca dict:
      feasible       bool
      missing_cpu_m  float  (>0 jesli brakuje)
      missing_mem_mib float
      free_cpu_m     float  lacznie wolne CPU na pozostalych nodach
      free_mem_mib   float  lacznie wolna RAM (efektywna po overcommit)
      detail         list of (node_name, free_cpu_m, free_mem_mib_eff)
    """
    nd_target = node_data.get(target_node, {"cpu_m": 0.0, "mem_mib": 0.0, "vms": []})
    needed_cpu = nd_target["cpu_m"]
    needed_mem = nd_target["mem_mib"]

    total_free_cpu = 0.0
    total_free_mem = 0.0
    detail = []

    for node_name, ni in nodes.items():
        if node_name == target_node:
            continue
        # efektywna pojemnosc RAM = allocatable * overcommit_ratio
        eff_mem = ni["allocatable_mem_mib"] * overcommit_ratio
        used_cpu = node_data.get(node_name, {}).get("cpu_m", 0.0)
        used_mem = node_data.get(node_name, {}).get("mem_mib", 0.0)

        free_cpu = max(0.0, ni["allocatable_cpu_m"] - used_cpu)
        free_mem = max(0.0, eff_mem - used_mem)

        total_free_cpu += free_cpu
        total_free_mem += free_mem
        detail.append((node_name, free_cpu, free_mem))

    missing_cpu = max(0.0, needed_cpu - total_free_cpu)
    missing_mem = max(0.0, needed_mem - total_free_mem)
    feasible    = (missing_cpu == 0.0 and missing_mem == 0.0)

    return {
        "feasible":        feasible,
        "needed_cpu_m":    needed_cpu,
        "needed_mem_mib":  needed_mem,
        "free_cpu_m":      total_free_cpu,
        "free_mem_mib":    total_free_mem,
        "missing_cpu_m":   missing_cpu,
        "missing_mem_mib": missing_mem,
        "detail":          detail,
    }


# ── Headroom per node ─────────────────────────────────────────────────────────

def calc_headroom(node_name, ni, node_data, overcommit_ratio):
    """
    Ile wolnych zasobow zostalo na nodzie po uwzglednieniu overcommit.
    Zwraca (free_cpu_m, free_mem_mib_effective).
    """
    eff_mem  = ni["allocatable_mem_mib"] * overcommit_ratio
    used_cpu = node_data.get(node_name, {}).get("cpu_m", 0.0)
    used_mem = node_data.get(node_name, {}).get("mem_mib", 0.0)
    return (
        max(0.0, ni["allocatable_cpu_m"] - used_cpu),
        max(0.0, eff_mem - used_mem),
    )


# ── Terminal output ───────────────────────────────────────────────────────────

def print_separator(char="─", width=120):
    print(char * width)


def print_node_report(node_data, nodes, warn_cpu, warn_mem, overcommit_ratio):
    print("\n" + BOLD + CYAN + "=" * 136 + RESET)
    print(BOLD + CYAN + "  OVERCOMMIT + HEADROOM + DRAIN FEASIBILITY PER WORKER NODE" + RESET)
    print(BOLD + CYAN + "  memoryOvercommitPercentage: {:.0f}%".format(overcommit_ratio * 100) + RESET)
    print(BOLD + CYAN + "=" * 136 + RESET)

    hdr = ("{:<28} {:<14} {:>5}  "
           "{:>10} {:>10} {:>7}  "
           "{:>11} {:>11} {:>7}  "
           "{:>10} {:>11}  "
           "{:>12}  "
           "{:<16}")
    print(BOLD + hdr.format(
        "NODE", "STATUS", "VMs",
        "CPU used", "CPU alloc", "CPU %",
        "MEM used", "MEM alloc", "MEM %",
        "Free CPU", "Free MEM",
        "STORAGE",
        "Drain OK?"
    ) + RESET)
    print_separator(width=136)

    all_nodes = sorted(set(nodes.keys()) | set(node_data.keys()))

    for node_name in all_nodes:
        nd = node_data.get(node_name, {"cpu_m": 0.0, "mem_mib": 0.0, "vms": []})
        ni = nodes.get(node_name)

        if not ni:
            print("{:<28} {:<14} {:>5}  {:>10} {:>10} {:>7}  {:>11} {:>11} {:>7}  {:>10} {:>11}  {:>12}  {:<16}".format(
                node_name, "unknown", len(nd["vms"]),
                fmt_cpu(nd["cpu_m"]), "?", "?",
                fmt_mib(nd["mem_mib"]), "?", "?",
                "?", "?", fmt_storage(nd["storage_gib"]), "?"))
            continue

        alloc_cpu  = ni["allocatable_cpu_m"]
        alloc_mem  = ni["allocatable_mem_mib"]
        eff_mem    = alloc_mem * overcommit_ratio

        cpu_pct    = (nd["cpu_m"]   / alloc_cpu * 100) if alloc_cpu > 0 else 0
        mem_pct    = (nd["mem_mib"] / eff_mem   * 100) if eff_mem   > 0 else 0

        free_cpu, free_mem = calc_headroom(node_name, ni, node_data, overcommit_ratio)

        dr = calc_drain_feasibility(node_name, nodes, node_data, overcommit_ratio)
        if not nd["vms"]:
            drain_str = GREEN + "OK (brak VM)" + RESET
        elif dr["feasible"]:
            drain_str = GREEN + "OK" + RESET
        else:
            parts = []
            if dr["missing_cpu_m"] > 0:
                parts.append("brak " + fmt_cpu(dr["missing_cpu_m"]) + " CPU")
            if dr["missing_mem_mib"] > 0:
                parts.append("brak " + fmt_mib(dr["missing_mem_mib"]) + " RAM")
            drain_str = RED + "NIE — " + ", ".join(parts) + RESET

        if not ni["ready"]:
            status_str = RED + "NotReady" + RESET
        elif ni["unschedulable"]:
            status_str = YELLOW + "Unschedulable" + RESET
        else:
            status_str = GREEN + "Ready" + RESET

        print("{:<28} {:<23} {:>5}  {:>10} {:>10} {:>17}  {:>11} {:>11} {:>17}  {:>10} {:>11}  {:>12}  {}".format(
            node_name, status_str, len(nd["vms"]),
            fmt_cpu(nd["cpu_m"]), fmt_cpu(alloc_cpu),
            color_pct(cpu_pct, warn_cpu),
            fmt_mib(nd["mem_mib"]),
            fmt_mib(eff_mem) + ("*" if overcommit_ratio != 1.0 else ""),
            color_pct(mem_pct, warn_mem),
            fmt_cpu(free_cpu), fmt_mib(free_mem),
            fmt_storage(nd["storage_gib"]),
            drain_str,
        ))

        for vmi in sorted(nd["vms"], key=lambda x: x["mem_mib"], reverse=True):
            phase_col = GREEN if vmi["phase"] == "Running" else YELLOW
            print("  {} {:<28} {}{:<36}{}  CPU: {:<10} MEM: {:<12} STOR: {}".format(
                "+-", vmi["namespace"],
                phase_col, vmi["name"], RESET,
                fmt_cpu(vmi["cpu_m"]), fmt_mib(vmi["mem_mib"]),
                fmt_storage(vmi["storage_gib"])))

    if overcommit_ratio != 1.0:
        print("\n" + CYAN + "  * efektywna pojemnosc RAM po overcommit ({:.0f}%)".format(
            overcommit_ratio * 100) + RESET)
    print_separator(width=136)


def print_namespace_report(ns_data):
    print("\n" + BOLD + CYAN + "=" * 120 + RESET)
    print(BOLD + CYAN + "  OVERCOMMIT PER NAMESPACE" + RESET)
    print(BOLD + CYAN + "=" * 120 + RESET)
    print(BOLD + "{:<38} {:>6}  {:>12} {:>14} {:>12}".format(
        "NAMESPACE", "VMs", "CPU commit", "MEM commit", "STORAGE") + RESET)
    print_separator()

    total_cpu = total_mem = total_stor = 0.0
    for ns in sorted(ns_data.keys()):
        nd = ns_data[ns]
        total_cpu  += nd["cpu_m"]
        total_mem  += nd["mem_mib"]
        total_stor += nd["storage_gib"]
        print("{:<38} {:>6}  {:>12} {:>14} {:>12}".format(
            ns, len(nd["vms"]),
            fmt_cpu(nd["cpu_m"]), fmt_mib(nd["mem_mib"]), fmt_storage(nd["storage_gib"])))
        for vmi in sorted(nd["vms"], key=lambda x: x["mem_mib"], reverse=True):
            phase_col = GREEN if vmi["phase"] == "Running" else YELLOW
            node_info = ("@ " + vmi["node"] if vmi["node"] != "<unscheduled>"
                         else RED + "unscheduled" + RESET)
            print("  {} {}{:<42}{}  CPU: {:<10} MEM: {:<14} STOR: {:<10} {}".format(
                "+-", phase_col, vmi["name"], RESET,
                fmt_cpu(vmi["cpu_m"]), fmt_mib(vmi["mem_mib"]),
                fmt_storage(vmi["storage_gib"]), node_info))

    print_separator()
    print("{:<38} {:>6}  {:>12} {:>14} {:>12}".format(
        "TOTAL",
        sum(len(nd["vms"]) for nd in ns_data.values()),
        fmt_cpu(total_cpu), fmt_mib(total_mem), fmt_storage(total_stor)))


def print_drain_summary(nodes, node_data, overcommit_ratio):
    print("\n" + BOLD + CYAN + "=" * 120 + RESET)
    print(BOLD + CYAN + "  PODSUMOWANIE DRAIN FEASIBILITY" + RESET)
    print(BOLD + CYAN + "=" * 120 + RESET)

    ok_nodes   = []
    fail_nodes = []

    for node_name in sorted(nodes.keys()):
        nd = node_data.get(node_name, {"vms": []})
        if not nd["vms"]:
            ok_nodes.append((node_name, "brak VM"))
            continue
        dr = calc_drain_feasibility(node_name, nodes, node_data, overcommit_ratio)
        if dr["feasible"]:
            ok_nodes.append((node_name, "OK"))
        else:
            parts = []
            if dr["missing_cpu_m"] > 0:
                parts.append("brakuje " + fmt_cpu(dr["missing_cpu_m"]) + " CPU")
            if dr["missing_mem_mib"] > 0:
                parts.append("brakuje " + fmt_mib(dr["missing_mem_mib"]) + " RAM")
            fail_nodes.append((node_name, ", ".join(parts), dr))

    print("\n" + GREEN + BOLD + "  Mozna bezpiecznie drenowac ({} nodow):".format(
        len(ok_nodes)) + RESET)
    for nn, reason in ok_nodes:
        print("    " + GREEN + "OK  " + RESET + nn + "  (" + reason + ")")

    if fail_nodes:
        print("\n" + RED + BOLD + "  NIE mozna bezpiecznie drenowac ({} nodow):".format(
            len(fail_nodes)) + RESET)
        for nn, reason, dr in fail_nodes:
            print("    " + RED + "NIE " + RESET + nn + "  -- " + reason)
            print("        VM-ki potrzebuja: CPU={} RAM={}  |  Pozostale nody maja wolne: CPU={} RAM={}".format(
                fmt_cpu(dr["needed_cpu_m"]),
                fmt_mib(dr["needed_mem_mib"]),
                fmt_cpu(dr["free_cpu_m"]),
                fmt_mib(dr["free_mem_mib"]),
            ))

    print_separator()


# ── HTML ──────────────────────────────────────────────────────────────────────

def pct_class(pct, warn, crit=100):
    if pct >= crit:
        return "crit"
    elif pct >= warn:
        return "warn"
    return "ok"


def bar_html(pct, warn):
    cls   = pct_class(pct, warn)
    width = min(pct, 100)
    return (
        '<div class="bar-wrap">'
        '<div class="bar ' + cls + '" style="width:' + "{:.1f}".format(width) + '%"></div>'
        '</div>'
        '<span class="pct ' + cls + '">' + "{:.1f}".format(pct) + '%</span>'
    )


def node_status_badge(ni):
    if not ni:
        return '<span class="badge unknown">unknown</span>'
    if not ni["ready"]:
        return '<span class="badge notready">NotReady</span>'
    if ni["unschedulable"]:
        return '<span class="badge unschedulable">Unschedulable</span>'
    return '<span class="badge ready">Ready</span>'


def phase_badge(phase):
    cls = "running" if phase == "Running" else "other"
    return '<span class="badge ' + cls + '">' + phase + '</span>'


def drain_badge(feasible, missing_cpu, missing_mem):
    if feasible:
        return '<span class="badge ready">OK</span>'
    parts = []
    if missing_cpu > 0:
        parts.append("CPU -" + fmt_cpu(missing_cpu))
    if missing_mem > 0:
        parts.append("RAM -" + fmt_mib(missing_mem))
    return '<span class="badge notready">NIE: ' + " ".join(parts) + '</span>'


CSS = """
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg:#0d1117; --bg2:#161b22; --bg3:#1c2128;
    --border:#30363d; --border2:#21262d;
    --text:#e6edf3; --muted:#7d8590;
    --ok:#3fb950; --warn:#d29922; --crit:#f85149;
    --accent:#388bfd; --accent2:#1f6feb;
    --mono:'JetBrains Mono',monospace; --sans:'Inter',system-ui,sans-serif;
  }
  body { background:var(--bg); color:var(--text); font-family:var(--sans); font-size:13px; line-height:1.5; }
  header { background:var(--bg2); border-bottom:1px solid var(--border); padding:20px 32px 16px;
           display:flex; align-items:flex-start; justify-content:space-between; gap:16px; }
  .header-left h1 { font-family:var(--mono); font-size:18px; font-weight:600; color:var(--accent); }
  .header-left h1 span { color:var(--muted); }
  .header-meta { margin-top:6px; font-size:11px; color:var(--muted); font-family:var(--mono); }
  .overcommit-tag { display:inline-block; background:#1a2a3a; border:1px solid var(--accent2);
                    border-radius:4px; padding:1px 8px; font-family:var(--mono);
                    font-size:11px; color:var(--accent); margin-left:8px; }
  .legend { display:flex; gap:16px; font-size:11px; color:var(--muted); align-items:center; }
  .legend-dot { width:8px; height:8px; border-radius:50%; display:inline-block; margin-right:4px; }
  .cards { display:flex; gap:12px; padding:20px 32px; border-bottom:1px solid var(--border2); flex-wrap:wrap; }
  .card { background:var(--bg2); border:1px solid var(--border); border-radius:8px; padding:14px 20px; min-width:130px; }
  .card--warn { border-color:var(--warn); }
  .card--crit { border-color:var(--crit); }
  .card-val { font-family:var(--mono); font-size:24px; font-weight:600; color:var(--text); line-height:1.2; }
  .card-lbl { font-size:11px; color:var(--muted); margin-top:2px; }
  .ok-text { color:var(--ok); } .warn-text { color:var(--warn); } .crit-text { color:var(--crit); }
  .section { padding:24px 32px; }
  .section + .section { border-top:1px solid var(--border2); }
  .section-title { font-family:var(--mono); font-size:12px; font-weight:600; color:var(--muted);
                   text-transform:uppercase; letter-spacing:1px; margin-bottom:14px; }
  table { width:100%; border-collapse:collapse; font-size:12px; }
  th { background:var(--bg3); color:var(--muted); font-family:var(--mono); font-size:10px;
       font-weight:600; text-transform:uppercase; letter-spacing:0.8px; padding:8px 12px;
       text-align:left; border-bottom:1px solid var(--border); white-space:nowrap; }
  td { padding:7px 12px; border-bottom:1px solid var(--border2); vertical-align:middle; }
  .node-row { background:var(--bg2); cursor:pointer; transition:background 0.15s; }
  .node-row:hover { background:var(--bg3); }
  .warn-row { border-left:3px solid var(--warn); }
  .crit-row { border-left:3px solid var(--crit); }
  .node-name { font-family:var(--mono); font-size:12px; font-weight:600; color:var(--text); white-space:nowrap; }
  .chevron { display:inline-block; font-size:9px; color:var(--muted); margin-right:6px; transition:transform 0.2s; }
  .node-row.open .chevron { transform:rotate(90deg); }
  .vm-group { background:var(--bg); } .vm-group.hidden { display:none; }
  .vm-table { margin:4px 0 4px 24px; width:calc(100% - 24px); }
  .vm-table td { border-color:transparent; padding:4px 12px; }
  .vm-indent { padding-left:28px !important; }
  .vm-ns { font-family:var(--mono); font-size:10px; color:var(--muted); margin-right:8px; }
  .vm-name { font-family:var(--mono); font-size:11px; color:var(--accent); }
  .vm-node { font-family:var(--mono); font-size:10px; color:var(--muted); }
  .total-row td { font-family:var(--mono); font-weight:600; color:var(--text);
                  background:var(--bg3); border-top:1px solid var(--border); }
  .badge { display:inline-block; padding:2px 7px; border-radius:10px; font-size:10px;
           font-weight:600; font-family:var(--mono); white-space:nowrap; }
  .badge.ready         { background:#1a3a1f; color:var(--ok);   border:1px solid #2ea043; }
  .badge.notready      { background:#3a1a1a; color:var(--crit); border:1px solid #da3633; }
  .badge.unschedulable { background:#3a2f1a; color:var(--warn); border:1px solid #9e6a03; }
  .badge.unknown       { background:var(--bg3); color:var(--muted); border:1px solid var(--border); }
  .badge.running       { background:#1a3a1f; color:var(--ok);   border:1px solid #2ea043; }
  .badge.other         { background:#3a2f1a; color:var(--warn); border:1px solid #9e6a03; }
  .headroom { font-family:var(--mono); font-size:11px; }
  .headroom.ok   { color:var(--ok); }
  .headroom.warn { color:var(--warn); }
  .headroom.crit { color:var(--crit); }
  .bar-wrap { display:inline-block; width:70px; height:6px; background:var(--bg3);
              border-radius:3px; overflow:hidden; vertical-align:middle; margin-right:4px;
              border:1px solid var(--border2); }
  .bar { height:100%; border-radius:3px; }
  .bar.ok { background:var(--ok); } .bar.warn { background:var(--warn); } .bar.crit { background:var(--crit); }
  .pct { font-family:var(--mono); font-size:11px; }
  .pct.ok { color:var(--ok); } .pct.warn { color:var(--warn); } .pct.crit { color:var(--crit); }
  .pct-cell { font-family:var(--mono); font-size:11px; font-weight:600; }
  .pct-cell.ok { color:var(--ok); } .pct-cell.warn { color:var(--warn); } .pct-cell.crit { color:var(--crit); }
  .drain-ok   { font-family:var(--mono); font-size:11px; color:var(--ok); font-weight:600; }
  .drain-fail { font-family:var(--mono); font-size:11px; color:var(--crit); font-weight:600; }
  .mono { font-family:var(--mono); font-size:11px; }
  footer { padding:16px 32px; border-top:1px solid var(--border2);
           font-size:11px; color:var(--muted); font-family:var(--mono); }
"""

JS = """
function toggleVMs(row) {
  row.classList.toggle('open');
  var next = row.nextElementSibling;
  if (next && next.classList.contains('vm-group')) {
    next.classList.toggle('hidden');
  }
}
"""


def generate_html(node_data, ns_data, nodes, warn_cpu, warn_mem,
                  overcommit_ratio, filter_node, filter_ns):
    now       = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    all_nodes = sorted(set(nodes.keys()) | set(node_data.keys()))

    total_vms   = sum(len(nd["vms"]) for nd in node_data.values())
    total_nodes = len(nodes)

    drain_ok   = 0
    drain_fail = 0
    for nn in all_nodes:
        nd = node_data.get(nn, {"vms": []})
        ni = nodes.get(nn)
        if not ni:
            continue
        if not nd["vms"]:
            drain_ok += 1
            continue
        dr = calc_drain_feasibility(nn, nodes, node_data, overcommit_ratio)
        if dr["feasible"]:
            drain_ok += 1
        else:
            drain_fail += 1

    drain_card_cls = "card card--crit" if drain_fail else "card"
    drain_val_cls  = "card-val crit-text" if drain_fail else "card-val ok-text"

    cards_html = (
        '<div class="cards">'
        '<div class="card"><div class="card-val">' + str(total_nodes) + '</div>'
        '<div class="card-lbl">Worker nodes</div></div>'
        '<div class="card"><div class="card-val">' + str(total_vms) + '</div>'
        '<div class="card-lbl">VM instancji</div></div>'
        '<div class="card"><div class="card-val ok-text">' + str(drain_ok) + '</div>'
        '<div class="card-lbl">Drain bezpieczny</div></div>'
        '<div class="' + drain_card_cls + '"><div class="' + drain_val_cls + '">' + str(drain_fail) + '</div>'
        '<div class="card-lbl">Drain ryzykowny</div></div>'
        '<div class="card"><div class="card-val" style="font-size:16px">'
        + "{:.0f}%".format(overcommit_ratio * 100) +
        '</div><div class="card-lbl">MEM overcommit ratio</div></div>'
        '</div>'
    )

    # node table
    node_rows = ""
    for node_name in all_nodes:
        nd = node_data.get(node_name, {"cpu_m": 0.0, "mem_mib": 0.0, "vms": []})
        ni = nodes.get(node_name)

        if not ni:
            node_rows += (
                '<tr class="node-row">'
                '<td class="node-name">' + node_name + '</td>'
                '<td>' + node_status_badge(None) + '</td>'
                '<td>' + str(len(nd["vms"])) + '</td>'
                '<td colspan="10">-</td>'
                '</tr>'
            )
            continue

        alloc_cpu = ni["allocatable_cpu_m"]
        eff_mem   = ni["allocatable_mem_mib"] * overcommit_ratio
        cpu_pct   = (nd["cpu_m"]   / alloc_cpu * 100) if alloc_cpu > 0 else 0
        mem_pct   = (nd["mem_mib"] / eff_mem   * 100) if eff_mem   > 0 else 0

        free_cpu, free_mem = calc_headroom(node_name, ni, node_data, overcommit_ratio)
        dr = calc_drain_feasibility(node_name, nodes, node_data, overcommit_ratio)

        # headroom color
        free_cpu_pct = (free_cpu / alloc_cpu * 100) if alloc_cpu > 0 else 0
        free_mem_pct = (free_mem / eff_mem   * 100) if eff_mem   > 0 else 0
        hcls_cpu = "ok" if free_cpu_pct > 30 else ("warn" if free_cpu_pct > 10 else "crit")
        hcls_mem = "ok" if free_mem_pct > 30 else ("warn" if free_mem_pct > 10 else "crit")

        row_cls = "node-row"
        if not dr["feasible"] and nd["vms"]:
            row_cls += " crit-row"
        elif cpu_pct >= warn_cpu or mem_pct >= warn_mem:
            row_cls += " warn-row"

        if not nd["vms"]:
            drain_cell = '<span class="drain-ok">OK (brak VM)</span>'
        elif dr["feasible"]:
            drain_cell = '<span class="drain-ok">OK</span>'
        else:
            parts = []
            if dr["missing_cpu_m"] > 0:
                parts.append("CPU -" + fmt_cpu(dr["missing_cpu_m"]))
            if dr["missing_mem_mib"] > 0:
                parts.append("RAM -" + fmt_mib(dr["missing_mem_mib"]))
            drain_cell = '<span class="drain-fail">NIE: ' + " ".join(parts) + '</span>'

        eff_mem_label = fmt_mib(eff_mem)
        if overcommit_ratio != 1.0:
            eff_mem_label += "*"

        vm_rows = ""
        for vmi in sorted(nd["vms"], key=lambda x: x["mem_mib"], reverse=True):
            vm_rows += (
                '<tr class="vm-row">'
                '<td colspan="2" class="vm-indent">'
                '<span class="vm-ns">' + vmi["namespace"] + '</span>'
                '<span class="vm-name">' + vmi["name"] + '</span>'
                '</td>'
                '<td>' + phase_badge(vmi["phase"]) + '</td>'
                '<td>' + fmt_cpu(vmi["cpu_m"]) + '</td>'
                '<td>-</td><td>-</td>'
                '<td>' + fmt_mib(vmi["mem_mib"]) + '</td>'
                '<td>-</td><td>-</td>'
                '<td>-</td><td>-</td>'
                '<td class="mono">' + fmt_storage(vmi["storage_gib"]) + '</td>'
                '<td>-</td>'
                '</tr>'
            )

        node_rows += (
            '<tr class="' + row_cls + '" onclick="toggleVMs(this)">'
            '<td class="node-name"><span class="chevron">&#9654;</span>' + node_name + '</td>'
            '<td>' + node_status_badge(ni) + '</td>'
            '<td>' + str(len(nd["vms"])) + '</td>'
            '<td>' + fmt_cpu(nd["cpu_m"]) + '</td>'
            '<td>' + fmt_cpu(alloc_cpu) + '</td>'
            '<td>' + bar_html(cpu_pct, warn_cpu) + '</td>'
            '<td>' + fmt_mib(nd["mem_mib"]) + '</td>'
            '<td>' + eff_mem_label + '</td>'
            '<td>' + bar_html(mem_pct, warn_mem) + '</td>'
            '<td class="headroom ' + hcls_cpu + '">' + fmt_cpu(free_cpu) + '</td>'
            '<td class="headroom ' + hcls_mem + '">' + fmt_mib(free_mem) + '</td>'
            '<td class="mono">' + fmt_storage(nd["storage_gib"]) + '</td>'
            '<td>' + drain_cell + '</td>'
            '</tr>'
            '<tr class="vm-group hidden">'
            '<td colspan="13"><table class="vm-table">' + vm_rows + '</table></td>'
            '</tr>'
        )

    # ns table
    ns_rows   = ""
    total_cpu = total_mem_ns = total_stor_ns = 0.0
    for ns in sorted(ns_data.keys()):
        nd = ns_data[ns]
        total_cpu     += nd["cpu_m"]
        total_mem_ns  += nd["mem_mib"]
        total_stor_ns += nd["storage_gib"]
        vm_rows = ""
        for vmi in sorted(nd["vms"], key=lambda x: x["mem_mib"], reverse=True):
            node_txt = vmi["node"] if vmi["node"] != "<unscheduled>" else "&#9888; unscheduled"
            vm_rows += (
                '<tr class="vm-row">'
                '<td class="vm-indent"><span class="vm-name">' + vmi["name"] + '</span></td>'
                '<td>' + phase_badge(vmi["phase"]) + '</td>'
                '<td>' + fmt_cpu(vmi["cpu_m"]) + '</td>'
                '<td>' + fmt_mib(vmi["mem_mib"]) + '</td>'
                '<td class="mono">' + fmt_storage(vmi["storage_gib"]) + '</td>'
                '<td class="vm-node">' + node_txt + '</td>'
                '</tr>'
            )
        ns_rows += (
            '<tr class="node-row" onclick="toggleVMs(this)">'
            '<td class="node-name"><span class="chevron">&#9654;</span>' + ns + '</td>'
            '<td>' + str(len(nd["vms"])) + '</td>'
            '<td>' + fmt_cpu(nd["cpu_m"]) + '</td>'
            '<td>' + fmt_mib(nd["mem_mib"]) + '</td>'
            '<td class="mono">' + fmt_storage(nd["storage_gib"]) + '</td>'
            '</tr>'
            '<tr class="vm-group hidden">'
            '<td colspan="5"><table class="vm-table">' + vm_rows + '</table></td>'
            '</tr>'
        )
    ns_rows += (
        '<tr class="total-row">'
        '<td>TOTAL</td>'
        '<td>' + str(sum(len(nd["vms"]) for nd in ns_data.values())) + '</td>'
        '<td>' + fmt_cpu(total_cpu) + '</td>'
        '<td>' + fmt_mib(total_mem_ns) + '</td>'
        '<td class="mono">' + fmt_storage(total_stor_ns) + '</td>'
        '</tr>'
    )

    filter_info = ""
    if filter_node:
        filter_info += ' &bull; node: ' + filter_node
    if filter_ns:
        filter_info += ' &bull; ns: ' + filter_ns

    overcommit_tag = (
        '<span class="overcommit-tag">memoryOvercommit: '
        + "{:.0f}%".format(overcommit_ratio * 100) + '</span>'
    )

    html = (
        '<!DOCTYPE html>\n<html lang="pl">\n<head>\n'
        '<meta charset="UTF-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1.0">\n'
        '<title>OCP Virt Overcommit Report</title>\n'
        '<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600'
        '&family=Inter:wght@300;400;500;600&display=swap" rel="stylesheet">\n'
        '<style>\n' + CSS + '</style>\n</head>\n<body>\n'
        '<header>'
        '<div class="header-left">'
        '<h1>OCP<span>/</span>Virt &mdash; Overcommit &amp; Drain Report</h1>'
        '<div class="header-meta">Wygenerowano: ' + now + filter_info + overcommit_tag + '</div>'
        '</div>'
        '<div class="legend">'
        '<span><span class="legend-dot" style="background:var(--ok)"></span>OK</span>'
        '<span><span class="legend-dot" style="background:var(--warn)"></span>Ostrzezenie</span>'
        '<span><span class="legend-dot" style="background:var(--crit)"></span>Krytyczny / drain niemozliwy</span>'
        '</div></header>\n'
        + cards_html + '\n'
        '<div class="section">'
        '<div class="section-title">&#9632; Overcommit + headroom + drain feasibility per worker node</div>'
        '<table><thead><tr>'
        '<th>Node</th><th>Status</th><th>VMs</th>'
        '<th>CPU used</th><th>CPU alloc</th><th>CPU %</th>'
        '<th>MEM used</th><th>MEM eff*</th><th>MEM %</th>'
        '<th>Free CPU</th><th>Free MEM</th>'
        '<th>Storage</th>'
        '<th>Drain OK?</th>'
        '</tr></thead>'
        '<tbody>' + node_rows + '</tbody></table>'
        + ('<p style="font-size:11px;color:var(--muted);margin-top:8px">'
           '* MEM eff = allocatable &times; overcommit ratio ({:.0f}%)'.format(overcommit_ratio * 100)
           + '</p>' if overcommit_ratio != 1.0 else '')
        + '</div>\n'
        '<div class="section">'
        '<div class="section-title">&#9632; Overcommit per namespace</div>'
        '<table><thead><tr>'
        '<th>Namespace</th><th>VMs</th><th>CPU commit</th><th>MEM commit</th><th>Storage</th>'
        '</tr></thead>'
        '<tbody>' + ns_rows + '</tbody></table>'
        '</div>\n'
        '<footer>OCP Virt Overcommit Analyzer'
        ' &bull; CPU warn: ' + "{:.0f}".format(warn_cpu) + '%'
        ' &bull; MEM warn: ' + "{:.0f}".format(warn_mem) + '%'
        ' &bull; overcommit: ' + "{:.0f}".format(overcommit_ratio * 100) + '%'
        '</footer>'
        '<script>\n' + JS + '</script>\n'
        '</body></html>\n'
    )
    return html


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="OCP Virt overcommit + drain analyzer")
    parser.add_argument("--namespace", "-n",  help="Filtruj po namespace")
    parser.add_argument("--node",      "-N",  help="Filtruj po worker nodzie")
    parser.add_argument("--warn-cpu",  type=float, default=80)
    parser.add_argument("--warn-mem",  type=float, default=80)
    parser.add_argument("--html", metavar="PLIK.html")
    args = parser.parse_args()

    print(BOLD + "Pobieranie danych z klastra..." + RESET)

    overcommit_ratio = get_overcommit_ratio()
    print("memoryOvercommitPercentage: " + CYAN + "{:.0f}%".format(
        overcommit_ratio * 100) + RESET)

    nodes = get_nodes()
    if not nodes:
        print(RED + "Nie udalo sie pobrac nodow." + RESET)
        sys.exit(1)

    pvcs = get_pvcs()
    print("Znaleziono {} PVC.".format(len(pvcs)))

    vmis = get_vmis(filter_ns=args.namespace, pvcs=pvcs)
    if not vmis:
        print(YELLOW + "Brak VMI w klastrze." + RESET)
        sys.exit(0)

    print("Znaleziono {} worker nodow i {} VMI.\n".format(len(nodes), len(vmis)))

    node_data, ns_data = analyze(vmis, nodes, filter_node=args.node)

    print_node_report(node_data, nodes, args.warn_cpu, args.warn_mem, overcommit_ratio)
    print_namespace_report(ns_data)
    print_drain_summary(nodes, node_data, overcommit_ratio)

    if args.html:
        html = generate_html(
            node_data, ns_data, nodes,
            args.warn_cpu, args.warn_mem,
            overcommit_ratio,
            args.node, args.namespace,
        )
        with open(args.html, "w", encoding="utf-8") as f:
            f.write(html)
        print("\n" + GREEN + BOLD + "Raport HTML: " + RESET + os.path.abspath(args.html))


if __name__ == "__main__":
    main()