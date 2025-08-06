#!/bin/bash

echo -e "NODE\tALLOC_MEM_GiB\tLIMITS_MEM_GiB\tOVERCOMMIT_MEM_%\tALLOC_CPU\tLIMITS_CPU\tOVERCOMMIT_CPU_%"

# Pobierz listę worker node’ów
for node in $(oc get nodes --selector='node-role.kubernetes.io/worker' -o name); do
    node_name=$(echo $node | cut -d'/' -f2)

    # ===== Pamięć =====
    alloc_mem=$(oc get node $node_name -o jsonpath='{.status.allocatable.memory}')
    if [[ "$alloc_mem" =~ Ki$ ]]; then
        alloc_mem_gib=$(echo "${alloc_mem%Ki} / 1048576" | bc -l)
    elif [[ "$alloc_mem" =~ Mi$ ]]; then
        alloc_mem_gib=$(echo "${alloc_mem%Mi} / 1024" | bc -l)
    elif [[ "$alloc_mem" =~ Gi$ ]]; then
        alloc_mem_gib="${alloc_mem%Gi}"
    else
        alloc_mem_gib=$(echo "$alloc_mem / 1073741824" | bc -l)
    fi

    limits_mem_gib=$(oc get pods --all-namespaces --field-selector spec.nodeName=$node_name -o json \
      | jq '[.items[].spec.containers[].resources.limits.memory // "0"]
        | map(
            if test("Ki$") then (. | sub("Ki$"; "") | tonumber / 1048576)
            elif test("Mi$") then (. | sub("Mi$"; "") | tonumber / 1024)
            elif test("Gi$") then (. | sub("Gi$"; "") | tonumber)
            else 0 end
          )
        | add')

    if (( $(echo "$alloc_mem_gib > 0" | bc -l) )); then
        overcommit_mem_pct=$(echo "scale=1; ($limits_mem_gib / $alloc_mem_gib) * 100" | bc -l)
    else
        overcommit_mem_pct="N/A"
    fi

    # ===== CPU =====
    alloc_cpu=$(oc get node $node_name -o jsonpath='{.status.allocatable.cpu}')
    if [[ "$alloc_cpu" =~ m$ ]]; then
        alloc_cpu_cores=$(echo "${alloc_cpu%m} / 1000" | bc -l)
    else
        alloc_cpu_cores=$(echo "$alloc_cpu" | bc -l)
    fi

    limits_cpu_cores=$(oc get pods --all-namespaces --field-selector spec.nodeName=$node_name -o json \
      | jq '[.items[].spec.containers[].resources.limits.cpu // "0"]
        | map(
            if test("m$") then (. | sub("m$"; "") | tonumber / 1000)
            else (. | tonumber)
            end
          )
        | add')

    if (( $(echo "$alloc_cpu_cores > 0" | bc -l) )); then
        overcommit_cpu_pct=$(echo "scale=1; ($limits_cpu_cores / $alloc_cpu_cores) * 100" | bc -l)
    else
        overcommit_cpu_pct="N/A"
    fi

    # ===== Output =====
    printf "%s\t%.1f\t%.1f\t%s%%\t%.1f\t%.1f\t%s%%\n" \
      "$node_name" "$alloc_mem_gib" "$limits_mem_gib" "$overcommit_mem_pct" \
      "$alloc_cpu_cores" "$limits_cpu_cores" "$overcommit_cpu_pct"
done
