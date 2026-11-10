#!/bin/bash
# nodepodAfinityV4.sh - symulacja planowania poda na wezly (v4)
#
# Uzycie: nodepodAfinityV4.sh -pod <NAZWA_PODA> -n <NAMESPACE> [--top N] [--all-nodes] [--no-debug] [--debug-image IMG]
#
#   --top N          ile nodow analizowac pod katem powiekszenia (domyslnie 3, najmniejszy deficyt)
#   --all-nodes      analizuj takze nody, ktore odpadaja na innych filtrach (taint/zasoby/affinity)
#   --no-debug       nie uruchamiaj 'oc debug node' - rekomendacja tylko z CR LVMS i CSIStorageCapacity
#   --debug-image    obraz dla 'oc debug node' (np. registry.redhat.io/rhel9/support-tools)
#
# Nowosci w v4 (TYLKO ODCZYT - skrypt niczego nie zmienia):
#  - dla PVC, ktore nie mieszcza sie na nodach, liczy deficyt per node/StorageClass
#  - czyta konfiguracje LVMS (LVMCluster deviceClass: thinPool sizePercent / overprovisionRatio,
#    deviceSelector) i LVMVolumeGroupNodeStatus (urzadzenia uzyte / wykluczone)
#  - na nodzie (oc debug, read-only: lsblk/vgs/pvs/lvs//sys) bada dyski, partycje i LVM:
#    VG, PV (dysk czy partycja), thin pool, miejsce za partycja, nieuzyte dyski
#  - proponuje CO powiekszyc i O ILE: pvresize / growpart+pvresize / nowy dysk do deviceSelector /
#    powiekszenie konkretnego dysku o X GiB (komendy tylko jako sugestia)
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
TOP_N=3
ALL_NODES=0
USE_DEBUG=1
DEBUG_IMAGE=""

while (( "$#" )); do
  case "$1" in
    -pod|--pod)
      if [ "$2" ]; then POD_NAME="$2"; shift 2
      else echo "🚨 Błąd: Wymagana nazwa poda po $1." >&2; exit 1; fi ;;
    -n|--namespace)
      if [ "$2" ]; then NAMESPACE="$2"; shift 2
      else echo "🚨 Błąd: Wymagana nazwa przestrzeni nazw po $1." >&2; exit 1; fi ;;
    --top)
      TOP_N="$2"; shift 2 ;;
    --all-nodes)
      ALL_NODES=1; shift ;;
    --no-debug)
      USE_DEBUG=0; shift ;;
    --debug-image)
      DEBUG_IMAGE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0"; exit 0 ;;
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
fetch lvmc.json    get lvmcluster -A
fetch lvmns.json   get lvmvolumegroupnodestatus -A

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
    --slurpfile lvmc "$TMP/lvmc.json" --slurpfile lvmns "$TMP/lvmns.json" \
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
    ( [{k:"SCHED",d:"cordon/NotReady"},{k:"AFFIN",d:"selector/affinity"},{k:"TAINT",d:"taint"},{k:"RES",d:"zasoby cpu/mem/eph/pods"},{k:"STOR",d:"storage"}][]
      | .k as $c | .d as $desc
      | ([$E[] | select(any(.reasons[]; .c == $c))] | length) as $cnt
      | select($cnt > 0) | "  \($cnt) node(s) odrzucone przez: \($desc)" )'

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

# ---------------------------------------------------------------------------
# 7. Rekomendacja powiekszenia storage (TYLKO ODCZYT - nic nie jest zmieniane)
# ---------------------------------------------------------------------------

# Skrypt uruchamiany na nodzie przez 'oc debug' - wylacznie komendy odczytu.
read -r -d '' NODE_SCRIPT <<'EOF'
lv() { c=$1; shift; "$c" --devicesfile "" "$@" 2>/dev/null || "$c" "$@" 2>/dev/null; }
echo ===LSBLK
lsblk -J -b -o NAME,KNAME,PKNAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,RO 2>/dev/null || echo '{"blockdevices":[]}'
echo ===VGS
lv vgs --reportformat json --units b --nosuffix -o vg_name,vg_size,vg_free,pv_count,lv_count || echo '{"report":[{"vg":[]}]}'
echo ===PVS
lv pvs --reportformat json --units b --nosuffix -o pv_name,vg_name,pv_size,pv_free,dev_size || echo '{"report":[{"pv":[]}]}'
echo ===LVS
lv lvs -a --reportformat json --units b --nosuffix -o lv_name,vg_name,lv_size,lv_attr,pool_lv,data_percent,metadata_percent || echo '{"report":[{"lv":[]}]}'
echo ===SYS
for b in /sys/class/block/*; do
  n=${b##*/}
  if [ -f "$b/partition" ]; then
    p=$(basename "$(dirname "$(readlink -f "$b")")")
    echo "PART $n $p $(cat "$b/start") $(cat "$b/size")"
  elif [ -e "$b/device" ]; then
    echo "DISK $n $(cat "$b/size")"
  fi
done
echo ===END
EOF

collect_node() { # collect_node <node>  -> $TMP/node-<node>/*.json ; rc!=0 przy bledzie
  local n="$1" d="$TMP/node-$1"
  mkdir -p "$d"
  local img=()
  [ -n "$DEBUG_IMAGE" ] && img=(--image="$DEBUG_IMAGE")
  timeout 240 oc debug "node/$n" "${img[@]}" --quiet -- chroot /host sh -c "$NODE_SCRIPT" > "$d/raw.txt" 2> "$d/err.txt"
  grep -q '^===END' "$d/raw.txt" || return 1
  awk -v d="$d" '/^===/{f=d "/" substr($0,4) ".out"; next} {print > f}' "$d/raw.txt"
  for x in LSBLK VGS PVS LVS; do
    [ -s "$d/$x.out" ] || echo '{}' > "$d/$x.out"
  done
  awk '$1=="DISK"{printf "{\"t\":\"disk\",\"name\":\"%s\",\"sec\":%s}\n",$2,$3}
       $1=="PART"{printf "{\"t\":\"part\",\"name\":\"%s\",\"disk\":\"%s\",\"start\":%s,\"sec\":%s}\n",$2,$3,$4,$5}' \
      "$d/SYS.out" 2>/dev/null | jq -s . > "$d/sys.json"
  return 0
}

# Biblioteka rekomendacji (wejscie: $deficit, $dccfg, $dcname, $node + dane z noda)
read -r -d '' RECLIB <<'EOF'
def num: (tostring | tonumber? ) // 0;
def gup: ((. / 1073741824) | ceil);                      # bajty -> pelne GiB w gore
def thinparams: { thin: ($dccfg.thinPoolConfig != null),
                  R:  ($dccfg.thinPoolConfig.overprovisionRatio // 10),
                  SP: ($dccfg.thinPoolConfig.sizePercent // 90),
                  pool: ($dccfg.thinPoolConfig.name // "thin-pool-1") };
EOF

# Wariant bez dostepu do noda: tylko wzor + CR LVMS
recommend_formula() { # <node> <deficitBytes> <dccfgJSON> <dcname>
  J "$RECLIB"'
    thinparams as $t
    | (if $t.thin then ($deficit / $t.R) else $deficit end) as $poolGrow
    | (if $t.thin then ($poolGrow * 100 / $t.SP) else $deficit end) as $vgGrow
    | "     Tryb: \(if $t.thin then "thin (overprovisionRatio=\($t.R), sizePercent=\($t.SP))" else "thick" end)",
      "     Deficyt \($deficit | gi)" + (if $t.thin then " → thin pool +\($poolGrow | gi) (÷\($t.R))" else "" end)
        + " → VG +\($vgGrow | gi) → zalecane +\(($vgGrow | gup) + 1)Gi (z zapasem na metadane LVM)",
      ( [ $lvmns[0].items[]? | select(.metadata.name == $node) | .spec.nodeStatus[]? | select(.name == $dcname) ] | first
        | if . == null then "     LVMVolumeGroupNodeStatus: brak danych dla \($dcname) na \($node)"
          else "     Urządzenia VG \($dcname) (LVMS): \(.devices // [] | join(", "))",
               ( .excluded[]? | "     Wykluczone przez LVMS: \(.name) → \(.reasons // [] | join("; "))" )
          end ),
      "     👉 Powiększ dysk(i) z listy urządzeń VG o ~\(($vgGrow | gup) + 1)Gi (lub dodaj nowy dysk tej wielkości), potem pvresize.",
      "        Z działającym oc debug (bez --no-debug, uprawnienia cluster-admin) skrypt wskaże konkretny dysk/partycję."' \
    --arg node "$1" --argjson deficit "$2" --argjson dccfg "$3" --arg dcname "$4"
}

# Wariant pelny: dane LVM z noda
recommend_node() { # <node> <deficitBytes> <dccfgJSON> <dcname>
  local d="$TMP/node-$1"
  J "$RECLIB"'
    ($lsblk[0].blockdevices // []) as $BD
    | ($vgs[0].report[0].vg // []) as $VGS
    | ($pvsn[0].report[0].pv // []) as $PVS
    | ($lvs[0].report[0].lv // []) as $LVS
    | ($sys[0] // []) as $SYS
    | thinparams as $t
    | ($VGS | map(select(.vg_name == $dcname)) | first) as $vg
    | ($vg.vg_size | num) as $vgSize
    | ($vg.vg_free | num) as $vgFree
    | ($LVS | map(select(.vg_name == $dcname and (.lv_attr | startswith("t")))) | first) as $pool
    | ($pool.lv_size | num) as $poolSize
    | ( [ $lvmns[0].items[]? | select(.metadata.name == $node) | .spec.nodeStatus[]? | select(.name == $dcname) ] | first ) as $ns

    # --- ile trzeba dolozyc do VG ---
    | (if $t.thin then ($deficit / $t.R) else $deficit end) as $poolGrow
    | (if $t.thin and $pool != null then ([$vgFree - $vgSize * (100 - $t.SP) / 100, 0] | max) else 0 end) as $poolSlack
    | (if $t.thin then
         (if $pool != null then ([(($poolSize + $poolGrow) * 100 / $t.SP) - $vgSize, 0] | max) else ($poolGrow * 100 / $t.SP) end)
       else ([$deficit - 0, 0] | max) end) as $vgGrowRaw
    | ((($vgGrowRaw | gup) + 1) * 1073741824) as $vgGrow

    # --- inwentaryzacja PV w VG ---
    | [ $PVS[] | select(.vg_name == $dcname)
        | (.pv_name | split("/") | last) as $bn
        | ($SYS | map(select(.name == $bn)) | first) as $s
        | (.pv_size | num) as $ps | (.dev_size | num) as $ds
        | { dev: .pv_name, bn: $bn, pvSize: $ps, devSize: $ds,
            pending: ([$ds - $ps, 0] | max | if . < 1073741824 then 0 else . end),
            kind: (if $s == null then "inne" elif $s.t == "part" then "partycja" else "dysk" end),
            disk: (if $s.t == "part" then $s.disk else $bn end),
            partnum: (if $s.t == "part" then ($bn | capture("(?<n>[0-9]+)$").n // "?") else null end),
            diskSize: (($SYS | map(select(.t == "disk" and .name == (if $s.t == "part" then $s.disk else $bn end))) | first | .sec // 0) * 512),
            last: (if $s.t == "part" then ([ $SYS[] | select(.t == "part" and .disk == $s.disk and .start > $s.start) ] | length == 0) else true end),
            tail: (if $s.t == "part" then
                     (($SYS | map(select(.t == "disk" and .name == $s.disk)) | first | .sec // 0) * 512) as $dsz
                     | ([ $SYS[] | select(.t == "part" and .disk == $s.disk and .start > $s.start) | .start * 512 ] | min) as $next
                     | ((($next // ($dsz - 34 * 512)) - ($s.start + $s.sec) * 512) | if . < 1073741824 then 0 else . end)
                   else 0 end) } ] as $P

    # --- nieuzyte dyski ---
    | [ $BD[] | select(.type == "disk" and ((.children // []) | length) == 0 and .fstype == null and .mountpoint == null
                       and ((.ro | tostring) as $r | $r != "true" and $r != "1"))
        | select(.name as $nm | ($PVS | any(.[]; .pv_name | endswith("/" + $nm))) | not)
        | { dev: "/dev/\(.name)", size: (.size | num),
            excl: (.name as $nm | [ $ns.excluded[]? | select(.name | endswith("/" + $nm)) | .reasons[]? ] | join("; ")) } ] as $FREE

    # --- opcje (od najtanszej) ---
    | ($P | map(.pending) | add // 0) as $pendSum
    | [
        ( if $t.thin and $pool != null and $poolSlack >= $poolGrow then
            { k: "lvextend", t: "Thin pool \($dcname)/\($pool.lv_name) ma zapas w VG (\($poolSlack | gi)) - wystarczy rozszerzyć pool o +\(($poolGrow | gup) + 1)Gi (LVMS/vgmanager zwykle robi to sam - sprawdź logi vgmanager)",
              cmd: "lvextend -L +\(($poolGrow | gup) + 1)G \($dcname)/\($pool.lv_name)" } else empty end ),
        ( if $pendSum >= $vgGrow then
            { k: "pvresize", t: "Dysk już jest większy niż PV (\($P | map(select(.pending > 0) | "\(.dev) +\(.pending | gi)") | join(", "))) - wystarczy pvresize, bez zmian w infrastrukturze",
              cmd: ($P | map(select(.pending > 0) | "pvresize \(.dev)") | join(" && ")) } else empty end ),
        ( $P[] | select(.kind == "partycja" and (.tail + .pending) >= $vgGrow)
          | { k: "growpart", t: "Za partycją \(.dev) na /dev/\(.disk) jest \(.tail | gi) wolnego (niepartycjonowanego) miejsca - rozciągnij partycję i PV",
              cmd: "growpart /dev/\(.disk) \(.partnum) && pvresize \(.dev)" } ),
        ( $FREE[] | select(.size >= $vgGrow)
          | { k: "newdisk", t: "Nieużyty dysk \(.dev) (\(.size | gi)) - dodaj do deviceClass \($dcname) (spec.storage.deviceClasses[].deviceSelector.paths w LVMCluster)\(if .excl != "" then "; LVMS go wyklucza: " + .excl else "" end)",
              cmd: "oc edit lvmcluster  # deviceSelector.paths += \(.dev)" } ),
        ( ($P | map(select(.kind == "dysk")) | sort_by(-.pvSize) | first) as $wd
          | if $wd != null then
              ([$vgGrow - $wd.pending, 0] | max) as $g
              | { k: "grow-disk", t: "Powiększ dysk \($wd.dev) (PV całego dysku, teraz \($wd.diskSize | gi)) o +\($g | gup)Gi → \((($wd.diskSize + $g) | gup))Gi w hypervisorze/SAN, potem pvresize",
                cmd: "pvresize \($wd.dev)" }
            else empty end ),
        ( ($P | map(select(.kind == "partycja" and .last)) | sort_by(-.pvSize) | first) as $lp
          | if $lp != null then
              ([$vgGrow - $lp.tail - $lp.pending, 0] | max) as $g
              | select($g > 0)
              | { k: "grow-disk-part", t: "Powiększ dysk /dev/\($lp.disk) (teraz \($lp.diskSize | gi)) o +\($g | gup)Gi → \((($lp.diskSize + $g) | gup))Gi; PV jest na ostatniej partycji \($lp.dev), więc potem growpart + pvresize",
                  cmd: "growpart /dev/\($lp.disk) \($lp.partnum) && pvresize \($lp.dev)" }
            else empty end ),
        { k: "add-disk", t: "Dołóż nowy dysk ≥ \($vgGrow | gup)Gi do noda i dodaj go do deviceClass \($dcname) (deviceSelector.paths)",
          cmd: "oc edit lvmcluster  # deviceSelector.paths += /dev/<nowy-dysk>" }
      ] as $OPTS

    # --- wydruk ---
    | if $vg == null then
        "     ❌ VG \($dcname) nie istnieje na nodzie \($node).",
        ( if $ns != null then "     LVMS nodeStatus: status=\($ns.status // "?") \($ns.reason // "")",
              ( $ns.excluded[]? | "     Wykluczone: \(.name) → \(.reasons // [] | join("; "))" ) else empty end ),
        ( if ($FREE | length) > 0 then "     Nieużyte dyski na nodzie: \($FREE | map("\(.dev)(\(.size | gi))") | join(", "))" else "     Brak nieużytych dysków na nodzie." end ),
        "     👉 Sprawdź nodeSelector/deviceSelector deviceClass \($dcname) w LVMCluster albo dołóż dysk ≥ \($vgGrow | gup)Gi."
      else
        "     VG \($dcname): rozmiar \($vgSize | gi), wolne \($vgFree | gi), PV: \($vg.pv_count), LV: \($vg.lv_count)",
        ( if $pool != null then "     Thin pool \($pool.lv_name): \($poolSize | gi), data \($pool.data_percent // "?")%, metadata \($pool.metadata_percent // "?")%"
              + (if ($pool.data_percent | num) >= 80 then "  ⚠️ pool fizycznie zapełniony ≥80%!" else "" end)
              + (if ($pool.metadata_percent | num) >= 80 then "  ⚠️ metadata ≥80%!" else "" end)
          else empty end ),
        ( $P[] | "       PV \(.dev | pad(18)) \(.kind | pad(9)) dysk=/dev/\(.disk) (\(.diskSize | gi))  PV=\(.pvSize | gi)"
                 + (if .pending > 0 then "  ⚡ dysk większy o \(.pending | gi) (brak pvresize)" else "" end)
                 + (if .kind == "partycja" then "  za partycją wolne: \(.tail | gi)\(if .last then "" else " (nie ostatnia partycja)" end)" else "" end) ),
        ( if ($FREE | length) > 0 then "       Nieużyte dyski: \($FREE | map("\(.dev)(\(.size | gi))") | join(", "))" else empty end ),
        "     Obliczenie: deficyt \($deficit | gi)"
          + (if $t.thin then " ÷ overprovisionRatio \($t.R) = pool +\($poolGrow | gi); pool może zająć \($t.SP)% VG → VG +\($vgGrowRaw | gi)" else " (thick) → VG +\($vgGrowRaw | gi)" end)
          + " → zaokrąglone z zapasem: +\($vgGrow | gup)Gi",
        "     ✅ REKOMENDACJA: \($OPTS[0].t)",
        "        sugestia (NIE wykonano): \($OPTS[0].cmd)",
        ( $OPTS[1:][] | "     ➖ alternatywa: \(.t)" )
      end' \
    --arg node "$1" --argjson deficit "$2" --argjson dccfg "$3" --arg dcname "$4" \
    --slurpfile lsblk "$d/LSBLK.out" --slurpfile vgs "$d/VGS.out" --slurpfile pvsn "$d/PVS.out" \
    --slurpfile lvs "$d/LVS.out" --slurpfile sys "$d/sys.json"
}

# Grupy: StorageClass -> suma niezbindowanych PVC vs pojemnosc per node
J 'pvcinfo as $PI
  | [ $PI[] | select((.bound | not) and .capTracking and .pvc != null) ] as $U
  | [ ($U | group_by(.scName))[] as $grp
      | $grp[0] as $v0
      | ($grp | map(.size) | add) as $need
      | { sc: $v0.scName, provisioner: $v0.provisioner, need: $need,
          dc: ($v0.sc.parameters["topolvm.io/device-class"] // ""),
          claims: ($grp | map("\(.claim)(\(.size | gi))")),
          rows: [ $nodes[0].items[] as $n
                  | ([ $evals[0][] | select(.name == $n.metadata.name) | .reasons[] | select(.c != "STOR") ] | length == 0) as $cand
                  | ([ $v0 | nodecaps($n)[] | capval ] | max) as $best
                  | { node: $n.metadata.name, cand: $cand, have: ($best // 0), hasCap: ($best != null),
                      deficit: ([$need - ($best // 0), 0] | max),
                      sel: any($grp[]; .selectedNode == $n.metadata.name) } ] } ]' > "$TMP/grow.json"

if [ "$(jq length "$TMP/grow.json")" -gt 0 ]; then
  echo ""
  echo "--- 💡 Rekomendacja powiększenia storage (tylko odczyt, nic nie jest zmieniane) ---"
  for gi in $(seq 0 $(( $(jq length "$TMP/grow.json") - 1 ))); do
    G=$(jq -c ".[$gi]" "$TMP/grow.json")
    SC=$(jq -r .sc <<<"$G"); PROV=$(jq -r .provisioner <<<"$G"); DC=$(jq -r .dc <<<"$G")
    echo ""
    echo "▶ StorageClass $SC (provisioner $PROV) - PVC: $(jq -r '.claims | join(", ")' <<<"$G"), razem $(J '$g.need | gi' --argjson g "$G")"

    FITS=$(jq -r '[.rows[] | select(.cand and .deficit == 0) | .node] | join(", ")' <<<"$G")
    if [ -n "$FITS" ]; then
      echo "   ✅ Nie trzeba nic powiększać - zmieszczą się na: $FITS (sprawdź selected-node / eventy PVC)"
      continue
    fi

    # Nody do analizy: najpierw selected-node, potem najmniejszy deficyt
    if [ "$ALL_NODES" -eq 1 ]; then SEL='.rows'; else SEL='[.rows[] | select(.cand)]'; fi
    TARGETS=$(jq -r "$SEL | sort_by((if .sel then 0 else 1 end), .deficit) | .[0:$TOP_N][] | [.node, (.deficit|tostring), (.have|tostring), (.cand|tostring), (.sel|tostring)] | @tsv" <<<"$G")
    if [ -z "$TARGETS" ]; then
      echo "   ⚠️  Żaden node nie przechodzi pozostałych filtrów (taint/zasoby/affinity/cordon) - samo powiększenie dysku nie pomoże."
      echo "      Użyj --all-nodes, aby mimo to policzyć powiększenie dla nodów."
      continue
    fi

    # Konfiguracja deviceClass z LVMCluster
    DCCFG=$(J '([ $lvmc[0].items[]?.spec.storage.deviceClasses[]? ]) as $all
               | (if $dc != "" then ($all | map(select(.name == $dc)) | first) else null end)
                 // ($all | map(select(.default == true)) | first) // $all[0] // {}' --arg dc "$DC" | jq -c .)
    DCNAME=$(jq -r --arg dc "$DC" '.name // (if $dc != "" then $dc else "vg1" end)' <<<"$DCCFG")
    IS_LVMS=0; [[ "$PROV" == *topolvm* ]] && IS_LVMS=1
    if [ "$IS_LVMS" -eq 1 ]; then
      echo "   LVMS deviceClass: $DCNAME  $(jq -r '"thinPool=" + (if .thinPoolConfig then "\(.thinPoolConfig.name // "-") sizePercent=\(.thinPoolConfig.sizePercent // 90) overprovisionRatio=\(.thinPoolConfig.overprovisionRatio // 10)" else "brak (thick)" end) + "  deviceSelector=" + ((.deviceSelector.paths // []) + (.deviceSelector.optionalPaths // []) | if length == 0 then "auto (wszystkie wolne dyski)" else join(",") end)' <<<"$DCCFG")"
    fi

    while IFS=$'\t' read -r NODE DEF HAVE CAND ISSEL; do
      echo ""
      echo "   🖥️  $NODE  (dostępne $(J '$x|tonumber|gi' --arg x "$HAVE"), brakuje $(J '$x|tonumber|gi' --arg x "$DEF")$( [ "$ISSEL" = true ] && echo ', 🎯 selected-node')$( [ "$CAND" = true ] || echo ', ⚠️ odpada też na innych filtrach'))"
      if [ "$DEF" = "0" ]; then
        echo "     ✅ Miejsca wystarcza - powiększanie nic nie da; node blokuje inny filtr (patrz tabela)."
        continue
      fi
      if [ "$IS_LVMS" -ne 1 ]; then
        echo "     Provisioner $PROV nie jest LVMS/TopoLVM - nie umiem zmapować pojemności na dyski."
        echo "     Parametry SC: $(J '[$scs[0].items[] | select(.metadata.name == $sc) | .parameters // {} | to_entries[] | "\(.key)=\(.value)"] | join(" ")' --arg sc "$SC")"
        echo "     👉 Zwiększ pulę backendu tej SC o co najmniej $(J '$x|tonumber|gi' --arg x "$DEF")."
        continue
      fi
      if [ "$USE_DEBUG" -eq 1 ]; then
        echo "     ⏳ oc debug node/$NODE (lsblk/vgs/pvs/lvs - tylko odczyt)..."
        if collect_node "$NODE"; then
          recommend_node "$NODE" "$DEF" "$DCCFG" "$DCNAME"
          continue
        else
          echo "     ⚠️  oc debug nie powiódł się: $(grep -v '^$' "$TMP/node-$NODE/err.txt" | tail -1). Rekomendacja przybliżona:"
        fi
      fi
      recommend_formula "$NODE" "$DEF" "$DCCFG" "$DCNAME"
    done <<< "$TARGETS"
  done
  echo ""
  echo "   ℹ️  Skrypt niczego nie zmienił. Komendy są sugestią - wykonuj je świadomie (oc debug node/<node> → chroot /host)."
  echo "      Po powiększeniu dysku: LVMS (vgmanager) powinien wykryć zmianę; CSIStorageCapacity odświeży się po chwili."
fi

echo ""
echo "--- ✅ Koniec symulacji planowania (v4). ---"
