#!/bin/bash
# nodepodAfinityV4.sh - symulacja planowania poda na wezly (v4)
#
# Uzycie: nodepodAfinityV4.sh -pod <NAZWA_PODA> -n <NAMESPACE> [--top N] [--all-nodes] [--no-debug]
#                              [--debug-image IMG] [--device-class NAZWA]
#
#   --top N          ile nodow analizowac pod katem powiekszenia (domyslnie 3, najmniejszy deficyt)
#   --all-nodes      analizuj takze nody, ktore odpadaja na innych filtrach (taint/zasoby/affinity)
#   --no-debug       nie uruchamiaj 'oc debug node' - rekomendacja tylko z CR LVMS i CSIStorageCapacity
#   --debug-image    obraz dla 'oc debug node' (np. registry.redhat.io/rhel9/support-tools)
#   --device-class N policz powiekszenie dla wskazanego deviceClass/VG (gdy StorageClass nie wskazuje
#                    istniejacego deviceClass albo chcesz sprawdzic inny)
#
# Nowosci w v4.1 (rekomendacja wprost z konfiguracji klastra, nadal TYLKO ODCZYT):
#  - StorageClass -> deviceClass ustalane jak w driverze (parametr SC, inaczej default: true w LVMCluster);
#    gdy SC nie wskazuje istniejacego deviceClass, skrypt mowi to wprost (blad konfiguracji, nie brak
#    miejsca) i pokazuje, ktory deviceClass / StorageClass pomiesci PVC juz teraz
#  - nody do analizy: najpierw te z istniejacym VG i objete nodeSelector deviceClass; nod spoza
#    nodeSelector jest od razu oznaczany jako bezcelowy do powiekszania
#  - wskazuje konkretny dysk (stabilna sciezka /dev/disk/by-id, serial), VG do ktorego go dodac,
#    pole LVMCluster (paths / optionalPaths) i gotowa komende oc patch (tylko sugestia)
#  - nieuzyte dyski: czy sa wystarczajace, zarezerwowane przez inny deviceClass, wykluczone przez LVMS
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
FORCE_DC=""

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
    --device-class)
      FORCE_DC="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"; exit 0 ;;
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
lsblk -J -b -o NAME,KNAME,PKNAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,RO,SERIAL,WWN,MODEL 2>/dev/null \
  || lsblk -J -b -o NAME,KNAME,PKNAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,RO 2>/dev/null || echo '{"blockdevices":[]}'
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
echo ===BYID
for l in /dev/disk/by-id/*; do
  [ -e "$l" ] && echo "$(basename "$(readlink -f "$l")") $l"
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
  # mapa: nazwa jadra -> stabilna sciezka /dev/disk/by-id
  { [ -s "$d/BYID.out" ] && jq -R 'split(" ") | {k: .[0], p: .[1]}' "$d/BYID.out"; } 2>/dev/null | jq -s . > "$d/byid.json"
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
def selpaths: (($dccfg.deviceSelector.paths // []) + ($dccfg.deviceSelector.optionalPaths // []));
def nstext:
  if ($dccfg.nodeSelector // null) == null then "brak (wszystkie nody z vg-manager)"
  else ($dccfg.nodeSelector.nodeSelectorTerms // []
        | map((.matchExpressions // []) + (.matchFields // []) | map("\(.key) \(.operator) \(.values // [] | join(","))") | join(" AND "))
        | join("  OR  "))
  end;
EOF

# Funkcje wymagajace danych z noda ($byid, $lsblk) i zasiegu deviceClass ($cover)
read -r -d '' NODELIB <<'EOF'
# sciezka z deviceSelector -> nazwa jadra dysku na tym nodzie
def pathk($p): ([ $byid[0][]? | select(.p == $p) | .k ] | first)
               // (if ($p | test("^/dev/[^/]+$")) then ($p | split("/") | last) else null end);
# stabilna sciezka by-id dysku; preferuj typ identyfikatora juz uzywany w deviceSelector
def stablepath($k):
  [ $byid[0][]? | select(.k == $k) | .p ] as $c
  | ([ selpaths[] | capture("^/dev/disk/by-id/(?<p>[A-Za-z0-9]+)-").p ] | unique) as $pref
  | ( [ $c[] | select((split("/") | last) as $b | any($pref[]; . as $p | $b | startswith($p + "-"))) ] | sort | first )
    // ( [ ("wwn-", "nvme-eui.", "scsi-3", "virtio-", "scsi-", "nvme-", "ata-") as $o
           | $c[] | select((split("/") | last) | startswith($o)) ] | first )
    // ($c | sort | first);
def devref($k): stablepath($k) // "/dev/\($k)";
def serial($k): [ $lsblk[0].blockdevices[]? | select(.name == $k) | .serial // empty | select(. != "") ] | first;
def ident($k):
  ([ (stablepath($k) // empty), (serial($k) // empty | "serial=\(.)") ] | join(", ")) as $x
  | if $x == "" then "" else " [\($x)]" end;
# inny deviceClass, ktory ma ten dysk w swoim deviceSelector
def reservedby($k):
  [ $lvmc[0].items[]?.spec.storage.deviceClasses[]? | select(.name != $dcname) | .name as $o
    | ((.deviceSelector.paths // []) + (.deviceSelector.optionalPaths // []))[] | select(pathk(.) == $k) | $o ] | first;
# sciezka by-id istnieje tylko na jednym nodzie: przy deviceClass na wielu nodach musi trafic do optionalPaths
def selfield:
  ($dccfg.deviceSelector // {}) as $ds
  | if $cover > 1 or ($ds.optionalPaths != null and $ds.paths == null) then "optionalPaths" else "paths" end;
def statuscmd:
  "oc get lvmvolumegroupnodestatus" + (if $dccfg._ns != null then " -n \($dccfg._ns) \($node)" else " -A" end) + " -o yaml";
def patchcmd($path):
  ($dccfg.deviceSelector // null) as $ds | selfield as $f
  | if $ds == null then null
    elif $dccfg._cr == null then "oc edit lvmcluster  # deviceClass \($dcname): deviceSelector.\($f) += \($path)"
    else "oc -n \($dccfg._ns) patch lvmcluster \($dccfg._cr) --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/storage/deviceClasses/\($dccfg._idx)/deviceSelector/\($f)\(if $ds[$f] != null then "/-" else "" end)\",\"value\":\(if $ds[$f] != null then ($path | tojson) else ([$path] | tojson) end)}]'"
    end;
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
      "     👉 Powiększ dysk(i) z listy urządzeń VG \($dcname) o ~\(($vgGrow | gup) + 1)Gi (lub dodaj nowy dysk tej wielkości do deviceSelector), potem pvresize.",
      "        Z działającym oc debug (bez --no-debug, uprawnienia cluster-admin) skrypt wskaże konkretny dysk/partycję."' \
    --arg node "$1" --argjson deficit "$2" --argjson dccfg "$3" --arg dcname "$4"
}

# Wariant pelny: dane LVM z noda
recommend_node() { # <node> <deficitBytes> <dccfgJSON> <dcname> <coverCount> <inSel true|false>
  local d="$TMP/node-$1"
  J "$RECLIB $NODELIB"'
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
        | (if $s.t == "part" then $s.disk else $bn end) as $dk
        | (.pv_size | num) as $ps | (.dev_size | num) as $ds
        | { dev: .pv_name, bn: $bn, pvSize: $ps, devSize: $ds,
            pending: ([$ds - $ps, 0] | max | if . < 1073741824 then 0 else . end),
            kind: (if $s == null then "inne" elif $s.t == "part" then "partycja" else "dysk" end),
            disk: $dk, id: ident($dk),
            partnum: (if $s.t == "part" then ($bn | capture("(?<n>[0-9]+)$").n // "?") else null end),
            diskSize: (($SYS | map(select(.t == "disk" and .name == $dk)) | first | .sec // 0) * 512),
            last: (if $s.t == "part" then ([ $SYS[] | select(.t == "part" and .disk == $s.disk and .start > $s.start) ] | length == 0) else true end),
            tail: (if $s.t == "part" then
                     (($SYS | map(select(.t == "disk" and .name == $s.disk)) | first | .sec // 0) * 512) as $dsz
                     | ([ $SYS[] | select(.t == "part" and .disk == $s.disk and .start > $s.start) | .start * 512 ] | min) as $next
                     | ((($next // ($dsz - 34 * 512)) - ($s.start + $s.sec) * 512) | if . < 1073741824 then 0 else . end)
                   else 0 end) } ] as $P

    # --- nieuzyte dyski (z identyfikatorem by-id i informacja, czy cos je blokuje) ---
    | [ $BD[] | select(.type == "disk" and ((.children // []) | length) == 0 and .fstype == null and .mountpoint == null
                       and ((.ro | tostring) as $r | $r != "true" and $r != "1"))
        | select(.name as $nm | ($PVS | any(.[]; .pv_name | endswith("/" + $nm))) | not)
        | .name as $nm
        | { dev: "/dev/\($nm)", size: (.size | num), ref: devref($nm), stable: (stablepath($nm) != null), id: ident($nm),
            resv: reservedby($nm), inThis: any(selpaths[]; pathk(.) == $nm),
            excl: ([ $ns.excluded[]? | select(.name | endswith("/" + $nm)) | .reasons[]? ] | join("; ")) } ] as $FREE
    | ([ $FREE[] | select(.resv == null and .size >= $vgGrow) ] | sort_by(.size)) as $USE

    # --- opcje (od najtanszej) ---
    | ($P | map(.pending) | add // 0) as $pendSum
    | (" (\(selfield)" + (if selfield == "optionalPaths" and $cover > 1 then " - deviceClass obejmuje \($cover) nody, a ta ścieżka istnieje tylko na tym" else "" end) + ")") as $fnote
    | [
        ( if $t.thin and $pool != null and $poolSlack >= $poolGrow then
            { k: "lvextend", t: "Thin pool \($dcname)/\($pool.lv_name) ma zapas w VG (\($poolSlack | gi)) - wystarczy rozszerzyć pool o +\(($poolGrow | gup) + 1)Gi (LVMS/vgmanager zwykle robi to sam - sprawdź logi vgmanager)",
              cmd: "lvextend -L +\(($poolGrow | gup) + 1)G \($dcname)/\($pool.lv_name)" } else empty end ),
        ( if $pendSum >= $vgGrow then
            { k: "pvresize", t: "Dysk już jest większy niż PV w VG \($dcname) (\($P | map(select(.pending > 0) | "\(.dev) +\(.pending | gi)") | join(", "))) - wystarczy pvresize, bez zmian w infrastrukturze",
              cmd: ($P | map(select(.pending > 0) | "pvresize \(.dev)") | join(" && ")) } else empty end ),
        ( $P[] | select(.kind == "partycja" and (.tail + .pending) >= $vgGrow)
          | { k: "growpart", t: "Za partycją \(.dev) na /dev/\(.disk)\(.id) jest \(.tail | gi) wolnego (niepartycjonowanego) miejsca - rozciągnij partycję i PV w VG \($dcname)",
              cmd: "growpart /dev/\(.disk) \(.partnum) && pvresize \(.dev)" } ),
        ( $USE[]
          | { k: "newdisk",
              t: ( "Użyj nieużytego dysku \(.dev) (\(.size | gi))\(.id) → dodaj do VG \($dcname)"
                   + (if .inThis then ": ścieżka już jest w deviceSelector, ale dysk nie trafił do VG - sprawdź status LVMS"
                      elif ($dccfg.deviceSelector // null) == null then ": deviceClass bez deviceSelector powinien dobrać go sam - sprawdź status LVMS"
                      else ": dopisz \(.ref) do LVMCluster deviceClass \($dcname) deviceSelector" + $fnote end)
                   + (if .excl != "" then "; LVMS go wyklucza: " + .excl else "" end)
                   + (if .stable then "" else "  ⚠️ brak linku by-id - nazwa /dev może się zmienić po restarcie" end) ),
              cmd: (if .inThis then statuscmd else (patchcmd(.ref) // statuscmd) end) } ),
        ( ($P | map(select(.kind == "dysk")) | sort_by(-.pvSize) | first) as $wd
          | if $wd != null then
              ([$vgGrow - $wd.pending, 0] | max) as $g
              | { k: "grow-disk", t: "Powiększ dysk \($wd.dev)\($wd.id) (PV całego dysku w VG \($dcname), teraz \($wd.diskSize | gi)) o +\($g | gup)Gi → \((($wd.diskSize + $g) | gup))Gi w hypervisorze/SAN, potem pvresize",
                cmd: "pvresize \($wd.dev)" }
            else empty end ),
        ( ($P | map(select(.kind == "partycja" and .last)) | sort_by(-.pvSize) | first) as $lp
          | if $lp != null then
              ([$vgGrow - $lp.tail - $lp.pending, 0] | max) as $g
              | select($g > 0)
              | { k: "grow-disk-part", t: "Powiększ dysk /dev/\($lp.disk)\($lp.id) (teraz \($lp.diskSize | gi)) o +\($g | gup)Gi → \((($lp.diskSize + $g) | gup))Gi; PV VG \($dcname) jest na ostatniej partycji \($lp.dev), więc potem growpart + pvresize",
                  cmd: "growpart /dev/\($lp.disk) \($lp.partnum) && pvresize \($lp.dev)" }
            else empty end ),
        { k: "add-disk",
          t: ( "Dołóż do noda nowy dysk ≥ \($vgGrow | gup)Gi i dodaj go do VG \($dcname)"
               + (if ($dccfg.deviceSelector // null) == null then " (deviceClass bez deviceSelector - LVMS dobierze wolny dysk sam)"
                  else ": dopisz jego ścieżkę /dev/disk/by-id do LVMCluster deviceClass \($dcname) deviceSelector" + $fnote end) ),
          cmd: (patchcmd("/dev/disk/by-id/<NOWY-DYSK>") // statuscmd) }
      ] as $OPTS

    # --- wydruk ---
    | ( if $vg == null then
          "     ❌ VG \($dcname) nie istnieje na nodzie \($node)" + (if $insel then " (nodeSelector deviceClass obejmuje ten nod - LVMS powinien go tu utworzyć)." else "." end),
          ( if $ns != null then "     LVMS nodeStatus: status=\($ns.status // "?") \($ns.reason // "")"
            else "     LVMVolumeGroupNodeStatus: brak wpisu \($dcname) dla tego noda." end )
        else
          "     VG \($dcname): rozmiar \($vgSize | gi), wolne \($vgFree | gi), PV: \($vg.pv_count), LV: \($vg.lv_count)",
          ( if $pool != null then "     Thin pool \($pool.lv_name): \($poolSize | gi), data \($pool.data_percent // "?")%, metadata \($pool.metadata_percent // "?")%"
                + (if ($pool.data_percent | num) >= 80 then "  ⚠️ pool fizycznie zapełniony ≥80%!" else "" end)
                + (if ($pool.metadata_percent | num) >= 80 then "  ⚠️ metadata ≥80%!" else "" end)
            else empty end ),
          ( $P[] | "       PV \(.dev | pad(18)) \(.kind | pad(9)) dysk=/dev/\(.disk) (\(.diskSize | gi))  PV=\(.pvSize | gi)\(.id)"
                   + (if .pending > 0 then "  ⚡ dysk większy o \(.pending | gi) (brak pvresize)" else "" end)
                   + (if .kind == "partycja" then "  za partycją wolne: \(.tail | gi)\(if .last then "" else " (nie ostatnia partycja)" end)" else "" end) )
        end ),
      ( $FREE[] | "       nieużyty dysk \(.dev) (\(.size | gi))\(.id)  "
                  + (if .resv != null then "⛔ zarezerwowany w deviceSelector deviceClass \(.resv)"
                     elif .size < $vgGrow then "⛔ za mały (potrzeba ≥ \($vgGrow | gup)Gi)"
                     else "✅ nadaje się" end)
                  + (if .excl != "" then "  (LVMS wyklucza: \(.excl))" else "" end) ),
      ( if ($FREE | length) == 0 then "       Brak nieużytych dysków na nodzie." else empty end ),
      "     Obliczenie: deficyt \($deficit | gi)"
        + (if $t.thin then " ÷ overprovisionRatio \($t.R) = pool +\($poolGrow | gi); pool może zająć \($t.SP)% VG → VG +\($vgGrowRaw | gi)" else " (thick) → VG +\($vgGrowRaw | gi)" end)
        + " → zaokrąglone z zapasem: +\($vgGrow | gup)Gi",
      "     ✅ REKOMENDACJA: \($OPTS[0].t)",
      "        sugestia (NIE wykonano): \($OPTS[0].cmd)",
      ( $OPTS[1:][] | "     ➖ alternatywa: \(.t)" )' \
    --arg node "$1" --argjson deficit "$2" --argjson dccfg "$3" --arg dcname "$4" --argjson cover "$5" --argjson insel "$6" \
    --slurpfile lsblk "$d/LSBLK.out" --slurpfile vgs "$d/VGS.out" --slurpfile pvsn "$d/PVS.out" \
    --slurpfile lvs "$d/LVS.out" --slurpfile sys "$d/sys.json" --slurpfile byid "$d/byid.json"
}

# StorageClass nie wskazuje istniejacego deviceClass: blad konfiguracji, nie brak miejsca.
# Pokaz, ktory deviceClass / StorageClass pomiesci PVC juz teraz (wg adnotacji pojemnosci na nodach).
dc_alternatives() { # <groupJSON> <infoJSON>
  J '
    $g.need as $need
    | [ $g.rows[] | select($alln == 1 or .cand) | .node ] as $cn
    | [ $lvmc[0].items[]?.spec.storage.deviceClasses[]? as $d
        | [ $scs[0].items[] | select(.provisioner == $g.provisioner
              and ((.parameters // {}) | (.["topolvm.io/device-class"] // .["topolvm.cybozu.com/device-class"] // "")) == $d.name) | .metadata.name ] as $dsc
        | [ $nodes[0].items[] | . as $n | select(any($cn[]; . == $n.metadata.name))
            | (($n.metadata.annotations // {})["capacity.topolvm.io/" + $d.name]) as $a
            | select($a != null) | {node: $n.metadata.name, free: ($a | qty)} ] as $caps
        | { name: $d.name, thin: ($d.thinPoolConfig != null), scs: $dsc, caps: $caps,
            fit: ($caps | map(select(.free >= $need)) | sort_by(-.free)) } ] as $D
    | ( if $info.how == "force" then "   ❌ --device-class \($info.want): takiego deviceClass nie ma w LVMCluster."
        elif $info.how == "param" then "   ❌ StorageClass \($g.sc) wskazuje deviceClass \($info.want), którego nie ma w LVMCluster."
        else "   ❌ StorageClass \($g.sc) nie ma parametru device-class, a żaden deviceClass w LVMCluster nie ma default: true." end ),
      "      Driver raportuje wtedy 0 lub brak pojemności na każdym nodzie - to błąd konfiguracji, powiększanie dysków NIE pomoże.",
      "      deviceClass dostępne w LVMCluster (wolne miejsce wg adnotacji capacity na nodach-kandydatach):",
      ( $D[]
        | "        • \(.name) [\(if .thin then "thin" else "thick" end)]  StorageClass: \(if (.scs | length) == 0 then "brak" else (.scs | join(", ")) end)",
          "            " + ( if (.fit | length) > 0 then
                               "✅ zmieści \($need | gi) na \(.fit | length) nodach: \(.fit[0:3] | map("\(.node) (wolne \(.free | gi))") | join(", "))\(if (.fit | length) > 3 then ", ..." else "" end)"
                             elif (.caps | length) > 0 then "❌ za mało miejsca (max \(.caps | map(.free) | max | gi) na \(.caps | sort_by(-.free) | .[0].node))"
                             else "❌ tego VG nie ma na żadnym nodzie-kandydacie" end ) ),
      ( ($D | map(select(.fit | length > 0)) | sort_by((if (.scs | length) > 0 then 0 else 1 end), -(.fit | length)) | first) as $b
        | if $b != null then
            ( if ($b.scs | length) > 0
              then "   ✅ REKOMENDACJA: użyj StorageClass \($b.scs[0]) (deviceClass \($b.name)) - PVC zmieści się od razu, bez powiększania dysków."
              else "   ✅ REKOMENDACJA: utwórz StorageClass z parametrem topolvm.io/device-class=\($b.name) i użyj jej - PVC zmieści się od razu, bez powiększania dysków." end ),
            "      storageClassName w PVC jest niezmienne: usuń PVC i utwórz ponownie z nową SC (StatefulSet: zmiana volumeClaimTemplates = odtworzenie StatefulSet).",
            ( if $info.how == "none" then "   ➖ alternatywa: oznacz docelowy deviceClass jako default: true w LVMCluster (o ile wersja LVMS pozwala to zmienić) - SC bez parametru zacznie go używać." else empty end ),
            "   ➖ inny deviceClass: uruchom ponownie z --device-class <nazwa> - skrypt wskaże dysk do dodania/powiększenia i VG."
          else
            "   ⚠️  Żaden deviceClass nie pomieści teraz \($need | gi) na nodach-kandydatach.",
            "   👉 Wybierz docelowy deviceClass i uruchom ponownie z --device-class <nazwa> - skrypt wskaże dysk do dodania/powiększenia i VG."
          end )' \
    --argjson g "$1" --argjson info "$2" --argjson alln "$ALL_NODES"
}

# Grupy: StorageClass -> suma niezbindowanych PVC vs pojemnosc per node
J 'pvcinfo as $PI
  | [ $PI[] | select((.bound | not) and .capTracking and .pvc != null) ] as $U
  | [ ($U | group_by(.scName))[] as $grp
      | $grp[0] as $v0
      | ($grp | map(.size) | add) as $need
      | { sc: $v0.scName, provisioner: $v0.provisioner, need: $need,
          dc: ($v0.sc.parameters["topolvm.io/device-class"] // $v0.sc.parameters["topolvm.cybozu.com/device-class"] // ""),
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

    if [ "$ALL_NODES" -ne 1 ] && [ "$(jq '[.rows[] | select(.cand)] | length' <<<"$G")" -eq 0 ]; then
      echo "   ⚠️  Żaden node nie przechodzi pozostałych filtrów (taint/zasoby/affinity/cordon) - samo powiększenie dysku nie pomoże."
      echo "      Użyj --all-nodes, aby mimo to policzyć powiększenie dla nodów."
      continue
    fi

    if [[ "$PROV" != *topolvm* ]]; then
      echo "   Provisioner $PROV nie jest LVMS/TopoLVM - nie umiem zmapować pojemności na dyski."
      echo "   Parametry SC: $(J '[$scs[0].items[] | select(.metadata.name == $sc) | .parameters // {} | to_entries[] | "\(.key)=\(.value)"] | join(" ")' --arg sc "$SC")"
      J '[ $g.rows[] | select($alln == 1 or .cand) ] | sort_by(.deficit, .node) | .[0:$top][]
         | "   🖥️  \(.node): dostępne \(.have | gi), brakuje \(.deficit | gi)"' --argjson g "$G" --argjson alln "$ALL_NODES" --argjson top "$TOP_N"
      echo "   👉 Zwiększ pulę backendu tej SC o co najmniej $(J '[ $g.rows[] | select($alln == 1 or .cand) | .deficit ] | min | gi' --argjson g "$G" --argjson alln "$ALL_NODES")."
      continue
    fi

    # StorageClass -> deviceClass tak, jak liczy to driver: parametr SC, a gdy go brak - deviceClass z default: true
    INFO=$(J '[ $lvmc[0].items[]? as $c | ($c.spec.storage.deviceClasses // []) | to_entries[]
                | .value + {_idx: .key, _cr: $c.metadata.name, _ns: $c.metadata.namespace} ] as $all
              | ($all | map(select(.default == true)) | first) as $dflt
              | (if $force != "" then $force elif $dc != "" then $dc else ($dflt.name // "") end) as $want
              | { want: $want, known: (($all | length) > 0),
                  how: (if $force != "" then "force" elif $dc != "" then "param" elif $dflt != null then "default" else "none" end),
                  cfg: ($all | map(select(.name == $want)) | first) }' --arg dc "$DC" --arg force "$FORCE_DC" | jq -c .)
    DCNAME=$(jq -r .want <<<"$INFO"); DCCFG=$(jq -c '.cfg // {}' <<<"$INFO")
    if [ "$(jq -r '.known and .cfg == null' <<<"$INFO")" = true ]; then
      dc_alternatives "$G" "$INFO"
      continue
    fi
    if [ -z "$DCNAME" ]; then
      echo "   ⚠️  Nie mogę ustalić deviceClass/VG: brak danych LVMCluster, a SC nie ma parametru device-class."
      echo "      Uruchom ponownie z --device-class <nazwa VG>."
      continue
    fi

    # Nody: zasieg nodeSelector deviceClass, istnienie VG, pojemnosc (przy --device-class z adnotacji noda)
    PLAN=$(J '[ $nodes[0].items[] as $n
                | (if ($dccfg.nodeSelector // null) != null then ($dccfg.nodeSelector | termsmatch($n)) else true end) as $cov
                | (($n.metadata.annotations // {})["capacity.topolvm.io/" + $dcname]) as $a
                | ($g.rows[] | select(.node == $n.metadata.name)) as $r
                | (if $force != "" then ($a | qty) else $r.have end) as $have
                | $r + { inSel: $cov, have: $have, deficit: ([$g.need - $have, 0] | max),
                         hasVg: ($a != null or any($lvmns[0].items[]?; .metadata.name == $r.node and any(.spec.nodeStatus[]?; .name == $dcname))) } ] as $R
              | { cover: ([ $R[] | select(.inSel) ] | length),
                  rows: [ $R[] | select($alln == 1 or .cand) ] }' \
            --argjson g "$G" --argjson dccfg "$DCCFG" --arg dcname "$DCNAME" --arg force "$FORCE_DC" --argjson alln "$ALL_NODES" | jq -c .)
    COVER=$(jq .cover <<<"$PLAN")

    J "$RECLIB"'
      "   deviceClass (= nazwa VG): \($dcname)  ← " + (if $info.how == "force" then "wymuszony opcją --device-class"
            elif $info.how == "param" then "parametr device-class w StorageClass \($g.sc)"
            else "default: true w LVMCluster (StorageClass \($g.sc) nie ma parametru device-class)" end),
      ( if $dccfg._cr != null then
          "   LVMCluster \($dccfg._ns)/\($dccfg._cr): " + (if $dccfg.thinPoolConfig != null
              then "thin pool \(thinparams.pool), sizePercent=\(thinparams.SP), overprovisionRatio=\(thinparams.R)" else "thick (bez thin pool)" end),
          "   nodeSelector: \(nstext)",
          "   deviceSelector: " + (if ($dccfg.deviceSelector // null) == null then "brak (LVMS sam bierze wszystkie wolne dyski)"
              else "paths=\($dccfg.deviceSelector.paths // [] | length), optionalPaths=\($dccfg.deviceSelector.optionalPaths // [] | length)" end)
        else "   ⚠️  Brak danych LVMCluster - parametry thin pool przyjęte domyślnie." end ),
      "   Zasięg: deviceClass obejmuje \($plan.cover) nodów; analizowane nody: \($plan.rows | length), z nich objęte deviceClass: \([$plan.rows[] | select(.inSel)] | length), z istniejącym VG: \([$plan.rows[] | select(.hasVg)] | length)"' \
      --argjson g "$G" --argjson info "$INFO" --argjson dccfg "$DCCFG" --arg dcname "$DCNAME" --argjson plan "$PLAN"

    if [ -n "$FORCE_DC" ]; then
      FITS=$(jq -r '[.rows[] | select(.deficit == 0) | .node] | join(", ")' <<<"$PLAN")
      if [ -n "$FITS" ]; then
        echo "   ✅ deviceClass $DCNAME pomieści PVC już teraz na: $FITS - wystarczy StorageClass wskazująca ten deviceClass, bez powiększania dysków."
        continue
      fi
    fi

    # Kolejnosc: selected-node, potem nody z istniejacym VG, potem objete deviceClass, potem najmniejszy deficyt
    TARGETS=$(jq -r --argjson top "$TOP_N" '.rows
      | sort_by((if .sel then 0 else 1 end), (if .hasVg then 0 else 1 end), (if .inSel then 0 else 1 end), .deficit, .node)
      | .[0:$top][] | [.node, (.deficit|tostring), (.have|tostring), (.cand|tostring), (.sel|tostring), (.inSel|tostring), (.hasVg|tostring)] | @tsv' <<<"$PLAN")

    while IFS=$'\t' read -r NODE DEF HAVE CAND ISSEL INSEL HASVG; do
      echo ""
      echo "   🖥️  $NODE  (dostępne $(J '$x|tonumber|gi' --arg x "$HAVE"), brakuje $(J '$x|tonumber|gi' --arg x "$DEF")$( [ "$ISSEL" = true ] && echo ', 🎯 selected-node')$( [ "$CAND" = true ] || echo ', ⚠️ odpada też na innych filtrach'))"
      if [ "$DEF" = "0" ]; then
        echo "     ✅ Miejsca wystarcza - powiększanie nic nie da; node blokuje inny filtr (patrz tabela)."
        continue
      fi
      if [ "$INSEL" != true ] && [ "$HASVG" != true ]; then
        echo "     ⛔ deviceClass $DCNAME nie obejmuje tego noda (nodeSelector: $(J "$RECLIB"'nstext' --argjson dccfg "$DCCFG"))."
        echo "        LVMS nie utworzy tu VG $DCNAME - dokładanie ani powiększanie dysku na tym nodzie nic nie da."
        echo "     👉 Wybierz nod objęty deviceClass albo nadaj temu nodowi etykietę zgodną z nodeSelector."
        continue
      fi
      if [ "$USE_DEBUG" -eq 1 ]; then
        echo "     ⏳ oc debug node/$NODE (lsblk/vgs/pvs/lvs - tylko odczyt)..."
        if collect_node "$NODE"; then
          recommend_node "$NODE" "$DEF" "$DCCFG" "$DCNAME" "$COVER" "$INSEL"
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
  echo "      Po zmianie: LVMS (vg-manager) powinien wykryć dysk/rozmiar; CSIStorageCapacity odświeży się po chwili."
fi

echo ""
echo "--- ✅ Koniec symulacji planowania (v4). ---"
