#!/usr/bin/env bash
# ocp_report.sh — OpenShift Cluster Summary Report
# Usage: ./ocp_report.sh
# Requires: oc CLI, logged in

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CLUSTER=$(oc config current-context 2>/dev/null | sed 's|.*/||' || echo "unknown")
VERSION=$(oc version 2>/dev/null | awk '/Server Version/{print $3}')

echo "============================================================"
echo "  OpenShift Cluster Report"
echo "  Cluster : $CLUSTER"
echo "  Version : $VERSION"
echo "  Time    : $TIMESTAMP"
echo "============================================================"

# ── Nodes ─────────────────────────────────────────────────────
echo ""
echo "[ NODES ]"
echo "------------------------------------------------------------"
oc get nodes --no-headers 2>/dev/null | \
  awk '{printf "  %-45s %-10s %s\n", $1, $2, $3}'

echo ""
TOTAL=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
MASTERS=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l | tr -d ' ')
INFRA=$(oc get nodes -l node-role.kubernetes.io/infra --no-headers 2>/dev/null | wc -l | tr -d ' ')
WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null \
  | grep -v -e "master" -e "infra" | wc -l | tr -d ' ')
echo "  Total: $TOTAL  |  Ready: $READY  |  Workers: $WORKERS  |  Masters: $MASTERS  |  Infra: $INFRA"

# ── Allocatable CPU + RAM (workers only, summed) ──────────────
echo ""
echo "[ ALLOCATABLE RESOURCES — WORKER NODES ONLY ]"
echo "------------------------------------------------------------"

oc get nodes -l node-role.kubernetes.io/worker \
  -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory' \
  --no-headers 2>/dev/null | grep -v -e "master" -e "infra" | \
awk '
{
  printf "  %-45s CPU: %-10s RAM: %s\n", $1, $2, $3
  # CPU sum
  cpu = $2
  if (cpu ~ /m$/) { sub(/m$/,"",cpu); cpu_total += cpu/1000 }
  else             { cpu_total += cpu+0 }
  # RAM sum
  mem = $3
  if      (mem ~ /Ki$/) { sub(/Ki$/,"",mem); mem_total += mem/1024/1024 }
  else if (mem ~ /Mi$/) { sub(/Mi$/,"",mem); mem_total += mem/1024 }
  else if (mem ~ /Gi$/) { sub(/Gi$/,"",mem); mem_total += mem+0 }
  count++
}
END {
  print  "  ----------------------------------------------------"
  printf "  %-45s CPU: %-10.1f RAM: %.1f GiB\n", \
         "TOTAL (" count " workers)", cpu_total, mem_total
}'

# ── Pods ───────────────────────────────────────────────────────
echo ""
echo "[ PODS — APPLICATION NAMESPACES ONLY ]"
echo "------------------------------------------------------------"
SYSTEM_PAT="^openshift-|^kube-|^open-cluster-|^multicluster-|^hive|^assisted-installer|^default$"
APP_PODS=$(oc get pods -A --no-headers 2>/dev/null | awk -v p="$SYSTEM_PAT" '$1 !~ p')
PODS_TOTAL=$(echo "$APP_PODS"   | grep -c . 2>/dev/null || echo 0)
PODS_RUNNING=$(echo "$APP_PODS" | awk '$4=="Running"'               | wc -l | tr -d ' ')
PODS_PENDING=$(echo "$APP_PODS" | awk '$4=="Pending"'               | wc -l | tr -d ' ')
PODS_FAILED=$(echo "$APP_PODS"  | awk '$4=="Failed"||$4=="Unknown"' | wc -l | tr -d ' ')
echo "  Total: $PODS_TOTAL  |  Running: $PODS_RUNNING  |  Pending: $PODS_PENDING  |  Failed: $PODS_FAILED"

# ── Namespaces ─────────────────────────────────────────────────
echo ""
echo "[ NAMESPACES ]"
echo "------------------------------------------------------------"
SYSTEM_PAT_GREP="^openshift-\|^kube-\|^open-cluster-\|^multicluster-\|^hive\|^assisted-installer\|^default$"
NS_TOTAL=$(oc get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
NS_APP=$(oc get namespaces --no-headers 2>/dev/null \
  | awk -v p="$SYSTEM_PAT_GREP" '$1 !~ p' | wc -l | tr -d ' ')
echo "  Total: $NS_TOTAL  |  Application: $NS_APP  |  System: $((NS_TOTAL - NS_APP))"

echo ""
echo "============================================================"
echo "  End of report — $TIMESTAMP"
echo "============================================================"