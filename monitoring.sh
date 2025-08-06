#!/bin/bash
NS="$1"

# Bieżące zużycie
read cpu_used mem_used <<< $(oc adm top pod -n "$NS" --no-headers \
  | awk '{cpu+=$2; mem+=$3} END {print cpu, mem}')

# Requests i Limits z resourcequotas (jeśli istnieją)
cpu_req=$(oc get quota -n "$NS" -o jsonpath='{.items[*].status.hard.cpu}' 2>/dev/null | sed 's/m//')
mem_req=$(oc get quota -n "$NS" -o jsonpath='{.items[*].status.hard.memory}' 2>/dev/null | sed 's/Mi//')
cpu_lim=$(oc get quota -n "$NS" -o jsonpath='{.items[*].status.hard.limits\.cpu}' 2>/dev/null | sed 's/m//')
mem_lim=$(oc get quota -n "$NS" -o jsonpath='{.items[*].status.hard.limits\.memory}' 2>/dev/null | sed 's/Mi//')

# Procentowe użycie (tylko jeśli limity są ustawione)
cpu_pct="N/A"
mem_pct="N/A"
if [[ -n "$cpu_lim" && "$cpu_lim" != "<no value>" ]]; then
  cpu_pct=$((cpu_used * 100 / cpu_lim))"%"
fi
if [[ -n "$mem_lim" && "$mem_lim" != "<no value>" ]]; then
  mem_pct=$((mem_used * 100 / mem_lim))"%"
fi

# Wynik
echo "Namespace: $NS"
echo "CPU usage: ${cpu_used}m / ${cpu_lim:-'no limit'} (${cpu_pct})"
echo "Mem usage: ${mem_used}Mi / ${mem_lim:-'no limit'} (${mem_pct})"
echo "Requests:  CPU ${cpu_req:-'-'}m, Memory ${mem_req:-'-'}Mi"
