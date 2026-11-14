#!/bin/bash
# infraNodeCheck.sh - weryfikacja infra nodow OpenShift zgodnie z dokumentacja (TYLKO ODCZYT)
#
# Uzycie: infraNodeCheck.sh [--nodes a,b,c] [--name-pattern REGEX] [--taint-value WART]
#                           [--noexecute] [--remove-worker] [--allow-ns REGEX] [--max N] [--emit PLIK]
#                           [--emit-rollback PLIK]
#
#   --nodes a,b,c       nody, ktore MAJA byc infra (domyslnie: nody z etykieta node-role.kubernetes.io/infra,
#                       a gdy takich brak - nody, ktorych nazwa pasuje do --name-pattern)
#   --name-pattern RE   wzorzec nazwy kandydatow na infra (domyslnie: infra)
#   --taint-value WART  wartosc taintu do zaproponowania (domyslnie: reserved, jak w dokumentacji)
#   --noexecute         wymagaj takze taintu NoExecute (wyrzuca z infra pody bez tolerancji)
#   --remove-worker     traktuj etykiete worker na infra nodzie jako blad i zaproponuj jej usuniecie
#                       (dokumentacja dopuszcza role infra,worker; usuniecie wymaga puli MCP infra)
#   --allow-ns RE       dodatkowe namespace'y dozwolone na infra (np. Quay, instancje GitOps)
#   --max N             ile pozycji pokazywac na listach (domyslnie 30)
#   --emit PLIK         zapisz proponowane komendy do pliku (skrypt NIE jest uruchamiany)
#   --emit-rollback PLIK zapisz komendy wycofania do pliku (skrypt NIE jest uruchamiany)
#
# Co sprawdza (wg dokumentacji OpenShift: "Creating infrastructure machine sets",
# "Binding infrastructure node workloads using taints and tolerations", "Moving resources to
# infrastructure machine sets", "Red Hat OpenShift infrastructure components"):
#  1. ktore nody maja role infra, czy sa dedykowane (infra bez worker/master), Ready, cordon
#  2. etykieta node-role.kubernetes.io/infra="" i taint node-role.kubernetes.io/infra:NoSchedule
#     (opcjonalnie NoExecute), etykiety/tainty w szablonie MachineSet (gdy nod pochodzi z MachineSet)
#  3. pula MachineConfigPool infra: czy istnieje, nodeSelector, machineConfigSelector (worker+infra),
#     stan puli, czy kazdy infra nod jest faktycznie w tej puli
#  4. selektory i tolerancje komponentow infrastruktury: IngressController (nodePlacement),
#     image registry, monitoring (cluster-monitoring-config), logging (tylko raport)
#  5. scheduler (defaultNodeSelector), adnotacje projektow (openshift.io/node-selector,
#     scheduler.alpha.kubernetes.io/defaultTolerations)
#  6. pody, ktore JUZ dzialaja na infra, a nie sa komponentami infrastruktury
#  7. pody/workloady, ktore MOGA trafic na infra - teraz oraz po wprowadzeniu proponowanych zmian
#     (tolerancje, nodeSelector, wymagane nodeAffinity)
#  Na koncu: komendy wprowadzajace brakujace zmiany, w bezpiecznej kolejnosci (tylko wypisywane):
#   KROK 0 - kopia wszystkich zmienianych obiektow (nodes, mcp, machinesets, ingresscontroller,
#            image registry, cluster-monitoring-config)
#  oraz ROLLBACK - komendy wycofania, wygenerowane ze stanu klastra SPRZED zmian, w odwrotnej
#  kolejnosci (tainty, etykiety, patche komponentow przywracaja dokladnie poprzednie wartosci;
#  pula MCP infra usuwana bezpiecznie: nody najpierw wracaja do puli worker). Nie da sie cofnac:
#  usunietych podow, podow wyrzuconych przez NoExecute, restartow nodow, zmian poza klastrem (LB/DNS).
#  Ostrzega tez, gdy PVC monitoringu sa przypiete do nodow spoza infra (lokalny storage, np. LVMS) -
#  po przeniesieniu pod zostalby w Pending.
#
# Kod wyjscia: 0 - OK, 1 - tylko ostrzezenia, 2 - bledy, 3 - blad uruchomienia

set -o pipefail

NODES=""
NAME_PATTERN="infra"
TAINT_VALUE="reserved"
NOEXEC=false
RMWORKER=false
ALLOW_NS=""
MAXLIST=30
EMIT=""
EMIT_RB=""

need() { if [ -z "$2" ]; then echo "🚨 Błąd: brak wartości po $1." >&2; exit 3; fi; }

while (( "$#" )); do
  case "$1" in
    --nodes)         need "$1" "$2"; NODES="$2"; shift 2 ;;
    --name-pattern)  need "$1" "$2"; NAME_PATTERN="$2"; shift 2 ;;
    --taint-value)   need "$1" "$2"; TAINT_VALUE="$2"; shift 2 ;;
    --noexecute)     NOEXEC=true; shift ;;
    --remove-worker) RMWORKER=true; shift ;;
    --allow-ns)      need "$1" "$2"; ALLOW_NS="$2"; shift 2 ;;
    --max)           need "$1" "$2"; MAXLIST="$2"; shift 2 ;;
    --emit)          need "$1" "$2"; EMIT="$2"; shift 2 ;;
    --emit-rollback) need "$1" "$2"; EMIT_RB="$2"; shift 2 ;;
    -h|--help)       sed -n '2,/^$/p' "$0"; exit 0 ;;
    *)               echo "🚨 Nieznany argument: $1" >&2; exit 3 ;;
  esac
done

case "$MAXLIST" in ''|*[!0-9]*) echo "🚨 --max musi być liczbą." >&2; exit 3 ;; esac
command -v oc >/dev/null || { echo "🚨 Brak polecenia oc." >&2; exit 3; }
command -v jq >/dev/null || { echo "🚨 Brak polecenia jq." >&2; exit 3; }
oc whoami >/dev/null 2>&1 || { echo "🚨 Brak zalogowania do klastra (oc whoami)." >&2; exit 3; }

TMP=$(mktemp -d) || exit 3
trap 'rm -rf "$TMP"' EXIT

# get <plik> <domyslny_json> <argumenty oc...> - brak zasobu / uprawnien => wartosc domyslna
get() {
  local out="$1" def="$2"; shift 2
  if ! oc get "$@" -o json >"$out" 2>/dev/null || ! jq -e . "$out" >/dev/null 2>&1; then
    echo "$def" >"$out"
  fi
}

echo "⏳ Pobieranie danych z klastra..." >&2
get "$TMP/nodes.json"  '{"items":[]}' nodes
get "$TMP/mcp.json"    '{"items":[]}' machineconfigpool
get "$TMP/sched.json"  '{}'           scheduler cluster
get "$TMP/ns.json"     '{"items":[]}' namespaces
get "$TMP/ic.json"     '{"items":[]}' ingresscontroller -n openshift-ingress-operator
get "$TMP/reg.json"    '{}'           configs.imageregistry.operator.openshift.io cluster
get "$TMP/cm.json"     '{}'           configmap cluster-monitoring-config -n openshift-monitoring
get "$TMP/ma.json"     '{"items":[]}' machines.machine.openshift.io -n openshift-machine-api
get "$TMP/ms.json"     '{"items":[]}' machinesets.machine.openshift.io -n openshift-machine-api
get "$TMP/pvc.json"    '{"items":[]}' pvc -n openshift-monitoring
if ! oc get pv -o json 2>/dev/null | jq -c '{items: [.items[] | select(.spec.claimRef.namespace == "openshift-monitoring")
      | {metadata: {name: .metadata.name}, spec: {nodeAffinity: .spec.nodeAffinity}}]}' >"$TMP/pv.json"; then
  echo '{"items":[]}' >"$TMP/pv.json"
fi

: >"$TMP/wl.list"
for ns in openshift-ingress openshift-image-registry openshift-monitoring openshift-logging; do
  get "$TMP/wl-$ns.json" '{"items":[]}' deployments,statefulsets -n "$ns"
  echo "$TMP/wl-$ns.json" >>"$TMP/wl.list"
done
# shellcheck disable=SC2046
jq -s '{items: (map(.items // []) | add // [])}' $(cat "$TMP/wl.list") >"$TMP/wl.json" || exit 3

if ! oc get pods -A -o json 2>/dev/null | jq -c '{items: [.items[] | {
      metadata: {name: .metadata.name, namespace: .metadata.namespace,
                 ownerReferences: .metadata.ownerReferences,
                 labels: {"pod-template-hash": (.metadata.labels["pod-template-hash"] // null)}},
      spec: {nodeName: .spec.nodeName, nodeSelector: .spec.nodeSelector, tolerations: .spec.tolerations,
             affinity: {nodeAffinity: (.spec.affinity.nodeAffinity // null)}},
      status: {phase: .status.phase}}]}' >"$TMP/pods.json"; then
  echo "⚠️  Nie udało się pobrać podów - sekcje 6/7 będą puste." >&2
  echo '{"items":[]}' >"$TMP/pods.json"
fi

if [ "$(jq '.items | length' "$TMP/nodes.json")" -eq 0 ]; then
  echo "🚨 Nie udało się pobrać listy nodów (uprawnienia?)." >&2; exit 3
fi

jq -n \
  --arg nodes "$NODES" --arg pat "$NAME_PATTERN" --arg tval "$TAINT_VALUE" \
  --argjson noexec "$NOEXEC" --argjson rmworker "$RMWORKER" --arg allowns "$ALLOW_NS" \
  --argjson max "$MAXLIST" --arg now "$(date '+%F %T')" \
  '{nodes: ($nodes | split(",") | map(select(. != ""))), pat: $pat, tval: $tval,
    noexec: $noexec, rmworker: $rmworker, allowns: $allowns, max: $max, now: $now}' >"$TMP/args.json" || exit 3

read -r -d '' JQPROG <<'EOF'
def IK: "node-role.kubernetes.io/infra";
def WK: "node-role.kubernetes.io/worker";
def lbl: .metadata.labels // {};
def hasrole($r): lbl | has("node-role.kubernetes.io/" + $r);
def ismaster: hasrole("master") or hasrole("control-plane");
def roles: [lbl | keys[] | select(startswith("node-role.kubernetes.io/")) | ltrimstr("node-role.kubernetes.io/")]
           | if length == 0 then "<brak>" else join(",") end;
def hard: .effect == "NoSchedule" or .effect == "NoExecute";
def isready: any(.status.conditions[]?; .type == "Ready" and .status == "True");
def tstr: "\(.key)\(if (.value // "") != "" then "=" + .value else "" end):\(.effect)";
def tolstr: "\(.key // "*")\(if .value then "=" + .value else "" end):\(.effect // "*")(\(.operator // "Equal"))";
def pad($w): tostring as $s | $s + ([range(0; ([$w - ($s|length), 0] | max))] | map(" ") | join(""));
def head($n): .[0:$n];

def OK($m):   "  ✅ " + $m;
def WARN($m): "  ⚠️  " + $m;
def FAIL($m): "  ❌ " + $m;
def INFO($m): "  ℹ️  " + $m;
def SUB($m):  "       " + $m;
def H($t): ["", "════════ " + $t + " ════════"];

# --- semantyka schedulera (jak w nodepodAfinityV3.sh) ---
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
def tolerates($tols):
  . as $t
  | any($tols[]?;
        ( ((.key // "") == "" and .operator == "Exists")
          or (.key == $t.key and ((.operator // "Equal") == "Exists" or (.value // "") == ($t.value // ""))) )
        and ((.effect // "") == "" or .effect == $t.effect));

# pod (.) wzgledem noda $n
def selok($n): (.spec.nodeSelector // {}) | to_entries | all(($n.metadata.labels // {})[.key] == .value);
def affok($n):
  (.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution) as $r
  | if $r == null then true else ($r | termsmatch($n)) end;
def blockers($n): (.spec.tolerations // []) as $tols | [ $n.spec.taints[]? | select(hard) | select(tolerates($tols) | not) ];
def canrun($n): selok($n) and affok($n) and (blockers($n) | length == 0);
def tolall: any(.spec.tolerations[]?; (.key // "") == "" and .operator == "Exists");

# podspec (.) komponentu: czy celuje w infra i czy toleruje tainty $tt
def targetsinfra:
  ((.nodeSelector // {}) | has(IK))
  or any(.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?;
         .key == IK and (.operator == "Exists" or .operator == "In"));
def targetsworker: (.nodeSelector // {}) | has(WK);
def tolok($tt): (.tolerations // []) as $tols | all($tt[]; tolerates($tols));

def owner:
  ((.metadata.ownerReferences // []) | map(select(.controller == true)) | .[0]) as $o
  | (.metadata.labels["pod-template-hash"] // "") as $h
  | if $o == null then {kind: "Pod", name: .metadata.name}
    elif $o.kind == "ReplicaSet" and $h != "" and ($o.name | endswith("-" + $h))
      then {kind: "Deployment", name: ($o.name | rtrimstr("-" + $h))}
    elif $o.kind == "Job" and ($o.name | test("-[0-9]{8,}$"))
      then {kind: "CronJob", name: ($o.name | sub("-[0-9]+$"; ""))}
    else {kind: $o.kind, name: $o.name} end;

# "k=v,k2=v2" -> {k: v, k2: v2}
def kvmap: split(",") | map(select(. != "") | capture("^\\s*(?<k>[^=]+?)\\s*=\\s*(?<v>.*?)\\s*$")) | map({key: .k, value: .v}) | from_entries;

($A[0]) as $a
| ($N[0].items // []) as $nodes
| ($MCP[0].items // []) as $mcps
| ([$P[0].items[]? | select(.status.phase != "Succeeded" and .status.phase != "Failed") | . + {_o: owner}]) as $pods
| ("^(openshift(-.*)?|kube-.*|default|open-cluster-management.*|multicluster-engine|hive|stackrox|rhacs-operator|istio-system)$") as $platre
| def allowedns: test($platre) or ($a.allowns != "" and test($a.allowns));

# ---------------- nody docelowe ----------------
  [$nodes[] | select(hasrole("infra"))] as $infra
| [$nodes[] | select((hasrole("infra") | not) and (ismaster | not)
                     and ((.metadata.name | test($a.pat)) or any(.spec.taints[]?; .key == IK)))] as $cand
| ( if ($a.nodes | length) > 0 then {src: "--nodes", list: [$nodes[] | select(.metadata.name as $x | any($a.nodes[]; . == $x))]}
    elif ($infra | length) > 0 then {src: ("etykieta " + IK), list: $infra}
    else {src: ("nazwa pasuje do /\($a.pat)/ (brak nodów z etykietą infra)"), list: $cand} end ) as $tsel
| $tsel.list as $T
| [$a.nodes[] | select(. as $x | any($nodes[]; .metadata.name == $x) | not)] as $unknown
| ($T | map({key: .metadata.name, value: true}) | from_entries) as $TS

# planowane tainty per nod i stan "po zmianach"
| def plan:
    (.spec.taints // []) as $t
    | (if any($t[]?; .key == IK and hard) then [] else [{key: IK, value: $a.tval, effect: "NoSchedule"}] end)
    + (if $a.noexec and (any($t[]?; .key == IK and .effect == "NoExecute") | not)
       then [{key: IK, value: $a.tval, effect: "NoExecute"}] else [] end);
  def simnode:
    plan as $pl
    | .spec.taints = ((.spec.taints // []) + $pl)
    | .metadata.labels = ((.metadata.labels // {}) + {(IK): ""})
    | if $a.rmworker then .metadata.labels |= del(.[WK]) else . end;
  [$T[] | simnode] as $TSIM

# zestaw taintow infra, ktore komponenty musza tolerowac + proponowane tolerancje
| ([$TSIM[] | .spec.taints[]? | select(.key == IK and hard) | {key, value: (.value // ""), effect}] | unique) as $TT0
| (if ($TT0 | length) == 0 then [{key: IK, value: $a.tval, effect: "NoSchedule"}] else $TT0 end) as $TT
| ($TT | map(.value) | unique) as $tvals
| ([$TT[].effect] | unique
   | map(if ($tvals | length) == 1 and $tvals[0] != ""
         then {key: IK, operator: "Equal", value: $tvals[0], effect: .}
         else {key: IK, operator: "Exists", effect: .} end)) as $SUGT

# ---------------- pule MCP ----------------
| def refsinfra: ((.spec.nodeSelector.matchLabels // {}) | has(IK)) or any(.spec.nodeSelector.matchExpressions[]?; .key == IK);
  [$mcps[] | select(refsinfra)] as $ipools
| def curpool: (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "")
               | if . == "" then "?" else sub("^rendered-"; "") | sub("-[0-9a-f]+$"; "") end;
  def matchpools: . as $n | [$mcps[] | select(.spec.nodeSelector != null and (.spec.nodeSelector | selmatch($n.metadata.labels // {}))) | .metadata.name];
  .

# ---------------- MachineSety ----------------
| ($MA[0].items // []) as $machines
| ($MS[0].items // []) as $msets
| def mset:
    ((.metadata.annotations["machine.openshift.io/machine"] // "") | split("/") | .[-1]) as $m
    | if $m == "" then null
      else ([$machines[] | select(.metadata.name == $m) | .metadata.ownerReferences[]? | select(.kind == "MachineSet") | .name] | .[0]) as $s
      | if $s == null then null else ([$msets[] | select(.metadata.name == $s)] | .[0]) end
      end;
  .

# =====================================================================
# 1. nody
| ( H("1. NODY I ROLE")
  + [ INFO("Nodów w klastrze: \($nodes | length); z etykietą infra: \($infra | length); dedykowanych (infra bez worker/master): \([$infra[] | select((hasrole("worker") | not) and (ismaster | not))] | length)"),
      INFO("Nody analizowane jako infra (źródło: \($tsel.src)): \(if ($T|length) == 0 then "<brak>" else ($T | map(.metadata.name) | join(", ")) end)") ]
  + (if ($unknown | length) > 0 then [FAIL("Nody z --nodes nieistniejące w klastrze: \($unknown | join(", "))")] else [] end)
  + (if ($T | length) == 0 then [FAIL("Brak nodów do analizy - podaj je przez --nodes a,b,c albo popraw --name-pattern")] else [] end)
  + (if ($infra | length) == 0 and ($T | length) > 0 and ($a.nodes | length) == 0
     then [WARN("Żaden nod nie ma roli infra - poniższe komendy bazują na kandydatach wskazanych po nazwie; sprawdź listę!")] else [] end)
  + [ "", "  " + ("NOD" | pad(34)) + ("ROLE" | pad(22)) + ("READY" | pad(7)) + ("PULA MCP" | pad(12)) + "TAINTY (NoSchedule/NoExecute)" ]
  + [ ($T + [$infra[] | select($TS[.metadata.name] != true)] + [$cand[] | select($TS[.metadata.name] != true)])[]
      | "  " + (.metadata.name | pad(34)) + (roles | pad(22)) + ((if isready then "tak" else "NIE" end) + (if .spec.unschedulable then "/C" else "" end) | pad(7))
        + (curpool | pad(12)) + ([.spec.taints[]? | select(hard) | tstr] | if length == 0 then "<brak>" else join(" ") end)
        + (if $TS[.metadata.name] == true then "" else "   (poza analizą)" end) ]
  ) as $S1

# 2. weryfikacja nodow
| ( H("2. WERYFIKACJA INFRA NODÓW (etykieta, taint, rola, MachineSet)")
  + ([ $T[] | . as $n | plan as $pl | mset as $ms
      | ["", "  ▶ \(.metadata.name)  [role: \(roles)]"]
      + (if isready then [] else [WARN("Nod nie jest Ready")] end)
      + (if .spec.unschedulable then [WARN("Nod jest wyłączony z planowania (cordon)")] else [] end)
      + (if hasrole("infra") then [OK("Etykieta \(IK)=\"\" obecna")]
         else [FAIL("Brak etykiety \(IK)")] end)
      + (if ismaster then [WARN("Nod ma rolę master/control-plane - to nie jest dedykowany infra nod")] else [] end)
      + (if hasrole("worker") then
           (if $a.rmworker then [WARN("Nod ma też rolę worker (wymagano --remove-worker) - do usunięcia po utworzeniu puli MCP infra")]
            else [INFO("Nod ma role infra,worker - układ wspierany przez dokumentację; dedykowanie zapewnia taint")] end)
         else [OK("Brak roli worker (dedykowany infra)")] end)
      + ([.spec.taints[]? | select(.key == IK and hard)] as $it
         | if ($it | length) > 0 then [OK("Taint infra: \($it | map(tstr) | join(" "))")]
           else [FAIL("Brak taintu \(IK) NoSchedule/NoExecute - każdy pod bez selektora może tu trafić")] end)
      + (if $a.noexec and (any(.spec.taints[]?; .key == IK and .effect == "NoExecute") | not)
         then [WARN("Brak taintu NoExecute (wymagany przez --noexecute)")] else [] end)
      + ([.spec.taints[]? | select(.key != IK)] | if length > 0 then [INFO("Inne tainty: \(map(tstr) | join(" "))")] else [] end)
      + (if $ms == null then
           (if (.metadata.annotations["machine.openshift.io/machine"] // "") == "" then [INFO("Nod nie pochodzi z MachineSet (UPI/bare metal) - etykiety i tainty ustawiane na nodzie")]
            else [WARN("Nie znaleziono MachineSet dla maszyny \(.metadata.annotations["machine.openshift.io/machine"])")] end)
         else
           ($ms.spec.template.spec.metadata.labels // {}) as $ml
           | ([$TT[] | . as $t | select(any($ms.spec.template.spec.taints[]?; .key == $t.key and .effect == $t.effect) | not)]) as $mt
           | [INFO("MachineSet: \($ms.metadata.name)")]
           + (if $ml | has(IK) then [OK("MachineSet ma etykietę infra w szablonie")]
              else [WARN("MachineSet bez etykiety infra w spec.template.spec.metadata.labels - nowe maszyny nie będą infra")] end)
           + (if ($mt | length) == 0 then [OK("MachineSet ma tainty infra w szablonie")]
              else [WARN("MachineSet bez taintów w szablonie: \($mt | map(tstr) | join(" "))")] end)
         end)
    ] | add // [])
  ) as $S2

# 3. MCP
| ( H("3. MACHINECONFIGPOOL INFRA")
  + (if ($ipools | length) == 0 then
       [FAIL("Brak puli MCP z nodeSelector \(IK) - infra nody pozostają w puli worker" + (if $a.rmworker then " (usunięcie etykiety worker bez tej puli = nod bez puli!)" else "" end))]
     else [ $ipools[] | . as $p
            | (.status.conditions // []) as $c
            | [OK("Pula \(.metadata.name): nodeSelector \(.spec.nodeSelector | tojson)")]
            + (if (.spec.machineConfigSelector // {}) | selmatch({"machineconfiguration.openshift.io/role": "worker"})
               then [OK("machineConfigSelector obejmuje MachineConfig roli worker (dziedziczenie konfiguracji)")]
               else [WARN("machineConfigSelector \(.spec.machineConfigSelector | tojson) NIE obejmuje roli worker - infra nody nie dostaną konfiguracji workerów (dokumentacja: role In [worker, infra])")] end)
            + (if (.spec.machineConfigSelector // {}) | selmatch({"machineconfiguration.openshift.io/role": "infra"})
               then [] else [WARN("machineConfigSelector nie obejmuje roli infra")] end)
            + (if .spec.paused then [WARN("Pula jest wstrzymana (paused)")] else [] end)
            + (if any($c[]; .type == "Degraded" and .status == "True") then [FAIL("Pula Degraded: \([$c[] | select(.type == "Degraded") | .message] | join(" "))")]
               elif any($c[]; .type == "Updated" and .status == "True") then [OK("Pula Updated (\(.status.updatedMachineCount // 0)/\(.status.machineCount // 0))")]
               else [WARN("Pula w trakcie aktualizacji (\(.status.updatedMachineCount // 0)/\(.status.machineCount // 0))")] end)
          ] | add end)
  + (if ($ipools | length) > 1 then [WARN("Więcej niż jedna pula wybiera nody infra: \($ipools | map(.metadata.name) | join(", "))")] else [] end)
  + [ $T[] | . as $n | matchpools as $mp | curpool as $cp
      | ([$mp[] | select(. != "worker" and . != "master")]) as $custom
      | if ($custom | length) > 1 then FAIL("\(.metadata.name): pasuje do kilku pul niestandardowych (\($custom | join(", "))) - MCO tego nie obsłuży")
        elif ($mp | length) == 0 then FAIL("\(.metadata.name): nie pasuje do żadnej puli MCP (aktualna konfiguracja: \($cp)) - MCO nie będzie go aktualizować")
        elif ($ipools | length) > 0 and (any($ipools[]; .metadata.name == $cp) | not) then
             (if any($ipools[]; . as $p | any($mp[]; . == $p.metadata.name)) then WARN("\(.metadata.name): pasuje do puli infra, ale ma jeszcze konfigurację z puli \($cp) (przenoszenie w toku)")
              else FAIL("\(.metadata.name): nie jest w puli infra (aktualnie: \($cp); pasuje do: \($mp | join(", ")))") end)
        else OK("\(.metadata.name): pula \($cp)") end ]
  ) as $S3

# 4. komponenty infrastruktury
| ($WL[0].items // []) as $wl
| def podsof($ns; $name): [$pods[] | select(.metadata.namespace == $ns and ._o.name == $name)];
  def placement($ns; $name):
    podsof($ns; $name) as $ps
    | [$ps[] | select($TS[.spec.nodeName // ""] == true)] as $on
    | if ($ps | length) == 0 then "brak podów"
      else "\($on | length)/\($ps | length) podów na infra" + ([$ps[] | select($TS[.spec.nodeName // ""] != true) | .spec.nodeName // "<pending>"] | unique | if length > 0 then " (poza infra: \(join(", ")))" else "" end)
      end;
  def outside($ns; $name): [podsof($ns; $name)[] | select($TS[.spec.nodeName // ""] != true)] | length;
  def compcheck($what; $spec; $ns; $name):
    ($spec | targetsinfra) as $ti | ($spec | tolok($TT)) as $to | placement($ns; $name) as $where
    | [ if $ti and $to and outside($ns; $name) > 0 then WARN("\($what): konfiguracja OK, ale pody nadal poza infra - usuń je, by zostały przeplanowane; \($where)")
        elif $ti and $to then OK("\($what): selektor infra i tolerancje OK; \($where)")
        elif $ti then FAIL("\($what): selektor infra jest, ale brak tolerancji dla \($TT | map(tstr) | join(" ")); \($where)")
        else FAIL("\($what): brak selektora \(IK) (nodeSelector: \($spec.nodeSelector // {} | tojson)); \($where)") end ]
    + (if $ti and ($spec | targetsworker) and $a.rmworker then [WARN("\($what): selektor zawiera też \(WK) - po usunięciu etykiety worker pody się nie uruchomią")] else [] end);

  # tylko komponenty, dla ktorych cluster-monitoring-config przyjmuje nodeSelector/tolerations
  # (prometheusOperatorAdmissionWebhook ich NIE przyjmuje - webhook odrzuca cala ConfigMape)
  ({"prometheus-k8s":"prometheusK8s","alertmanager-main":"alertmanagerMain","prometheus-operator":"prometheusOperator",
    "kube-state-metrics":"kubeStateMetrics",
    "openshift-state-metrics":"openshiftStateMetrics","telemeter-client":"telemeterClient","thanos-querier":"thanosQuerier",
    "metrics-server":"metricsServer","prometheus-adapter":"k8sPrometheusAdapter","monitoring-plugin":"monitoringPlugin"}) as $monmap
| [$wl[] | select(.metadata.namespace == "openshift-monitoring" and $monmap[.metadata.name] != null)
         | {key: $monmap[.metadata.name], wl: ., ok: ((.spec.template.spec | targetsinfra) and (.spec.template.spec | tolok($TT)))}] as $mon
| ($IC[0].items // []) as $ics
| [$ics[] | . as $ic | (.spec.nodePlacement // {}) as $np
    | {name: .metadata.name, np: $np, rawnp: .spec.nodePlacement,
       ti: (((($np.nodeSelector.matchLabels // {}) | has(IK))) or any($np.nodeSelector.matchExpressions[]?; .key == IK)),
       tw: (($np.nodeSelector.matchLabels // {}) | has(WK)),
       to: ($np | tolok($TT)),
       replicas: (.spec.replicas // .status.availableReplicas // 2),
       eps: (.status.endpointPublishingStrategy.type // .spec.endpointPublishingStrategy.type // "?")}] as $icx
| ($REG[0]) as $reg
| (($reg.spec.managementState // "") | . == "Managed" or . == "") as $regman
| (($reg.spec // {}) | targetsinfra and tolok($TT)) as $regok
| ($CM[0].data["config.yaml"] // null) as $cmy
| ($PV[0].items // []) as $pvs
| [ ($PVC[0].items // [])[] | select(.status.phase == "Bound") | . as $c
    | ([$pvs[] | select(.metadata.name == $c.spec.volumeName)] | .[0]) as $pv
    | select($pv != null and $pv.spec.nodeAffinity.required != null)
    | select(any($TSIM[]; . as $n | $pv.spec.nodeAffinity.required | termsmatch($n)) | not)
    | {pvc: .metadata.name, pv: $pv.metadata.name,
       hosts: ([$pv.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?.values[]?] | unique)} ] as $pinned

| ( H("4. KOMPONENTY INFRASTRUKTURY (selektory i tolerancje)")
  + [INFO("Wymagane tolerancje (tainty infra po zmianach): \($TT | map(tstr) | join(" "))")]
  + ["", "  ▶ Ingress (openshift-ingress-operator/IngressController)"]
  + (if ($icx | length) == 0 then [WARN("Nie odczytano IngressControllerów (uprawnienia?)")]
     else [ $icx[] | . as $x
            | (if .ti and .to and outside("openshift-ingress"; "router-" + .name) > 0 then [WARN("\(.name): konfiguracja OK, ale routery nadal poza infra; \(placement("openshift-ingress"; "router-" + .name))")]
               elif .ti and .to then [OK("\(.name): nodePlacement → infra, tolerancje OK; \(placement("openshift-ingress"; "router-" + .name))")]
               elif .ti then [FAIL("\(.name): nodePlacement → infra, ale brak tolerancji \($TT | map(tstr) | join(" ")); \(placement("openshift-ingress"; "router-" + .name))")]
               else [FAIL("\(.name): brak nodePlacement.nodeSelector \(IK); \(placement("openshift-ingress"; "router-" + .name))")] end)
            + (if .tw and $a.rmworker then [WARN("\(.name): nodeSelector zawiera \(WK) - zostanie usunięty w proponowanym patchu")] else [] end)
            + (if .replicas > ($T | length) then [WARN("\(.name): replicas=\(.replicas) > liczba infra nodów (\($T | length)) - routery nie zmieszczą się (anti-affinity)")] else [] end)
            + (if .eps == "HostNetwork" or .eps == "NodePortService" then [INFO("\(.name): publikacja \(.eps) - zewnętrzny LB / VIP *.apps musi wskazywać infra nody")] else [] end)
          ] | add end)
  + ["", "  ▶ Image registry (configs.imageregistry.operator.openshift.io/cluster)"]
  + (if $reg == {} or $reg == null then [WARN("Nie odczytano konfiguracji rejestru (uprawnienia?)")]
     elif ($regman | not) then [INFO("managementState=\($reg.spec.managementState) - rejestr nie jest zarządzany, pomijam")]
     else compcheck("image-registry"; $reg.spec; "openshift-image-registry"; "image-registry") end)
  + ["", "  ▶ Monitoring (openshift-monitoring/cluster-monitoring-config)"]
  + (if $cmy == null then [INFO("ConfigMap cluster-monitoring-config nie istnieje")] else [OK("ConfigMap cluster-monitoring-config istnieje")] end)
  + (if ($mon | length) == 0 then [WARN("Nie odczytano workloadów openshift-monitoring")]
     else [ $mon[] | compcheck("\(.key) (\(.wl.kind)/\(.wl.metadata.name))"; .wl.spec.template.spec; "openshift-monitoring"; .wl.metadata.name) ] | add end)
  + [ $pinned[] | WARN("PVC \(.pvc): wolumen \(.pv) przypięty do \(.hosts | join(",")) (lokalny storage) - na infra pod zostanie w Pending (volume node affinity conflict); potrzebny storage dostępny na infra albo usunięcie PVC (UTRATA DANYCH)") ]
  + ([$wl[] | select(.metadata.namespace == "openshift-logging")] as $lg
     | if ($lg | length) == 0 then []
       else ["", "  ▶ Logging (openshift-logging) - tylko raport; konfiguracja w LokiStack spec.template.<komponent>.nodeSelector/tolerations"]
         + ([ $lg[] | compcheck("\(.kind)/\(.metadata.name)"; .spec.template.spec; "openshift-logging"; .metadata.name)
                     | map(sub("❌"; "⚠️ ")) ] | add)
       end)
  ) as $S4

# 5. scheduler i projekty
| ($SCH[0].spec.defaultNodeSelector // "") as $dns
| ($NS[0].items // []) as $nss
| [$nss[] | select(.metadata.name | allowedns | not)
          | (.metadata.annotations // {}) as $an
          | {name: .metadata.name,
             sel: $an["openshift.io/node-selector"],
             dtol: (try ($an["scheduler.alpha.kubernetes.io/defaultTolerations"] | fromjson) catch null)}] as $uns
| ( H("5. SCHEDULER I PROJEKTY")
  + (if $dns == "" then [INFO("Scheduler: brak defaultNodeSelector - nowe pody bez selektora chroni wyłącznie taint infra")]
     else ($dns | kvmap) as $m
       | if any($TSIM[]; . as $n | $m | to_entries | all(($n.metadata.labels // {})[.key] == .value))
         then [WARN("Scheduler: defaultNodeSelector \"\($dns)\" pasuje do infra nodów - pody bez własnego selektora będą kierowane na infra")]
         else [OK("Scheduler: defaultNodeSelector \"\($dns)\" nie pasuje do infra nodów")] end end)
  + [ $uns[] | select(.sel != null) | . as $u
      | if .sel == "" then INFO("Projekt \(.name): openshift.io/node-selector=\"\" (wyłączony domyślny selektor klastra)")
        elif ((.sel | kvmap) as $m | any($TSIM[]; . as $n | $m | to_entries | all(($n.metadata.labels // {})[.key] == .value)))
        then FAIL("Projekt \(.name): openshift.io/node-selector=\"\(.sel)\" kieruje pody na infra nody")
        else empty end ]
  + [ $uns[] | select(.dtol != null) | . as $u
      | select(any($TT[]; tolerates($u.dtol)))
      | WARN("Projekt \(.name): scheduler.alpha.kubernetes.io/defaultTolerations toleruje taint infra (\(.dtol | map(tolstr) | join(" ")))") ]
  ) as $S5

# 6. pody na infra
| [$pods[] | select($TS[.spec.nodeName // ""] == true)] as $onT
| [$onT[] | select(.metadata.namespace | allowedns | not)] as $foreign
| [$foreign[] | select(._o.kind != "DaemonSet")] as $viol
| [$foreign[] | select(._o.kind == "DaemonSet")] as $fds
| def grp: group_by(.metadata.namespace + "/" + ._o.kind + "/" + ._o.name)
           | map({ns: .[0].metadata.namespace, kind: .[0]._o.kind, name: .[0]._o.name, n: length,
                  nodes: (map(.spec.nodeName) | unique), pods: map(.metadata.name), tolall: any(.[]; tolall)});
  ($viol | grp) as $violg
| ($fds | grp) as $fdsg
| [$onT[] | select(._o.kind == "DaemonSet") | . as $p
          | ($TSIM[] | select(.metadata.name == $p.spec.nodeName)) as $sn
          | select(($p | blockers($sn) | length) > 0)] as $misds
| ( H("6. PODY DZIAŁAJĄCE TERAZ NA INFRA NODACH")
  + [INFO("Podów na analizowanych nodach: \($onT | length); komponentów platformy/dozwolonych: \(($onT | length) - ($foreign | length))")]
  + (if ($violg | length) == 0 then [OK("Brak aplikacji spoza komponentów infrastruktury")]
     else [FAIL("Aplikacje, które nie powinny działać na infra: \($violg | length) workloadów / \($viol | length) podów")]
        + [ $violg | head($a.max)[] | SUB("\(.ns)/\(.kind)/\(.name)  pody: \(.n)  nody: \(.nodes | join(","))\(if .tolall then "  [toleruje WSZYSTKIE tainty]" else "" end)") ]
        + (if ($violg | length) > $a.max then [SUB("... i \(($violg | length) - $a.max) kolejnych (zwiększ --max)")] else [] end) end)
  + (if ($fdsg | length) > 0 then
       [WARN("DaemonSety spoza platformy na infra (agenci?) - sprawdź, czy dozwolone w subskrypcji:")]
       + [ $fdsg | head($a.max)[] | SUB("\(.ns)/DaemonSet/\(.name)  nody: \(.nodes | join(","))") ]
     else [] end)
  + (if ($misds | length) > 0 then
       [WARN("Pody DaemonSet bez tolerancji planowanych taintów - po dodaniu taintu będą 'misscheduled' (dokumentacja: usuń je albo dodaj tolerancję):")]
       + [ $misds | map("\(.metadata.namespace)/\(._o.name)") | unique | head($a.max)[] | SUB(.) ]
     else [] end)
  + (if $a.noexec then
       ([$onT[] | select(._o.kind != "DaemonSet") | . as $p | select(any($TSIM[]; . as $sn | .metadata.name == $p.spec.nodeName and (($p | blockers($sn)) | length) > 0))]) as $ev
       | if ($ev | length) > 0 then [INFO("Taint NoExecute wyrzuci z infra \($ev | length) podów bez tolerancji (np. \($ev[0:5] | map(.metadata.namespace + "/" + .metadata.name) | join(", ")))")] else [] end
     else [] end)
  ) as $S6

# 7. potencjalne
| [$pods[] | select(($TS[.spec.nodeName // ""] != true) and (.metadata.namespace | allowedns | not))] as $others
| def couldgo($nl): [$others[] | . as $p | [$nl[] | select(. as $n | $p | canrun($n)) | .metadata.name] as $c
                     | select(($c | length) > 0) | . + {_can: $c}]
                    | group_by(.metadata.namespace + "/" + ._o.kind + "/" + ._o.name)
                    | map({ns: .[0].metadata.namespace, kind: .[0]._o.kind, name: .[0]._o.name, can: .[0]._can,
                           tolall: any(.[]; tolall), sel: (.[0].spec.nodeSelector // {})});
  couldgo($T) as $now
| couldgo($TSIM) as $after
| ( H("7. APLIKACJE, KTÓRE MOGĄ TRAFIĆ NA INFRA (symulacja: tainty, nodeSelector, nodeAffinity)")
  + (if ($now | length) == 0 then [OK("Teraz: żaden workload spoza infrastruktury nie zmieści się na infra nodach")]
     else [WARN("Teraz: \($now | length) workloadów spoza infrastruktury mogłoby zostać zaplanowanych na infra" + (if any($T[]; any(.spec.taints[]?; .key == IK and hard) | not) then " (część nodów bez taintu)" else "" end))]
        + [ $now | head($a.max)[] | SUB("\(.ns)/\(.kind)/\(.name) → \(.can | join(","))\(if .tolall then "  [toleruje wszystkie tainty]" else "" end)") ]
        + (if ($now | length) > $a.max then [SUB("... i \(($now | length) - $a.max) kolejnych")] else [] end) end)
  + (if ($after | length) == 0 then [OK("Po wprowadzeniu proponowanych zmian: żaden workload spoza infrastruktury nie trafi na infra")]
     else [FAIL("Po zmianach NADAL \($after | length) workloadów może trafić na infra (tolerują taint infra) - popraw ich tolerancje/selektory:")]
        + [ $after | head($a.max)[] | SUB("\(.ns)/\(.kind)/\(.name) → \(.can | join(","))\(if .tolall then "  [toleration operator: Exists bez klucza]" else "  [toleruje \(IK)]" end)") ] end)
  + [INFO("Dozwolone na infra (dokumentacja): control plane, router/Ingress, image registry, monitoring, logging, Quay, ODF, ACM, ACS, GitOps, Pipelines, Service Mesh; namespace'y: /\($platre)/\(if $a.allowns != "" then " + /\($a.allowns)/" else "" end)")]
  ) as $S7

# =====================================================================
# KOMENDY
| ($T | map(select(hasrole("infra") | not))) as $nolabel
| ([$T[] | . as $n | plan as $pl | select(($pl | length) > 0) | {n: .metadata.name, pl: $pl}]) as $taintplan
| ([$T[] | mset | select(. != null)] | unique_by(.metadata.name)) as $msl
| ($SUGT | tojson) as $tolj
| def yamltols($ind): [ $SUGT[] | ($ind + "- key: " + .key), ($ind + "  operator: " + .operator)
                        , (if .value then $ind + "  value: " + .value else empty end), ($ind + "  effect: " + .effect) ];
  def monblock($ind; $k): [$ind + $k + ":", $ind + "  nodeSelector:", $ind + "    " + IK + ": \"\"", $ind + "  tolerations:"] + yamltols($ind + "  ");
  def step($t; $c): if ($c | length) == 0 then [] else ["", "# ---- " + $t + " ----"] + $c end;
  ([$mon[] | select(.ok | not) | .key] | unique) as $monmiss
| [ $msl[] | . as $ms
    | ((.spec.template.spec.taints // []) + [$TT[] | . as $t | select(any($ms.spec.template.spec.taints[]?; .key == $t.key and .effect == $t.effect) | not)]) as $nt
    | select((((.spec.template.spec.metadata.labels // {}) | has(IK)) | not) or ($nt | length) > ((.spec.template.spec.taints // []) | length))
    | {ms: ., nt: $nt} ] as $mspatch
| [ $icx[] | select((.ti and .to and ((.tw and $a.rmworker) | not)) | not) ] as $icpatch
| ($regman and ($reg != {}) and ($regok | not)) as $regpatch
| (($ipools | length) == 0 and ($T | length) > 0) as $mcpcreate
| (if $a.rmworker then [ $T[] | select(hasrole("worker")) ] else [] end) as $rmw

| ( [ "#!/bin/bash",
      "# Komendy wygenerowane przez infraNodeCheck.sh - przejrzyj przed wykonaniem, wykonuj krok po kroku.",
      "# Nody infra: \($T | map(.metadata.name) | join(" "))",
      "",
      "# ---- KROK 0: kopia zmienianych obiektów (podstawa rollbacku) ----",
      "B=infra-backup-$(date +%F-%H%M); mkdir -p \"$B\"",
      "oc get nodes -o yaml > \"$B/nodes.yaml\"",
      "oc get mcp -o yaml > \"$B/mcp.yaml\"",
      "oc get machinesets.machine.openshift.io -n openshift-machine-api -o yaml > \"$B/machinesets.yaml\" 2>/dev/null",
      "oc get ingresscontroller -n openshift-ingress-operator -o yaml > \"$B/ingresscontrollers.yaml\"",
      "oc get configs.imageregistry.operator.openshift.io cluster -o yaml > \"$B/imageregistry.yaml\"",
      "oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml > \"$B/cluster-monitoring-config.yaml\" 2>/dev/null",
      "echo \"Kopia: $B\"" ]
  + step("KROK 1: etykieta roli infra"; [ $nolabel[] | "oc label node \(.metadata.name) \(IK)=\"\"" ])
  + step("KROK 2: pula MachineConfigPool infra (UWAGA: nody puli mogą zostać zrestartowane)";
      if ($mcpcreate | not) then [] else
      [ "cat <<'YAML' | oc create -f -", "apiVersion: machineconfiguration.openshift.io/v1", "kind: MachineConfigPool",
        "metadata:", "  name: infra", "spec:", "  machineConfigSelector:", "    matchExpressions:",
        "      - key: machineconfiguration.openshift.io/role", "        operator: In", "        values: [worker, infra]",
        "  nodeSelector:", "    matchLabels:", "      \(IK): \"\"", "YAML",
        "oc get machineconfig | grep rendered-infra", "oc get mcp infra -w   # czekaj na UPDATED=True" ] end)
  + step("KROK 3: MachineSety - etykieta/taint w szablonie (dotyczy tylko NOWYCH maszyn)";
      [ $mspatch[] | "oc patch machineset \(.ms.metadata.name) -n openshift-machine-api --type=merge -p " + ({spec: {template: {spec: {metadata: {labels: {(IK): ""}}, taints: .nt}}}} | tojson | @sh) ])
  + step("KROK 4a: Ingress - routery na infra";
      [ $icpatch[]
        | "oc patch ingresscontroller/\(.name) -n openshift-ingress-operator --type=merge -p "
          + ({spec: {nodePlacement: {nodeSelector: {matchLabels: ({(IK): ""} + (if .tw then {(WK): null} else {} end))}, tolerations: $SUGT}}} | tojson | @sh) ]
      + (if any($icx[]; .replicas > ($T | length)) then ["# replicas > liczba infra nodów - rozważ: oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge -p '{\"spec\":{\"replicas\":\($T | length)}}'"] else [] end))
  + step("KROK 4b: image registry na infra";
      if $regpatch
      then [ "oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p " + ({spec: {nodeSelector: {(IK): ""}, tolerations: $SUGT}} | tojson | @sh) ]
      else [] end)
  + step("KROK 4c: monitoring na infra (\($monmiss | join(", ")))";
      if ($monmiss | length) == 0 then []
      elif $cmy == null then
        [ "cat <<'YAML' | oc apply -f -", "apiVersion: v1", "kind: ConfigMap", "metadata:", "  name: cluster-monitoring-config",
          "  namespace: openshift-monitoring", "data:", "  config.yaml: |" ] + ([$monmiss[] | monblock("    "; .)] | add) + ["YAML"]
      elif any($monmiss[]; . as $k | $cmy | test("(^|\n)" + $k + "\\s*:")) then
        [ "# ConfigMap zawiera już część tych sekcji - edytuj ręcznie i dodaj do każdej nodeSelector/tolerations:",
          "oc -n openshift-monitoring edit configmap cluster-monitoring-config" ]
        + [ ([$monmiss[] | monblock("#   "; .)] | add)[] ]
      else
        [ "oc -n openshift-monitoring patch configmap cluster-monitoring-config --type=merge -p "
          + ({data: {"config.yaml": (($cmy | if . == "" or endswith("\n") then . else . + "\n" end) + ([$monmiss[] | monblock(""; .)] | add | join("\n")) + "\n")}} | tojson | @sh) ]
      end
      + (if ($monmiss | length) > 0 then ["oc get pods -n openshift-monitoring -o wide   # sprawdź, czy pody przeszły na infra"]
           + [ $pinned[] | "# UWAGA: PVC \(.pvc) przypięty do \(.hosts | join(",")) - pod nie wystartuje na infra (patrz sekcja 4)" ] else [] end))
  + step("KROK 4d: komponenty już skonfigurowane, ale ich pody działają poza infra - przeplanowanie";
      ( [ $mon[] | select(.ok) | {ns: "openshift-monitoring", name: .wl.metadata.name} ]
      + (if $regman and $regok then [{ns: "openshift-image-registry", name: "image-registry"}] else [] end)
      + [ $icx[] | select(.ti and .to) | {ns: "openshift-ingress", name: ("router-" + .name)} ] )
      | map(. as $c | [podsof($c.ns; $c.name)[] | select($TS[.spec.nodeName // ""] != true) | .metadata.name] as $all
            | [$all[] | . as $pn | select($c.ns == "openshift-monitoring" and any($pinned[]; .pvc | endswith("-" + $pn)))] as $blk
            | ($all - $blk) as $pn
            | (if ($pn | length) > 0 then "oc delete pod -n \($c.ns) \($pn | join(" "))" else empty end),
              ($blk[] | "# NIE usuwaj \($c.ns)/\(.) - jego PVC jest przypięty do noda spoza infra (Pending); najpierw rozwiąż storage (sekcja 4)")))
  + step("KROK 5: weryfikacja przed taintem (komponenty muszą już działać na infra)";
      if ($taintplan | length) > 0 then
        [ "oc get pods -n openshift-ingress -o wide", "oc get pods -n openshift-image-registry -o wide", "oc get mcp" ] else [] end)
  + step("KROK 6: tainty infra (NoSchedule nie usuwa działających podów" + (if $a.noexec then "; NoExecute USUWA pody bez tolerancji" else "" end) + ")";
      [ $taintplan[] | "oc adm taint nodes \(.n) " + (.pl | map("\(.key)=\(.value):\(.effect)") | join(" ")) + " --overwrite" ])
  + step("KROK 7: usunięcie roli worker (dopiero gdy pula infra jest Updated, a routery mają selektor infra)";
      [ $rmw[] | "oc label node \(.metadata.name) \(WK)-" ])
  + step("KROK 8: aplikacje spoza infrastruktury działające na infra (po taincie przeniosą się po restarcie poda)";
      [ $violg[] | select(.kind != "DaemonSet")
        | (if .tolall then "# \(.ns)/\(.kind)/\(.name) toleruje wszystkie tainty - usuń 'operator: Exists' bez klucza z tolerancji, inaczej wróci na infra" else empty end),
          (if .kind == "Pod" then "# \(.ns)/\(.name) - pod bez kontrolera, usunięcie jest trwałe: oc delete pod -n \(.ns) \(.name)"
           else "oc delete pod -n \(.ns) \(.pods | join(" "))" end) ]
      + [ $after[] | "# \(.ns)/\(.kind)/\(.name): po zmianach nadal toleruje taint infra - popraw tolerancje (lub dodaj nodeAffinity \(IK) DoesNotExist)" ])
  ) as $CMDS

# ---------------- ROLLBACK (odwrotna kolejnosc, wartosci sprzed zmian) ----------------
| (($infra + $nolabel) | map(.metadata.name) | unique) as $allinfra
| ( [ "#!/bin/bash",
      "# ROLLBACK wygenerowany przez infraNodeCheck.sh \($a.now) ze stanu klastra SPRZED zmian.",
      "# Wykonuj od góry, krok po kroku; cofaj tylko kroki, które faktycznie wykonano.",
      "# Jeśli konfiguracja zmieniła się po wygenerowaniu - przywracaj z kopii z KROKU 0 (katalog infra-backup-*)." ]
  + step("R7: przywrócenie roli worker (przed zmianami w puli MCP!)";
      [ $rmw[] | "oc label node \(.metadata.name) \(WK)=\"\"" ])
  + step("R6: zdjęcie dodanych taintów (natychmiastowe, bez restartu; najszybszy 'hamulec')";
      [ $taintplan[] | "oc adm taint nodes \(.n) " + (.pl | map("\(.key):\(.effect)-") | join(" ")) ]
      + (if any($taintplan[].pl[]; .effect == "NoExecute") then ["# pody wyrzucone przez NoExecute nie wrócą same na te nody"] else [] end))
  + step("R8/R4d: usunięte pody - nie do wycofania";
      if ($violg | length) > 0 or ([$CMDS[] | select(startswith("oc delete pod"))] | length) > 0
      then ["# pody z kontrolerem (Deployment/StatefulSet/...) zostały odtworzone automatycznie; pody bez kontrolera przepadły"] else [] end)
  + step("R4c: monitoring - przywrócenie cluster-monitoring-config";
      if ($monmiss | length) == 0 then []
      elif $cmy == null then
        [ "oc delete configmap cluster-monitoring-config -n openshift-monitoring   # nie istniała przed zmianą - CMO wraca do ustawień domyślnych" ]
      else
        [ "oc -n openshift-monitoring patch configmap cluster-monitoring-config --type=merge -p " + ({data: {"config.yaml": $cmy}} | tojson | @sh) ]
      end
      + (if ($monmiss | length) > 0 then ["oc get pods -n openshift-monitoring -o wide   # pody wracają na poprzednie nody (PVC lokalne - na nod z wolumenem)"] else [] end))
  + step("R4b: image registry - poprzedni nodeSelector/tolerations";
      if $regpatch then
        ($reg.spec.nodeSelector) as $o
        | [ "oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p "
            + ({spec: {nodeSelector: (if $o == null then null elif ($o | has(IK)) then $o else $o + {(IK): null} end),
                       tolerations: ($reg.spec.tolerations // null)}} | tojson | @sh) ]
      else [] end)
  + step("R4a: Ingress - poprzedni nodePlacement (routery wracają na workery)";
      [ $icpatch[]
        | if .rawnp == null then
            "oc patch ingresscontroller/\(.name) -n openshift-ingress-operator --type=merge -p " + ({spec: {nodePlacement: null}} | tojson | @sh)
          else
            (.np.nodeSelector.matchLabels) as $ml
            | "oc patch ingresscontroller/\(.name) -n openshift-ingress-operator --type=merge -p "
              + ({spec: {nodePlacement: {nodeSelector: {matchLabels: (if $ml == null then null elif ($ml | has(IK)) then $ml else $ml + {(IK): null} end)},
                                         tolerations: (.np.tolerations // null)}}} | tojson | @sh)
          end ]
      + (if ($icpatch | length) > 0 then ["# jeśli LB / VIP *.apps przestawiono na infra nody - przywróć go na workery RAZEM z tym krokiem",
                                          "oc get pods -n openshift-ingress -o wide"] else [] end)
      + [ $icx[] | select(.replicas > ($T | length)) | "# jeśli zmieniono replicas: oc patch ingresscontroller/\(.name) -n openshift-ingress-operator --type=merge -p '{\"spec\":{\"replicas\":\(.replicas)}}'" ])
  + step("R3: MachineSety - poprzednie etykiety/tainty szablonu (istniejące maszyny bez zmian)";
      [ $mspatch[] | .ms as $ms
        | "oc patch machineset \($ms.metadata.name) -n openshift-machine-api --type=merge -p "
          + ({spec: {template: {spec: {metadata: {labels: (if (($ms.spec.template.spec.metadata.labels // {}) | has(IK)) then {} else {(IK): null} end)},
                                       taints: ($ms.spec.template.spec.taints // null)}}}} | tojson | @sh) ])
  + step("R2: usunięcie puli MCP infra (UWAGA: restart nodów przy powrocie do puli worker)";
      if ($mcpcreate | not) then [] else
        [ "# 1) zdejmij etykietę infra, by nody wróciły do puli worker (usunięcie puli z nodami w środku zostawia je z nieistniejącym rendered-infra)" ]
        + [ $allinfra[] | "oc label node \(.) \(IK)-" ]
        + [ $T[] | . as $n | select((hasrole("worker") | not) and (any($rmw[]; .metadata.name == $n.metadata.name) | not))
            | "# UWAGA: \(.metadata.name) nie miał roli worker - po zdjęciu etykiety infra nie będzie w żadnej puli (jak przed zmianą); rozważ: oc label node \(.metadata.name) \(WK)=\"\"" ]
        + [ "# 2) czekaj, aż pula worker obejmie te nody i będzie UPDATED=True, a pula infra MACHINECOUNT=0",
            "oc get mcp -w",
            "# 3) usuń pulę",
            "oc delete mcp infra" ]
        + (if ($infra | length) > 0 then
             ["# 4) przywróć etykietę infra nodom, które miały ją przed zmianą (bez puli infra zostają w puli worker)"]
             + [ $infra[] | "oc label node \(.metadata.name) \(IK)=\"\"" ]
           else [] end)
      end)
  + step("R1: zdjęcie etykiety infra dodanej w KROKU 1";
      if $mcpcreate then
        (if ($nolabel | length) > 0 then ["# wykonane już w R2 (nody bez etykiety infra przed zmianą jej nie odzyskują)"] else [] end)
      else
        [ $nolabel[] | "oc label node \(.metadata.name) \(IK)-" ]
        + (if ($nolabel | length) > 0 and ($ipools | length) > 0 then ["# nody opuszczą pulę \($ipools | map(.metadata.name) | join(",")) i wrócą do worker - możliwy restart"] else [] end)
      end)
  ) as $RB

| ($S1 + $S2 + $S3 + $S4 + $S5 + $S6 + $S7) as $R
| ([$CMDS[] | select(startswith("# ---- KROK") and (startswith("# ---- KROK 0") | not))] | length) as $nsteps
| {r: $R, n: $nsteps,
   c: (if $nsteps > 0 then $CMDS else [] end),
   rb: (if $nsteps > 0 then $RB else [] end),
   f: ([$R[] | select(test("^ *❌"))] | length),
   w: ([$R[] | select(test("^ *⚠️"))] | length)}
EOF

jq -n \
  --slurpfile A "$TMP/args.json" --slurpfile N "$TMP/nodes.json" --slurpfile MCP "$TMP/mcp.json" \
  --slurpfile P "$TMP/pods.json" --slurpfile SCH "$TMP/sched.json" --slurpfile NS "$TMP/ns.json" \
  --slurpfile IC "$TMP/ic.json" --slurpfile REG "$TMP/reg.json" --slurpfile CM "$TMP/cm.json" \
  --slurpfile WL "$TMP/wl.json" --slurpfile MA "$TMP/ma.json" --slurpfile MS "$TMP/ms.json" \
  --slurpfile PVC "$TMP/pvc.json" --slurpfile PV "$TMP/pv.json" \
  "$JQPROG" >"$TMP/out.json" || { echo "🚨 Błąd przetwarzania danych (jq)." >&2; exit 3; }

jq -r '.r[]' "$TMP/out.json"

FAILS=$(jq '.f' "$TMP/out.json")
WARNS=$(jq '.w' "$TMP/out.json")
NSTEPS=$(jq '.n' "$TMP/out.json")

echo
echo "════════ PODSUMOWANIE ════════"
echo "  Błędy: $FAILS   Ostrzeżenia: $WARNS   Proponowanych kroków zmian: $NSTEPS"
echo
echo "════════ PROPONOWANE KOMENDY (skrypt niczego nie zmienia) ════════"
if [ "$NSTEPS" -eq 0 ]; then
  echo "  Brak - konfiguracja zgodna."
else
  jq -r '.c[]' "$TMP/out.json"
  if [ -n "$EMIT" ]; then
    jq -r '.c[]' "$TMP/out.json" >"$EMIT" && echo && echo "💾 Komendy zapisane do: $EMIT (nie zostały wykonane)"
  fi
  echo
  echo "════════ ROLLBACK - KOMENDY WYCOFANIA (skrypt niczego nie zmienia) ════════"
  jq -r '.rb[]' "$TMP/out.json"
  if [ -n "$EMIT_RB" ]; then
    jq -r '.rb[]' "$TMP/out.json" >"$EMIT_RB" && echo && echo "💾 Rollback zapisany do: $EMIT_RB (nie został wykonany)"
  fi
fi

if   [ "$FAILS" -gt 0 ]; then exit 2
elif [ "$WARNS" -gt 0 ]; then exit 1
else exit 0; fi
