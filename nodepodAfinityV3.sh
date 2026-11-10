#!/bin/bash
# nodepodAfinityV3.sh - symulacja planowania poda na wezly (v3)
#
# Uzycie: nodepodAfinityV3.sh -pod <NAZWA_PODA> -n <NAMESPACE>
#
# Nowosci w v3 (wzgledem v2):
#  - komunikat schedulera (PodScheduled / FailedScheduling) + interpretacja przyczyny
#  - nodeAffinity (required), poprawna semantyka tolerancji (Exists/Equal, puste effect)
#  - zasoby: cpu / memory / ephemeral-storage / liczba podow (requests vs allocatable)
#  - storage (jak plugin VolumeBinding):
#       * PV Bound -> nodeAffinity PV (volume node affinity conflict)
#       * PVC Pending + WaitForFirstConsumer -> CSIStorageCapacity vs rozmiar PVC
#         ("node(s) did not have enough free storage")
#       * adnotacja volume.kubernetes.io/selected-node (gdzie provisioner probuje utworzyc wolumen)
#       * allowedTopologies SC, statyczne PV, Immediate + Pending
#  - raport per PVC: na ktorym nodzie ile miejsca, czy sie zmiesci, ile brakuje
#  - wszystkie dane pobierane raz (szybciej na duzych klastrach)

set -o pipefail

POD_NAME=""
NAMESPACE=""

while (( "$#" )); do
  case "$1" in
    -pod|--pod)
      if [ "$2" ]; then POD_NAME="$2"; shift 2
      else echo "🚨 Błąd: Wymagana nazwa poda po $1." >&2; exit 1; fi ;;
    -n|--namespace)
      if [ "$2" ]; then NAMESPACE="$2"; shift 2
      else echo "🚨 Błąd: Wymagana nazwa przestrzeni nazw po $1." >&2; exit 1; fi ;;
    -h|--help)
      echo "Użycie: $0 -pod <NAZWA_PODA> -n <NAMESPACE>"; exit 0 ;;
    *)
      echo "🚨 Nieznany argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$POD_NAME" ] || [ -z "$NAMESPACE" ]; then
  echo "🚨 Użycie: $0 -pod <NAZWA_PODA> -n <NAMESPACE>"
  echo "Przykład: $0 -pod my-app-deploy-xyz -n development"
  exit 1
fi

command -v jq >/dev/null || { echo "🚨 Brak jq w PATH." >&2; exit 1; }
command -v oc >/dev/null || { echo "🚨 Brak oc w PATH." >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 1. Pobranie danych (raz)
# ---------------------------------------------------------------------------
fetch() {
  local out="$1"; shift
  if ! oc "$@" -o json > "$TMP/$out" 2> "$TMP/$out.err"; then
    echo '{"items":[]}' > "$TMP/$out"
    echo "⚠️  Nie udało się pobrać: oc $* -> $(head -1 "$TMP/$out.err")" >&2
  fi
}

if ! oc get pod "$POD_NAME" -n "$NAMESPACE" -o json > "$TMP/pod.json" 2> "$TMP/pod.err"; then
  echo "🚨 Nie znaleziono poda $POD_NAME w $NAMESPACE: $(cat "$TMP/pod.err")" >&2
  exit 1
fi

echo "⏳ Pobieram dane z klastra..."
fetch nodes.json   get nodes
fetch pods.json    get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed
fetch pvcs.json    get pvc -n "$NAMESPACE"
fetch pvs.json     get pv
fetch scs.json     get storageclass
fetch drivers.json get csidriver
fetch caps.json    get csistoragecapacities -A
fetch events.json  get events -n "$NAMESPACE"

# ---------------------------------------------------------------------------
# Biblioteka jq
# ---------------------------------------------------------------------------
read -r -d '' JQLIB <<'EOF'
def qty:
  if . == null then 0
  else (tostring) as $s
    | ( ( $s | capture("^(?<n>[0-9.eE+-]+?)(?<u>m|k|Ki|Mi|Gi|Ti|Pi|Ei|M|G|T|P|E)?$") ) as $c
        | ($c.n | tonumber) * ({"m":0.001,"k":1e3,"M":1e6,"G":1e9,"T":1e12,"P":1e15,"E":1e18,
                                "Ki":1024,"Mi":1048576,"Gi":1073741824,"Ti":1099511627776,
                                "Pi":1125899906842624,"Ei":1152921504606846976}[$c.u // ""] // 1)
      ) // 0
  end;
def gi:  ((. / 1073741824 * 10 | round) / 10 | tostring) + "Gi";
def mcpu: ((. * 1000 | round) | tostring) + "m";
def pad($w): tostring as $s | $s + ([range(0; ([$w - ($s|length), 0] | max))] | map(" ") | join(""));

def P:  $pod[0];
def NS: P.metadata.namespace;

# requests poda: max(suma kontenerow + sidecary, max initContainers) + overhead
def podreq($r):
  ([.spec.containers[]?.resources.requests[$r]? | qty] | add // 0) as $c
  | ([.spec.initContainers[]? | select(.restartPolicy == "Always") | .resources.requests[$r]? | qty] | add // 0) as $sc
  | ([.spec.initContainers[]? | select(.restartPolicy != "Always") | .resources.requests[$r]? | qty] | max // 0) as $i
  | ([$c + $sc, $i] | max) + (.spec.overhead[$r]? | qty);

def exprmatch($l):
  .key as $k | ($l[$k]) as $v
  | if   .operator == "In"           then ($v != null and any(.values[]?; . == $v))
    elif .operator == "NotIn"        then ($v == null or all(.values[]?; . != $v))
    elif .operator == "Exists"       then ($l | has($k))
    elif .operator == "DoesNotExist" then ($l | has($k) | not)
    elif .operator == "Gt"           then (try (($v|tonumber) > (.values[0]|tonumber)) catch false)
    elif .operator == "Lt"           then (try (($v|tonumber) < (.values[0]|tonumber)) catch false)
    else false end;

def termmatch($n):
  if ((.matchExpressions // []) | length) == 0 and ((.matchFields // []) | length) == 0 then false
  else ((.matchExpressions // []) | all(exprmatch($n.metadata.labels // {})))
   and ((.matchFields // [])      | all(exprmatch({"metadata.name": $n.metadata.name})))
  end;
def termsmatch($n): (.nodeSelectorTerms // []) | any(.[]; termmatch($n));

def selmatch($l):
  ((.matchLabels // {}) | to_entries | all($l[.key] == .value))
  and ((.matchExpressions // []) | all(exprmatch($l)));

def topomatch($l):
  any(.[]; (.matchLabelExpressions // []) | all(. as $e | $l[$e.key] as $v | $v != null and any($e.values[]; . == $v)));

def tolerates($tols):
  . as $t
  | any($tols[]?;
        ( ((.key // "") == "" and .operator == "Exists")
          or (.key == $t.key and ((.operator // "Equal") == "Exists" or (.value // "") == ($t.value // ""))) )
        and ((.effect // "") == "" or .effect == $t.effect));

def pvcinfo:
  [ P.spec.volumes[]?
    | if .persistentVolumeClaim then {vol: .name, claim: .persistentVolumeClaim.claimName}
      elif .ephemeral then {vol: .name, claim: "\(P.metadata.name)-\(.name)"}
      else empty end ]
  | map( . as $c
      | ($pvcs[0].items | map(select(.metadata.name == $c.claim)) | first) as $pvc
      | ($pvc.spec.storageClassName // null) as $scn
      | ($scs[0].items | map(select(.metadata.name == $scn)) | first) as $sc
      | ($pvc.spec.volumeName // "") as $pvn
      | ($pvs[0].items | map(select($pvn != "" and .metadata.name == $pvn)) | first) as $pv
      | ($drivers[0].items | map(select(.metadata.name == ($sc.provisioner // ""))) | first) as $drv
      | $c + { pvc: $pvc, scName: $scn, sc: $sc, pv: $pv,
               provisioner: ($sc.provisioner // null),
               mode: ($sc.volumeBindingMode // "Immediate"),
               capTracking: (($drv.spec.storageCapacity // false) == true),
               size: ($pvc.spec.resources.requests.storage | qty),
               bound: ($pvc.status.phase == "Bound"),
               selectedNode: ($pvc.metadata.annotations["volume.kubernetes.io/selected-node"] // null),
               caps: [ $caps[0].items[]? | select(.storageClassName == $scn) ] } );

def capval: if .maximumVolumeSize then (.maximumVolumeSize | qty) else (.capacity | qty) end;
def nodecaps($n): [ .caps[] | select(.nodeTopology != null and (.nodeTopology | selmatch($n.metadata.labels // {}))) ];

def used:
  reduce ($pods[0].items[] | select(.spec.nodeName != null)) as $x ({};
    .[$x.spec.nodeName] |= ((. // {cpu:0, memory:0, eph:0, pods:0})
      | .cpu    += ($x | podreq("cpu"))
      | .memory += ($x | podreq("memory"))
      | .eph    += ($x | podreq("ephemeral-storage"))
      | .pods   += 1));

def rescheck($name; $r; $alloc; $used; f):
  if $r > 0 and $r > ($alloc - $used)
  then {c: "RES", r: "Za mało \($name): wymaga \($r|f), wolne \((($alloc - $used) | if . < 0 then 0 else . end) | f) z \($alloc|f)"}
  else empty end;

def storcheck($n; $v):
  ($n.metadata.labels // {}) as $L
  | if $v.pvc == null then {c: "STOR", r: "PVC \($v.claim) nie istnieje"}
    elif $v.bound then
      ( if $v.pv.spec.nodeAffinity.required != null and ($v.pv.spec.nodeAffinity.required | termsmatch($n) | not)
        then {c: "STOR", r: "PVC \($v.claim): PV \($v.pv.metadata.name) przypięty do innego noda (volume node affinity conflict)"}
        else empty end )
    elif $v.mode != "WaitForFirstConsumer" then
      {c: "STOR", r: "PVC \($v.claim) Pending przy volumeBindingMode=Immediate (provisioning/binding nieudany)"}
    elif ($v.provisioner // "") == "" or $v.provisioner == "kubernetes.io/no-provisioner" then
      ( [ $pvs[0].items[] | select(.status.phase == "Available"
            and (.spec.storageClassName // "") == ($v.scName // "")
            and (.spec.capacity.storage | qty) >= $v.size
            and (.spec.nodeAffinity.required == null or (.spec.nodeAffinity.required | termsmatch($n)))) ]
        | if length == 0 then {c: "STOR", r: "PVC \($v.claim): brak wolnego statycznego PV (SC \($v.scName // "-"), >= \($v.size|gi)) dostępnego na tym nodzie"} else empty end )
    elif $v.selectedNode != null and $v.selectedNode != $n.metadata.name then
      {c: "STOR", r: "PVC \($v.claim): selected-node=\($v.selectedNode) (provisioning przypięty do innego noda)"}
    elif ($v.sc.allowedTopologies // null) != null and ($v.sc.allowedTopologies | topomatch($L) | not) then
      {c: "STOR", r: "PVC \($v.claim): SC \($v.scName) allowedTopologies nie obejmuje noda"}
    elif $v.capTracking then
      ( ($v | nodecaps($n)) as $nc
        | if ($nc | length) == 0 then
            {c: "STOR", r: "PVC \($v.claim) (SC \($v.scName)): brak CSIStorageCapacity dla noda (driver/VG nie raportuje pojemności)"}
          elif any($nc[]; capval >= $v.size) then empty
          else {c: "STOR", r: "PVC \($v.claim) (SC \($v.scName)): wymaga \($v.size|gi), dostępne max \([$nc[] | capval] | max | gi)"}
          end )
    else empty end;

def evalnode($n; $U; $PI):
  ($n.metadata.labels // {}) as $L
  | ($U[$n.metadata.name] // {cpu:0, memory:0, eph:0, pods:0}) as $u
  | ($n.status.allocatable // {}) as $a
  | { name: $n.metadata.name,
      reasons: [
        ( if $n.spec.unschedulable == true then {c: "SCHED", r: "Node cordoned (unschedulable)"} else empty end ),
        ( if ([$n.status.conditions[]? | select(.type == "Ready") | .status] | first) != "True"
          then {c: "SCHED", r: "Node NotReady"} else empty end ),
        ( P.spec.nodeSelector // {} | to_entries[] | select($L[.key] != .value)
          | {c: "AFFIN", r: "nodeSelector \(.key)=\(.value) (na nodzie: \($L[.key] // "brak"))"} ),
        ( P.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution // null
          | if . != null and (termsmatch($n) | not) then {c: "AFFIN", r: "nodeAffinity (required) niespełnione"} else empty end ),
        ( $n.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")
          | select(tolerates(P.spec.tolerations // []) | not)
          | {c: "TAINT", r: "Nietolerowany taint \(.key)\(if .value then "=" + .value else "" end):\(.effect)"} ),
        rescheck("cpu";               (P | podreq("cpu"));               ($a.cpu | qty);                 $u.cpu;    mcpu),
        rescheck("memory";            (P | podreq("memory"));            ($a.memory | qty);              $u.memory; gi),
        rescheck("ephemeral-storage"; (P | podreq("ephemeral-storage")); ($a["ephemeral-storage"] | qty); $u.eph;   gi),
        ( if ($a.pods != null) and ($u.pods + 1) > ($a.pods | qty) then {c: "RES", r: "Too many pods (\($u.pods)/\($a.pods))"} else empty end ),
        ( $PI[] as $v | storcheck($n; $v) )
      ] };
EOF

echo "[]" > "$TMP/evals.json"
J() { # J <program> [jq args...]
  local prog="$1"; shift
  jq -nr \
    --slurpfile pod "$TMP/pod.json" --slurpfile nodes "$TMP/nodes.json" \
    --slurpfile pods "$TMP/pods.json" --slurpfile pvcs "$TMP/pvcs.json" \
    --slurpfile pvs "$TMP/pvs.json" --slurpfile scs "$TMP/scs.json" \
    --slurpfile drivers "$TMP/drivers.json" --slurpfile caps "$TMP/caps.json" \
    --slurpfile events "$TMP/events.json" --slurpfile evals "$TMP/evals.json" \
    "$@" "$JQLIB $prog"
}

# ---------------------------------------------------------------------------
# 2. Stan poda i komunikat schedulera
# ---------------------------------------------------------------------------
echo ""
echo "--- 🔍 Analiza Podu: $POD_NAME w przestrzeni $NAMESPACE ---"
J '"Faza: \(P.status.phase)   Node: \(P.spec.nodeName // "<nieprzypisany>")"'

SCHED_MSG=$(J '
  ([P.status.conditions[]? | select(.type == "PodScheduled" and .status != "True") | .message] | first) //
  ([$events[0].items[] | select(.involvedObject.kind == "Pod" and .involvedObject.name == P.metadata.name and .reason == "FailedScheduling")]
   | sort_by(.lastTimestamp // .eventTime // .metadata.creationTimestamp) | last | .message) // ""')

if [ -n "$SCHED_MSG" ]; then
  echo "📣 Scheduler: $SCHED_MSG"
else
  echo "📣 Scheduler: brak komunikatu FailedScheduling (pod zaplanowany lub event wygasł)"
fi

# ---------------------------------------------------------------------------
# 3. Wymagania poda
# ---------------------------------------------------------------------------
echo ""
echo "--- 📋 Wymagania poda ---"
J '
  "Node Selector : [ \((P.spec.nodeSelector // {}) | to_entries | map("\(.key)=\(.value)") | join(" ")) ]",
  "Node Affinity : \(if P.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution then
      (P.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms
       | map((.matchExpressions // []) + (.matchFields // []) | map("\(.key) \(.operator) \(.values // [] | join(","))") | join(" AND ")) | join("  OR  "))
    else "brak (required)" end)",
  "Tolerancje    : [ \((P.spec.tolerations // []) | map("\(.key // "*")\(if .value then "=" + .value else "" end):\(.effect // "*")(\(.operator // "Equal"))") | join(" ")) ]",
  "Requests      : cpu=\(P | podreq("cpu") | mcpu)  memory=\(P | podreq("memory") | gi)  ephemeral-storage=\(P | podreq("ephemeral-storage") | gi)",
  "PVC           : [ \(pvcinfo | map("\(.claim)(\(.size | gi), \(.scName // "-"), \(.pvc.status.phase // "BRAK"))") | join(" ")) ]",
  (if P.spec.affinity.podAffinity or P.spec.affinity.podAntiAffinity then "⚠️  Pod ma podAffinity/podAntiAffinity - NIE symulowane przez skrypt" else empty end),
  (if (P.spec.topologySpreadConstraints // [] | length) > 0 then "⚠️  Pod ma topologySpreadConstraints - NIE symulowane przez skrypt" else empty end)'

# ---------------------------------------------------------------------------
# 4. Symulacja per node
# ---------------------------------------------------------------------------
J 'pvcinfo as $PI | used as $U | [ $nodes[0].items | sort_by(.metadata.name)[] | evalnode(.; $U; $PI) ]' > "$TMP/evals.json"

echo ""
echo "--- 🖥️  Symulacja planowania per node ---"
FMT="%-35s | %-5s | %-5s | %-5s | %-6s | %-7s | %-6s | %s\n"
printf "$FMT" "NODE" "SCHED" "AFFIN" "TAINT" "ZASOBY" "STORAGE" "WYNIK" "PRZYCZYNA ODRZUCENIA"
printf "$FMT" "-----------------------------------" "-----" "-----" "-----" "------" "-------" "------" "------------------------------------------------"

jq -r '.[] | . as $e
  | [ $e.name ]
    + ( ["SCHED","AFFIN","TAINT","RES","STOR"] | map(. as $c | if any($e.reasons[]; .c == $c) then "NIE" else "OK" end) )
    + [ (if ($e.reasons | length) == 0 then "✅ TAK" else "❌ NIE" end),
        (if ($e.reasons | length) == 0 then "Spełnione wymagania" else ($e.reasons | map(.r) | join("; ")) end) ]
  | @tsv' "$TMP/evals.json" |
while IFS=$'\t' read -r N S A T R ST W RS; do
  printf "$FMT" "$N" "$S" "$A" "$T" "$R" "$ST" "$W" "$RS"
done

# ---------------------------------------------------------------------------
# 5. Analiza storage per PVC
# ---------------------------------------------------------------------------
HAS_PVC=$(J 'pvcinfo | length')
if [ "$HAS_PVC" -gt 0 ]; then
  echo ""
  echo "--- 💾 Analiza storage (PVC poda) ---"
  J '
    pvcinfo[] as $v
    | "",
      "▶ PVC \($v.claim)  (wolumen poda: \($v.vol))",
      "   status=\($v.pvc.status.phase // "BRAK")  rozmiar=\($v.size | gi)  SC=\($v.scName // "-")  provisioner=\($v.provisioner // "-")",
      "   volumeBindingMode=\($v.mode)  CSI capacity tracking=\($v.capTracking)  accessModes=\($v.pvc.spec.accessModes // [] | join(","))",
      ( if $v.selectedNode then "   🎯 selected-node (tu provisioner próbuje utworzyć wolumen): \($v.selectedNode)" else empty end ),
      ( if $v.bound then
          ( [ $nodes[0].items[] | . as $n | select($v.pv.spec.nodeAffinity.required != null and ($v.pv.spec.nodeAffinity.required | termsmatch($n))) | .metadata.name ] ) as $pin
          | "   PV=\($v.pv.metadata.name // $v.pvc.spec.volumeName)  " +
            (if $v.pv.spec.nodeAffinity.required == null then "bez nodeAffinity (dostępny z każdego noda)"
             else "przypięty do: \(if ($pin | length) == 0 then "żadnego istniejącego noda!" else ($pin | join(", ")) end)" end)
        else empty end ),
      ( [ $pods[0].items[] | select(.metadata.namespace == NS and .metadata.name != P.metadata.name
            and any(.spec.volumes[]?; .persistentVolumeClaim.claimName? == $v.claim)) | "\(.metadata.name)@\(.spec.nodeName // "-")" ]
        | if length > 0 then "   Używany też przez: \(join(", "))" + (if ($v.pvc.spec.accessModes // [] | index("ReadWriteOncePod")) then "  ⚠️ ReadWriteOncePod - konflikt!" else "" end) else empty end ),
      ( [ $events[0].items[] | select(.involvedObject.kind == "PersistentVolumeClaim" and .involvedObject.name == $v.claim) ]
        | sort_by(.lastTimestamp // .eventTime // .metadata.creationTimestamp) | .[-5:][]
        | "   event [\(.type)] \(.reason): \(.message | gsub("\n"; " ") | .[0:220])" ),
      ( if ($v.bound | not) and $v.capTracking then
          "   Pojemność wg CSIStorageCapacity (SC \($v.scName)) per node:",
          "     \("NODE" | pad(35)) \("KANDYDAT*" | pad(10)) \("DOSTĘPNE" | pad(10)) WERDYKT",
          ( $nodes[0].items | sort_by(.metadata.name)[] as $n
            | ($evals[0][] | select(.name == $n.metadata.name)) as $e
            | ([ $e.reasons[] | select(.c != "STOR") ] | length == 0) as $cand
            | ([ $v | nodecaps($n)[] | capval ] | max) as $best
            | ( ($n.metadata.annotations // {}) | to_entries
                | map(select(.key | startswith("capacity.topolvm.io/")) | "\(.key | sub("capacity.topolvm.io/"; ""))=\(.value | qty | gi)")
                | join(",") ) as $tl
            | "     \($n.metadata.name | pad(35)) \((if $cand then "TAK" else "nie" end) | pad(10)) \((if $best == null then "brak" else ($best | gi) end) | pad(10)) "
              + (if $best == null then "❌ brak CSIStorageCapacity dla noda"
                 elif $best >= $v.size then "✅ zmieści się"
                 else "❌ za mało (brakuje \(($v.size - $best) | gi))" end)
              + (if $v.selectedNode == $n.metadata.name then "  🎯 selected-node" else "" end)
              + (if $tl != "" then "  [topolvm: \($tl)]" else "" end) ),
          "     * KANDYDAT = node przechodzi pozostałe filtry (selector/affinity/taint/zasoby/cordon)"
        elif ($v.bound | not) and $v.mode == "WaitForFirstConsumer" then
          "   ℹ️  Driver nie ma storageCapacity=true - scheduler NIE sprawdza miejsca, brak miejsca wyjdzie dopiero przy provisioningu (patrz eventy PVC)"
        else empty end )'
fi

# ---------------------------------------------------------------------------
# 6. Podsumowanie i potencjalna przyczyna
# ---------------------------------------------------------------------------
echo ""
echo "--- 📊 Podsumowanie symulacji ---"
J '
  $evals[0] as $E
  | "Nodów łącznie: \($E | length)   Pasujących (symulacja): \([$E[] | select(.reasons | length == 0)] | length)",
    ( ["SCHED:cordon/NotReady","AFFIN:selector/affinity","TAINT:taint","RES:zasoby cpu/mem/eph/pods","STOR:storage"][]
      | split(":") as [$c, $label]
      | ([$E[] | select(any(.reasons[]; .c == $c))] | length) as $cnt
      | select($cnt > 0) | "  \($cnt) node(s) odrzucone przez: \($label)" )'

MATCHING=$(jq '[.[] | select(.reasons | length == 0)] | length' "$TMP/evals.json")
STOR_FAIL=$(jq '[.[] | select(any(.reasons[]; .c == "STOR"))] | length' "$TMP/evals.json")

echo ""
echo "--- 🧭 Potencjalna przyczyna ---"
hint() { echo "$SCHED_MSG" | grep -qiE "$1" && echo "  • $2"; }
if [ -n "$SCHED_MSG" ]; then
  hint "enough free storage"                "Brak miejsca w storage (CSIStorageCapacity < rozmiar PVC) - zobacz sekcję 💾: który PVC, na którym nodzie ile brakuje."
  hint "volume node affinity conflict"      "PV jest przypięty do noda (local/LVMS), na którym pod nie może wstać (taint/zasoby/cordon) - zobacz 'przypięty do' w sekcji 💾."
  hint "available persistent volumes to bind" "Brak pasującego PV albo PVC ma selected-node innego noda - zobacz sekcję 💾."
  hint "unbound immediate"                  "PVC z bindingMode=Immediate jest Pending - problem z provisioningiem (eventy PVC)."
  hint "Insufficient (cpu|memory)"          "Brak wolnych zasobów cpu/memory (requests) na nodach."
  hint "Insufficient ephemeral-storage"     "Brak ephemeral-storage na nodach (requests ephemeral-storage)."
  hint "untolerated taint|had taint"        "Tainty bez tolerancji w podzie."
  hint "node affinity/selector|didn.t match Pod.s node affinity" "nodeSelector/nodeAffinity nie pasuje do etykiet nodów."
  hint "pod affinity|anti-affinity"         "podAffinity/podAntiAffinity - NIE symulowane przez skrypt; sprawdź rozmieszczenie podów."
  hint "topology spread"                    "topologySpreadConstraints - NIE symulowane przez skrypt."
  hint "max volume count|exceed max volume" "Limit liczby wolumenów na nodzie (CSINode allocatable.count)."
  hint "were unschedulable"                 "Nody są cordoned (oc adm uncordon)."
  hint "Too many pods"                      "Osiągnięty limit podów na nodzie."
  hint "free ports"                         "Konflikt hostPort."
fi
if [ "$STOR_FAIL" -gt 0 ]; then
  echo "  • Symulacja: $STOR_FAIL node(s) odrzucone przez storage - szczegóły w sekcji 💾 powyżej."
fi
if [ "$MATCHING" -gt 0 ] && [ -n "$SCHED_MSG" ]; then
  echo "  • Symulacja widzi $MATCHING pasujących nodów, a scheduler nie - przyczyna leży w czymś niesymulowanym"
  echo "    (pod (anti)affinity, topology spread, hostPort, limity wolumenów) albo stan klastra zmienił się od eventu."
fi
if [ "$MATCHING" -eq 0 ] && [ -z "$SCHED_MSG" ]; then
  echo "  • Symulacja nie znalazła pasującego noda, a scheduler nie zgłasza błędu - sprawdź czy pod nie jest już zaplanowany."
fi

echo ""
echo "--- ✅ Koniec symulacji planowania (v3). ---"
