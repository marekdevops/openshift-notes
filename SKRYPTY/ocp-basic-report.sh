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

echo ""
echo "[ NODES ]"
echo "------------------------------------------------------------"
oc get nodes --no-headers -o wide 2>/dev/null | awk '
{
  name=$1; status=$2; role=$3; ver=$5; os=$6
  printf "  %-40s %-10s %-30s\n", name, status, role
}'
echo ""
WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
MASTERS=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
echo "  Total: $TOTAL  |  Masters: $MASTERS  |  Workers: $WORKERS  |  Ready: $READY"

echo ""
echo "[ RESOURCE UTILIZATION ]"
echo "------------------------------------------------------------"
if oc adm top nodes --no-headers 2>/dev/null | grep -q .; then
  echo "  Node                                     CPU          CPU%   Memory       Mem%"
  oc adm top nodes --no-headers 2>/dev/null | awk '{printf "  %-40s %-12s %-6s %-12s %-6s\n", $1, $2, $3, $4, $5}'
else
  echo "  metrics-server unavailable"
fi

echo ""
echo "[ ALLOCATABLE RESOURCES ]"
echo "------------------------------------------------------------"
oc get nodes --no-headers -o custom-columns=\
'NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory' 2>/dev/null | \
awk 'NR>0 {printf "  %-40s CPU: %-8s  RAM: %s\n", $1, $2, $3}'

echo ""
echo "[ PODS — APPLICATION NAMESPACES ONLY ]"
echo "------------------------------------------------------------"
SYSTEM_PATTERN="^openshift-\|^kube-\|^open-cluster-\|^multicluster-\|^hive\|^assisted-installer\|^default$"
APP_PODS=$(oc get pods -A --no-headers 2>/dev/null | awk -v pat="$SYSTEM_PATTERN" '$1 !~ pat')
PODS_TOTAL=$(echo "$APP_PODS"   | grep -c . || true)
PODS_RUNNING=$(echo "$APP_PODS" | awk '$4=="Running"'  | wc -l | tr -d ' ')
PODS_PENDING=$(echo "$APP_PODS" | awk '$4=="Pending"'  | wc -l | tr -d ' ')
PODS_FAILED=$(echo "$APP_PODS"  | awk '$4=="Failed" || $4=="Unknown"' | wc -l | tr -d ' ')
echo "  Total: $PODS_TOTAL  |  Running: $PODS_RUNNING  |  Pending: $PODS_PENDING  |  Failed: $PODS_FAILED"

echo ""
echo "[ NAMESPACES ]"
echo "------------------------------------------------------------"
NS_TOTAL=$(oc get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
NS_APP=$(oc get namespaces --no-headers 2>/dev/null | awk -v pat="$SYSTEM_PATTERN" '$1 !~ pat' | wc -l | tr -d ' ')
echo "  Total: $NS_TOTAL  |  Application: $NS_APP  |  System: $((NS_TOTAL - NS_APP))"

echo ""
echo "============================================================"
echo "  End of report — $TIMESTAMP"
echo "============================================================"