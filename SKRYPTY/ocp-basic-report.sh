#!/usr/bin/env bash
# ocp_report.sh — OpenShift Cluster Summary
# Requires: oc CLI, logged in

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CLUSTER=$(oc config current-context 2>/dev/null | sed 's|.*/||' || echo "unknown")
VERSION=$(oc version 2>/dev/null | awk '/Server Version/{print $3}')

# Worker nodes only: has worker label, no master, no infra
WORKER_ALLOC=$(oc get nodes \
  -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master,!node-role.kubernetes.io/infra' \
  -o custom-columns='CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory' \
  --no-headers 2>/dev/null)

WORKERS=$(echo "$WORKER_ALLOC" | grep -c . || echo 0)

read CPU_TOTAL MEM_TOTAL <<< $(echo "$WORKER_ALLOC" | awk '
{
  cpu=$1; mem=$2
  if (cpu~/m$/) { sub(/m$/,"",cpu); c+=cpu/1000 } else { c+=cpu+0 }
  if      (mem~/Ki$/) { sub(/Ki$/,"",mem); m+=mem/1024/1024 }
  else if (mem~/Mi$/) { sub(/Mi$/,"",mem); m+=mem/1024 }
  else if (mem~/Gi$/) { sub(/Gi$/,"",mem); m+=mem+0 }
}
END { printf "%.1f %.1f", c, m }')

# Pods — app namespaces only
SYS='^openshift-|^kube-|^open-cluster-|^multicluster-|^hive|^assisted-installer|^default$'
APP_PODS=$(oc get pods -A --no-headers 2>/dev/null | awk -v p="$SYS" '$1!~p')
PODS_TOTAL=$(  echo "$APP_PODS" | grep -c . 2>/dev/null || echo 0)
PODS_RUNNING=$(echo "$APP_PODS" | awk '$4=="Running"'               | wc -l | tr -d ' ')
PODS_PENDING=$(echo "$APP_PODS" | awk '$4=="Pending"'               | wc -l | tr -d ' ')
PODS_FAILED=$( echo "$APP_PODS" | awk '$4=="Failed"||$4=="Unknown"' | wc -l | tr -d ' ')

echo "=============================="
echo "  OCP Cluster: $CLUSTER"
echo "  Version    : $VERSION"
echo "  Time       : $TIMESTAMP"
echo "=============================="
echo ""
echo "  Worker nodes : $WORKERS"
echo "  CPU (alloc)  : ${CPU_TOTAL} cores"
echo "  RAM (alloc)  : ${MEM_TOTAL} GiB"
echo ""
echo "  Pods total   : $PODS_TOTAL"
echo "  Pods running : $PODS_RUNNING"
echo "  Pods pending : $PODS_PENDING"
echo "  Pods failed  : $PODS_FAILED"
echo "=============================="