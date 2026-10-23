#!/bin/bash
# audit-ns.sh <namespace> [FROM] [TO]   — czasy w UTC
NS="$1"; FROM="${2:-2026-10-23T12:00}"; TO="${3:-2026-10-23T12:40}"
[ -z "$NS" ] && { echo "uzycie: $0 <namespace> [FROM] [TO]"; exit 1; }
F=${FROM//:/-}; T=${TO//:/-}
OUT=/tmp/audit-ns-$NS; mkdir -p $OUT; : > $OUT/ns.json

MASTERS=$(oc get nodes -l node-role.kubernetes.io/control-plane -o name | cut -d/ -f2)
[ -z "$MASTERS" ] && MASTERS=$(oc get nodes -l node-role.kubernetes.io/master -o name | cut -d/ -f2)
echo "NS=$NS | $FROM - $TO UTC | mastery: $(echo $MASTERS | wc -w)"

for n in $MASTERS; do
  for f in $(oc adm node-logs $n --path=kube-apiserver/ | grep -oE 'audit[^ ]*\.log' | sort); do
    ts=${f#audit-}; ts=${ts%.log}; [ "$f" = audit.log ] && ts=9999
    [[ "$ts" > "$F" ]] || continue
    cnt=$(oc adm node-logs $n --path=kube-apiserver/$f | sed 's/^[^{]*//' | \
      jq -R -c --arg ns "$NS" --arg a "$FROM" --arg b "$TO" 'fromjson?
        | select(.objectRef.namespace==$ns
                 and .requestReceivedTimestamp > $a and .requestReceivedTimestamp < $b
                 and (.verb|test("create|update|patch|delete")))' \
      | tee -a $OUT/ns.json | wc -l)
    printf "%-10s %-40s trafien:%s\n" "${n%%.*}" "$f" "$cnt"
    [[ "$ts" > "$T" ]] && break
  done
done
J=$OUT/ns.json

echo; echo "== Zapisy na minute (UTC) =="
jq -r '.requestReceivedTimestamp[11:16]' $J | sort | uniq -c

echo; echo "== TOP 10: user / verb / zasob =="
jq -r '"\(.user.username) \(.verb) \(.objectRef.resource)/\(.objectRef.subresource // "")"' $J \
  | sort | uniq -c | sort -rn | head -10

echo; echo "== TOP 15 obiektow =="
jq -r '"\(.objectRef.resource)/\(.objectRef.name // "-") \(.verb)"' $J \
  | sort | uniq -c | sort -rn | head -15

echo; echo "== Zmiany Deploymentow spoza kube-system (ile, od-do, kto, verb, nazwa, subres, agent) =="
jq -r 'select(.objectRef.resource=="deployments" and (.objectRef.subresource // "")!="status"
        and (.user.username|startswith("system:serviceaccount:kube-system")|not))
  | "\(.requestReceivedTimestamp[11:19]) \(.user.username) \(.verb) \(.objectRef.name) \(.objectRef.subresource // "-") \((.userAgent // "-")|split(" ")[0]|split("/")[0])"' $J \
  | sort | awk '{k=$2" "$3" "$4" "$5" "$6; c[k]++; if(!(k in f))f[k]=$1; l[k]=$1}
               END{for(k in c) print c[k], f[k]"-"l[k], k}' | sort -rn | head -15

echo; echo "== Kubelety patchujace pody (wg wezla) =="
jq -r 'select(.objectRef.resource=="pods" and (.user.username|startswith("system:node:"))) | .user.username' $J \
  | sort | uniq -c | sort -rn | head -10

echo; echo "Surowe zdarzenia: $J"