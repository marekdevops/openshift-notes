#!/bin/bash
# audit-window.sh — kto zapisywał do API w zadanym oknie (czasy w UTC)
FROM="${1:-2026-10-23T12:15}"; TO="${2:-2026-10-23T12:35}"
F=${FROM//:/-}; T=${TO//:/-}
OUT=/tmp/audit-window; mkdir -p $OUT; : > $OUT/hits.txt

MASTERS=$(oc get nodes -l node-role.kubernetes.io/control-plane -o name | cut -d/ -f2)
[ -z "$MASTERS" ] && MASTERS=$(oc get nodes -l node-role.kubernetes.io/master -o name | cut -d/ -f2)
echo "Okno $FROM - $TO UTC | mastery: $(echo $MASTERS | wc -w)"

for n in $MASTERS; do
  for f in $(oc adm node-logs $n --path=kube-apiserver/ | grep -oE 'audit[^ ]*\.log' | sort); do
    ts=${f#audit-}; ts=${ts%.log}; [ "$f" = audit.log ] && ts=9999
    [[ "$ts" > "$F" ]] || continue
    oc adm node-logs $n --path=kube-apiserver/$f | sed 's/^[^{]*//' > $OUT/raw.json
    range=$(jq -R -r 'fromjson? | .requestReceivedTimestamp' $OUT/raw.json | sed -n '1p;$p' | cut -c12-19 | paste -sd-)
    hits=$(jq -R -r --arg a "$FROM" --arg b "$TO" 'fromjson?
      | select(.requestReceivedTimestamp > $a and .requestReceivedTimestamp < $b)
      | select(.verb|test("create|update|patch|delete"))
      | "\(.user.username) \(.verb) \(.objectRef.resource) \(.objectRef.namespace // "-")"' $OUT/raw.json \
      | tee -a $OUT/hits.txt | wc -l)
    printf "%-10s %-40s linii:%-8s zakres:%-17s trafien:%s\n" "${n%%.*}" "$f" "$(wc -l < $OUT/raw.json)" "$range" "$hits"
    [[ "$ts" > "$T" ]] && break
  done
done
rm -f $OUT/raw.json

echo; echo "== TOP 15: user / verb / zasob =="
awk '{print $1, $2, $3}' $OUT/hits.txt | sort | uniq -c | sort -rn | head -15
echo; echo "== TOP 10: zasob / namespace =="
awk '{print $3, $4}' $OUT/hits.txt | sort | uniq -c | sort -rn | head -10