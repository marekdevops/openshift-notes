#!/bin/bash

echo -e "NODE\tALLOCATABLE_GiB\tLIMITS_SUM_GiB\tOVERCOMMIT_%"

# Pobierz listę nodów roboczych
for node in $(oc get nodes --selector='node-role.kubernetes.io/worker' -o name); do
    node_name=$(echo $node | cut -d'/' -f2)

    # Allocatable memory (w bajtach -> GiB)
    alloc_bytes=$(oc get node $node_name -o jsonpath='{.status.allocatable.memory}')
    if [[ "$alloc_bytes" =~ Ki$ ]]; then
        alloc_gib=$(echo "${alloc_bytes%Ki} / 1048576" | bc -l)
    elif [[ "$alloc_bytes" =~ Mi$ ]]; then
        alloc_gib=$(echo "${alloc_bytes%Mi} / 1024" | bc -l)
    elif [[ "$alloc_bytes" =~ Gi$ ]]; then
        alloc_gib="${alloc_bytes%Gi}"
    else
        alloc_gib=$(echo "$alloc_bytes / 1073741824" | bc -l)
    fi

    # Suma limitów pamięci wszystkich podów na tym node (GiB)
    limits_sum_gib=$(oc get pods --all-namespaces --field-selector spec.nodeName=$node_name -o json \
      | jq '[.items[].spec.containers[].resources.limits.memory // "0"]
        | map(
            if test("Ki$") then (. | sub("Ki$"; "") | tonumber / 1048576)
            elif test("Mi$") then (. | sub("Mi$"; "") | tonumber / 1024)
            elif test("Gi$") then (. | sub("Gi$"; "") | tonumber)
            else 0 end
          )
        | add' )

    # Overcommit %
    if (( $(echo "$alloc_gib > 0" | bc -l) )); then
        overcommit_pct=$(echo "scale=1; ($limits_sum_gib / $alloc_gib) * 100" | bc -l)
    else
        overcommit_pct="N/A"
    fi

    printf "%s\t%.1f\t%.1f\t%s%%\n" "$node_name" "$alloc_gib" "$limits_sum_gib" "$overcommit_pct"
done
