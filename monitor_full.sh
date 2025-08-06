#!/bin/bash
set -euo pipefail

echo -e "NODE\tALLOC_MEM_GiB\tLIMITS_MEM_GiB\tUSED_MEM_GiB\tMEM_USED%_ALLOC\tOVERCOMMIT_MEM_%\tALLOC_CPU\tLIMITS_CPU\tUSED_CPU\tCPU_USED%_ALLOC\tOVERCOMMIT_CPU_%"

# Lista node’ów worker
for node in $(oc get nodes --selector='node-role.kubernetes.io/worker' -o name); do
  node_name="${node#*/}"

  #### ===== Allocatable: MEMORY =====
  alloc_mem=$(oc get node "$node_name" -o jsonpath='{.status.allocatable.memory}')
  if [[ "$alloc_mem" =~ Ki$ ]]; then
    alloc_mem_gib=$(echo "scale=4; ${alloc_mem%Ki} / 1048576" | bc)
  elif [[ "$alloc_mem" =~ Mi$ ]]; then
    alloc_mem_gib=$(echo "scale=4; ${alloc_mem%Mi} / 1024" | bc)
  elif [[ "$alloc_mem" =~ Gi$ ]]; then
    alloc_mem_gib=$(echo "scale=4; ${alloc_mem%Gi}" | bc)
  else
    # bajty
    alloc_mem_gib=$(echo "scale=4; $alloc_mem / 1073741824" | bc)
  fi

  #### ===== Limits SUM: MEMORY =====
  limits_mem_gib=$(oc get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json \
    | jq -r '[.items[].spec.containers[].resources.limits.memory // "0"]
      | map(
          if test("Ki$") then (. | sub("Ki$"; "") | tonumber / 1048576)
          elif test("Mi$") then (. | sub("Mi$"; "") | tonumber / 1024)
          elif test("Gi$") then (. | sub("Gi$"; "") | tonumber)
          else 0 end
        )
      | add')

  #### ===== Actual usage: MEMORY =====
  # oc adm top node zwraca m.in. kolumnę "MEMORY(bytes)" np. 12345Mi / 12Gi
  read -r _ _ _ mem_used_raw _ < <(oc adm top node "$node_name" --no-headers | awk '{print $1,$2,$3,$4,$5}')
  if [[ "$mem_used_raw" =~ Ki$ ]]; then
    used_mem_gib=$(echo "scale=4; ${mem_used_raw%Ki} / 1048576" | bc)
  elif [[ "$mem_used_raw" =~ Mi$ ]]; then
    used_mem_gib=$(echo "scale=4; ${mem_used_raw%Mi} / 1024" | bc)
  elif [[ "$mem_used_raw" =~ Gi$ ]]; then
    used_mem_gib=$(echo "scale=4; ${mem_used_raw%Gi}" | bc)
  else
    # bajty
    used_mem_gib=$(echo "scale=4; $mem_used_raw / 1073741824" | bc)
  fi

  #### ===== Procenty: MEMORY =====
  if [[ $(echo "$alloc_mem_gib > 0" | bc) -eq 1 ]]; then
    mem_used_pct_alloc=$(echo "scale=1; ($used_mem_gib / $alloc_mem_gib) * 100" | bc)
    overcommit_mem_pct=$(echo "scale=1; ($limits_mem_gib / $alloc_mem_gib) * 100" | bc)
  else
    mem_used_pct_alloc="N/A"
    overcommit_mem_pct="N/A"
  fi

  #### ===== Allocatable: CPU (cores) =====
  alloc_cpu=$(oc get node "$node_name" -o jsonpath='{.status.allocatable.cpu}')
  if [[ "$alloc_cpu" =~ m$ ]]; then
    alloc_cpu_cores=$(echo "scale=4; ${alloc_cpu%m} / 1000" | bc)
  else
    alloc_cpu_cores=$(echo "scale=4; $alloc_cpu" | bc)
  fi

  #### ===== Limits SUM: CPU (cores) =====
  limits_cpu_cores=$(oc get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json \
    | jq -r '[.items[].spec.containers[].resources.limits.cpu // "0"]
      | map(
          if test("m$") then (. | sub("m$"; "") | tonumber / 1000)
          else (. | tonumber)
          end
        )
      | add')

  #### ===== Actual usage: CPU (cores) =====
  # oc adm top node zwraca "CPU(cores)" np. 2500m / 2
  cpu_used_raw=$(oc adm top node "$node_name" --no-headers | awk '{print $2}')
  if [[ "$cpu_used_raw" =~ m$ ]]; then
    used_cpu_cores=$(echo "scale=4; ${cpu_used_raw%m} / 1000" | bc)
  else
    used_cpu_cores=$(echo "scale=4; $cpu_used_raw" | bc)
  fi

  #### ===== Procenty: CPU =====
  if [[ $(echo "$alloc_cpu_cores > 0" | bc) -eq 1 ]]; then
    cpu_used_pct_alloc=$(echo "scale=1; ($used_cpu_cores / $alloc_cpu_cores) * 100" | bc)
    overcommit_cpu_pct=$(echo "scale=1; ($limits_cpu_cores / $alloc_cpu_cores) * 100" | bc)
  else
    cpu_used_pct_alloc="N/A"
    overcommit_cpu_pct="N/A"
  fi

  #### ===== Output =====
  printf "%s\t%.1f\t%.1f\t%.1f\t%s\t%s\t%.1f\t%.1f\t%.1f\t%s\t%s\n" \
    "$node_name" \
    "$alloc_mem_gib" "$limits_mem_gib" "$used_mem_gib" "$mem_used_pct_alloc%" "$overcommit_mem_pct%" \
    "$alloc_cpu_cores" "$limits_cpu_cores" "$used_cpu_cores" "$cpu_used_pct_alloc%" "$overcommit_cpu_pct%"
done
