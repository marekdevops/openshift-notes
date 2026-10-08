#!/usr/bin/env bash
# =============================================================================
#  ocp-mcp-diag.sh — diagnostyka MachineConfigPool / Machine Config Operatora
#                    (TYLKO ODCZYT)
#
#  Użycie:
#     ./ocp-mcp-diag.sh [pula]
#
#  Przykłady:
#     ./ocp-mcp-diag.sh               # wszystkie pule
#     ./ocp-mcp-diag.sh worker        # tylko pula worker
#     ANONYMIZE=1 ./ocp-mcp-diag.sh   # wynik z zamaskowanymi nazwami nodów/domeny
#
#  Zmienne środowiskowe (opcjonalne):
#     STUCK_MIN=60      po ilu minutach w stanie Updating bez postępu pula jest
#                       uznawana za potencjalnie zablokowaną
#     REBOOT_MIN=20     po ilu minutach NotReady w trakcie aktualizacji node
#                       jest uznawany za „nie wrócił po reboocie”
#     LOG_SINCE=2h      okno logów machine-config-controller / daemon
#     SKIP_ALERTS=1     pomiń odpytywanie Prometheusa o alerty MCO
#     ANONYMIZE=1       zamaskuj w wyniku nazwy nodów, domenę klastra, użytkownika
#
#  Skrypt niczego nie zmienia w klastrze: wyłącznie `oc get`, `oc logs`
#  oraz `oc exec` do prometheus-k8s-0 (odczyt alertów). Wymaga jq.
#  Pliki tymczasowe tworzy lokalnie i usuwa po zakończeniu.
# =============================================================================
set -o pipefail

POOL_FILTER=${1:-}
STUCK_MIN=${STUCK_MIN:-60}
REBOOT_MIN=${REBOOT_MIN:-20}
LOG_SINCE=${LOG_SINCE:-2h}
SKIP_ALERTS=${SKIP_ALERTS:-0}
ANONYMIZE=${ANONYMIZE:-0}
NS_MCO=openshift-machine-config-operator

if [[ -t 1 ]]; then
  R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[34m'; C=$'\e[36m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=''; Y=''; G=''; B=''; C=''; BOLD=''; N=''
fi

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

declare -a F_CRIT=() F_WARN=() F_INFO=() ACTIONS=()
crit() { F_CRIT+=("$*"); printf '  %s[CRIT]%s %s\n' "$R" "$N" "$*"; }
warn() { F_WARN+=("$*"); printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; }
info() { F_INFO+=("$*"); printf '  %s[INFO]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$*"; }
line() { printf '         %s\n' "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$BOLD$B" "$*" "$N"; }
act()  { ACTIONS+=("$*"); }
die()  { printf '%sBŁĄD:%s %s\n' "$R" "$N" "$*" >&2; exit 2; }

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

NOW=$(date +%s)
age_min() {   # ISO8601 -> minuty od teraz
  local t
  [[ -z ${1:-} ]] && { echo -1; return; }
  t=$(date -d "$1" +%s 2>/dev/null) || { echo -1; return; }
  echo $(( (NOW - t) / 60 ))
}
fmt_age() {   # minuty -> "2 h 15 min"
  local m=${1:--1}
  (( m < 0 )) && { echo "?"; return; }
  if (( m >= 1440 )); then echo "$((m / 1440)) d $(( (m % 1440) / 60 )) h"
  elif (( m >= 60 )); then echo "$((m / 60)) h $((m % 60)) min"
  else echo "$m min"; fi
}
pool_of() { sed -E 's/^rendered-//; s/-[0-9a-f]+$//' <<<"${1:-}"; }

# --------------------------------------------------------------- znaczenie plików
hint_for_path() {
  case $1 in
    /etc/kubernetes/kubelet.conf)               echo "KubeletConfig (rezerwacje, maxPods, eviction…)";;
    /etc/node-sizing*)                          echo "KubeletConfig autoSizingReserved";;
    /etc/kubernetes/kubelet-ca.crt)             echo "rotacja CA kubeleta (automatyczna)";;
    /etc/kubernetes/static-pod-resources/*)     echo "zasoby static podów / certyfikaty";;
    /etc/crio/*|/etc/containers/storage.conf)   echo "ContainerRuntimeConfig";;
    /etc/containers/registries.conf*)           echo "ImageDigestMirrorSet / ImageTagMirrorSet / image.config";;
    /etc/containers/policy.json)                echo "image.config (dozwolone/zablokowane rejestry)";;
    /etc/pki/ca-trust/*)                        echo "zaufane CA (proxy / additionalTrustedCA)";;
    /etc/chrony.conf)                           echo "konfiguracja NTP (chrony)";;
    /etc/mco/proxy.env)                         echo "proxy klastra";;
    /etc/sysctl.d/*)                            echo "sysctl (MachineConfig / Tuned)";;
    /etc/NetworkManager/*)                      echo "konfiguracja sieci NetworkManager";;
    /etc/systemd/system/*)                      echo "jednostka systemd";;
    *)                                          echo "";;
  esac
}

# =============================================================================
main() {
  [[ $POOL_FILTER == -h || $POOL_FILTER == --help ]] && usage
  command -v oc >/dev/null 2>&1 || die "brak polecenia oc w PATH"
  command -v jq >/dev/null 2>&1 || die "brak jq w PATH (wymagane)"
  oc whoami >/dev/null 2>&1     || die "brak zalogowania do klastra (oc login)"

  printf '%sDiagnostyka MachineConfigPool%s%s\n' "$BOLD" "$N" "${POOL_FILTER:+ (pula: $POOL_FILTER)}"
  printf 'Klaster: %s   użytkownik: %s   %s\n' "$(oc whoami --show-server 2>/dev/null)" "$(oc whoami 2>/dev/null)" "$(date '+%F %T')"
  printf '\nZbieranie danych...\n'

  oc get mcp -o json  >"$TMP/mcp.json"   2>/dev/null || die "nie udało się pobrać MachineConfigPool"
  oc get nodes -o json >"$TMP/nodes.json" 2>/dev/null || die "nie udało się pobrać nodów"
  oc get pdb -A -o json >"$TMP/pdb.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/pdb.json"
  oc get clusterversion version -o json >"$TMP/cv.json" 2>/dev/null || echo '{}' >"$TMP/cv.json"
  oc get co machine-config -o json >"$TMP/co.json" 2>/dev/null || echo '{}' >"$TMP/co.json"

  if [[ -n $POOL_FILTER ]] && ! jq -e --arg p "$POOL_FILTER" '.items[] | select(.metadata.name==$p)' "$TMP/mcp.json" >/dev/null; then
    die "pula $POOL_FILTER nie istnieje"
  fi

  # Nody: nazwa|pula|current|desired|state|reason|ready|readyLTT|unsched|desiredDrain|lastAppliedDrain
  jq -r '
    .items[] |
    (.metadata.annotations // {}) as $a |
    ([.status.conditions[]? | select(.type=="Ready")][0]) as $r |
    [ .metadata.name,
      (($a["machineconfiguration.openshift.io/desiredConfig"] // "") | sub("^rendered-";"") | sub("-[0-9a-f]+$";"")),
      ($a["machineconfiguration.openshift.io/currentConfig"] // ""),
      ($a["machineconfiguration.openshift.io/desiredConfig"] // ""),
      ($a["machineconfiguration.openshift.io/state"] // ""),
      (($a["machineconfiguration.openshift.io/reason"] // "") | gsub("[\n|]";" ")),
      ($r.status // "Unknown"),
      ($r.lastTransitionTime // ""),
      (.spec.unschedulable // false | tostring),
      ($a["machineconfiguration.openshift.io/desiredDrain"] // ""),
      ($a["machineconfiguration.openshift.io/lastAppliedDrain"] // "")
    ] | join("|")' "$TMP/nodes.json" >"$TMP/nodes.txt"

  # ================================================ 0. KONTEKST KLASTRA
  hdr "0. Kontekst klastra"
  local cv_ver cv_des cv_prog cv_prog_msg
  cv_ver=$(jq -r '[.status.history[]? | select(.state=="Completed")][0].version // "?"' "$TMP/cv.json")
  cv_des=$(jq -r '.status.desired.version // "?"' "$TMP/cv.json")
  cv_prog=$(jq -r '[.status.conditions[]? | select(.type=="Progressing")][0].status // "?"' "$TMP/cv.json")
  cv_prog_msg=$(jq -r '[.status.conditions[]? | select(.type=="Progressing")][0].message // ""' "$TMP/cv.json")
  line "Wersja klastra: $cv_ver   docelowa: $cv_des   Progressing=$cv_prog"
  UPGRADE=0
  if [[ $cv_prog == True ]]; then
    UPGRADE=1
    info "Trwa aktualizacja klastra ($cv_ver → $cv_des): ${cv_prog_msg:0:140}"
    line "Aktualizacja pul MCP jest wtedy normalnym, końcowym etapem upgrade'u."
  else
    ok "Klaster nie jest w trakcie upgrade'u"
  fi

  local co_av co_pr co_dg co_msg
  co_av=$(jq -r '[.status.conditions[]? | select(.type=="Available")][0].status // "?"' "$TMP/co.json")
  co_pr=$(jq -r '[.status.conditions[]? | select(.type=="Progressing")][0].status // "?"' "$TMP/co.json")
  co_dg=$(jq -r '[.status.conditions[]? | select(.type=="Degraded")][0].status // "?"' "$TMP/co.json")
  co_msg=$(jq -r '[.status.conditions[]? | select(.type=="Degraded" or .type=="Available")][] | select(.message!=null) | .message' "$TMP/co.json" | head -1)
  line "ClusterOperator machine-config: Available=$co_av Progressing=$co_pr Degraded=$co_dg"
  if [[ $co_dg == True ]]; then crit "Operator machine-config Degraded: ${co_msg:0:200}"
  elif [[ $co_av != True ]]; then warn "Operator machine-config nie jest Available: ${co_msg:0:200}"
  else ok "Operator machine-config zdrowy"; fi

  # ================================================ 1. PRZEGLĄD PUL
  hdr "1. Przegląd pul"
  jq -r '
    .items[] |
    def c(t): ([.status.conditions[]? | select(.type==t)][0]);
    [ .metadata.name,
      (.spec.paused // false | tostring),
      (.status.machineCount // 0), (.status.updatedMachineCount // 0),
      (.status.readyMachineCount // 0), (.status.unavailableMachineCount // 0),
      (.status.degradedMachineCount // 0),
      (.spec.maxUnavailable // 1 | tostring),
      (c("Updated").status // "?"), (c("Updating").status // "?"), (c("Degraded").status // "?"),
      (c("Updating").lastTransitionTime // ""),
      (.spec.configuration.name // ""), (.status.configuration.name // ""),
      (([.status.conditions[]? | select((.type=="NodeDegraded" or .type=="RenderDegraded" or .type=="Degraded") and .status=="True") | .message] | join(" / ")) | gsub("[\n|]";" "))
    ] | map(tostring) | join("|")' "$TMP/mcp.json" >"$TMP/pools.txt"

  printf '  %s%-16s %-7s %-6s %-8s %-6s %-7s %-7s %-6s %-12s%s\n' "$BOLD" "PULA" "PAUSED" "NODY" "UPDATED" "READY" "UNAVAIL" "DEGRAD" "MAXU" "STAN" "$N"
  while IFS='|' read -r name paused mc umc rmc uamc dmc maxu upd updating deg _rest; do
    [[ -n $POOL_FILTER && $name != "$POOL_FILTER" ]] && continue
    local st=Updated
    [[ $updating == True ]] && st=Updating
    [[ $deg == True ]] && st=Degraded
    [[ $paused == true && $st != Updated ]] && st="$st+Paused"
    [[ $paused == true && $st == Updated ]] && st="Paused"
    printf '  %-16s %-7s %-6s %-8s %-6s %-7s %-7s %-6s %-12s\n' "$name" "$paused" "$mc" "$umc" "$rmc" "$uamc" "$dmc" "$maxu" "$st"
  done <"$TMP/pools.txt"

  # Nody poza pulami
  local orphans
  orphans=$(awk -F'|' '$4==""{print $1}' "$TMP/nodes.txt")
  if [[ -n $orphans && -z $POOL_FILTER ]]; then
    warn "Nody bez przypisanej konfiguracji MCO: $(tr '\n' ' ' <<<"$orphans")"
  fi

  # ================================================ 2. ANALIZA KAŻDEJ PULI
  local idx=2
  while IFS='|' read -r name paused mc umc rmc uamc dmc maxu upd updating deg upd_ltt spec_cfg stat_cfg deg_msg; do
    [[ -n $POOL_FILTER && $name != "$POOL_FILTER" ]] && continue
    (( mc == 0 )) && { hdr "$idx. Pula $name"; line "Pula bez nodów — pomijam"; idx=$((idx+1)); continue; }
    hdr "$idx. Pula $name"; idx=$((idx+1))

    line "Konfiguracja docelowa (spec):   $spec_cfg"
    line "Konfiguracja wg statusu puli:   $stat_cfg"

    # Rozkład nodów
    local -a n_done=() n_prog=() n_wait=() n_deg=() n_cordon=()
    local cur_counts
    while IFS='|' read -r nn np ncur ndes nst nreason nready nready_ltt nuns ndd nlad; do
      [[ $np == "$name" ]] || continue
      if [[ $nst == Degraded || $nst == Unreconcilable ]]; then n_deg+=("$nn")
      elif [[ $ndes != "$spec_cfg" ]]; then n_wait+=("$nn")
      elif [[ $ncur == "$ndes" && $nst == Done ]]; then n_done+=("$nn")
      else n_prog+=("$nn"); fi
      [[ $nuns == true ]] && n_cordon+=("$nn")
    done <"$TMP/nodes.txt"
    cur_counts=$(awk -F'|' -v p="$name" '$2==p{c[$3]++} END{for(k in c) printf "%s=%d  ", k, c[k]}' "$TMP/nodes.txt")
    line "Nody na konfiguracji (current): $cur_counts"
    line "Zaktualizowane: ${#n_done[@]}   w trakcie: ${#n_prog[@]}   czekające: ${#n_wait[@]}   degraded: ${#n_deg[@]}   (razem $mc)"

    # --- Degraded
    if [[ $deg == True ]]; then
      crit "Pula $name jest Degraded: ${deg_msg:0:220}"
      act "Pula $name Degraded — przeczytaj powód poniżej (sekcja nodów) i usuń przyczynę; rollout nie ruszy dalej, dopóki node jest Degraded."
    fi

    # --- Paused
    local pending=0
    [[ ${#n_wait[@]} -gt 0 || ${#n_prog[@]} -gt 0 || $spec_cfg != "$stat_cfg" ]] && pending=1
    if [[ $paused == true ]]; then
      if (( pending )); then
        warn "Pula $name jest ZAPAUZOWANA i ma oczekujące zmiany ($spec_cfg) — nic się nie zaktualizuje do odpauzowania"
        act "Pula $name: zmiany czekają na odpauzowanie — zaplanuj okno i odpauzuj świadomie (oc patch mcp $name --type merge -p '{\"spec\":{\"paused\":false}}')."
      else
        info "Pula $name jest zapauzowana (brak oczekujących zmian)"
      fi
      line "Uwaga: długa pauza blokuje też rotację CA kubeleta (alert MachineConfigControllerPausedPoolKubeletCA)."
    fi

    # --- Updating
    local upd_age; upd_age=$(age_min "$upd_ltt")
    if [[ $updating == True ]]; then
      line "W stanie Updating od: $(fmt_age "$upd_age")"
      if [[ $paused != true && $deg != True ]]; then
        if (( ${#n_prog[@]} == 0 && ${#n_wait[@]} > 0 )); then
          if (( upd_age >= STUCK_MIN )); then
            warn "Pula $name: ${#n_wait[@]} nodów czeka, żaden nie jest aktualizowany od $(fmt_age "$upd_age") — MCO nie wybiera kolejnego noda"
            act "Pula $name: sprawdź logi machine-config-controller (sekcja logów) — najczęściej powodem są nody NotReady/unavailable zjadające limit maxUnavailable=$maxu."
          else
            info "Pula $name: rollout w toku, MCO zaraz wybierze kolejny node"
          fi
        elif (( upd_age >= STUCK_MIN )); then
          warn "Pula $name aktualizuje się od $(fmt_age "$upd_age") — możliwe zablokowanie; zobacz analizę nodów w trakcie"
        else
          ok "Rollout puli $name przebiega normalnie (${#n_done[@]}/$mc zaktualizowanych)"
        fi
      fi
    elif [[ $deg != True && $paused != true ]]; then
      if (( pending )); then warn "Pula $name nie raportuje Updating, a nie wszystkie nody są na $spec_cfg"
      else ok "Wszystkie nody puli $name na docelowej konfiguracji"; fi
    fi

    # --- Unavailable vs maxUnavailable
    if [[ $maxu =~ ^[0-9]+$ ]] && (( uamc > maxu )); then
      warn "Unavailable ($uamc) > maxUnavailable ($maxu) — część nodów jest niedostępna z innych przyczyn niż rollout"
    fi

    # --- Ręcznie cordonowane nody
    if (( ${#n_cordon[@]} )); then
      local manual=()
      for nn in "${n_cordon[@]}"; do
        printf '%s\n' "${n_prog[@]}" | grep -qx "$nn" || manual+=("$nn")
      done
      if (( ${#manual[@]} )); then
        info "Nody cordoned poza aktualizacją MCO: ${manual[*]}"
        line "Zmniejszają pojemność puli podczas rolloutu. Jeśli MCO je zaktualizuje, po reboocie może zdjąć cordon — sprawdź ich stan po rolloucie."
        (( ${#n_wait[@]} > 0 )) && act "Pula $name: przed/w trakcie rolloutu uwzględnij, że ${manual[*]} jest cordoned — realna pojemność puli jest mniejsza."
      fi
    fi

    # --- Co się zmienia (porównanie rendered config)
    local from_cfg
    from_cfg=$(awk -F'|' -v p="$name" -v t="$spec_cfg" '$2==p && $3!=t{c[$3]++} END{m=0; for(k in c) if(c[k]>m){m=c[k]; r=k} print r}' "$TMP/nodes.txt")
    if [[ -n $from_cfg && -n $spec_cfg && $from_cfg != "$spec_cfg" ]]; then
      printf '\n'
      line "${BOLD}Co się zmienia:${N} $from_cfg → $spec_cfg"
      if oc get mc "$from_cfg" -o json >"$TMP/from.json" 2>/dev/null && oc get mc "$spec_cfg" -o json >"$TMP/to.json" 2>/dev/null; then
        jq -rn --slurpfile a "$TMP/from.json" --slurpfile b "$TMP/to.json" '
          ($a[0]) as $A | ($b[0]) as $B |
          def files(x): [x.spec.config.storage.files[]? | {key:.path, value:(.contents.source // "")}] | from_entries;
          def units(x): [x.spec.config.systemd.units[]? | {key:.name, value:((.contents // "") + (.enabled|tostring) + ([.dropins[]?.contents]|join("")))}] | from_entries;
          (files($A)) as $fa | (files($B)) as $fb |
          (units($A)) as $ua | (units($B)) as $ub |
          (if ($A.spec.osImageURL // "") != ($B.spec.osImageURL // "") then "OS|obraz systemu (osImageURL) — aktualizacja RHCOS" else empty end),
          (if ($A.spec.kernelArguments // []) != ($B.spec.kernelArguments // []) then "KARGS|" + (($A.spec.kernelArguments // [])|join(" ")) + " → " + (($B.spec.kernelArguments // [])|join(" ")) else empty end),
          (if ($A.spec.kernelType // "") != ($B.spec.kernelType // "") then "KTYPE|" + ($A.spec.kernelType // "default") + " → " + ($B.spec.kernelType // "default") else empty end),
          (if ($A.spec.extensions // []) != ($B.spec.extensions // []) then "EXT|" + (($B.spec.extensions // [])|join(",")) else empty end),
          ($fb | keys[] | select($fa[.] == null) | "FADD|" + .),
          ($fa | keys[] | select($fb[.] == null) | "FDEL|" + .),
          ($fa | keys[] | select($fb[.] != null and $fa[.] != $fb[.]) | "FMOD|" + .),
          ($ub | keys[] | select($ua[.] == null) | "UADD|" + .),
          ($ua | keys[] | select($ub[.] == null) | "UDEL|" + .),
          ($ua | keys[] | select($ub[.] != null and $ua[.] != $ub[.]) | "UMOD|" + .)
        ' >"$TMP/diff.txt" 2>/dev/null
        if [[ ! -s $TMP/diff.txt ]]; then
          line "   brak różnic w plikach/jednostkach/kernelu (zmiana np. w ignition/SSH/FIPS)"
        else
          local kind what h
          while IFS='|' read -r kind what; do
            h=$(hint_for_path "$what")
            case $kind in
              OS)    line "   • $what"; [[ $UPGRADE == 0 ]] && warn "Pula $name: zmiana obrazu RHCOS bez trwającego upgrade'u klastra — sprawdź, czy ktoś nie ustawił osImageURL / layeringu" ;;
              KARGS) line "   • argumenty kernela: $what" ;;
              KTYPE) line "   • typ kernela: $what" ;;
              EXT)   line "   • rozszerzenia RHCOS: $what" ;;
              FADD)  line "   • nowy plik:      $what${h:+   ← $h}" ;;
              FDEL)  line "   • usunięty plik:  $what${h:+   ← $h}" ;;
              FMOD)  line "   • zmieniony plik: $what${h:+   ← $h}" ;;
              UADD)  line "   • nowa jednostka systemd:      $what" ;;
              UDEL)  line "   • usunięta jednostka systemd:  $what" ;;
              UMOD)  line "   • zmieniona jednostka systemd: $what" ;;
            esac
          done <"$TMP/diff.txt"
          info "Pula $name: zmiana $from_cfg → $spec_cfg liczba zmienionych elementów: $(wc -l <"$TMP/diff.txt") (szczegóły w sekcji puli)"
        fi
      else
        line "   nie udało się pobrać rendered MachineConfig do porównania"
      fi

      # Źródłowe MC zmienione po utworzeniu starej konfiguracji
      local from_ts
      from_ts=$(jq -r '.metadata.creationTimestamp // ""' "$TMP/from.json" 2>/dev/null)
      if [[ -n $from_ts ]]; then
        jq -r --arg p "$name" '.items[] | select(.metadata.name==$p) | .spec.configuration.source[]?.name' "$TMP/mcp.json" >"$TMP/src.txt"
        local newsrc=()
        while IFS= read -r s; do
          [[ -z $s ]] && continue
          local ts mts
          ts=$(oc get mc "$s" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
          mts=$(oc get mc "$s" -o jsonpath='{.metadata.managedFields[*].time}' 2>/dev/null | tr ' ' '\n' | sort | tail -1)
          [[ -z $mts ]] && mts=$ts
          if [[ -n $mts ]] && [[ $(date -d "$mts" +%s 2>/dev/null || echo 0) -gt $(date -d "$from_ts" +%s 2>/dev/null || echo 0) ]]; then
            newsrc+=("$s (zmieniony $(fmt_age "$(age_min "$mts")") temu)")
          fi
        done <"$TMP/src.txt"
        if (( ${#newsrc[@]} )); then
          line "   Źródłowe MachineConfig utworzone/zmienione po poprzedniej konfiguracji:"
          for s in "${newsrc[@]}"; do line "      - $s"; done
        fi
      fi
      local kc
      kc=$(oc get kubeletconfig,containerruntimeconfig -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null)
      [[ -n $kc ]] && line "   Obiekty generujące MC w klastrze: $(tr '\n' ' ' <<<"$kc")"
    fi

    # --- Analiza nodów w trakcie / degraded
    local -a focus=("${n_prog[@]}" "${n_deg[@]}")
    if (( ${#focus[@]} )); then
      printf '\n'
      line "${BOLD}Nody w trakcie aktualizacji / z błędem:${N}"
    fi
    for nn in "${focus[@]}"; do
      IFS='|' read -r _ _ ncur ndes nst nreason nready nready_ltt nuns ndd nlad < <(awk -F'|' -v n="$nn" '$1==n' "$TMP/nodes.txt")
      local short=${nn%%.*}
      line "   ▸ $nn   state=$nst  Ready=$nready  cordoned=$nuns"
      line "     current=$ncur  desired=$ndes"

      if [[ $nst == Degraded || $nst == Unreconcilable ]]; then
        crit "Node $short: MCO state=$nst — ${nreason:0:220}"
        case $nreason in
          *"unexpected on-disk state"*|*"content mismatch"*)
            act "Node $short: dryf konfiguracji — ktoś zmienił plik na nodzie ręcznie. Porównaj plik z MachineConfig; naprawa wymaga świadomej decyzji (przywrócenie pliku albo forcefile)." ;;
          *drain*|*evict*)
            act "Node $short: nieudany drain — zobacz blokujące pody/PDB poniżej." ;;
          *)
            act "Node $short: przeczytaj pełny powód: oc get node $nn -o jsonpath='{.metadata.annotations.machineconfiguration\\.openshift\\.io/reason}'" ;;
        esac
      fi

      # Reboot / NotReady
      if [[ $nready != True ]]; then
        local nra; nra=$(age_min "$nready_ltt")
        if (( nra >= REBOOT_MIN )); then
          crit "Node $short jest NotReady od $(fmt_age "$nra") w trakcie aktualizacji — nie wrócił po reboocie"
          act "Node $short: sprawdź konsolę VM-ki na klastrze hostującym (oc get vmi; virtctl console) — boot, sieć, ignition, kubelet."
        else
          info "Node $short restartuje się (NotReady od $(fmt_age "$nra"))"
        fi
      fi

      # Drain
      if [[ $ndd == drain-* && $ndd != "$nlad" ]]; then
        line "     drain w toku (desiredDrain=$ndd, lastAppliedDrain=${nlad:-brak})"
        oc get pods -A --field-selector "spec.nodeName=$nn" -o json 2>/dev/null | jq -r '
          .items[] |
          select(.status.phase!="Succeeded" and .status.phase!="Failed") |
          select(([.metadata.ownerReferences[]?.kind] | index("DaemonSet")) | not) |
          select((.metadata.annotations["kubernetes.io/config.mirror"] // "") == "") |
          "\(.metadata.namespace)|\(.metadata.name)|\(.metadata.deletionTimestamp // "")"' >"$TMP/left.txt"
        local left; left=$(wc -l <"$TMP/left.txt")
        if (( left == 0 )); then
          line "     na nodzie nie ma już podów do ewakuacji — drain powinien się zaraz zakończyć"
        else
          line "     pody pozostałe do ewakuacji: $left"
          local -a blockers=()
          while IFS='|' read -r pns pn pdel; do
            local b
            b=$(jq -r --arg ns "$pns" '.items[] | select(.metadata.namespace==$ns and (.status.disruptionsAllowed // 0)==0) | .metadata.name' "$TMP/pdb.json" | tr '\n' ' ')
            if [[ -n $b ]]; then blockers+=("$pns/$pn  ← PDB: ${b% }${pdel:+ (terminating)}")
            elif [[ -n $pdel ]]; then blockers+=("$pns/$pn  ← utknął w Terminating (finalizer / wolumen?)"); fi
          done <"$TMP/left.txt"
          if (( ${#blockers[@]} )); then
            if (( upd_age >= STUCK_MIN )); then
              crit "Node $short: drain zablokowany (pula w Updating od $(fmt_age "$upd_age")) — blokerów: ${#blockers[@]} (PDB z disruptionsAllowed=0 lub Terminating)"
            else
              warn "Node $short: drain blokowany przez ${#blockers[@]} podów (PDB z disruptionsAllowed=0 lub Terminating)"
            fi
            for b in "${blockers[@]:0:10}"; do line "       $b"; done
            (( ${#blockers[@]} > 10 )) && line "       … i $(( ${#blockers[@]} - 10 )) więcej"
            act "Node $short: uzgodnij z właścicielami aplikacji z listy blokerów zwolnienie PDB (skalowanie w górę, poprawa zdrowia aplikacji) — nie usuwaj PDB bez ich wiedzy."
          else
            line "     brak oczywistych blokerów — pody są ewakuowane"
          fi
        fi
      fi

      # Logi MCD z noda
      local mcd
      mcd=$(oc get pods -n $NS_MCO -l k8s-app=machine-config-daemon --field-selector "spec.nodeName=$nn" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      if [[ -n $mcd ]]; then
        local mlog
        mlog=$(oc logs -n $NS_MCO "$mcd" -c machine-config-daemon --since="$LOG_SINCE" 2>/dev/null | grep -iE 'error|fail|unable|drain|reboot|degraded' | tail -6)
        if [[ -n $mlog ]]; then
          line "     ostatnie istotne wpisy machine-config-daemon:"
          while IFS= read -r l; do line "       ${l:0:170}"; done <<<"$mlog"
        fi
      fi
    done

    if (( ${#n_wait[@]} )); then
      printf '\n'
      line "Nody czekające w kolejce (${#n_wait[@]}): $(printf '%s ' "${n_wait[@]%%.*}")"
    fi
  done <"$TMP/pools.txt"

  # ================================================ LOGI KONTROLERA
  hdr "$idx. Logi machine-config-controller (ostatnie $LOG_SINCE)"; idx=$((idx+1))
  local clog
  clog=$(oc logs -n $NS_MCO deployment/machine-config-controller -c machine-config-controller --since="$LOG_SINCE" 2>/dev/null \
         | grep -iE 'error|fail|drain|evict|cannot|unable|degraded' | grep -v 'Successfully' | tail -12)
  if [[ -n $clog ]]; then
    local ne; ne=$(grep -ciE 'error|fail|cannot|unable' <<<"$clog")
    while IFS= read -r l; do line "${l:0:180}"; done <<<"$clog"
    (( ne > 0 )) && warn "W logach kontrolera są błędy ($ne w ostatnich wpisach) — patrz wyżej"
  else
    ok "Brak błędów w logach kontrolera"
  fi

  # ================================================ ALERTY
  hdr "$idx. Aktywne alerty MCO"
  if [[ $SKIP_ALERTS == 1 ]]; then
    line "pominięte (SKIP_ALERTS=1)"
  else
    local aj al
    aj=$(oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- curl -s http://localhost:9090/api/v1/alerts 2>/dev/null)
    if [[ -z $aj ]]; then
      line "nie udało się odczytać alertów z Prometheusa"
    else
      al=$(jq -r '.data.alerts[]? | select(.state=="firing") |
             select((.labels.alertname | test("^(MCD|MCC|MachineConfig|KubeletHealthState|SystemMemoryExceedsReservation)")) or ((.labels.namespace // "")=="openshift-machine-config-operator")) |
             "\(.labels.severity // "-")|\(.labels.alertname)|\(.labels.node // .labels.pool // "")"' <<<"$aj" 2>/dev/null | sort | uniq -c)
      if [[ -z $al ]]; then ok "Brak aktywnych alertów MCO"
      else
        while read -r cnt rest; do
          IFS='|' read -r sev an tgt <<<"$rest"
          local msg="Alert $an${tgt:+ ($tgt)}$( (( cnt > 1 )) && echo " ×$cnt")"
          case $sev in critical) crit "$msg";; warning) warn "$msg";; *) info "$msg";; esac
        done <<<"$al"
      fi
    fi
  fi

  # ================================================ WNIOSKI
  hdr "WNIOSKI"
  if (( ${#F_CRIT[@]} )); then
    printf '%s%sKRYTYCZNE (%d):%s\n' "$BOLD" "$R" "${#F_CRIT[@]}" "$N"
    for f in "${F_CRIT[@]}"; do printf '  • %s\n' "$f"; done
  fi
  if (( ${#F_WARN[@]} )); then
    printf '%s%sOSTRZEŻENIA (%d):%s\n' "$BOLD" "$Y" "${#F_WARN[@]}" "$N"
    for f in "${F_WARN[@]}"; do printf '  • %s\n' "$f"; done
  fi
  if (( ${#F_INFO[@]} )); then
    printf '%s%sINFORMACJE (%d):%s\n' "$BOLD" "$C" "${#F_INFO[@]}" "$N"
    for f in "${F_INFO[@]}"; do printf '  • %s\n' "$f"; done
  fi

  printf '\n%sOcena:%s\n' "$BOLD" "$N"
  if (( ${#F_CRIT[@]} )); then
    printf '  Rollout jest ZABLOKOWANY lub pula ma błąd. Nie wgrywaj kolejnych zmian MachineConfig/KubeletConfig,\n'
    printf '  dopóki pozycje KRYTYCZNE nie zostaną usunięte.\n'
  elif (( ${#F_WARN[@]} )); then
    printf '  Rollout wymaga uwagi — prawdopodobnie zwolniony lub czeka (pauza, PDB, pojemność).\n'
    printf '  Nie nakładaj nowych zmian, dopóki pula nie wróci do Updated=True.\n'
  else
    printf '  Pule są w porządku albo rollout przebiega normalnie. Jeśli coś się aktualizuje — poczekaj\n'
    printf '  na Updated=True przed kolejnymi zmianami (watch oc get mcp).\n'
  fi
  (( UPGRADE )) && printf '  Trwa upgrade klastra — aktualizacja pul jest jego częścią; nie pauzuj pul bez potrzeby.\n'

  if (( ${#ACTIONS[@]} )); then
    printf '\n%sZalecane kroki:%s\n' "$BOLD" "$N"
    local i=1
    for a in "${ACTIONS[@]}"; do printf '  %d. %s\n' "$i" "$a"; i=$((i+1)); done
  fi

  (( ${#F_CRIT[@]} )) && return 2
  (( ${#F_WARN[@]} )) && return 1
  return 0
}

# ------------------------------------------------------------- anonimizacja
build_anon_sed() {
  local api dom user i=0 n role short
  : >"$TMP/anon.sed"
  api=$(oc whoami --show-server 2>/dev/null | sed -E 's#^https?://##; s#:[0-9]+$##')
  dom=${api#api.}
  user=$(oc whoami 2>/dev/null)
  # nody: od najdłuższych nazw, żeby nie podmieniać fragmentów
  while IFS= read -r n; do
    [[ -z $n ]] && continue
    i=$((i + 1))
    short=${n%%.*}
    case $short in master*|*control*) role=master;; infra*) role=infra;; worker*|*wrk*) role=worker;; *) role=node;; esac
    printf '%s %s\n' "$n" "$(printf '%s-%02d.cluster.example.com' "$role" "$i")" >>"$TMP/anon.map"
    [[ $short != "$n" ]] && printf '%s %s\n' "$short" "$(printf '%s-%02d' "$role" "$i")" >>"$TMP/anon.map"
  done < <(jq -r '.items[].metadata.name' "$TMP/nodes.json" 2>/dev/null || oc get nodes -o name | sed 's#node/##')
  [[ -n $api ]] && printf '%s %s\n' "$api" "api.cluster.example.com" >>"$TMP/anon.map"
  [[ -n $dom && $dom != "$api" ]] && printf '%s %s\n' "$dom" "cluster.example.com" >>"$TMP/anon.map"
  [[ -n $user ]] && printf '%s %s\n' "$user" "user" >>"$TMP/anon.map"
  awk '{print length($1), $0}' "$TMP/anon.map" | sort -rn | cut -d' ' -f2- | while read -r from to; do
    printf 's/\\b%s\\b/%s/g\n' "$(sed 's/[.[\*^$/]/\\&/g' <<<"$from")" "$to"
  done >"$TMP/anon.sed"
}

if [[ $ANONYMIZE == 1 ]]; then
  oc get nodes -o json >"$TMP/nodes.json" 2>/dev/null
  : >"$TMP/anon.map"
  build_anon_sed
  main | sed -f "$TMP/anon.sed"
  exit "${PIPESTATUS[0]}"
else
  main
  exit $?
fi