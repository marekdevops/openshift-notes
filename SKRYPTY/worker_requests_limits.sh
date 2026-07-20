#!/bin/bash
set -euo pipefail

# worker_requests_limits.sh
# Raport sumy REQUESTS i LIMITS (CPU + RAM) wszystkich podów per worker,
# odniesiony do wartości allocatable danego node'a.
#
# Kolumny:
#   NODE
#   ALLOC_CPU / REQ_CPU / LIM_CPU        (w rdzeniach)
#   REQ_CPU%  / LIM_CPU%                 (% allocatable = overcommit)
#   ALLOC_MEM / REQ_MEM / LIM_MEM        (w GiB)
#   REQ_MEM%  / LIM_MEM%                 (% allocatable = overcommit)
#
# Wymagane: oc (zalogowany), jq, bc
# Użycie:
#   ./worker_requests_limits.sh                 # wszystkie workery
#   ./worker_requests_limits.sh worker-03       # tylko jeden node

set -o pipefail

NODE_FILTER="${1:-}"

# --- jq: sumuje pole resources.<requests|limits>.<cpu|memory> ze wszystkich kontenerów ---
# CPU zwracamy w rdzeniach, pamięć w GiB.
JQ_CPU='
  [ .items[].spec.containers[].resources.'"'"'FIELD'"'"'.cpu // "0" ]
  | map(
      if   test("n$")  then (sub("n$";"")  | tonumber / 1000000000)
      elif test("u$")  then (sub("u$";"")  | tonumber / 1000000)
      elif test("m$")  then (sub("m$";"")  | tonumber / 1000)
      else (tonumber)
      end
    )
  | add // 0'

JQ_MEM='
  [ .items[].spec.containers[].resources.'"'"'FIELD'"'"'.memory // "0" ]
  | map(
      if   test("Ki$") then (sub("Ki$";"") | tonumber / 1048576)
      elif test("Mi$") then (sub("Mi$";"") | tonumber / 1024)
      elif test("Gi$") then (sub("Gi$";"") | tonumber)
      elif test("Ti$") then (sub("Ti$";"") | tonumber * 1024)
      elif test("[0-9]$") then (tonumber / 1073741824)
      else 0
      end
    )
  | add // 0'

# Zamiana allocatable CPU (np. "8", "7500m") na rdzenie
cpu_to_cores() {
  local v="$1"
  if [[ "$v" =~ m$ ]]; then
    echo "scale=4; ${v%m} / 1000" | bc
  else
    echo "scale=4; $v" | bc
  fi
}

# Zamiana allocatable MEM (Ki/Mi/Gi/bajty) na GiB
mem_to_gib() {
  local v="$1"
  if   [[ "$v" =~ Ki$ ]]; then echo "scale=4; ${v%Ki} / 1048576" | bc
  elif [[ "$v" =~ Mi$ ]]; then echo "scale=4; ${v%Mi} / 1024"    | bc
  elif [[ "$v" =~ Gi$ ]]; then echo "scale=4; ${v%Gi}"           | bc
  else                         echo "scale=4; $v / 1073741824"   | bc
  fi
}

pct() { # $1/$2 * 100, N/A gdy dzielnik = 0
  if (( $(echo "$2 == 0" | bc -l) )); then echo "N/A"; else
    echo "scale=1; ($1 / $2) * 100" | bc
  fi
}

printf "NODE\tALLOC_CPU\tREQ_CPU\tLIM_CPU\tREQ_CPU%%\tLIM_CPU%%\tALLOC_MEM_GiB\tREQ_MEM_GiB\tLIM_MEM_GiB\tREQ_MEM%%\tLIM_MEM%%\n"

for node in $(oc get nodes --selector='node-role.kubernetes.io/worker' -o name); do
  node_name="${node#*/}"
  [[ -n "$NODE_FILTER" && "$node_name" != "$NODE_FILTER" ]] && continue

  # Allocatable
  alloc_cpu=$(cpu_to_cores "$(oc get node "$node_name" -o jsonpath='{.status.allocatable.cpu}')")
  alloc_mem=$(mem_to_gib  "$(oc get node "$node_name" -o jsonpath='{.status.allocatable.memory}')")

  # Pody na tym node (jeden pobór JSON, wielokrotne przeliczenia jq)
  pods_json=$(oc get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json)

  req_cpu=$(echo "$pods_json" | jq -r "${JQ_CPU/FIELD/requests}")
  lim_cpu=$(echo "$pods_json" | jq -r "${JQ_CPU/FIELD/limits}")
  req_mem=$(echo "$pods_json" | jq -r "${JQ_MEM/FIELD/requests}")
  lim_mem=$(echo "$pods_json" | jq -r "${JQ_MEM/FIELD/limits}")

  printf "%s\t%.2f\t%.2f\t%.2f\t%s%%\t%s%%\t%.2f\t%.2f\t%.2f\t%s%%\t%s%%\n" \
    "$node_name" \
    "$alloc_cpu" "$req_cpu" "$lim_cpu" "$(pct "$req_cpu" "$alloc_cpu")" "$(pct "$lim_cpu" "$alloc_cpu")" \
    "$alloc_mem" "$req_mem" "$lim_mem" "$(pct "$req_mem" "$alloc_mem")" "$(pct "$lim_mem" "$alloc_mem")"
done | column -t -s $'\t'
