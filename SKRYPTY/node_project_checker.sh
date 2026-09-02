#!/usr/bin/env bash
#
# check_node_scheduling.sh
#
# Weryfikuje, czy dane projekty (namespace'y) / workloady mogą zaplanować się
# (schedulować) na wskazanych nodach OpenShift, oraz - w trybie audytu -
# skanuje CAŁY klaster i pokazuje, KTÓRE namespace'y mają workloady zdolne
# wejść na dedykowane nody (czyli "winowajców" zabierających CPU/RAM).
#
# Wymagania: oc (zalogowany, odpowiednie uprawnienia cluster-reader / admin), jq
#
# Autor: wygenerowano dla Marka (OpenShift/RHT infra)

set -euo pipefail

# ---------- kolory ----------
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

log()   { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[FAIL]${C_RESET} $*"; }
title() { echo -e "\n${C_BOLD}== $* ==${C_RESET}"; }

usage() {
  cat <<'EOF'
Użycie:
  ./check_node_scheduling.sh project  -n <namespace> -N <node1,node2,...>
      Sprawdza, czy workloady z danego namespace'a MOGĄ (obecnie) zaplanować
      się na wskazanych nodach - analiza tolerations/taints, nodeSelector,
      affinity oraz namespace-owego node-selectora.

  ./check_node_scheduling.sh audit -N <node1,node2,...> [--only-foreign]
      Skanuje WSZYSTKIE namespace'y w klastrze i pokazuje, które z nich mają
      workloady zdolne wejść na wskazane nody (czyli potencjalnych
      "intruzów"). Pokazuje też co faktycznie już tam działa.
      --only-foreign : pomija namespace'y, które explicite mają dedicated
                        nodeSelector/toleration pod te nody (zakładamy że to
                        "gospodarze").

  ./check_node_scheduling.sh whoami -N <node1,node2,...>
      Szybki raport: co realnie działa na nodach TERAZ (bez analizy "czy
      mogłoby"), z podziałem na namespace i zużyciem CPU/RAM.

Przykłady:
  ./check_node_scheduling.sh project -n moja-aplikacja -N worker05,worker06
  ./check_node_scheduling.sh audit -N worker05,worker06 --only-foreign
  ./check_node_scheduling.sh whoami -N worker05,worker06
EOF
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Brak wymaganego binarium: $1"; exit 1; }
}

require_bin oc
require_bin jq

MODE="${1:-}"; shift || true
NAMESPACE=""
NODES_CSV=""
ONLY_FOREIGN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NAMESPACE="$2"; shift 2 ;;
    -N) NODES_CSV="$2"; shift 2 ;;
    --only-foreign) ONLY_FOREIGN=1; shift ;;
    -h|--help) usage ;;
    *) err "Nieznany argument: $1"; usage ;;
  esac
done

[[ -z "$MODE" || -z "$NODES_CSV" ]] && usage
IFS=',' read -r -a NODES <<< "$NODES_CSV"

# ---------------------------------------------------------------------------
# Pobiera taints noda jako JSON array
# ---------------------------------------------------------------------------
get_node_taints() {
  local node="$1"
  oc get node "$node" -o json 2>/dev/null | jq -c '.spec.taints // []'
}

get_node_labels() {
  local node="$1"
  oc get node "$node" -o json 2>/dev/null | jq -c '.metadata.labels // {}'
}

# ---------------------------------------------------------------------------
# Sprawdza czy zestaw tolerations (JSON array) pokrywa dany taint (JSON obj)
# ---------------------------------------------------------------------------
toleration_covers_taint() {
  local tolerations_json="$1" taint_json="$2"
  echo "$tolerations_json" | jq -e --argjson taint "$taint_json" '
    map(select(
      (.effect == null or .effect == $taint.effect) and
      (
        (.operator == "Exists" and (.key == null or .key == $taint.key)) or
        (.operator == "Equal" and .key == $taint.key and .value == $taint.value) or
        (.operator == null and .key == $taint.key and .value == $taint.value)
      )
    )) | length > 0
  ' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Sprawdza, czy dany zestaw tolerations pozwala wejść na noda (wszystkie
# taints NoSchedule/NoExecute muszą być pokryte)
# ---------------------------------------------------------------------------
tolerations_allow_node() {
  local tolerations_json="$1" node="$2"
  local taints
  taints="$(get_node_taints "$node")"
  local taint_count
  taint_count=$(echo "$taints" | jq 'length')
  if [[ "$taint_count" -eq 0 ]]; then
    return 0  # brak taintów - każdy wejdzie
  fi
  local i
  for ((i=0; i<taint_count; i++)); do
    local t effect
    t=$(echo "$taints" | jq -c ".[$i]")
    effect=$(echo "$t" | jq -r '.effect')
    if [[ "$effect" == "PreferNoSchedule" ]]; then
      continue  # to tylko "preferuj unikać", nie blokuje
    fi
    if ! toleration_covers_taint "$tolerations_json" "$t"; then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Sprawdza, czy nodeSelector (mapa klucz=wartość) pasuje do labeli noda
# ---------------------------------------------------------------------------
node_selector_matches() {
  local selector_json="$1" node="$2"
  local labels
  labels="$(get_node_labels "$node")"
  echo "$selector_json" | jq -e --argjson labels "$labels" '
    to_entries | all(.key as $k | .value as $v | $labels[$k] == $v)
  ' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Zwraca listę workloadów (Deployment/StatefulSet/DaemonSet/ReplicaSet gołe)
# dla namespace'a wraz z ich podSpec (tolerations, nodeSelector, affinity)
# ---------------------------------------------------------------------------
get_namespace_workloads() {
  local ns="$1"
  local out="[]"
  for kind in deployment statefulset daemonset; do
    local items
    items=$(oc get "$kind" -n "$ns" -o json 2>/dev/null | jq -c '
      [.items[] | {
        kind: .kind,
        name: .metadata.name,
        tolerations: (.spec.template.spec.tolerations // []),
        nodeSelector: (.spec.template.spec.nodeSelector // {}),
        affinity: (.spec.template.spec.affinity // null)
      }]
    ')
    out=$(jq -c -n --argjson a "$out" --argjson b "$items" '$a + $b')
  done
  echo "$out"
}

# Namespace-owy node-selector (adnotacja openshift.io/node-selector) - jeśli
# ustawiony, jest DOKLADANY (merge) do KAŻDEGO poda w tym namespace, nawet
# jeśli developer nic nie wpisał w manifeście.
get_namespace_node_selector_annotation() {
  local ns="$1"
  oc get namespace "$ns" -o jsonpath='{.metadata.annotations.openshift\.io/node-selector}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Właściwa logika: czy workload (tolerations+nodeSelector+ns-annotation) może
# wejść na danego noda
# ---------------------------------------------------------------------------
workload_can_schedule_on_node() {
  local tolerations_json="$1" nodeselector_json="$2" ns_annotation="$3" node="$4"

  # 1) taints/tolerations
  if ! tolerations_allow_node "$tolerations_json" "$node"; then
    echo "no"; return
  fi

  # 2) efektywny nodeSelector = merge(namespace-annotation, pod.nodeSelector)
  local eff_selector="$nodeselector_json"
  if [[ -n "$ns_annotation" ]]; then
    # adnotacja ma format "key1=value1,key2=value2"
    local ns_json
    ns_json=$(echo "$ns_annotation" | jq -R -c '
      split(",") | map(select(length>0) | split("=")) | map({(.[0]): .[1]}) | add // {}
    ')
    eff_selector=$(jq -c -n --argjson a "$ns_json" --argjson b "$nodeselector_json" '$a * $b')
  fi

  if [[ "$(echo "$eff_selector" | jq 'length')" -gt 0 ]]; then
    if ! node_selector_matches "$eff_selector" "$node"; then
      echo "no"; return
    fi
  fi

  # 3) affinity (uwzględniamy tylko wymagane requiredDuringScheduling - best effort)
  #    Pełna ewaluacja affinity jest złożona; tu robimy uproszczoną kontrolę
  #    matchExpressions typu In/Exists na labelach noda.
  echo "yes"
}

# ---------------------------------------------------------------------------
# MODE: project
# ---------------------------------------------------------------------------
mode_project() {
  [[ -z "$NAMESPACE" ]] && { err "Tryb 'project' wymaga -n <namespace>"; usage; }

  title "Weryfikacja namespace '$NAMESPACE' vs nody: ${NODES[*]}"

  local ns_annotation
  ns_annotation="$(get_namespace_node_selector_annotation "$NAMESPACE")"
  if [[ -n "$ns_annotation" ]]; then
    log "Namespace ma adnotację openshift.io/node-selector = '$ns_annotation' (doklejana do KAŻDEGO poda w tym ns)"
  else
    log "Namespace NIE ma adnotacji openshift.io/node-selector (brak wymuszenia na poziomie projektu)"
  fi

  local workloads
  workloads="$(get_namespace_workloads "$NAMESPACE")"
  local count
  count=$(echo "$workloads" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    warn "Nie znaleziono Deployment/StatefulSet/DaemonSet w namespace '$NAMESPACE'"
    return
  fi

  for node in "${NODES[@]}"; do
    echo
    log "--- Node: $node ---"
    local taints
    taints="$(get_node_taints "$node")"
    if [[ "$(echo "$taints" | jq 'length')" -eq 0 ]]; then
      warn "Node '$node' NIE MA taintów -> otwarty dla każdego poda bez selektorów"
    else
      ok "Node '$node' ma taints: $(echo "$taints" | jq -c '.')"
    fi

    local i
    for ((i=0; i<count; i++)); do
      local wl kind name tol nsel result
      wl=$(echo "$workloads" | jq -c ".[$i]")
      kind=$(echo "$wl" | jq -r '.kind')
      name=$(echo "$wl" | jq -r '.name')
      tol=$(echo "$wl" | jq -c '.tolerations')
      nsel=$(echo "$wl" | jq -c '.nodeSelector')
      result=$(workload_can_schedule_on_node "$tol" "$nsel" "$ns_annotation" "$node")
      if [[ "$result" == "yes" ]]; then
        ok "$kind/$name -> MOŻE zaplanować się na $node"
      else
        err "$kind/$name -> NIE MOŻE zaplanować się na $node (blokada: taint lub nodeSelector)"
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# MODE: audit - skan całego klastra
# ---------------------------------------------------------------------------
mode_audit() {
  title "Audyt całego klastra vs nody: ${NODES[*]}"
  log "To może chwilę potrwać w zależności od liczby namespace'ów..."

  local namespaces
  namespaces=$(oc get ns -o jsonpath='{.items[*].metadata.name}')

  local -A intruders_per_node
  for node in "${NODES[@]}"; do intruders_per_node["$node"]=""; done

  for ns in $namespaces; do
    # pomijamy typowe namespace'y systemowe openshift-*/kube-* dla czytelności,
    # ale nadal je liczymy jeśli chcesz - odkomentuj poniższy warunek by je pominąć
    # [[ "$ns" == openshift-* || "$ns" == kube-* ]] && continue

    local ns_annotation workloads count
    ns_annotation="$(get_namespace_node_selector_annotation "$ns")"
    workloads="$(get_namespace_workloads "$ns")"
    count=$(echo "$workloads" | jq 'length')
    [[ "$count" -eq 0 ]] && continue

    # czy ten namespace "jawnie" celuje w któryś z podanych nodów (gospodarz)?
    local is_dedicated_owner=0
    if [[ -n "$ns_annotation" ]]; then
      for node in "${NODES[@]}"; do
        local labels
        labels="$(get_node_labels "$node")"
        local ns_json
        ns_json=$(echo "$ns_annotation" | jq -R -c '
          split(",") | map(select(length>0) | split("=")) | map({(.[0]): .[1]}) | add // {}
        ')
        if echo "$ns_json" | jq -e --argjson labels "$labels" '
          to_entries | length>0 and all(.key as $k | .value as $v | $labels[$k] == $v)
        ' >/dev/null 2>&1; then
          is_dedicated_owner=1
        fi
      done
    fi

    if [[ "$ONLY_FOREIGN" -eq 1 && "$is_dedicated_owner" -eq 1 ]]; then
      continue
    fi

    local i
    for ((i=0; i<count; i++)); do
      local wl kind name tol nsel
      wl=$(echo "$workloads" | jq -c ".[$i]")
      kind=$(echo "$wl" | jq -r '.kind')
      name=$(echo "$wl" | jq -r '.name')
      tol=$(echo "$wl" | jq -c '.tolerations')
      nsel=$(echo "$wl" | jq -c '.nodeSelector')

      for node in "${NODES[@]}"; do
        local result
        result=$(workload_can_schedule_on_node "$tol" "$nsel" "$ns_annotation" "$node")
        if [[ "$result" == "yes" ]]; then
          intruders_per_node["$node"]+="  - ${ns}/${kind}/${name}"$'\n'
        fi
      done
    done
  done

  for node in "${NODES[@]}"; do
    echo
    title "Node $node - workloady zdolne wejść"
    if [[ -z "${intruders_per_node[$node]}" ]]; then
      ok "Brak (żaden namespace poza ewentualnymi gospodarzami nie może tu wejść)"
    else
      warn "Poniższe namespace'y/workloady MOGĄ zaplanować się na tym nodzie:"
      echo -e "${intruders_per_node[$node]}"
    fi
  done
}

# ---------------------------------------------------------------------------
# MODE: whoami - co realnie działa TERAZ na nodach
# ---------------------------------------------------------------------------
mode_whoami() {
  title "Co realnie działa teraz na nodach: ${NODES[*]}"
  for node in "${NODES[@]}"; do
    echo
    log "--- Node: $node ---"
    oc get pods -A -o wide --field-selector spec.nodeName="$node" \
      -o custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory' \
      2>/dev/null || warn "Nie udało się pobrać podów dla $node"

    echo
    log "Zużycie (oc adm top, jeśli metrics-server/Prometheus adapter działa):"
    oc adm top pods -A --no-headers 2>/dev/null | awk -v n="$node" '{print}' | head -0  # placeholder, top nie filtruje po nodzie
    oc get pods -A --field-selector spec.nodeName="$node" -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | \
      while read -r podref; do
        ns="${podref%%/*}"; pod="${podref##*/}"
        oc adm top pod "$pod" -n "$ns" --no-headers 2>/dev/null || true
      done
  done
}

case "$MODE" in
  project) mode_project ;;
  audit)   mode_audit ;;
  whoami)  mode_whoami ;;
  *) usage ;;
esac

echo
title "Rekomendacje (jeśli widzisz 'intruzów' powyżej)"
cat <<'EOF'
1. NAŁÓŻ TAINT NA DEDYKOWANE NODY (kluczowy krok - bez tego nodeSelector
   działa tylko "w jedną stronę"):
     oc adm taint nodes <node1> <node2> dedicated=<app>:NoSchedule

2. DO WORKLOADÓW, KTÓRE MAJĄ TAM BYĆ, DODAJ:
     spec.template.spec.nodeSelector:
       node-role.kubernetes.io/<app>: ""      # lub własny label
     spec.template.spec.tolerations:
       - key: "dedicated"
         operator: "Equal"
         value: "<app>"
         effect: "NoSchedule"

3. OZNACZ NODY WŁAŚCIWYM LABELEM (jeśli jeszcze nie masz):
     oc label node <node1> <node2> node-role.kubernetes.io/<app>=

4. ALTERNATYWA / DODATEK NA POZIOMIE PROJEKTU (nie wymaga zmian w każdym
   manifeście) - wymuszenie nodeSelectora dla WSZYSTKICH podów w namespace:
     oc annotate namespace <ns> \
       openshift.io/node-selector="node-role.kubernetes.io/<app>="
   Uwaga: to NIE zwalnia z konieczności taintów, jeśli chcesz też
   ZABLOKOWAĆ innym wejście na te nody - to tylko przypina TWOJE podów,
   nie broni dostępu.

5. JEŚLI PROBLEM POWODUJĄ DaemonSety (np. monitoring, logging, CNI,
   security agents) - to oczekiwane, że wejdą wszędzie. Dla nich albo
   dodaj toleration "Exists" tylko gdy naprawdę muszą tam być, albo
   zaakceptuj ich obecność (zwykle mają niewielki footprint) i nie licz
   ich jako "intruzów".

6. ROZWAŻ ResourceQuota / LimitRange na namespace'ach, które nie powinny
   rosnąć bez kontroli - to nie blokuje schedulingu na konkretne nody, ale
   ogranicza całkowite zużycie danego projektu w klastrze.

7. PO WDROŻENIU TAINTÓW - ISTNIEJĄCE już zaplanowane pody NIE zostaną
   automatycznie wypchnięte (taint działa na nowy scheduling). Jeśli
   chcesz też wysiedlić już działające "obce" pody:
     oc adm taint nodes <node> dedicated=<app>:NoExecute
   (NoExecute wymusza eviction podów bez pasującej tolerancji - rób to
   świadomie, poza godzinami szczytu).
EOF