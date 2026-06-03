#!/usr/bin/env bash
# ocp_report.sh — OpenShift Cluster Summary Report Generator
# Usage: ./ocp_report.sh [--output /path/to/report.html]
# Requires: oc CLI, logged in to target cluster

set -euo pipefail

OUTPUT="${1:-ocp_report.html}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[ocp_report] $*" >&2; }

# ── Cluster info ────────────────────────────────────────────────────────────
log "Collecting cluster info..."
CLUSTER_NAME=$(oc config current-context 2>/dev/null | sed 's|.*/||' || echo "unknown")
OCP_VERSION=$(oc version --client=false -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('openshiftVersion','n/a'))
" 2>/dev/null || oc version 2>/dev/null | grep "Server Version" | awk '{print $3}' || echo "n/a")

# ── Nodes ───────────────────────────────────────────────────────────────────
log "Collecting node data..."
NODE_JSON=$(oc get nodes -o json 2>/dev/null)

NODES_TOTAL=$(echo "$NODE_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(len(d['items']))
")

WORKERS_TOTAL=$(echo "$NODE_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
workers=[n for n in d['items'] if 'node-role.kubernetes.io/worker' in n['metadata'].get('labels',{})]
print(len(workers))
")

MASTERS_TOTAL=$(echo "$NODE_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
masters=[n for n in d['items'] if 'node-role.kubernetes.io/master' in n['metadata'].get('labels',{})]
print(len(masters))
")

NODES_READY=$(echo "$NODE_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ready=0
for n in d['items']:
  for c in n['status'].get('conditions',[]):
    if c['type']=='Ready' and c['status']=='True':
      ready+=1
print(ready)
")

# ── CPU ─────────────────────────────────────────────────────────────────────
log "Collecting CPU/memory allocatable..."
ALLOC_JSON=$(echo "$NODE_JSON" | python3 -c "
import sys,json,re

def parse_cpu(s):
  if s.endswith('m'):
    return int(s[:-1])
  return int(float(s)*1000)

def parse_mem_gi(s):
  if s.endswith('Ki'):
    return int(s[:-2])/1024/1024
  if s.endswith('Mi'):
    return int(s[:-2])/1024
  if s.endswith('Gi'):
    return float(s[:-2])
  return int(s)/1024/1024/1024

d=json.load(sys.stdin)
total_cpu_m=0
total_mem_gi=0.0
for n in d['items']:
  alloc=n['status'].get('allocatable',{})
  total_cpu_m += parse_cpu(alloc.get('cpu','0'))
  total_mem_gi += parse_mem_gi(alloc.get('memory','0Ki'))

print(json.dumps({'cpu_cores': round(total_cpu_m/1000,1), 'mem_gi': round(total_mem_gi,1)}))
")

CPU_ALLOCATABLE=$(echo "$ALLOC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['cpu_cores'])")
MEM_ALLOCATABLE_GI=$(echo "$ALLOC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['mem_gi'])")

# ── CPU/Memory usage (metrics-server or oc adm top) ──────────────────────
log "Collecting resource usage (oc adm top nodes)..."
TOP_JSON=$(oc adm top nodes --no-headers 2>/dev/null | python3 -c "
import sys,re
lines=sys.stdin.read().strip().split('\n')
total_cpu_m=0
total_mem_mi=0
count=0
for line in lines:
  parts=line.split()
  if len(parts)<5:
    continue
  cpu_s=parts[1]
  mem_s=parts[3]
  if cpu_s.endswith('m'):
    total_cpu_m+=int(cpu_s[:-1])
  else:
    total_cpu_m+=int(cpu_s)*1000
  if mem_s.endswith('Mi'):
    total_mem_mi+=int(mem_s[:-2])
  elif mem_s.endswith('Gi'):
    total_mem_mi+=int(float(mem_s[:-2])*1024)
  count+=1
cpu_used=round(total_cpu_m/1000,1)
mem_used_gi=round(total_mem_mi/1024,1)
import json
print(json.dumps({'cpu_used':cpu_used,'mem_used_gi':mem_used_gi,'ok':True}))
" 2>/dev/null || echo '{"cpu_used":0,"mem_used_gi":0,"ok":false}')

CPU_USED=$(echo "$TOP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['cpu_used'])")
MEM_USED_GI=$(echo "$TOP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['mem_used_gi'])")
METRICS_OK=$(echo "$TOP_JSON" | python3 -c "import sys,json; print('true' if json.load(sys.stdin)['ok'] else 'false')")

# ── Pods (application namespaces only) ───────────────────────────────────────
# Excluded prefixes: openshift-*, kube-*, default, kube-public, kube-node-lease
log "Collecting pod counts (application namespaces only)..."
POD_JSON=$(oc get pods -A -o json 2>/dev/null)

PODS_TOTAL=$(echo "$POD_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
SYSTEM=('openshift-','kube-','open-cluster-','multicluster-','hive','assisted-installer')
EXACT={'default','kube-public','kube-node-lease'}
def app_ns(ns):
  if ns in EXACT: return False
  return not any(ns.startswith(p) for p in SYSTEM)
print(sum(1 for p in d['items'] if app_ns(p['metadata']['namespace'])))
")
PODS_RUNNING=$(echo "$POD_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
SYSTEM=('openshift-','kube-','open-cluster-','multicluster-','hive','assisted-installer')
EXACT={'default','kube-public','kube-node-lease'}
def app_ns(ns):
  if ns in EXACT: return False
  return not any(ns.startswith(p) for p in SYSTEM)
print(sum(1 for p in d['items'] if app_ns(p['metadata']['namespace']) and p['status'].get('phase')=='Running'))
")
PODS_PENDING=$(echo "$POD_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
SYSTEM=('openshift-','kube-','open-cluster-','multicluster-','hive','assisted-installer')
EXACT={'default','kube-public','kube-node-lease'}
def app_ns(ns):
  if ns in EXACT: return False
  return not any(ns.startswith(p) for p in SYSTEM)
print(sum(1 for p in d['items'] if app_ns(p['metadata']['namespace']) and p['status'].get('phase')=='Pending'))
")
PODS_FAILED=$(echo "$POD_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
SYSTEM=('openshift-','kube-','open-cluster-','multicluster-','hive','assisted-installer')
EXACT={'default','kube-public','kube-node-lease'}
def app_ns(ns):
  if ns in EXACT: return False
  return not any(ns.startswith(p) for p in SYSTEM)
print(sum(1 for p in d['items'] if app_ns(p['metadata']['namespace']) and p['status'].get('phase') in ('Failed','Unknown')))
")

# ── Namespaces ───────────────────────────────────────────────────────────────
log "Collecting namespace count..."
NS_TOTAL=$(oc get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')

# ── Build JSON payload ───────────────────────────────────────────────────────
log "Building JSON payload..."
JSON_DATA=$(python3 -c "
import json,sys
data = {
  'cluster_name': '$CLUSTER_NAME',
  'ocp_version':  '$OCP_VERSION',
  'timestamp':    '$TIMESTAMP',
  'metrics_available': $METRICS_OK,
  'nodes': {
    'total':   $NODES_TOTAL,
    'ready':   $NODES_READY,
    'workers': $WORKERS_TOTAL,
    'masters': $MASTERS_TOTAL
  },
  'cpu': {
    'allocatable': $CPU_ALLOCATABLE,
    'used':        $CPU_USED
  },
  'memory': {
    'allocatable_gi': $MEM_ALLOCATABLE_GI,
    'used_gi':        $MEM_USED_GI
  },
  'pods': {
    'total':   $PODS_TOTAL,
    'running': $PODS_RUNNING,
    'pending': $PODS_PENDING,
    'failed':  $PODS_FAILED
  },
  'namespaces': $NS_TOTAL
}
print(json.dumps(data, indent=2))
")

# ── Inject into HTML template ────────────────────────────────────────────────
log "Generating HTML report -> $OUTPUT"

HTML_TEMPLATE='<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OCP Cluster Report</title>
<style>
  @import url("https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;400;600&display=swap");

  :root {
    --red:    #cc0000;
    --bg:     #0f0f0f;
    --surface:#161616;
    --border: #262626;
    --text:   #f4f4f4;
    --muted:  #8d8d8d;
    --green:  #42be65;
    --amber:  #f1c21b;
    --blue:   #4589ff;
    --danger: #ff8389;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: "IBM Plex Sans", sans-serif;
    font-weight: 300;
    min-height: 100vh;
    padding: 2rem;
  }

  header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 1rem;
    border-bottom: 1px solid var(--border);
    padding-bottom: 1.5rem;
    margin-bottom: 2rem;
  }

  .logo {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .logo svg { flex-shrink: 0; }

  .logo-text {
    font-family: "IBM Plex Mono", monospace;
    font-size: 0.7rem;
    color: var(--muted);
    line-height: 1.6;
  }

  .logo-text strong {
    display: block;
    font-size: 1rem;
    color: var(--text);
    font-weight: 600;
    letter-spacing: -0.02em;
  }

  .meta {
    text-align: right;
    font-family: "IBM Plex Mono", monospace;
    font-size: 0.72rem;
    color: var(--muted);
    line-height: 1.8;
  }

  .meta .version {
    color: var(--blue);
    font-weight: 600;
  }

  .section-title {
    font-size: 0.65rem;
    font-family: "IBM Plex Mono", monospace;
    letter-spacing: 0.15em;
    color: var(--muted);
    text-transform: uppercase;
    margin-bottom: 1rem;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .section-title::after {
    content: "";
    flex: 1;
    height: 1px;
    background: var(--border);
  }

  .grid-4 {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 1px;
    background: var(--border);
    border: 1px solid var(--border);
    margin-bottom: 2rem;
  }

  .metric-card {
    background: var(--surface);
    padding: 1.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 4px;
    position: relative;
    overflow: hidden;
  }

  .metric-card::before {
    content: "";
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: var(--accent, transparent);
  }

  .metric-card.accent-red    { --accent: var(--red); }
  .metric-card.accent-green  { --accent: var(--green); }
  .metric-card.accent-blue   { --accent: var(--blue); }
  .metric-card.accent-amber  { --accent: var(--amber); }

  .metric-label {
    font-size: 0.65rem;
    font-family: "IBM Plex Mono", monospace;
    letter-spacing: 0.1em;
    color: var(--muted);
    text-transform: uppercase;
  }

  .metric-value {
    font-family: "IBM Plex Mono", monospace;
    font-size: 2rem;
    font-weight: 600;
    line-height: 1.1;
    color: var(--text);
  }

  .metric-sub {
    font-size: 0.72rem;
    color: var(--muted);
    font-family: "IBM Plex Mono", monospace;
  }

  .metric-sub .ok    { color: var(--green); }
  .metric-sub .warn  { color: var(--amber); }
  .metric-sub .crit  { color: var(--danger); }

  .gauge-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
    gap: 1rem;
    margin-bottom: 2rem;
  }

  .gauge-card {
    background: var(--surface);
    border: 1px solid var(--border);
    padding: 1.25rem 1.5rem;
  }

  .gauge-header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 0.75rem;
  }

  .gauge-name {
    font-size: 0.65rem;
    font-family: "IBM Plex Mono", monospace;
    letter-spacing: 0.1em;
    color: var(--muted);
    text-transform: uppercase;
  }

  .gauge-numbers {
    font-family: "IBM Plex Mono", monospace;
    font-size: 0.8rem;
    color: var(--text);
  }

  .gauge-numbers span {
    color: var(--muted);
    font-size: 0.7rem;
  }

  .bar-track {
    height: 4px;
    background: var(--border);
    width: 100%;
    position: relative;
  }

  .bar-fill {
    height: 100%;
    background: var(--fill-color, var(--green));
    transition: width 0.6s ease;
  }

  .pod-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 1px;
    background: var(--border);
    border: 1px solid var(--border);
    margin-bottom: 2rem;
  }

  .pod-item {
    background: var(--surface);
    padding: 1rem 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .pod-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    display: inline-block;
    margin-right: 6px;
    vertical-align: middle;
  }

  .pod-label {
    font-size: 0.65rem;
    font-family: "IBM Plex Mono", monospace;
    letter-spacing: 0.08em;
    color: var(--muted);
    text-transform: uppercase;
    display: flex;
    align-items: center;
  }

  .pod-val {
    font-family: "IBM Plex Mono", monospace;
    font-size: 1.5rem;
    font-weight: 600;
  }

  .node-health {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
    margin-bottom: 2rem;
  }

  .node-chip {
    font-family: "IBM Plex Mono", monospace;
    font-size: 0.68rem;
    padding: 4px 10px;
    border: 1px solid var(--border);
    background: var(--surface);
    color: var(--muted);
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .node-chip .dot {
    width: 6px; height: 6px;
    border-radius: 50%;
    background: var(--green);
    flex-shrink: 0;
  }

  footer {
    border-top: 1px solid var(--border);
    padding-top: 1rem;
    margin-top: 1rem;
    font-family: "IBM Plex Mono", monospace;
    font-size: 0.65rem;
    color: var(--muted);
    display: flex;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 0.5rem;
  }

  .no-metrics {
    font-family: "IBM Plex Mono", monospace;
    font-size: 0.7rem;
    color: var(--amber);
    padding: 0.5rem 0;
  }
</style>
</head>
<body>

<header>
  <div class="logo">
    <svg width="32" height="32" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="16" cy="16" r="15.5" stroke="#cc0000" stroke-width="1"/>
      <circle cx="16" cy="16" r="6" fill="#cc0000"/>
      <line x1="16" y1="1" x2="16" y2="8" stroke="#cc0000" stroke-width="1.5"/>
      <line x1="16" y1="24" x2="16" y2="31" stroke="#cc0000" stroke-width="1.5"/>
      <line x1="1" y1="16" x2="8" y2="16" stroke="#cc0000" stroke-width="1.5"/>
      <line x1="24" y1="16" x2="31" y2="16" stroke="#cc0000" stroke-width="1.5"/>
      <line x1="4.5" y1="4.5" x2="9.5" y2="9.5" stroke="#cc0000" stroke-width="1"/>
      <line x1="22.5" y1="22.5" x2="27.5" y2="27.5" stroke="#cc0000" stroke-width="1"/>
      <line x1="27.5" y1="4.5" x2="22.5" y2="9.5" stroke="#cc0000" stroke-width="1"/>
      <line x1="9.5" y1="22.5" x2="4.5" y2="27.5" stroke="#cc0000" stroke-width="1"/>
    </svg>
    <div class="logo-text">
      <strong id="cluster-name">cluster</strong>
      OpenShift Container Platform
    </div>
  </div>
  <div class="meta">
    <div>Generated: <span id="ts"></span></div>
    <div>Version: <span class="version" id="ocp-ver">—</span></div>
    <div id="metrics-note"></div>
  </div>
</header>

<div class="section-title">infrastructure</div>

<div class="grid-4">
  <div class="metric-card accent-red">
    <div class="metric-label">Worker nodes</div>
    <div class="metric-value" id="workers">—</div>
    <div class="metric-sub"><span id="nodes-ready-sub"></span></div>
  </div>
  <div class="metric-card accent-blue">
    <div class="metric-label">Control plane</div>
    <div class="metric-value" id="masters">—</div>
    <div class="metric-sub">master nodes</div>
  </div>
  <div class="metric-card accent-green">
    <div class="metric-label">Namespaces</div>
    <div class="metric-value" id="namespaces">—</div>
    <div class="metric-sub">across all projects</div>
  </div>
  <div class="metric-card accent-amber">
    <div class="metric-label">Total nodes</div>
    <div class="metric-value" id="nodes-total">—</div>
    <div class="metric-sub" id="nodes-health-sub"></div>
  </div>
</div>

<div class="section-title">resource utilization</div>

<div class="gauge-row">
  <div class="gauge-card">
    <div class="gauge-header">
      <span class="gauge-name">CPU (cores)</span>
      <span class="gauge-numbers"><span id="cpu-used">—</span> / <span id="cpu-alloc">—</span> <span>allocatable</span></span>
    </div>
    <div class="bar-track">
      <div class="bar-fill" id="cpu-bar" style="width:0%; --fill-color: var(--green)"></div>
    </div>
    <div class="metric-sub" style="margin-top:6px" id="cpu-pct">—</div>
  </div>

  <div class="gauge-card">
    <div class="gauge-header">
      <span class="gauge-name">Memory (GiB)</span>
      <span class="gauge-numbers"><span id="mem-used">—</span> / <span id="mem-alloc">—</span> <span>allocatable</span></span>
    </div>
    <div class="bar-track">
      <div class="bar-fill" id="mem-bar" style="width:0%; --fill-color: var(--blue)"></div>
    </div>
    <div class="metric-sub" style="margin-top:6px" id="mem-pct">—</div>
  </div>
</div>

<div class="section-title">application pods (excl. system namespaces)</div>

<div class="pod-row">
  <div class="pod-item">
    <div class="pod-label"><span class="pod-dot" style="background:var(--muted)"></span>total</div>
    <div class="pod-val" id="pods-total">—</div>
  </div>
  <div class="pod-item">
    <div class="pod-label"><span class="pod-dot" style="background:var(--green)"></span>running</div>
    <div class="pod-val" style="color:var(--green)" id="pods-running">—</div>
  </div>
  <div class="pod-item">
    <div class="pod-label"><span class="pod-dot" style="background:var(--amber)"></span>pending</div>
    <div class="pod-val" style="color:var(--amber)" id="pods-pending">—</div>
  </div>
  <div class="pod-item">
    <div class="pod-label"><span class="pod-dot" style="background:var(--danger)"></span>failed</div>
    <div class="pod-val" style="color:var(--danger)" id="pods-failed">—</div>
  </div>
</div>

<footer>
  <span>ocp_report.sh — cluster summary</span>
  <span id="footer-cluster">—</span>
</footer>

<script>
const D = __DATA_PLACEHOLDER__;

document.getElementById("cluster-name").textContent  = D.cluster_name;
document.getElementById("ocp-ver").textContent        = D.ocp_version;
document.getElementById("ts").textContent             = D.timestamp;
document.getElementById("footer-cluster").textContent = D.cluster_name + " · " + D.timestamp;

if (!D.metrics_available) {
  document.getElementById("metrics-note").innerHTML =
    '<span style="color:var(--amber)">⚠ metrics-server unavailable — usage N/A</span>';
}

document.getElementById("workers").textContent       = D.nodes.workers;
document.getElementById("masters").textContent       = D.nodes.masters;
document.getElementById("nodes-total").textContent   = D.nodes.total;
document.getElementById("namespaces").textContent    = D.namespaces;

const notReady = D.nodes.total - D.nodes.ready;
const readySub = document.getElementById("nodes-ready-sub");
readySub.innerHTML = notReady === 0
  ? '<span class="ok">' + D.nodes.ready + '/' + D.nodes.total + ' ready</span>'
  : '<span class="warn">' + D.nodes.ready + '/' + D.nodes.total + ' ready</span>';

document.getElementById("nodes-health-sub").innerHTML = notReady === 0
  ? '<span class="ok">all nodes healthy</span>'
  : '<span class="crit">' + notReady + ' not ready</span>';

function pct(used, total) { return total > 0 ? Math.round(used/total*100) : 0; }
function barColor(p) { return p >= 85 ? "var(--danger)" : p >= 70 ? "var(--amber)" : "var(--green)"; }

const cpuPct = pct(D.cpu.used, D.cpu.allocatable);
document.getElementById("cpu-used").textContent  = D.metrics_available ? D.cpu.used : "N/A";
document.getElementById("cpu-alloc").textContent = D.cpu.allocatable;
const cpuBar = document.getElementById("cpu-bar");
cpuBar.style.width = (D.metrics_available ? cpuPct : 0) + "%";
cpuBar.style.setProperty("--fill-color", barColor(cpuPct));
document.getElementById("cpu-pct").textContent = D.metrics_available
  ? cpuPct + "% utilization"
  : "usage data unavailable";

const memPct = pct(D.memory.used_gi, D.memory.allocatable_gi);
document.getElementById("mem-used").textContent  = D.metrics_available ? D.memory.used_gi : "N/A";
document.getElementById("mem-alloc").textContent = D.memory.allocatable_gi;
const memBar = document.getElementById("mem-bar");
memBar.style.width = (D.metrics_available ? memPct : 0) + "%";
memBar.style.setProperty("--fill-color", barColor(memPct));
document.getElementById("mem-pct").textContent = D.metrics_available
  ? memPct + "% utilization"
  : "usage data unavailable";

document.getElementById("pods-total").textContent   = D.pods.total;
document.getElementById("pods-running").textContent = D.pods.running;
document.getElementById("pods-pending").textContent = D.pods.pending;
document.getElementById("pods-failed").textContent  = D.pods.failed;
</script>
</body>
</html>'

# Replace placeholder with actual JSON data
ESCAPED_JSON=$(echo "$JSON_DATA" | python3 -c "import sys; print(sys.stdin.read().strip())")
echo "${HTML_TEMPLATE//__DATA_PLACEHOLDER__/$ESCAPED_JSON}" > "$OUTPUT"

log "Done. Report saved: $OUTPUT"
echo "$OUTPUT"