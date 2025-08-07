#!/bin/bash

echo -e "NODE\tALLOCATABLE(m)\tREQUESTED(m)\tLIMITED(m)\tUSAGE(m)"

for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  allocatable=$(oc get node "$node" -o json | jq -r '.status.allocatable.cpu' | sed 's/[^0-9]//g')
  allocatable_m=$((allocatable * 1000))

  # Podsumowanie requests i limits dla wszystkich podów na tym node
  pods=$(oc get pods --all-namespaces --field-selector spec.nodeName="$node" -o json)

  requested=$(echo "$pods" | jq '[.items[].spec.containers[].resources.requests.cpu // "0"] |
    map(if test("m") then sub("m"; "") | tonumber else (tonumber * 1000) end) | add')

  limited=$(echo "$pods" | jq '[.items[].spec.containers[].resources.limits.cpu // "0"] |
    map(if test("m") then sub("m"; "") | tonumber else (tonumber * 1000) end) | add')

  # Rzeczywiste użycie (z oc adm top node)
  usage=$(oc adm top node "$node" --no-headers | awk '{print $3}' | sed 's/m//')

  echo -e "$node\t${allocatable_m}m\t${requested}m\t${limited}m\t${usage}m"
done
