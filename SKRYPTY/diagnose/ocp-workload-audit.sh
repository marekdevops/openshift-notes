#!/usr/bin/env bash
# =============================================================================
# ocp-workload-audit.sh - AUDYT JEDNEGO WORKLOADU (Deployment / StatefulSet /
#                         DaemonSet / DeploymentConfig / CronJob / Job / Pod)
#
# Odpowiada calosciowo na pytania o jedna aplikacje w zadanym oknie (domyslnie 24h):
#   1. jak workload jest skonfigurowany (repliki, requesty/limity, probe, HPA,
#      opcje JVM, emptyDir w RAM) i czy byly wdrozenia / skalowania;
#   2. ktore pody istnialy, NA KTORYCH WORKERACH dzialaly i od kiedy do kiedy
#      (takze pody juz usuniete - z historii Prometheusa);
#   3. ILE BYLO RESTARTOW i DLACZEGO (OOMKilled, zabicie przez liveness/startup,
#      blad aplikacji, SIGTERM, ewikcja) - per pod i kontener;
#   4. zuzycie CPU / pamieci / ruchu godzina po godzinie, trend pamieci
#      (wyciek?), throttling CPU, watki, deskryptory;
#   5. stan workerow w tym czasie (pamiec, CPU, steal, OOM na wezle, NotReady,
#      presja pamieci/dysku, reboot);
#   6. eventy Kubernetes dotyczace workloadu i jego podow;
#   7. LOGI WORKERA dotyczace tej aplikacji: kubelet (probe, zabicia,
#      back-off), crio, kernel (OOM killer - limit kontenera czy brak pamieci wezla);
#   8. logi poprzedniej instancji kontenera (co aplikacja mowila przed smiercia);
#   9. OS CZASU - wszystko powyzej ulozone chronologicznie;
#  10. ILE ZASOBOW POTRZEBA - wyliczone requesty/limity pamieci i CPU per kontener
#      (p95 i maksimum z ostatnich -D dni, korekta na OOM, -Xmx, wzrost pamieci);
#  11. PRZYCZYNY, PROBLEMY i WNIOSKI z podzialem: aplikacja / platforma.
#
# TYLKO ODCZYT: oc get / oc whoami / oc logs / oc adm node-logs (journal wezla)
# + HTTP GET do Prometheusa (thanos-querier). Niczego nie zmienia w klastrze.
# Wymagania: oc, jq (>=1.6), curl, column, awk, timeout.
# Uprawnienia: odczyt namespace + cluster-monitoring-view; logi workerow
# (oc adm node-logs) wymagaja uprawnien do nodes/proxy (np. cluster-admin) -
# bez nich sekcja 7 jest pomijana (albo wylacz ja opcja -N).
# =============================================================================
set -uo pipefail
export LC_ALL=C

HOURS=24; RDAYS=7; LOGL=100; NODELOGS=1; MAXNODES=6; TLMAX=120
CURL_K=""; OC_K=()

usage() { cat <<EOF
Uzycie: $0 [opcje] <namespace> <workload>

  <workload>   deploy/NAZWA, sts/NAZWA, ds/NAZWA, dc/NAZWA, cj/NAZWA, job/NAZWA,
               pod/NAZWA albo sama NAZWA (szukane kolejno: Deployment, StatefulSet,
               DaemonSet, DeploymentConfig, CronJob, Pod)

  -H GODZINY   okno analizy wstecz                        (domyslnie: $HOURS)
  -D DNI       okno do wyliczenia potrzebnych zasobow (sekcja 10) (domyslnie: $RDAYS)
  -l LINIE     ile ostatnich linii logow pokazywac        (domyslnie: $LOGL, 0 = bez logow aplikacji)
  -m N         maks. liczba workerow, z ktorych czytac journal (domyslnie: $MAXNODES)
  -N           nie czytaj logow workerow (oc adm node-logs)
  -k, --insecure
               nie weryfikuj certyfikatow TLS (oc + thanos-querier)

Przyklady:
  $0 moja-aplikacja deploy/backend
  $0 -k -H 48 moja-aplikacja sts/baza | tee audyt-\$(date +%F_%H%M).txt
EOF
exit "${1:-0}"; }

pos=()
while (( $# )); do case $1 in
  -H) HOURS=${2:-}; shift 2 || usage 1;;
  -l) LOGL=${2:-}; shift 2 || usage 1;;
  -D) RDAYS=${2:-}; shift 2 || usage 1;;
  -m) MAXNODES=${2:-}; shift 2 || usage 1;;
  -N) NODELOGS=0; shift;;
  -k|--insecure|--insecure-skip-tls-verify|--insecure-skip-tls-verify=true)
      CURL_K="-k"; OC_K=(--insecure-skip-tls-verify=true); shift;;
  -h|--help) usage 0;;
  -*) usage 1;;
  *) pos+=("$1"); shift;;
esac; done
(( ${#pos[@]} == 2 )) || usage 1
NS=${pos[0]}; WLARG=${pos[1]}

die()  { echo "BLAD: $*" >&2; exit 1; }
warn() { echo "UWAGA: $*" >&2; }
LINE=$(printf '=%.0s' {1..100})
hdr()  { printf '\n%s\n== %s\n%s\n' "$LINE" "$1" "$LINE"; }
sub()  { printf '\n--- %s\n' "$1"; }
say()  { fold -s -w 96 <<<"$*" | sed 's/^/  | /'; }
table() { local rows; rows=$(cat)
  if [[ $(wc -l <<<"$rows") -le 1 ]]; then echo "  (brak danych)"; else column -t -s $'\t' <<<"$rows" | sed 's/^/  /'; fi; }

# Jedyna droga do klastra: get / whoami / logs / adm node-logs (journal wezla).
oc_ro() { case "${1:-}" in
  get|whoami|logs) command oc "${OC_K[@]+"${OC_K[@]}"}" "$@";;
  adm) [[ ${2:-} == node-logs ]] && (( NODELOGS )) || die "oc_ro: 'oc adm $*' niedozwolone"
       timeout 180 oc "${OC_K[@]+"${OC_K[@]}"}" "$@";;
  *) die "oc_ro: zablokowano 'oc $1' (skrypt jest tylko do odczytu)";; esac; }

for c in oc jq curl column awk timeout; do command -v "$c" >/dev/null || die "brak polecenia: $c"; done
[[ $HOURS =~ ^[0-9]+$ ]] && (( HOURS > 0 )) || die "-H: podaj liczbe godzin"
[[ $LOGL =~ ^[0-9]+$ ]] || die "-l: podaj liczbe linii"
[[ $RDAYS =~ ^[0-9]+$ ]] && (( RDAYS > 0 )) || die "-D: podaj liczbe dni"
[[ $MAXNODES =~ ^[0-9]+$ ]] || die "-m: podaj liczbe"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: >"$TMP/findings"; : >"$TMP/tl.tsv"
# finding POZIOM STRONA TEKST   (POZIOM: KRYT|OSTR|INFO|OK, STRONA: APLIKACJA|PLATFORMA|KONFIG|-)
finding() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$TMP/findings"; }
# tl EPOCH ZRODLO OPIS - wpis na osi czasu
tl() { [[ ${1:-0} =~ ^[0-9]+$ ]] && (( $1 > 0 )) && printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$TMP/tl.tsv"; return 0; }
ge() { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
fdate() { date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%m-%d %H:%M'; }
fmem() { awk -v b="${1:-}" 'BEGIN{ if (b=="" || b+0<=0) {print "-"; exit} b+=0
  if (b>=1073741824) printf "%.1fGi", b/1073741824; else printf "%.0fMi", b/1048576 }'; }

if ! oc_ro whoami >/dev/null 2>"$TMP/err"; then
  grep -qiE 'x509|certificate|tls' "$TMP/err" && [[ -z $CURL_K ]] && die "blad certyfikatu TLS - uruchom ponownie z -k"
  die "brak sesji oc ($(head -c 200 "$TMP/err"))"
fi
TOKEN=${TOKEN:-$(oc_ro whoami -t 2>/dev/null || true)}
[[ -n $TOKEN ]] || die "brak tokenu - uzyj 'oc login --token=...' albo ustaw zmienna TOKEN"
THANOS=$(oc_ro get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
[[ -n $THANOS ]] || die "nie znaleziono route thanos-querier w openshift-monitoring"

EMPTY='{"status":"success","data":{"result":[]}}'
prom() { # $1=query|query_range $2=plik  reszta: parametry
  local ep=$1 out=$2; shift 2; local a=() p
  for p in "$@"; do a+=(--data-urlencode "$p"); done
  # shellcheck disable=SC2086
  if ! curl -sS $CURL_K --max-time 120 -G -H "Authorization: Bearer $TOKEN" "${a[@]}" \
        "https://$THANOS/api/v1/$ep" >"$out" 2>"$TMP/err"; then
    warn "curl: $(cat "$TMP/err")"; echo "$EMPTY" >"$out"; return 1; fi
  jq -e '.status=="success"' "$out" >/dev/null 2>&1 || { warn "zapytanie odrzucone: $(head -c 300 "$out")"; echo "$EMPTY" >"$out"; return 1; }
}
pq() { prom query "$TMP/$1.json" "query=$2" || true; }                                  # chwilowe
pr() { prom query_range "$TMP/$1.json" "query=$2" "start=$3" "end=$NOW" "step=$4" || true; }  # zakres

# wspolne definicje jq
JQDEF='
  def num: if type == "number" then . elif type == "string" and test("^[-+]?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$") then tonumber else null end;
  def ts: if . == null or . == "" then null else (sub("\\.[0-9]+"; "") | fromdateiso8601) end;
  def ft: if . == null then "-" else strflocaltime("%m-%d %H:%M") end;
  def r1: (. * 10 | round) / 10;
  def fb: if . == null then "-" elif . >= 1073741824 then "\(. / 1073741824 | r1)Gi" else "\(. / 1048576 | round)Mi" end;
  def fc: if . == null then "-" elif . >= 1 then "\(. | r1)" else "\(. * 1000 | round)m" end;
  def fp: if . == null then "-" else "\(. | round)%" end;
  def fr: if . == null then "-" elif . >= 1048576 then "\(. / 1048576 | r1)MB/s" else "\(. / 1024 | round)KB/s" end;
  def mem: if . == null then null else tostring |
      if test("Ki$") then (.[:-2]|tonumber)*1024 elif test("Mi$") then (.[:-2]|tonumber)*1048576
      elif test("Gi$") then (.[:-2]|tonumber)*1073741824 elif test("Ti$") then (.[:-2]|tonumber)*1099511627776
      elif test("k$") then (.[:-1]|tonumber)*1000 elif test("M$") then (.[:-1]|tonumber)*1000000
      elif test("G$") then (.[:-1]|tonumber)*1000000000 else tonumber end end;
  def cpu: if . == null then null else tostring | if test("m$") then (.[:-1]|tonumber)/1000 else tonumber end end;
  def exitdesc: if . == null then "" elif . == 0 then "zakonczyl sie sam"
      elif . == 1 then "blad aplikacji" elif . == 2 then "blad aplikacji/skryptu"
      elif . == 126 or . == 127 then "nie da sie uruchomic polecenia" elif . == 134 then "SIGABRT (abort)"
      elif . == 137 then "SIGKILL (OOM albo zabicie przez kubelet)" elif . == 139 then "SIGSEGV (naruszenie pamieci)"
      elif . == 143 then "SIGTERM (zatrzymanie na zadanie)" elif . > 128 then "sygnal \(. - 128)" else "blad aplikacji" end;
  # opis zakonczenia z uwzglednieniem powodu: OOMKilled ustawia tylko kernel (OOM killer), kubelet nigdy
  def termdesc($r): if $r == "OOMKilled" then "kernel OOM killer - przekroczony limit pamieci kontenera (lub brak pamieci wezla - patrz sekcja 7)"
      elif . == 137 and ($r == "Error" or $r == null) then "SIGKILL od kubeleta/CRI-O - nieudana probe liveness/startup albo przekroczony terminationGracePeriod"
      elif $r == "ContainerStatusUnknown" or $r == "Unknown" then "kontener zginal razem z workerem/kubeletem (reboot, awaria)"
      else exitdesc end;
  def podspec: if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
      elif .kind == "Pod" then .spec else .spec.template.spec end;'

NOW=$(date +%s); T0=$(( NOW - HOURS * 3600 )); W="${HOURS}h"
STEP=$(( HOURS * 3600 / 1400 )); (( STEP < 60 )) && STEP=60
HSH=$(( (HOURS + 47) / 48 )); HS=$(( HSH * 3600 ))     # krok tabeli godzinowej

# =============================================================================
# Ustalenie workloadu
# =============================================================================
oc_ro get ns "$NS" -o name >/dev/null 2>&1 || die "namespace $NS nie istnieje lub brak dostepu"
case $WLARG in */*) K=${WLARG%%/*}; NAME=${WLARG#*/};; *) K=""; NAME=$WLARG;; esac
case ${K,,} in
  deploy|deployment|deployments|deployment.apps) KIND=Deployment;;
  sts|statefulset|statefulsets|statefulset.apps)  KIND=StatefulSet;;
  ds|daemonset|daemonsets|daemonset.apps)        KIND=DaemonSet;;
  dc|deploymentconfig|deploymentconfigs)         KIND=DeploymentConfig;;
  cj|cronjob|cronjobs)                           KIND=CronJob;;
  job|jobs)                                      KIND=Job;;
  po|pod|pods)                                   KIND=Pod;;
  rs|replicaset|replicasets)                     KIND=ReplicaSet;;
  "")                                            KIND="";;
  *) die "nieznany typ workloadu: $K";;
esac
if [[ -z $KIND ]]; then
  for k in Deployment StatefulSet DaemonSet DeploymentConfig CronJob Pod; do
    oc_ro get "$k" "$NAME" -n "$NS" -o json >"$TMP/wl.json" 2>/dev/null && { KIND=$k; break; }
  done
  [[ -n $KIND ]] || die "nie znaleziono workloadu '$NAME' w $NS (podaj typ, np. deploy/$NAME)"
else
  oc_ro get "$KIND" "$NAME" -n "$NS" -o json >"$TMP/wl.json" 2>"$TMP/err" || die "nie znaleziono $KIND/$NAME w $NS ($(head -c 200 "$TMP/err"))"
fi
if [[ $KIND == ReplicaSet ]]; then   # RS -> nadrzedny Deployment
  own=$(jq -r '[.metadata.ownerReferences[]? | select(.kind=="Deployment") | .name][0] // empty' "$TMP/wl.json")
  if [[ -n $own ]]; then NAME=$own; KIND=Deployment; oc_ro get deploy "$NAME" -n "$NS" -o json >"$TMP/wl.json" || die "brak Deployment $NAME"; fi
fi
# Pod nalezacy do kontrolera -> audytuj kontroler
if [[ $KIND == Pod ]]; then
  read -r ok on < <(jq -r '((.metadata.ownerReferences // []) | map(select(.controller == true))[0]) | "\(.kind // "-") \(.name // "-")"' "$TMP/wl.json")
  case $ok in
    ReplicaSet) d=$(oc_ro get rs "$on" -n "$NS" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
                [[ -n $d ]] && oc_ro get deploy "$d" -n "$NS" -o json >"$TMP/wl.json" 2>/dev/null && { KIND=Deployment; NAME=$d; echo "Pod nalezy do Deployment/$d - audytuje caly workload."; };;
    StatefulSet|DaemonSet) oc_ro get "$ok" "$on" -n "$NS" -o json >"$TMP/wl.json" 2>/dev/null && { KIND=$ok; NAME=$on; echo "Pod nalezy do $ok/$on - audytuje caly workload."; };;
  esac
fi

# Wzorzec nazw wlascicieli podow (created_by_name w kube_pod_info / ownerReferences)
NRE=$(sed 's/\./\\./g' <<<"$NAME")             # regex (jq / awk)
case $KIND in
  Deployment)            ORE="$NRE-[a-z0-9]{5,12}";;     # ReplicaSet-y
  DeploymentConfig)      ORE="$NRE-[0-9]+";;             # ReplicationController-y
  CronJob)               ORE="$NRE-[0-9]+";;             # Joby
  *)                     ORE="$NRE";;
esac
if [[ $KIND == Pod ]]; then PSEL="namespace=\"$NS\",pod=\"$NAME\""
else PSEL="namespace=\"$NS\",created_by_name=~\"$(sed 's/\\/\\\\/g' <<<"$ORE")\""; fi
OWNI="max by (namespace, pod) (kube_pod_info{$PSEL})"                      # w chwili
OWNW="max by (namespace, pod) (max_over_time(kube_pod_info{$PSEL}[$W]))"   # w calym oknie
CSEL="namespace=\"$NS\",container!=\"\",container!=\"POD\""
J() { printf '* on (namespace, pod) group_left() %s' "$1"; }

echo "$LINE"
echo "AUDYT WORKLOADU  (tylko odczyt)"
echo "Klaster : $(oc_ro whoami --show-server)   uzytkownik: $(oc_ro whoami)"
echo "Workload: $KIND/$NAME   namespace: $NS"
echo "Okno    : ostatnie ${HOURS}h ($(fdate "$T0") - $(fdate "$NOW"))   teraz: $(date '+%F %T %Z')"
cat <<'EOF'

Jak czytac: sekcje 1-8 to fakty (konfiguracja, pody i workery, restarty, zuzycie, stan
workerow, eventy, logi). Sekcja 9 uklada je w czasie, sekcja 10 wylicza ile pamieci/CPU
aplikacja potrzebuje, sekcja 11 to przyczyny i wnioski.
EOF

# =============================================================================
# Zbieranie danych z API
# =============================================================================
oc_ro get pods -n "$NS" -o json >"$TMP/allpods.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/allpods.json"
jq --arg re "^$ORE\$" --arg k "$KIND" --arg n "$NAME" '{items: [.items[]
     | ((.metadata.ownerReferences // []) | map(select(.controller == true))[0]) as $o
     | select(if $k == "Pod" then .metadata.name == $n else (($o.name // "") | test($re)) end)]}' \
   "$TMP/allpods.json" >"$TMP/pods.json"
oc_ro get events -n "$NS" -o json >"$TMP/ev.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/ev.json"
oc_ro get hpa -n "$NS" -o json 2>/dev/null | jq --arg k "$KIND" --arg n "$NAME" \
  '{items: [.items[]? | select(.spec.scaleTargetRef.kind == $k and .spec.scaleTargetRef.name == $n)]}' >"$TMP/hpa.json" \
  || echo '{"items":[]}' >"$TMP/hpa.json"
echo '{"items":[]}' >"$TMP/rs.json"
case $KIND in
  Deployment) oc_ro get rs -n "$NS" -o json 2>/dev/null | jq --arg n "$NAME" \
      '{items: [.items[]? | select(any(.metadata.ownerReferences[]?; .kind == "Deployment" and .name == $n))]}' >"$TMP/rs.json" \
      || echo '{"items":[]}' >"$TMP/rs.json";;
  StatefulSet|DaemonSet) oc_ro get controllerrevisions -n "$NS" -o json 2>/dev/null | jq --arg n "$NAME" --arg k "$KIND" \
      '{items: [.items[]? | select(any(.metadata.ownerReferences[]?; .kind == $k and .name == $n))]}' >"$TMP/rs.json" \
      || echo '{"items":[]}' >"$TMP/rs.json";;
  DeploymentConfig) oc_ro get rc -n "$NS" -o json 2>/dev/null | jq --arg n "$NAME" \
      '{items: [.items[]? | select(any(.metadata.ownerReferences[]?; .name == $n))]}' >"$TMP/rs.json" \
      || echo '{"items":[]}' >"$TMP/rs.json";;
esac

# =============================================================================
# 1. KONFIGURACJA WORKLOADU
# =============================================================================
hdr "1. KONFIGURACJA WORKLOADU"
jq -r "$JQDEF"'
  "  Typ: \(.kind)   utworzony: \(.metadata.creationTimestamp | ts | ft)",
  (if .kind == "Deployment" or .kind == "StatefulSet" or .kind == "DeploymentConfig" then
     "  Repliki: zadane \(.spec.replicas // 1), gotowe \(.status.readyReplicas // 0), dostepne \(.status.availableReplicas // 0), zaktualizowane \(.status.updatedReplicas // 0)"
   elif .kind == "DaemonSet" then
     "  Pody: zadane \(.status.desiredNumberScheduled // 0), gotowe \(.status.numberReady // 0), niedostepne \(.status.numberUnavailable // 0)"
   else empty end),
  (if .spec.strategy then "  Strategia: \(.spec.strategy.type // "-") \(if .spec.strategy.rollingUpdate then "(maxSurge \(.spec.strategy.rollingUpdate.maxSurge // "-"), maxUnavailable \(.spec.strategy.rollingUpdate.maxUnavailable // "-"))" else "" end)" else empty end),
  "  Selektor wezlow: \((podspec.nodeSelector // {}) | to_entries | map("\(.key)=\(.value)") | join(",") | if . == "" then "-" else . end)   tolerancje: \((podspec.tolerations // []) | length)   antiAffinity: \(if podspec.affinity.podAntiAffinity then "tak" else "nie" end)   topologySpread: \(if (podspec.topologySpreadConstraints // []) | length > 0 then "tak" else "nie" end)",
  "  terminationGracePeriod: \(podspec.terminationGracePeriodSeconds // 30)s   priorityClass: \(podspec.priorityClassName // "-")"' "$TMP/wl.json"
jq -r '.items[] | "  HPA: min \(.spec.minReplicas // 1) / max \(.spec.maxReplicas), teraz \(.status.currentReplicas // "-") -> chce \(.status.desiredReplicas // "-"), ostatnie skalowanie: \(.status.lastScaleTime // "-")"' "$TMP/hpa.json"

sub "Kontenery: zasoby i probe (budzet = initialDelay + period x failureThreshold = czas do zabicia)"
{ printf 'KONTENER\tREQ_CPU\tLIM_CPU\tREQ_MEM\tLIM_MEM\tLIVENESS\tREADINESS\tSTARTUP\n'
  jq -r "$JQDEF"'
    def pr: if . == null then "-" else
      "\(([keys[] | select(. == "exec" or . == "httpGet" or . == "tcpSocket" or . == "grpc")][0]) // "?"):d\(.initialDelaySeconds // 0)/p\(.periodSeconds // 10)/t\(.timeoutSeconds // 1)/f\(.failureThreshold // 3)=\((.initialDelaySeconds // 0) + (.periodSeconds // 10) * (.failureThreshold // 3))s" end;
    podspec | (.initContainers // [] | map(. + {init: true})) + .containers | .[]
    | [(if .init then "(init) " else "" end) + .name, (.resources.requests.cpu // "-"), (.resources.limits.cpu // "-"),
       (.resources.requests.memory // "-"), (.resources.limits.memory // "-"),
       (.livenessProbe | pr), (.readinessProbe | pr), (.startupProbe | pr)] | @tsv' "$TMP/wl.json"
} | table
echo "  (probe: typ:d=initialDelay/p=period/t=timeout/f=failureThreshold=budzet)"

# JVM / emptyDir w RAM / QoS
jq -r "$JQDEF"'
  podspec as $s
  | ($s.containers[] | . as $c
      | ([(.env // [])[] | .value // empty] + (.args // []) + (.command // []) | join(" ")) as $all
      | ([$all | capture("-Xmx(?<n>[0-9]+)(?<u>[kKmMgG]?)")] | .[0]) as $x
      | ([$all | capture("MaxRAMPercentage=(?<p>[0-9.]+)")] | .[0]) as $p
      | select($x != null or $p != null)
      | "JVM|\($c.name)|\(if $x then ($x.n | tonumber) * ({"": 1, "k": 1024, "K": 1024, "m": 1048576, "M": 1048576, "g": 1073741824, "G": 1073741824} | .[$x.u]) else "" end)|\($p.p // "")|\($c.resources.limits.memory | mem // "")"),
    ($s.volumes // [] | map(select(.emptyDir.medium == "Memory")) | select(length > 0)
      | "EMPTYDIRMEM|\(map(.name + "(" + (.emptyDir.sizeLimit // "bez limitu") + ")") | join(", "))")' "$TMP/wl.json" >"$TMP/jvm.tsv"
while IFS='|' read -r t a b c d; do
  case $t in
    JVM) msg="Kontener $a: opcje JVM"
         [[ -n $b ]] && msg+=" -Xmx $(fmem "$b")"
         [[ -n $c ]] && msg+=" MaxRAMPercentage=$c%"
         [[ -n $d ]] && msg+=" przy limicie $(fmem "$d")"
         echo "  $msg"
         if [[ -n $b && -n $d ]] && ge "$b" "$(awk -v l="$d" 'BEGIN{print l*0.8}')"; then
           finding OSTR APLIKACJA "JVM w kontenerze $a: -Xmx $(fmem "$b") to >=80% limitu $(fmem "$d"). Poza heapem JVM potrzebuje pamieci na metaspace, watki, bufory (zwykle 20-40% wiecej) - kontener dojdzie do limitu i dostanie OOMKilled, choc heap nie jest pelny. Zalecane: -Xmx <= ~70-75% limitu albo MaxRAMPercentage=70."
         fi
         if [[ -n $c ]] && ge "$c" 81; then
           finding OSTR APLIKACJA "JVM w kontenerze $a: MaxRAMPercentage=$c% - za malo miejsca na pamiec poza heapem (zalecane <= 75%)."
         fi;;
    EMPTYDIRMEM) echo "  Wolumeny emptyDir w RAM (tmpfs, licza sie do limitu pamieci kontenera!): $a"
         finding INFO APLIKACJA "Workload ma emptyDir w RAM ($a) - pliki zapisane tam zuzywaja pamiec kontenera (working set) i moga prowadzic do OOMKilled.";;
  esac
done <"$TMP/jvm.tsv"
echo "  (opcje JVM odczytane tylko ze stalych wartosci env/args/command - wartosci z ConfigMap/Secret nie sa widoczne)"

# Wdrozenia (nowe ReplicaSet / rewizje) w oknie
sub "Wdrozenia / rewizje"
{ printf 'REWIZJA\tOBIEKT\tUTWORZONY\tREPLIKI_TERAZ\tW_OKNIE\n'
  jq -r --argjson t0 "$T0" "$JQDEF"'
    .items | sort_by(.metadata.creationTimestamp)[] | (.metadata.creationTimestamp | ts) as $c
    | [(.metadata.annotations["deployment.kubernetes.io/revision"] // .metadata.annotations["openshift.io/deployment-config.latest-version"] // .revision // "-" | tostring),
       .metadata.name, ($c | ft), (.status.replicas // .spec.replicas // "-" | tostring), (if $c >= $t0 then "TAK" else "" end)] | @tsv' "$TMP/rs.json"
} | table
jq -r --argjson t0 "$T0" "$JQDEF"'.items[] | (.metadata.creationTimestamp | ts) as $c | select($c >= $t0)
  | "\($c)\tWDROZENIE\tnowa rewizja \(.metadata.annotations["deployment.kubernetes.io/revision"] // .revision // "") (\(.metadata.name))"' "$TMP/rs.json" >>"$TMP/tl.tsv"
NREV=$(jq --argjson t0 "$T0" "$JQDEF"'[.items[] | select((.metadata.creationTimestamp | ts) >= $t0)] | length' "$TMP/rs.json")

# historia liczby replik (skalowanie)
RQ=""
case $KIND in
  Deployment)  RQ="max(kube_deployment_spec_replicas{namespace=\"$NS\",deployment=\"$NAME\"})";;
  StatefulSet) RQ="max(kube_statefulset_replicas{namespace=\"$NS\",statefulset=\"$NAME\"})";;
esac
NSCALE=0
if [[ -n $RQ ]]; then
  pr reps "$RQ" "$T0" "$STEP"
  jq -r '.data.result[0].values // [] | . as $v | range(1; length) | select($v[.][1] != $v[. - 1][1])
         | "\($v[.][0] | floor)\tSKALOWANIE\trepliki \($v[. - 1][1]) -> \($v[.][1])"' "$TMP/reps.json" >"$TMP/scale.tsv"
  NSCALE=$(wc -l <"$TMP/scale.tsv"); cat "$TMP/scale.tsv" >>"$TMP/tl.tsv"
  (( NSCALE > 0 )) && echo "  Zmiany liczby replik w oknie: $NSCALE (szczegoly na osi czasu)" || echo "  Liczba replik bez zmian w oknie."
fi
(( NREV > 0 )) && finding INFO KONFIG "W oknie bylo $NREV wdrozen (nowych rewizji) - pody byly wymieniane; to nie sa restarty, ale nowe pody na innych workerach."

# =============================================================================
# 2. PODY I WORKERY
# =============================================================================
hdr "2. PODY I WORKERY (gdzie dzialaly i kiedy)"
pr life "max by (pod, node, uid) (kube_pod_info{$PSEL})" "$T0" "$STEP"
jq -r --argjson now "$NOW" --argjson st "$STEP" '.data.result[] | select(.metric.pod != null)
  | [.metric.pod, (.metric.node // "-"), (.metric.uid // ""), (.values[0][0] | floor), (.values[-1][0] | floor)] | @tsv' \
  "$TMP/life.json" | sort -t$'\t' -k4,4n >"$TMP/life.tsv"
# uzupelnij o pody z API, ktorych nie ma w metrykach
jq -r '.items[] | [.metadata.name, (.spec.nodeName // "-"), .metadata.uid] | @tsv' "$TMP/pods.json" | while IFS=$'\t' read -r p n u; do
  grep -q "^$p"$'\t' "$TMP/life.tsv" || printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$n" "$u" "$NOW" "$NOW" >>"$TMP/life.tsv"
done
cut -f1 "$TMP/life.tsv" | sort -u >"$TMP/podnames.txt"
cut -f2 "$TMP/life.tsv" | grep -v '^-$' | sort -u >"$TMP/nodes.txt"
cut -f3 "$TMP/life.tsv" | grep -v '^$' | sort -u >"$TMP/uids.txt"
NPODS=$(wc -l <"$TMP/podnames.txt"); NNODES=$(wc -l <"$TMP/nodes.txt")

sub "Wszystkie pody w oknie (takze juz usuniete) - wedlug metryk kube_pod_info"
{ printf 'POD\tWORKER\tOD\tDO\tSTAN_TERAZ\n'
  while IFS=$'\t' read -r p n u f l; do
    st=$(jq -r --arg p "$p" '.items[] | select(.metadata.name == $p) | .status.phase + (if .status.reason then "/" + .status.reason else "" end)' "$TMP/pods.json")
    fs=$(fdate "$f"); (( f <= T0 + STEP )) && fs="<$(fdate "$T0")"
    ls=$(fdate "$l"); (( l >= NOW - 2 * STEP )) && ls="teraz"
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "${n%%.*}" "$fs" "$ls" "${st:-usuniety}"
    (( f > T0 + STEP )) && tl "$f" POD "pojawil sie $p na ${n%%.*}"
    (( l < NOW - 2 * STEP )) && tl "$l" POD "zniknal $p z ${n%%.*}"
  done <"$TMP/life.tsv"
} | table
echo "  Podow w oknie: $NPODS, na workerach: $NNODES"

sub "Pody teraz (API)"
{ printf 'POD\tWORKER\tFAZA\tGOTOWE\tRESTARTY_LACZNIE\tSTAN\tWIEK\tSTART->READY\n'
  jq -r --argjson now "$NOW" "$JQDEF"'.items[]
    | ([.status.containerStatuses[]? | select(.ready)] | length) as $r
    | (.status.containerStatuses // []) as $cs
    | ([.status.conditions[]? | select(.type == "Ready" and .status == "True") | .lastTransitionTime | ts][0]) as $rd
    | ([$cs[] | .state.running.startedAt | ts] | max) as $sa
    | [.metadata.name, ((.spec.nodeName // "-") | split(".")[0]), (.status.phase + (if .status.reason then "/" + .status.reason else "" end)),
       "\($r)/\($cs | length)", ([$cs[].restartCount] | add // 0 | tostring),
       ([$cs[] | .state | if .waiting then .waiting.reason elif .terminated then "Terminated:" + (.terminated.reason // "") else empty end] | unique | join(",") | if . == "" then "Running" else . end),
       ((($now - (.metadata.creationTimestamp | ts)) / 3600) | if . >= 48 then "\(. / 24 | floor)d" else "\(. | floor)h" end),
       (if $rd != null and $sa != null and $rd >= $sa then "\($rd - $sa | floor)s" else "-" end)] | @tsv' "$TMP/pods.json"
} | table
MAXPN=$(jq '[.items[] | select(.status.phase == "Running") | .spec.nodeName] | group_by(.) | map(length) | max // 0' "$TMP/pods.json")
NRUN=$(jq '[.items[] | select(.status.phase == "Running")] | length' "$TMP/pods.json")
NEVICT=$(jq '[.items[] | select(.status.reason == "Evicted")] | length' "$TMP/pods.json")
if (( NRUN > 1 && MAXPN * 2 > NRUN )); then
  finding OSTR KONFIG "Repliki skupione: $MAXPN z $NRUN dzialajacych podow na jednym workerze - problem tego workera zabiera wiekszosc aplikacji (brak/za slaba antiAffinity lub topologySpread)."
fi

# =============================================================================
# 3. RESTARTY I ICH PRZYCZYNY
# =============================================================================
hdr "3. RESTARTY I ICH PRZYCZYNY (okno ${HOURS}h)"
R="kube_pod_container_status_restarts_total{namespace=\"$NS\"}"
WSQ="container_memory_working_set_bytes{$CSEL}"
pq c_rst   "sum by (pod, container) (increase($R[$W]) $(J "$OWNW"))"
pq c_ws    "max by (pod, container) (max_over_time($WSQ[$W]) $(J "$OWNW"))"
pq c_rss   "max by (pod, container) (max_over_time(container_memory_rss{$CSEL}[$W]) $(J "$OWNW"))"
pq c_mlim  "max by (pod, container) (max_over_time(kube_pod_container_resource_limits{namespace=\"$NS\",resource=\"memory\"}[$W]) $(J "$OWNW"))"
pq c_mreq  "max by (pod, container) (max_over_time(kube_pod_container_resource_requests{namespace=\"$NS\",resource=\"memory\"}[$W]) $(J "$OWNW"))"
pq c_cpu   "max by (pod, container) (max_over_time(rate(container_cpu_usage_seconds_total{$CSEL}[5m])[$W:5m]) $(J "$OWNW"))"
pq c_clim  "max by (pod, container) (max_over_time(kube_pod_container_resource_limits{namespace=\"$NS\",resource=\"cpu\"}[$W]) $(J "$OWNW"))"
pq c_creq  "max by (pod, container) (max_over_time(kube_pod_container_resource_requests{namespace=\"$NS\",resource=\"cpu\"}[$W]) $(J "$OWNW"))"
pq c_thr   "max by (pod, container) (max_over_time((rate(container_cpu_cfs_throttled_periods_total{$CSEL}[5m]) / rate(container_cpu_cfs_periods_total{$CSEL}[5m]))[$W:5m]) $(J "$OWNW")) * 100"
pq c_thd   "max by (pod, container) (max_over_time(container_threads{$CSEL}[$W]) $(J "$OWNW"))"
pq c_fd    "max by (pod, container) (max_over_time(container_file_descriptors{$CSEL}[$W]) $(J "$OWNW"))"
pq c_oome  "sum by (pod, container) (increase(container_oom_events_total{$CSEL}[$W]) $(J "$OWNW"))"
pq c_reas  "max by (pod, container, reason) (max_over_time(kube_pod_container_status_last_terminated_reason{namespace=\"$NS\"}[$W]) $(J "$OWNW"))"
pq c_exit  "max by (pod, container) (max_over_time(kube_pod_container_status_last_terminated_exitcode{namespace=\"$NS\"}[$W]) $(J "$OWNW"))"
pq c_wait  "max by (pod, container, reason) (max_over_time(kube_pod_container_status_waiting_reason{namespace=\"$NS\"}[$W]) $(J "$OWNW"))"
pq c_grow  "max by (pod, container) (deriv($WSQ[$(( HOURS < 6 ? HOURS : 6 ))h]) $(J "$OWNI")) * 3600"
pq c_wsnow "max by (pod, container) ($WSQ $(J "$OWNI"))"
pq p_reas  "max by (pod, reason) (max_over_time(kube_pod_status_reason{namespace=\"$NS\"}[$W]) $(J "$OWNW")) > 0"
{ printf '{'; for n in rst ws rss mlim mreq cpu clim creq thr thd fd oome reas exit wait grow wsnow; do printf '"%s":' "$n"; cat "$TMP/c_$n.json"; printf ','; done
  printf '"pods":'; cat "$TMP/pods.json"; printf '}'; } >"$TMP/c_all.json"

# tabela per pod/kontener + fakty do analizy
jq -r --argjson now "$NOW" "$JQDEF"'
  def mp(n): (.[n].data.result // []) | map(select(.value[1] | num != null) | {key: "\(.metric.pod)\t\(.metric.container // "")", value: (.value[1] | num)}) | from_entries;
  def rs(n): (.[n].data.result // []) | map(select((.value[1] | num // 0) > 0)) | group_by("\(.metric.pod)\t\(.metric.container // "")")
             | map({key: "\(.[0].metric.pod)\t\(.[0].metric.container // "")", value: [.[].metric.reason] | unique}) | from_entries;
  . as $a
  | (mp("rst")) as $rst | (mp("ws")) as $ws | (mp("rss")) as $rss | (mp("mlim")) as $ml | (mp("mreq")) as $mr
  | (mp("cpu")) as $cpu | (mp("clim")) as $cl | (mp("thr")) as $thr | (mp("thd")) as $thd | (mp("fd")) as $fd
  | (mp("oome")) as $oe | (rs("reas")) as $re | (mp("exit")) as $ex | (rs("wait")) as $wt
  | ([$a.pods.items[] | .metadata.name as $p | (.spec.nodeName // "-") as $n | .status.containerStatuses[]?
      | {key: "\($p)\t\(.name)", value: {n: $n, rc: .restartCount, lr: .lastState.terminated.reason, le: .lastState.terminated.exitCode,
          fin: (.lastState.terminated.finishedAt | ts), sta: (.lastState.terminated.startedAt | ts), w: .state.waiting.reason}}] | from_entries) as $api
  | ([$rst, $ws, $api, $re] | map(keys) | add | unique) as $keys
  | ["POD", "KONTENER", "RESTARTY", "POWODY", "EXIT", "MEM_MAX", "RSS_MAX", "LIMIT", "%LIM", "CPU_MAX", "CPU_LIM", "THR_MAX", "WATKI", "FD"],
    ($keys[] | . as $k | ($api[$k] // {}) as $p
      | ((($re[$k] // []) + (if $p.lr then [$p.lr] else [] end) + ($wt[$k] // []) + (if $p.w then [$p.w] else [] end)) | unique) as $rr
      | ($ex[$k] // $p.le) as $e
      | [($k | split("\t")[0]), ($k | split("\t")[1]),
         (($rst[$k] // 0) | round | tostring), (if ($rr | length) > 0 then $rr | join(",") else "-" end),
         (if $e == null then "-" else ($e | tostring) end),
         ($ws[$k] | fb), ($rss[$k] | fb), ($ml[$k] | fb),
         (if $ml[$k] and $ws[$k] then ($ws[$k] / $ml[$k] * 100 | fp) else "-" end),
         ($cpu[$k] | fc), ($cl[$k] | fc), ($thr[$k] | fp),
         ($thd[$k] // null | if . == null then "-" else (. | round | tostring) end), ($fd[$k] // null | if . == null then "-" else (. | round | tostring) end)])
  | @tsv' "$TMP/c_all.json" | table
echo "  RESTARTY = przyrost licznika w oknie (metryki), POWODY = ostatnie zakonczenia widziane w oknie"
echo "  (OOMKilled, Error, Completed...) + obecny stan oczekiwania (CrashLoopBackOff...)."
echo "  %LIM = maks. working set / limit pamieci. THR_MAX = maks. % okresow CPU zdlawionych przez limit."

# fakty (klucz<TAB>wartosc)
jq -r "$JQDEF"'
  def mp(n): (.[n].data.result // []) | map(select(.value[1] | num != null) | {key: "\(.metric.pod)\t\(.metric.container // "")", value: (.value[1] | num)}) | from_entries;
  . as $a | (mp("rst")) as $rst | (mp("ws")) as $ws | (mp("rss")) as $rss | (mp("mlim")) as $ml | (mp("cpu")) as $cpu
  | (mp("clim")) as $cl | (mp("thr")) as $thr | (mp("thd")) as $thd | (mp("oome")) as $oe | (mp("grow")) as $gr | (mp("wsnow")) as $wn
  | ([$a.reas.data.result[]? | select((.value[1] | num // 0) > 0) | .metric.reason]) as $reasons
  | ([$a.wait.data.result[]? | select((.value[1] | num // 0) > 0) | .metric.reason]) as $waits
  | ([$a.pods.items[] | .status.containerStatuses[]?]) as $cs
  | ([$ws | to_entries[] | select($ml[.key] != null and $ml[.key] > 0) | {k: .key, p: (.value / $ml[.key] * 100), w: .value, l: $ml[.key], r: ($rss[.key] // null)}] | max_by(.p) // null) as $mx
  | ([$gr | to_entries[] | select(.value > 0) | {k: .key, g: .value, now: ($wn[.key] // 0), l: ($ml[.key] // 0)}] | max_by(.g) // null) as $g
  | "RST_TOTAL\t\([$rst[]] | add // 0 | round)",
    "RST_API\t\([$cs[].restartCount] | add // 0)",
    "OOM_KSM\t\([$reasons[] | select(. == "OOMKilled")] | length)",
    "ERR_KSM\t\([$reasons[] | select(. == "Error")] | length)",
    "UNK_KSM\t\([$reasons[] | select(. == "Unknown" or . == "ContainerStatusUnknown")] | length)",
    "COMPL_KSM\t\([$reasons[] | select(. == "Completed")] | length)",
    "OTHER_REASONS\t\([$reasons[] | select(. != "OOMKilled" and . != "Error" and . != "Completed")] | unique | join(","))",
    "WAITS\t\($waits + [$cs[] | .state.waiting.reason // empty] | unique | join(","))",
    "OOM_API\t\([$cs[] | select(.lastState.terminated.reason == "OOMKilled")] | length)",
    "K137_API\t\([$cs[] | select(.lastState.terminated.exitCode == 137 and .lastState.terminated.reason != "OOMKilled")] | length)",
    "K143_API\t\([$cs[] | select(.lastState.terminated.exitCode == 143)] | length)",
    "EXITS_ERR\t\([$cs[] | .lastState.terminated.exitCode // empty | select(. != 0 and . != 137 and . != 143)] | unique | map(tostring) | join(","))",
    "OOM_EVENTS\t\([$oe[]] | add // 0 | round)",
    "MEM_PCT\t\(if $mx then ($mx.p | round) else "" end)",
    "MEM_PCT_K\t\(if $mx then ($mx.k | sub("\t"; "/")) else "" end)",
    "MEM_PCT_W\t\(if $mx then ($mx.w | round) else "" end)",
    "MEM_PCT_L\t\(if $mx then ($mx.l | round) else "" end)",
    "MEM_RSS_RATIO\t\(if $mx and $mx.r != null and $mx.w > 0 then ($mx.r / $mx.w * 100 | round) else "" end)",
    "NOLIM_MEM\t\([$a.pods.items[0].spec.containers[]? | select(.resources.limits.memory == null)] | length)",
    "NOREQ_MEM\t\([$a.pods.items[0].spec.containers[]? | select(.resources.requests.memory == null)] | length)",
    "NOLIM_CPU\t\([$a.pods.items[0].spec.containers[]? | select(.resources.limits.cpu == null)] | length)",
    "CPU_PCT\t\([$cpu | to_entries[] | select($cl[.key] != null and $cl[.key] > 0) | .value / $cl[.key] * 100] | max // "" | if . == "" then . else round end)",
    "THR_MAX\t\([$thr[]] | max // "" | if . == "" then . else round end)",
    "THD_MAX\t\([$thd[]] | max // "" | if . == "" then . else round end)",
    "GROW_MBH\t\(if $g then ($g.g / 1048576 | round) else "" end)",
    "GROW_K\t\(if $g then ($g.k | sub("\t"; "/")) else "" end)",
    "GROW_ETA\t\(if $g and $g.l > 0 and $g.now < $g.l then (($g.l - $g.now) / $g.g | r1) else "" end)",
    "LIV_TIMEOUT\t\([$a.pods.items[0].spec.containers[]? | .livenessProbe.timeoutSeconds // empty] | min // "")",
    "HAS_LIV\t\([$a.pods.items[0].spec.containers[]? | select(.livenessProbe != null)] | length)",
    "HAS_STARTUP\t\([$a.pods.items[0].spec.containers[]? | select(.startupProbe != null)] | length)",
    "LIV_BUDGET\t\([$a.pods.items[0].spec.containers[]? | .livenessProbe | select(. != null) | (.initialDelaySeconds // 0) + (.periodSeconds // 10) * (.failureThreshold // 3)] | min // "")",
    "START_MAX\t\([$a.pods.items[] | ([.status.conditions[]? | select(.type == "Ready" and .status == "True") | .lastTransitionTime | ts][0]) as $rd
       | ([.status.containerStatuses[]? | .state.running.startedAt | ts] | max) as $sa | select($rd != null and $sa != null and $rd >= $sa) | $rd - $sa] | max // "" | if . == "" then . else floor end)"
  ' "$TMP/c_all.json" >"$TMP/facts.tsv"
declare -A F=()
while IFS=$'\t' read -r k v; do F[$k]=$v; done <"$TMP/facts.tsv"
fv() { echo "${F[$1]:-}"; }
fn() { local v=${F[$1]:-0}; [[ $v =~ ^-?[0-9]+$ ]] && echo "$v" || echo 0; }

jq -r "$JQDEF"'(.data.result // [])[] | "  Pod \(.metric.pod): status \(.metric.reason) w oknie"' "$TMP/p_reas.json"
NEVICT_P=$(jq '[.data.result[]? | select(.metric.reason == "Evicted")] | length' "$TMP/p_reas.json")
(( NEVICT_P > NEVICT )) && NEVICT=$NEVICT_P

sub "Ostatnie zakonczenia kontenerow (API, biezace pody)"
{ printf 'POD\tKONTENER\tZAKONCZONY\tPOWOD\tEXIT\tZNACZENIE\tDZIALAL\n'
  jq -r "$JQDEF"'.items[] | .metadata.name as $p | .status.containerStatuses[]? | select(.lastState.terminated != null)
    | .lastState.terminated as $t | ($t.finishedAt | ts) as $f | ($t.startedAt | ts) as $s
    | [$p, .name, ($f | ft), ($t.reason // "-"), ($t.exitCode | tostring), ($t.exitCode | termdesc($t.reason)),
       (if $f != null and $s != null then (($f - $s) | if . >= 3600 then "\(. / 3600 | r1)h" elif . >= 60 then "\(. / 60 | round)min" else "\(.)s" end) else "-" end)] | @tsv' "$TMP/pods.json"
} | table
jq -r "$JQDEF"'.items[] | .metadata.name as $p | .status.containerStatuses[]? | select(.lastState.terminated != null)
  | .lastState.terminated as $t | "\($t.finishedAt | ts | floor)\tKONTENER\t\($p)/\(.name) zakonczony: \($t.reason // "-") exit \($t.exitCode) (\($t.exitCode | termdesc($t.reason)))"' \
  "$TMP/pods.json" >>"$TMP/tl.tsv"
echo "  API pamieta tylko OSTATNIE zakonczenie kazdego kontenera; wczesniejsze - patrz eventy, logi workera i os czasu."
echo "  Restarty w oknie: $(fv RST_TOTAL) (metryki)   lacznie od startu biezacych podow: $(fn RST_API) (API)"

# =============================================================================
# 4. ZUZYCIE GODZINA PO GODZINIE
# =============================================================================
hdr "4. ZUZYCIE GODZINA PO GODZINIE (krok ${HSH}h; wartosci maksymalne w danej godzinie)"
HW="${HSH}h"; HT0=$(( T0 + HS ))
pr h_rst  "round(sum(increase($R[$HW]) $(J "max by (namespace, pod) (max_over_time(kube_pod_info{$PSEL}[$HW]))")))" "$HT0" "$HS"
pr h_pods "count(max by (pod) (max_over_time(kube_pod_info{$PSEL}[$HW])))" "$HT0" "$HS"
pr h_mem  "max(max_over_time((sum by (namespace, pod) ($WSQ) $(J "$OWNI"))[$HW:2m]))" "$HT0" "$HS"
pr h_msum "max_over_time((sum(sum by (namespace, pod) ($WSQ) $(J "$OWNI")))[$HW:2m])" "$HT0" "$HS"
pr h_cpu  "max(max_over_time((sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{$CSEL}[5m])) $(J "$OWNI"))[$HW:2m]))" "$HT0" "$HS"
pr h_thr  "max(max_over_time((sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{$CSEL}[5m])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{$CSEL}[5m])) $(J "$OWNI"))[$HW:2m])) * 100" "$HT0" "$HS"
pr h_net  "max_over_time((sum(sum by (namespace, pod) (rate(container_network_receive_bytes_total{namespace=\"$NS\"}[5m])) $(J "$OWNI")))[$HW:2m])" "$HT0" "$HS"
pr h_thd  "max(max_over_time((sum by (namespace, pod) (container_threads{$CSEL}) $(J "$OWNI"))[$HW:2m]))" "$HT0" "$HS"
{ printf '{'; for n in rst pods mem msum cpu thr net thd; do printf '"%s":' "$n"; cat "$TMP/h_$n.json"; printf ','; done; printf '"_":0}'; } >"$TMP/h_all.json"
{ printf 'GODZINA\tRESTARTY\tPODY\tMEM_POD_MAX\tMEM_SUMA\tCPU_POD_MAX\tTHROTTLING\tRUCH_RX\tWATKI\n'
  jq -r --argjson hs "$HS" "$JQDEF"'
    def ser(n): (.[n].data.result[0].values // []) | map({key: (.[0] | floor | tostring), value: (.[1] | num)}) | from_entries;
    . as $a | (ser("rst")) as $r | (ser("pods")) as $p | (ser("mem")) as $m | (ser("msum")) as $s | (ser("cpu")) as $c
    | (ser("thr")) as $t | (ser("net")) as $n | (ser("thd")) as $d
    | ([$r, $p, $m, $c] | map(keys) | add | unique | map(tonumber) | sort)[]
    | tostring as $k | tonumber as $e
    | ["\($e - $hs | ft)-\($e | strflocaltime("%H:%M"))", ($r[$k] // 0 | round | tostring), ($p[$k] // 0 | tostring),
       ($m[$k] | fb), ($s[$k] | fb), ($c[$k] | fc), ($t[$k] | fp), ($n[$k] | fr), ($d[$k] // null | if . == null then "-" else (round | tostring) end)] | @tsv' "$TMP/h_all.json"
} | table
echo "  MEM_POD_MAX / CPU_POD_MAX = najwiekszy pojedynczy pod, MEM_SUMA = wszystkie repliki razem, RUCH_RX = ruch przychodzacy (suma)."

jq -r --argjson hs "$HS" "$JQDEF"'
  def ser(n): (.[n].data.result[0].values // []) | map({t: (.[0] | floor), v: (.[1] | num)}) | map(select(.v != null));
  def peak(n): (ser(n) | max_by(.v) // null);
  def med: sort | if length == 0 then null else .[(length / 2 | floor)] end;
  (peak("rst")) as $pr | (peak("mem")) as $pm | (peak("cpu")) as $pc | (peak("net")) as $pn
  | (ser("net") | map(.v) | med) as $nm | (ser("mem")) as $ms
  | ([range(1; $ms | length) as $i | select($ms[$i].v > $ms[$i - 1].v * 1.02)] | length) as $up
  | "H_RST_PEAK_T\t\($pr.t // "")", "H_RST_PEAK_V\t\($pr.v // 0 | round)",
    "H_RST_HOURS\t\([ser("rst")[] | select(.v >= 0.5)] | length)",
    "H_MEM_PEAK_T\t\($pm.t // "")", "H_CPU_PEAK_T\t\($pc.t // "")", "H_NET_PEAK_T\t\($pn.t // "")",
    "H_NET_PEAK_X\t\(if $pn and $nm != null and $nm > 0 then ($pn.v / $nm | r1) else "" end)",
    "H_MEM_FIRST\t\($ms[0].v // "")", "H_MEM_LAST\t\($ms[-1].v // "")",
    "H_MEM_UP\t\($up)", "H_MEM_N\t\($ms | length)"' "$TMP/h_all.json" >>"$TMP/facts.tsv"
while IFS=$'\t' read -r k v; do F[$k]=$v; done <"$TMP/facts.tsv"
jq -r '.data.result[0].values // [] | .[] | select((.[1] | tonumber) >= 1) | "\(.[0] | floor)\tRESTARTY\t\(.[1]) restart(ow) w ciagu poprzedniej godziny (metryki)"' "$TMP/h_rst.json" >>"$TMP/tl.tsv"

[[ -n $(fv GROW_MBH) ]] && ge "$(fv GROW_MBH)" 1 && \
  echo "  Trend pamieci (ostatnie $(( HOURS < 6 ? HOURS : 6 ))h): najszybciej rosnie $(fv GROW_K) o ok. $(fv GROW_MBH) MiB/h$([[ -n $(fv GROW_ETA) ]] && echo ", do limitu za ok. $(fv GROW_ETA)h")"

# =============================================================================
# 5. STAN WORKEROW W OKNIE
# =============================================================================
hdr "5. WORKERY, NA KTORYCH DZIALALA APLIKACJA (stan w oknie ${HOURS}h)"
if (( NNODES == 0 )); then echo "  (brak danych o workerach)"; else
  NODERE=$(sed 's/\./\\\\./g' "$TMP/nodes.txt" | paste -sd'|')
  NI="instance=~\"$NODERE\""; NN="node=~\"$NODERE\""
  pq n_memmax "max by (instance) (max_over_time((1 - node_memory_MemAvailable_bytes{$NI} / node_memory_MemTotal_bytes{$NI})[$W:5m])) * 100"
  pq n_memnow "max by (instance) (1 - node_memory_MemAvailable_bytes{$NI} / node_memory_MemTotal_bytes{$NI}) * 100"
  pq n_cpumax "max by (instance) (max_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\",$NI}[5m])))[$W:5m])) * 100"
  pq n_steal  "max by (instance) (max_over_time((avg by (instance) (rate(node_cpu_seconds_total{mode=\"steal\",$NI}[5m])))[$W:5m])) * 100"
  pq n_load   "max by (instance) (max_over_time(node_load15{$NI}[$W])) / count by (instance) (node_cpu_seconds_total{mode=\"idle\",$NI})"
  pq n_oom    "max by (instance) (increase(node_vmstat_oom_kill{$NI}[$W]))"
  pq n_boot   "max by (instance) (node_boot_time_seconds{$NI})"
  pq n_nrdy   "max by (node) (max_over_time(kube_node_status_condition{condition=\"Ready\",status!=\"true\",$NN}[$W]))"
  pq n_press  "max by (node, condition) (max_over_time(kube_node_status_condition{condition=~\"MemoryPressure|DiskPressure|PIDPressure\",status=\"true\",$NN}[$W])) > 0"
  pr n_ready  "max by (node) (kube_node_status_condition{condition=\"Ready\",status=\"true\",$NN})" "$T0" "$STEP"
  { printf '{'; for n in memmax memnow cpumax steal load oom boot nrdy press; do printf '"%s":' "$n"; cat "$TMP/n_$n.json"; printf ','; done; printf '"_":0}'; } >"$TMP/n_all.json"
  oc_ro get nodes -o json 2>/dev/null | jq --rawfile ns "$TMP/nodes.txt" '{items: [.items[] | select(.metadata.name as $n | $ns | split("\n") | index($n))]}' >"$TMP/nodes.json" \
    || echo '{"items":[]}' >"$TMP/nodes.json"
  # requesty pamieci na wezlach (teraz)
  : >"$TMP/nreq.tsv"
  while IFS= read -r n; do
    oc_ro get pods -A --field-selector "spec.nodeName=$n,status.phase!=Succeeded,status.phase!=Failed" -o json </dev/null 2>/dev/null \
    | jq -r --arg n "$n" "$JQDEF"'"\($n)\t\([.items[] | .spec.containers[] | .resources.requests.memory // "0" | mem] | add // 0)\t\(.items | length)"' >>"$TMP/nreq.tsv" 2>/dev/null
  done <"$TMP/nodes.txt"
  { printf 'WORKER\tROLA\tREADY\tCORDON\tNOTREADY_W_OKNIE\tPRESJA\tREBOOT\tMEM_MAX\tMEM_TERAZ\tREQ/ALLOC\tCPU_MAX\tSTEAL_MAX\tLOAD15/RDZEN\tOOM_KILL_WEZLA\tPODY\n'
    jq -r --argjson t0 "$T0" --rawfile req "$TMP/nreq.tsv" --rawfile nl "$TMP/nodes.txt" --slurpfile nodes "$TMP/nodes.json" "$JQDEF"'
      def mp(n; l): (.[n].data.result // []) | map(select(.value[1] | num != null) | {key: .metric[l], value: (.value[1] | num)}) | from_entries;
      . as $a | (mp("memmax"; "instance")) as $mm | (mp("memnow"; "instance")) as $mn | (mp("cpumax"; "instance")) as $cm
      | (mp("steal"; "instance")) as $st | (mp("load"; "instance")) as $ld | (mp("oom"; "instance")) as $oo | (mp("boot"; "instance")) as $bt
      | (mp("nrdy"; "node")) as $nr
      | ([$a.press.data.result[]? | {n: .metric.node, c: .metric.condition}] | group_by(.n) | map({key: .[0].n, value: (map(.c) | join(","))}) | from_entries) as $pr
      | ($req | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {r: (.[1] | tonumber), p: .[2]}}) | from_entries) as $rq
      | $nodes[0].items as $ni
      | ($ni | map({key: .metadata.name, value: .}) | from_entries) as $nd
      | ($nl | split("\n") | map(select(. != "")))[] as $n | ($nd[$n] // {}) as $o
      | [($n | split(".")[0]),
         ([($o.metadata.labels // {}) | keys[] | select(startswith("node-role.kubernetes.io/")) | sub("node-role.kubernetes.io/"; "")] | join(",") | if . == "" then "-" else . end),
         ([$o.status.conditions[]? | select(.type == "Ready") | .status][0] // "?"),
         (if $o.spec.unschedulable then "TAK" else "-" end),
         (if ($nr[$n] // 0) > 0 then "TAK" else "-" end),
         ($pr[$n] // "-"),
         (if ($bt[$n] // 0) > $t0 then "TAK " + ($bt[$n] | ft) else "-" end),
         ($mm[$n] | fp), ($mn[$n] | fp),
         (if $rq[$n] and $o.status.allocatable.memory then ($rq[$n].r / ($o.status.allocatable.memory | mem) * 100 | fp) else "-" end),
         ($cm[$n] | fp), ($st[$n] | fp), ($ld[$n] // null | if . == null then "-" else (r1 | tostring) end),
         ($oo[$n] // null | if . == null then "-" else (round | tostring) end), ($rq[$n].p // "-")] | @tsv' "$TMP/n_all.json"
  } | table
  echo "  REQ/ALLOC = suma requestow pamieci wszystkich podow na workerze / allocatable (teraz). OOM_KILL_WEZLA = wszystkie"
  echo "  zabicia przez kernel OOM na workerze (dowolne pody). LOAD15/RDZEN > 1 = kolejka do CPU."
  # os czasu: reboot, NotReady
  jq -r --argjson t0 "$T0" '.data.result[]? | select((.value[1] | tonumber) > $t0) | "\(.value[1] | tonumber | floor)\tWORKER\treboot \(.metric.instance | split(".")[0])"' "$TMP/n_boot.json" >>"$TMP/tl.tsv"
  jq -r '.data.result[]? | .metric.node as $n | .values as $v | range(1; $v | length) | select($v[.][1] != $v[. - 1][1])
    | "\($v[.][0] | floor)\tWORKER\t\($n | split(".")[0]) \(if $v[.][1] == "1" then "znow Ready" else "NotReady" end)"' "$TMP/n_ready.json" >>"$TMP/tl.tsv"
  # fakty o workerach
  jq -r --argjson t0 "$T0" "$JQDEF"'
    def mp(n): (.[n].data.result // []) | map(.value[1] | num) | map(select(. != null));
    "N_MEMMAX\t\(mp("memmax") | max // "" | if . == "" then . else round end)",
    "N_STEAL\t\(mp("steal") | max // "" | if . == "" then . else round end)",
    "N_LOAD\t\(mp("load") | max // "" | if . == "" then . else r1 end)",
    "N_OOM\t\(mp("oom") | add // 0 | round)",
    "N_REBOOT\t\([mp("boot")[] | select(. > $t0)] | length)",
    "N_NOTREADY\t\([mp("nrdy")[] | select(. > 0)] | length)",
    "N_PRESS\t\([.press.data.result[]? | "\(.metric.node | split(".")[0]):\(.metric.condition)"] | join(" "))"' "$TMP/n_all.json" >>"$TMP/facts.tsv"
  while IFS=$'\t' read -r k v; do F[$k]=$v; done <"$TMP/facts.tsv"
fi

# =============================================================================
# 6. EVENTY
# =============================================================================
hdr "6. EVENTY KUBERNETES (workload, jego ReplicaSet/rewizje, pody, HPA)"
{ cat "$TMP/podnames.txt"; echo "$NAME"; jq -r '.items[].metadata.name' "$TMP/rs.json" "$TMP/hpa.json"; } | sort -u >"$TMP/objnames.txt"
jq --rawfile o "$TMP/objnames.txt" "$JQDEF"'($o | split("\n") | map(select(. != "")) | map({key: ., value: true}) | from_entries) as $on
  | [.items[] | select($on[.involvedObject.name])
     | {t: ((.lastTimestamp // .eventTime // .firstTimestamp // .metadata.creationTimestamp) | ts),
        f: ((.firstTimestamp // .eventTime // .metadata.creationTimestamp) | ts),
        type, reason, obj: "\(.involvedObject.kind)/\(.involvedObject.name)", n: (.count // .series.count // 1),
        msg: ((.message // "") | gsub("[\n\t]"; " "))}]' "$TMP/ev.json" >"$TMP/myev.json"
OLDEST=$(jq -r '[.items[] | (.lastTimestamp // .eventTime // .metadata.creationTimestamp) | select(. != null)] | min // empty' "$TMP/ev.json")
sub "Zestawienie (wg powodu)"
{ printf 'TYP\tPOWOD\tLICZBA\tOSTATNIO\tPRZYKLAD\n'
  jq -r "$JQDEF"'group_by(.type + .reason) | map({type: .[0].type, reason: .[0].reason, n: (map(.n) | add), t: (map(.t) | max), msg: (max_by(.t).msg)})
    | sort_by(-.t)[] | [.type, .reason, (.n | tostring), (.t | ft), (.msg | .[0:110])] | @tsv' "$TMP/myev.json"
} | table
sub "Ostatnie ostrzezenia (Warning)"
{ printf 'OSTATNIO\tPOWOD\tLICZBA\tOBIEKT\tKOMUNIKAT\n'
  jq -r "$JQDEF"'map(select(.type == "Warning")) | sort_by(.t) | .[-15:][] | [(.t | ft), .reason, (.n | tostring), .obj, (.msg | .[0:120])] | @tsv' "$TMP/myev.json"
} | table
[[ -n $OLDEST ]] && echo "  Uwaga: eventy w klastrze sa przechowywane krotko (domyslnie ok. 3h) - najstarszy event w namespace: ${OLDEST}."
jq -r '.[] | select(.t != null) | select(.type == "Warning" or .reason == "Killing" or .reason == "Evicted" or .reason == "Preempting" or .reason == "Scheduled")
  | "\(.t | floor)\tEVENT\t\(.reason) \(.obj) (x\(.n)): \(.msg | .[0:140])"' "$TMP/myev.json" >>"$TMP/tl.tsv"
for r in BackOff Unhealthy Killing Evicted FailedScheduling FailedMount OOMKilling Preempting FailedCreatePodSandBox; do
  F[EV_$r]=$(jq --arg r "$r" '[.[] | select(.reason == $r) | .n] | add // 0' "$TMP/myev.json")
done
F[EV_LIVENESS]=$(jq '[.[] | select(.reason == "Unhealthy" and (.msg | test("Liveness"))) | .n] | add // 0' "$TMP/myev.json")
F[EV_READINESS]=$(jq '[.[] | select(.reason == "Unhealthy" and (.msg | test("Readiness"))) | .n] | add // 0' "$TMP/myev.json")
F[EV_LIVKILL]=$(jq '[.[] | select(.reason == "Killing" and (.msg | test("failed (liveness|startup) probe"))) | .n] | add // 0' "$TMP/myev.json")
F[EV_STARTUP]=$(jq '[.[] | select(.reason == "Unhealthy" and (.msg | test("Startup"))) | .n] | add // 0' "$TMP/myev.json")
F[EV_PROBE_TIMEOUT]=$(jq '[.[] | select(.reason == "Unhealthy" and (.msg | test("timeout|deadline exceeded|Timeout"))) | .n] | add // 0' "$TMP/myev.json")

# =============================================================================
# 7. LOGI WORKEROW (journal: kubelet, crio, kernel)
# =============================================================================
hdr "7. LOGI WORKEROW DOTYCZACE APLIKACJI (kubelet, crio, kernel OOM)"
F[KL_LIVKILL]=0; F[KL_STKILL]=0; F[KL_LIVFAIL]=0; F[KL_RDYFAIL]=0; F[KL_STFAIL]=0; F[KL_TIMEOUT]=0
F[KL_BACKOFF]=0; F[KL_EVICT]=0; F[KL_MOUNT]=0; F[KO_OURS]=0; F[KO_OTHER]=0; F[KO_NODE]=0; NL_DONE=0
if (( ! NODELOGS )); then echo "  Pominiete (opcja -N)."
elif (( NNODES == 0 )); then echo "  Brak workerow do sprawdzenia."
else
  # uid w sciezkach cgroup: '-' -> '_'
  { cat "$TMP/uids.txt"; jq -r '.items[].metadata.uid' "$TMP/pods.json"; } | grep -v '^$' | sort -u | while read -r u; do echo "$u"; echo "${u//-/_}"; done >"$TMP/uidpat.txt"
  PCRE="$NS/$(sed 's/\./\\./g' <<<"$NAME")"
  # normalizacja: "EPOCH<TAB>komunikat" (format short-unix; zapasowo zwykly format)
  jnorm() { awk '
    { if ($1 ~ /^[0-9]+\.[0-9]+$/) { t=int($1); sub(/^[^ ]+ [^ ]+ [^ ]+ /, "") }
      else { t=0; sub(/^[A-Z][a-z][a-z] +[0-9]+ [0-9:]+ [^ ]+ [^ ]+ /, "") }
      sub(/^[IWEF][0-9][0-9][0-9][0-9] [0-9:.]+ +[0-9]+ [^]]+\] /, "")
      print t "\t" $0 }'; }
  nlog() { # $1=node $2=plik reszta=parametry
    local n=$1 out=$2; shift 2
    if ! oc_ro adm node-logs "$n" --since="-${HOURS}h" -o short-unix "$@" </dev/null >"$out.raw" 2>"$TMP/nlerr" || [[ ! -s $out.raw && -s $TMP/nlerr ]]; then
      oc_ro adm node-logs "$n" --since="-${HOURS}h" "$@" </dev/null >"$out.raw" 2>"$TMP/nlerr" || return 1
    fi
    { grep -v '^-- ' "$out.raw" || true; } | jnorm >"$out"
  }
  i=0
  while IFS= read -r n; do
    i=$((i + 1)); (( i > MAXNODES )) && { echo "  ... pominieto pozostale workery (limit -m $MAXNODES)"; break; }
    sn=${n%%.*}
    sub "Worker $sn"
    if ! nlog "$n" "$TMP/kl.$i" -u kubelet --grep="$PCRE"; then
      echo "  Nie mozna odczytac journala ($(head -c 160 "$TMP/nlerr")) - brak uprawnien do 'oc adm node-logs'? Pomijam logi workerow."
      break
    fi
    NL_DONE=$((NL_DONE + 1))
    grep -F -f "$TMP/podnames.txt" "$TMP/kl.$i" >"$TMP/klf.$i" || true
    nlog "$n" "$TMP/cr.$i" -u crio --grep="$PCRE" || : >"$TMP/cr.$i"
    grep -F -f "$TMP/podnames.txt" "$TMP/cr.$i" >"$TMP/crf.$i" || true
    nlog "$n" "$TMP/ko.$i" --grep="oom-kill|Out of memory|Killed process|Memory cgroup out of memory" || : >"$TMP/ko.$i"

    # --- kubelet: kategorie
    awk -F'\t' '
      /Probe failed/ && /probeType="Liveness"/  { lf++ }
      /Probe failed/ && /probeType="Readiness"/ { rf++ }
      /Probe failed/ && /probeType="Startup"/   { sf++ }
      /Probe failed/ && /(deadline exceeded|Client.Timeout|timeout|timed out)/ { to++ }
      /failed liveness probe, will be restarted/ { lk++ }
      /failed startup probe, will be restarted/  { sk++ }
      /Killing container with a grace period/    { kc++ }
      /ContainerDied/                            { cd++ }
      /CrashLoopBackOff|Back-off restarting/     { bo++ }
      /[Ee]vict/                                 { ev++ }
      /OOMKilled|oom/                            { om++ }
      /MountVolume|FailedMount|Unable to attach or mount/ { mt++ }
      /Error syncing pod/                        { es++ }
      END { printf "LIVFAIL %d\nRDYFAIL %d\nSTFAIL %d\nTIMEOUT %d\nLIVKILL %d\nSTKILL %d\nKILLING %d\nDIED %d\nBACKOFF %d\nEVICT %d\nOOM %d\nMOUNT %d\nERRSYNC %d\n",
            lf, rf, sf, to, lk, sk, kc, cd, bo, ev, om, mt, es }' "$TMP/klf.$i" >"$TMP/klc.$i"
    declare -A KC=(); while read -r k v; do KC[$k]=$v; done <"$TMP/klc.$i"
    for k in LIVKILL STKILL LIVFAIL RDYFAIL STFAIL TIMEOUT BACKOFF EVICT MOUNT; do F[KL_$k]=$(( ${F[KL_$k]} + ${KC[$k]:-0} )); done
    echo "  kubelet (linie dotyczace podow aplikacji: $(wc -l <"$TMP/klf.$i")):"
    printf '    probe nieudane: liveness %s, readiness %s, startup %s (w tym timeout: %s)\n' "${KC[LIVFAIL]}" "${KC[RDYFAIL]}" "${KC[STFAIL]}" "${KC[TIMEOUT]}"
    printf '    restart przez kubelet: po liveness %s, po startup %s;  zabijanie kontenerow: %s;  ContainerDied: %s\n' "${KC[LIVKILL]}" "${KC[STKILL]}" "${KC[KILLING]}" "${KC[DIED]}"
    printf '    CrashLoop/back-off: %s;  ewikcja: %s;  OOM: %s;  wolumeny: %s;  bledy synchronizacji: %s\n' "${KC[BACKOFF]}" "${KC[EVICT]}" "${KC[OOM]}" "${KC[MOUNT]}" "${KC[ERRSYNC]}"
    if (( ${KC[LIVFAIL]:-0} + ${KC[STFAIL]:-0} + ${KC[RDYFAIL]:-0} > 0 )); then
      echo "    najczestsze odpowiedzi nieudanych probe:"
      grep 'Probe failed' "$TMP/klf.$i" | sed -nE 's/.*probeType="([A-Za-z]+)".*output="(.*)"[^"]*$/\1: \2/p' \
        | sed -E 's/\\"/"/g; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/<ip>/g' | cut -c1-150 | sort | uniq -c | sort -rn | head -5 \
        | sed -E 's/^ *([0-9]+) /      \1x  /'
    fi
    if [[ -s $TMP/klf.$i ]]; then
      echo "    ostatnie istotne wpisy:"
      grep -E 'Probe failed|will be restarted|Killing container|CrashLoopBackOff|Back-off|[Ee]vict|OOM|ContainerDied|Error syncing|FailedMount|MountVolume' "$TMP/klf.$i" \
        | tail -n "$(( LOGL > 0 ? LOGL : 10 ))" | awk -F'\t' '{ t=($1>0)?strftime("%m-%d %H:%M:%S", $1):"?"; print "      " t "  " substr($2, 1, 200) }' 2>/dev/null \
        || tail -n 10 "$TMP/klf.$i" | cut -f2 | cut -c1-200 | sed 's/^/      /'
    fi
    grep -E 'will be restarted' "$TMP/klf.$i" | awk -F'\t' '$1>0 { m=$2; if (match(m, /containerMessage="[^"]*"/)) m=substr(m, RSTART+18, RLENGTH-19); print $1 "\tKUBELET\t" substr(m, 1, 160) }' >>"$TMP/tl.tsv"
    grep -E '[Ee]victing|evicted' "$TMP/klf.$i" | awk -F'\t' '$1>0 { print $1 "\tKUBELET\t" substr($2, 1, 160) }' >>"$TMP/tl.tsv"

    # --- crio
    awk -F'\t' '/Started container/ {s++} /Stopped container|Stopping container/ {t++} /Removed container/ {r++} /level=error|[Ee]rror/ {e++}
      END { printf "    crio: start kontenerow %d, stop %d, usuniecia %d, bledy %d\n", s, t, r, e }' "$TMP/crf.$i"
    grep -E 'level=error|[Ee]rror' "$TMP/crf.$i" | tail -3 | cut -f2 | cut -c1-200 | sed 's/^/      /'

    # --- kernel OOM
    awk -F'\t' -v ufile="$TMP/uidpat.txt" -v sn="$sn" -v tlf="$TMP/kotl.$i" '
      BEGIN { while ((getline u < ufile) > 0) if (u != "") U[u] = 1 }
      /oom-kill:/ { ours = 0; for (u in U) if (index($2, u)) { ours = 1; break }
                    if ($2 ~ /constraint=CONSTRAINT_NONE/) { node++ ; last = "NODE" }
                    else if (ours) { o++; last = "OURS" } else { other++; last = "OTHER" }
                    tk = $1; tsk = ""; if (match($2, /task=[^,]+/)) tsk = substr($2, RSTART+5, RLENGTH-5); next }
      /Killed process/ && last != "" {
                    if (last == "OURS" || last == "NODE") {
                      why = "brak pamieci CALEGO WEZLA"; if (last == "OURS") why = "limit pamieci KONTENERA aplikacji"
                      rs = ""; if (match($2, /anon-rss:[0-9]+kB/)) rs = sprintf(" (anon-rss %.0f MiB)", substr($2, RSTART+9, RLENGTH-11) / 1024)
                      msg = why ": OOM killer zabil proces " tsk rs " na " sn
                      print tk "\tKERNEL\t" msg > tlf
                    }
                    last = "" }
      END { printf "OURS %d\nOTHER %d\nNODE %d\n", o, other, node }' "$TMP/ko.$i" >"$TMP/koc.$i"
    touch "$TMP/kotl.$i"; declare -A KO=(); while read -r k v; do KO[$k]=$v; done <"$TMP/koc.$i"
    F[KO_OURS]=$(( ${F[KO_OURS]} + ${KO[OURS]:-0} )); F[KO_OTHER]=$(( ${F[KO_OTHER]} + ${KO[OTHER]:-0} )); F[KO_NODE]=$(( ${F[KO_NODE]} + ${KO[NODE]:-0} ))
    printf '    kernel OOM killer: w kontenerach aplikacji %s, w innych kontenerach %s, brak pamieci calego wezla %s\n' "${KO[OURS]:-0}" "${KO[OTHER]:-0}" "${KO[NODE]:-0}"
    cut -f3 "$TMP/kotl.$i" | sort | uniq -c | sort -rn | head -3 | sed -E 's/^ *([0-9]+) /      \1x  /'
    cat "$TMP/kotl.$i" >>"$TMP/tl.tsv"
    unset KC KO
  done <"$TMP/nodes.txt"
fi

# =============================================================================
# 8. LOGI APLIKACJI (poprzednia instancja kontenera)
# =============================================================================
hdr "8. LOGI APLIKACJI - POPRZEDNIA INSTANCJA KONTENERA (co mowila przed restartem)"
F[AL_JVMOOM]=0; F[AL_CONN]=0; F[AL_SIGTERM]=0; F[AL_ERR]=0; F[AL_DISK]=0; F[AL_PERM]=0; F[AL_DONE]=0
if (( LOGL == 0 )); then echo "  Pominiete (-l 0)."
else
  jq -r '[.items[] | .metadata.name as $p | .status.containerStatuses[]? | select(.restartCount > 0) | {p: $p, c: .name, r: .restartCount}]
         | sort_by(-.r) | .[:3][] | "\(.p)\t\(.c)\t\(.r)"' "$TMP/pods.json" >"$TMP/prev.tsv"
  if [[ ! -s $TMP/prev.tsv ]]; then echo "  Brak kontenerow z restartami wsrod biezacych podow."; fi
  while IFS=$'\t' read -r p c r; do
    sub "$p / $c (restartow: $r)"
    if ! oc_ro logs -n "$NS" "$p" -c "$c" --previous --tail=3000 </dev/null >"$TMP/prev.log" 2>"$TMP/err"; then
      echo "  (brak logu poprzedniej instancji: $(head -c 150 "$TMP/err"))"; continue; fi
    F[AL_DONE]=$(( ${F[AL_DONE]} + 1 ))
    awk '
      /OutOfMemoryError|Java heap space|GC overhead limit|Metaspace|unable to create native thread|Cannot allocate memory|out of memory|MemoryError|heap out of memory/ { jo++ }
      /[Cc]onnection refused|ECONNREFUSED|[Cc]onnection reset|[Tt]imed? ?out|UnknownHost|[Nn]ame or service not known|no such host|could not connect|Unable to connect|503 Service/ { cn++ }
      /SIGTERM|[Ss]hutting down|[Gg]raceful shutdown|[Ss]topping|received signal/ { st++ }
      /No space left on device|[Dd]isk full/ { ds++ }
      /[Pp]ermission denied|[Rr]ead-only file system|AccessDenied/ { pm++ }
      /Exception|ERROR|FATAL|[Pp]anic|Traceback|[Ss]egmentation fault|level=error|"level":"error"/ { er++ }
      END { printf "AL_JVMOOM %d\nAL_CONN %d\nAL_SIGTERM %d\nAL_DISK %d\nAL_PERM %d\nAL_ERR %d\n", jo, cn, st, ds, pm, er }' "$TMP/prev.log" >"$TMP/alc"
    while read -r k v; do F[$k]=$(( ${F[$k]} + v )); done <"$TMP/alc"
    printf '  w ostatnich %s liniach: brak pamieci w aplikacji %s, problemy z polaczeniem %s, zamkniecie na sygnal %s,\n' "$(wc -l <"$TMP/prev.log")" \
      "$(awk '$1=="AL_JVMOOM"{print $2}' "$TMP/alc")" "$(awk '$1=="AL_CONN"{print $2}' "$TMP/alc")" "$(awk '$1=="AL_SIGTERM"{print $2}' "$TMP/alc")"
    printf '  brak miejsca na dysku %s, brak uprawnien %s, bledy/wyjatki %s\n' "$(awk '$1=="AL_DISK"{print $2}' "$TMP/alc")" "$(awk '$1=="AL_PERM"{print $2}' "$TMP/alc")" "$(awk '$1=="AL_ERR"{print $2}' "$TMP/alc")"
    echo "  najczestsze bledy:"
    grep -E 'Exception|ERROR|FATAL|[Pp]anic|Traceback|level=error|"level":"error"|OutOfMemory' "$TMP/prev.log" \
      | sed -E 's/^[0-9TZ:., +-]{10,35}//; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/<ip>/g; s/[0-9a-f]{8}-[0-9a-f-]{27}/<id>/g; s/[0-9]{3,}/N/g' \
      | cut -c1-150 | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
    echo "  ostatnie $LOGL linii:"
    tail -n "$LOGL" "$TMP/prev.log" | cut -c1-220 | sed 's/^/    | /'
  done <"$TMP/prev.tsv"
fi

# =============================================================================
# 9. OS CZASU
# =============================================================================
hdr "9. OS CZASU (wszystkie zrodla, chronologicznie)"
sort -t$'\t' -k1,1n -u "$TMP/tl.tsv" | awk -F'\t' -v t0="$T0" '$1 >= t0' >"$TMP/tls.tsv"
NTL=$(wc -l <"$TMP/tls.tsv")
(( NTL > TLMAX )) && echo "  (pokazano ostatnie $TLMAX z $NTL wpisow)"
tail -n "$TLMAX" "$TMP/tls.tsv" | while IFS=$'\t' read -r t s m; do printf '  %s  %-10s %s\n' "$(fdate "$t")" "$s" "${m:0:170}"; done
(( NTL == 0 )) && echo "  (brak zdarzen)"

# =============================================================================
# 10. ILE ZASOBOW POTRZEBA
# =============================================================================
hdr "10. ILE PAMIECI I CPU APLIKACJA POTRZEBUJE (wyliczenie z ${RDAYS} dni - nic nie jest wdrazane)"
RW="${RDAYS}d"
OWNR="max by (namespace, pod) (max_over_time(kube_pod_info{$PSEL}[$RW]))"
WSC="max by (namespace, pod, container) ($WSQ)"
CPC="max by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{$CSEL}[5m]))"
THC="max by (namespace, pod, container) (rate(container_cpu_cfs_throttled_periods_total{$CSEL}[5m]) / rate(container_cpu_cfs_periods_total{$CSEL}[5m]))"
pq r_mp95 "max by (container) (quantile_over_time(0.95, ($WSC $(J "$OWNI"))[$RW:5m]))"
pq r_mmax "max by (container) (max_over_time($WSQ[$RW]) $(J "$OWNR"))"
pq r_cp95 "max by (container) (quantile_over_time(0.95, ($CPC $(J "$OWNI"))[$RW:5m]))"
pq r_cmax "max by (container) (max_over_time(($CPC $(J "$OWNI"))[$RW:5m]))"
pq r_thr  "max by (container) (max_over_time(($THC $(J "$OWNI"))[$RW:5m])) * 100"
pq r_oome "sum by (container) (increase(container_oom_events_total{$CSEL}[$RW]) $(J "$OWNR"))"
pq r_oomk "max by (container) (max_over_time(kube_pod_container_status_last_terminated_reason{namespace=\"$NS\",reason=\"OOMKilled\"}[$RW]) $(J "$OWNR"))"
pq r_t0   "min(min_over_time(timestamp(max by (namespace) (kube_pod_info{$PSEL}))[$RW:1h]))"
{ printf '{'; for n in mp95 mmax cp95 cmax thr oome oomk t0; do printf '"%s":' "$n"; cat "$TMP/r_$n.json"; printf ','; done
  printf '"grow":'; cat "$TMP/c_grow.json"; printf ',"hpa":'; cat "$TMP/hpa.json"; printf ',"pods":'; cat "$TMP/pods.json"
  printf ',"wl":'; cat "$TMP/wl.json"; printf '}'; } >"$TMP/r_all.json"

# rekomendacja per kontener (wartosci per pod)
#   request pamieci = p95 working set x 1.2           (zaokr. w gore do 64Mi / 256Mi powyzej 1Gi, min. 64Mi)
#   limit pamieci   = maks. working set x 1.2, ale nie mniej niz:
#                     obecny limit x 1.5 gdy byl OOM (szczyt byl ucinany - prawdziwy nieznany),
#                     -Xmx / 0.7 (JVM potrzebuje ~30% poza heapem), request
#   request CPU     = p95 zuzycia CPU (zaokr. do 10m, min. 10m)
#   limit CPU       = bez zmian; "usun lub >= maks. x 1.5" gdy throttling >= 25%
jq --argjson now "$NOW" "$JQDEF"'
  def up(s): (. / s) as $x | (if $x == ($x | floor) then $x else ($x | floor) + 1 end) * s;
  def mup: if . < 1073741824 then up(67108864) else up(268435456) end;
  def bc(n): (.[n].data.result // []) | map(select(.value[1] | num != null) | {k: (.metric.container // ""), v: (.value[1] | num)})
             | group_by(.k) | map({key: .[0].k, value: (map(.v) | max)}) | from_entries;
  . as $a
  | (bc("mp95")) as $p | (bc("mmax")) as $mx | (bc("cp95")) as $cp | (bc("cmax")) as $cm | (bc("thr")) as $th
  | (bc("oome")) as $oe | (bc("oomk")) as $ok | (bc("grow")) as $gr
  | ([$a.t0.data.result[]? | .value[1] | num | select(. != null and . > 0)] | min // $now) as $t0
  | ($a.wl | if .kind == "DaemonSet" then (.status.desiredNumberScheduled // 1)
             elif .kind == "Deployment" or .kind == "StatefulSet" or .kind == "DeploymentConfig" then (.spec.replicas // 1) else 1 end) as $rep
  | {days: (($now - $t0) / 86400), rep: $rep, hmax: ([$a.hpa.items[]?.spec.maxReplicas] | max),
     c: [$a.wl | podspec | .containers[] | . as $c | .name as $n
       | ([$a.pods.items[]?.spec.containers[]? | select(.name == $n)] | .[0].resources // {}) as $pr
       | ([(.env // [])[] | .value // empty] + (.args // []) + (.command // []) | join(" ")) as $all
       | ([$all | capture("-Xmx(?<n>[0-9]+)(?<u>[kKmMgG]?)")] | .[0]) as $x
       | (if $x then ($x.n | tonumber) * ({"": 1, "k": 1024, "K": 1024, "m": 1048576, "M": 1048576, "g": 1073741824, "G": 1073741824} | .[$x.u]) else null end) as $xmx
       | (($c.resources.requests.memory // $pr.requests.memory) | mem) as $rq
       | (($c.resources.limits.memory // $pr.limits.memory) | mem) as $lm
       | (($c.resources.requests.cpu // $pr.requests.cpu) | cpu) as $crq
       | (($c.resources.limits.cpu // $pr.limits.cpu) | cpu) as $clm
       | $p[$n] as $p95 | $mx[$n] as $max | ($th[$n] // 0) as $thr | ($gr[$n] // 0) as $g
       | ((($oe[$n] // 0) | round) + (if ($ok[$n] // 0) > 0 then 1 else 0 end)) as $oom
       | (if $p95 == null then null else ([$p95 * 1.2 | mup, 67108864] | max) end) as $rreq
       | (if $rreq == null then null
          else [(if $max then $max * 1.2 else 0 end), (if $oom > 0 and $lm then $lm * 1.5 else 0 end),
                (if $xmx then $xmx / 0.7 else 0 end), $rreq] | max | mup end) as $rlim
       | (if $cp[$n] == null then null else ([$cp[$n] * 1000 | up(10), 10] | max) / 1000 end) as $rcreq
       | {n: $n, rq: $rq, lm: $lm, crq: $crq, clm: $clm, p95: $p95, max: $max, cp95: $cp[$n], cmax: $cm[$n], thr: $thr,
          oom: $oom, g: $g, xmx: $xmx, rreq: $rreq, rlim: $rlim, rcreq: $rcreq,
          rclim: (if $clm == null then "-" elif $thr >= 25 then "usun lub >=" + (if $cm[$n] then ([$cm[$n] * 1.5, $clm] | max | fc) else "?" end) else ($clm | fc) end),
          conf: (if $p95 == null then "BRAK DANYCH" elif $oom > 0 then "NISKA" elif (($now - $t0) / 86400) < 2 then "SREDNIA" else "DOBRA" end)}]}
  ' "$TMP/r_all.json" >"$TMP/rec.json" 2>"$TMP/err" || { warn "wyliczenie zasobow: $(head -c 300 "$TMP/err")"; echo '{"days":0,"rep":1,"hmax":null,"c":[]}' >"$TMP/rec.json"; }

RDAYS_REAL=$(jq -r '.days * 10 | round / 10' "$TMP/rec.json")
echo "  Dane: ostatnie $RDAYS_REAL dni$(awk -v a="$RDAYS_REAL" -v b="$RDAYS" 'BEGIN{ if (a+0 < b-0.5) print " (tyle ma Prometheus / tyle istnieje workload; zadano " b ")" }'). Wartosci PER POD (jedna replika)."
sub "Pamiec"
{ printf 'KONTENER\tP95\tMAKS\tOOM\tREQUEST\t->ZALECANY\tLIMIT\t->ZALECANY\tPEWNOSC\n'
  jq -r "$JQDEF"'.c[] | [.n, (.p95 | fb), (.max | fb), (.oom | tostring), (.rq | fb), (.rreq | fb), (.lm | fb), (.rlim | fb), .conf] | @tsv' "$TMP/rec.json"
} | table
sub "CPU"
{ printf 'KONTENER\tP95\tMAKS\tTHROTTLE\tREQUEST\t->ZALECANY\tLIMIT\t->ZALECANY\n'
  jq -r "$JQDEF"'.c[] | [.n, (.cp95 | fc), (.cmax | fc), (.thr | fp), (.crq | fc), (.rcreq | fc), (.clm | fc), .rclim] | @tsv' "$TMP/rec.json"
} | table
jq -r "$JQDEF"'.c[] | .n as $n
  | (if .oom > 0 then "  \($n): byl OOM (\(.oom)) - zmierzone maksimum jest UCIETE na limicie \(.lm | fb), prawdziwy szczyt jest wyzszy. Zalecany limit (+50%) to punkt startowy - po zmianie uruchom skrypt ponownie i sprawdz, czy MAKS ustabilizowal sie ponizej limitu." else empty end),
    (if .xmx then "  \($n): JVM -Xmx \(.xmx | fb) - limit musi miec ~30% zapasu poza heapem (metaspace, watki, bufory): min. \(.xmx / 0.7 | fb)." else empty end),
    (if .g >= 5242880 then "  \($n): pamiec rosnie ok. \(.g / 1048576 | round) MiB/h - jesli to wyciek, wyzszy limit tylko opozni OOM; najpierw zespol aplikacji (heap dump / profil)." else empty end),
    (if .lm and .rlim and .rlim < .lm * 0.7 and .oom == 0 then "  \($n): obecny limit \(.lm | fb) ma duzy zapas wzgledem maks. \(.max | fb) - mozna obnizyc do \(.rlim | fb), jesli okno \("'"$RDAYS"'") dni obejmuje typowe szczyty (koniec miesiaca, batch)." else empty end)' "$TMP/rec.json"
jq -r "$JQDEF"'
  ([.c[] | .rreq // 0] | add // 0) as $nr | ([.c[] | .rq // 0] | add // 0) as $cr
  | ([.c[] | .rlim // 0] | add // 0) as $nl
  | "  Lacznie na pod: request \($cr | fb) -> \($nr | fb), limit -> \($nl | fb).",
    "  Lacznie dla workloadu (replik: \(.rep)): request \($cr * .rep | fb) -> \($nr * .rep | fb)" + (if .hmax then "; przy maks. HPA (replik: \(.hmax)): \($nr * .hmax | fb)" else "" end) + " - tyle pamieci scheduler musi znalezc na workerach."' "$TMP/rec.json"
echo "  Wzor: request = p95 x 1.2; limit = maks. x 1.2 (min. obecny limit x 1.5 po OOM, min. -Xmx/0.7); CPU request = p95;"
echo "  limit CPU: zostaw, chyba ze throttling >= 25% (wtedy usun albo podnies). Init-kontenery pominiete."
echo "  To propozycja z metryk - okno ${RDAYS} dni musi obejmowac typowe szczyty; zmiane wprowadza zespol aplikacji."

while IFS=$'\t' read -r lv sd tx; do finding "$lv" "$sd" "$tx"; done < <(jq -r "$JQDEF"'.c[] | . as $c
  | (if .lm and .rlim and .rlim > .lm * 1.1 then ["OSTR", "KONFIG", "Kontener \(.n): limit pamieci za niski - teraz \(.lm | fb), potrzeba ok. \(.rlim | fb) (p95 \(.p95 | fb), maks. \(.max | fb)\(if .oom > 0 then ", byl OOM - maks. uciete na limicie" else "" end)). Szczegoly w sekcji 10."] else empty end),
    (if .lm == null and .rlim then ["INFO", "KONFIG", "Kontener \(.n): brak limitu pamieci - na podstawie zuzycia ustaw ok. \(.rlim | fb)."] else empty end),
    (if .rq and .p95 and .p95 > .rq * 1.1 then ["OSTR", "KONFIG", "Kontener \(.n): request pamieci \(.rq | fb) ponizej realnego zuzycia (p95 \(.p95 | fb)) - scheduler upycha pody na workerach, ktore nie maja tyle pamieci; zalecane \(.rreq | fb)."] else empty end),
    (if .rq == null and .rreq then ["INFO", "KONFIG", "Kontener \(.n): brak requestu pamieci - ustaw ok. \(.rreq | fb)."] else empty end),
    (if .rq and .rreq and .oom == 0 and .rreq * 2 < .rq then ["INFO", "KONFIG", "Kontener \(.n): request pamieci \(.rq | fb) ponad 2x wiekszy niz potrzeba (p95 \(.p95 | fb)) - blokuje pojemnosc workerow; wystarczy ok. \(.rreq | fb)."] else empty end)
  | @tsv' "$TMP/rec.json")

# =============================================================================
# 11. PRZYCZYNY, PROBLEMY, WNIOSKI
# =============================================================================
hdr "11. PRZYCZYNY, PROBLEMY I WNIOSKI"
RST=$(fv RST_TOTAL); RST=${RST:-0}
OOMN=$(( $(fn OOM_KSM) + $(fn OOM_API) + ${F[KO_OURS]} ))
(( $(fn OOM_EVENTS) > OOMN )) && OOMN=$(fn OOM_EVENTS)
LIVK=$(( ${F[KL_LIVKILL]} + ${F[KL_STKILL]} ))
(( ${F[EV_LIVKILL]} > LIVK )) && LIVK=${F[EV_LIVKILL]}
(( LIVK == 0 && ${F[EV_LIVENESS]} > 0 )) && LIVK=$(( F[EV_LIVENESS] / 3 + 1 ))
ERRN=$(fn ERR_KSM); [[ -n $(fv EXITS_ERR) ]] && ERRN=$(( ERRN + 1 ))
# bezposrednie dowody (OOM wezla, ewikcje, kontener "Unknown" po restarcie workera) waza 3x, kontekst (reboot/NotReady/presja) 1x
NODEP=$(( (${F[KO_NODE]} + NEVICT + $(fn UNK_KSM)) * 3 + $(fn N_REBOOT) + $(fn N_NOTREADY) ))
[[ -n $(fv N_PRESS) ]] && NODEP=$((NODEP + 1))

# --- restarty: glowna przyczyna
if (( RST == 0 && $(fn RST_API) == 0 )); then
  finding OK - "Brak restartow kontenerow w oknie ${HOURS}h."
else
  finding "$( (( RST >= 10 )) && echo KRYT || echo OSTR )" - "Restarty w oknie ${HOURS}h: $RST (w $(fv H_RST_HOURS) godzinach; najwiecej $(fv H_RST_PEAK_V) w godzinie konczacej sie o $( [[ -n $(fv H_RST_PEAK_T) ]] && fdate "$(fv H_RST_PEAK_T)" || echo '?'))."
  if (( OOMN > 0 )); then
    msg="OOMKilled: kontener przekroczyl LIMIT PAMIECI (dowody: zakonczenia OOMKilled, kernel OOM w cgroup kontenera: ${F[KO_OURS]})."
    [[ -n $(fv MEM_PCT) ]] && msg+=" Maks. zuzycie $(fmem "$(fv MEM_PCT_W)") = $(fn MEM_PCT)% limitu $(fmem "$(fv MEM_PCT_L)") ($(fv MEM_PCT_K))."
    finding KRYT APLIKACJA "$msg"
    if [[ -n $(fv GROW_MBH) ]] && ge "$(fv GROW_MBH)" 5; then
      finding OSTR APLIKACJA "Pamiec stale rosnie (ok. $(fv GROW_MBH) MiB/h w $(fv GROW_K)$([[ -n $(fv GROW_ETA) ]] && echo ", limit za ok. $(fv GROW_ETA)h")) - wzorzec wycieku pamieci lub rosnacego cache w aplikacji: kontener rosnie az do limitu i jest zabijany. Do sprawdzenia przez zespol aplikacji (heap dump / profil pamieci)."
    elif ge "$(fv H_NET_PEAK_X)" 2 && [[ $(fv H_NET_PEAK_T) == "$(fv H_MEM_PEAK_T)" ]]; then
      finding OSTR APLIKACJA "Szczyt pamieci pokrywa sie ze szczytem ruchu ($(fv H_NET_PEAK_X)x mediany o $(fdate "$(fv H_NET_PEAK_T)")) - zuzycie rosnie z obciazeniem; limit nie ma zapasu na szczyt ruchu (podnies limit lub dodaj repliki/HPA)."
    else
      finding INFO APLIKACJA "Pamiec nie rosnie liniowo i nie koreluje wyraznie z ruchem - prawdopodobnie skoki zuzycia (duze zadania, batch, cache, GC) albo limit po prostu za niski dla normalnej pracy."
    fi
    [[ -n $(fv MEM_RSS_RATIO) ]] && (( $(fn MEM_RSS_RATIO) < 60 )) && \
      finding INFO APLIKACJA "W working set tylko $(fn MEM_RSS_RATIO)% to RSS procesu - reszta to page cache / tmpfs (pliki, emptyDir w RAM, logi do pliku). Sprawdz zapisy do plikow i emptyDir medium: Memory."
  fi
  if (( LIVK > 0 )); then
    msg="Kubelet zabijal kontener po nieudanych probe (logi kubeleta - liveness: ${F[KL_LIVKILL]}, startup: ${F[KL_STKILL]}; eventy Killing: ${F[EV_LIVKILL]}, Unhealthy liveness: ${F[EV_LIVENESS]}) - aplikacja nie odpowiadala na probe w czasie."
    finding KRYT APLIKACJA "$msg"
    if ge "$(fv THR_MAX)" 25; then
      finding OSTR APLIKACJA "Throttling CPU dochodzil do $(fv THR_MAX)% - limit CPU dlawi kontener, probe nie dostaje odpowiedzi w timeoutSeconds=$(fv LIV_TIMEOUT)s. Podnies/usun limit CPU albo zwieksz timeoutSeconds/failureThreshold probe."
    fi
    (( ${F[KL_TIMEOUT]} + ${F[EV_PROBE_TIMEOUT]} > 0 )) && \
      finding INFO APLIKACJA "Nieudane probe to glownie TIMEOUTY (${F[KL_TIMEOUT]} w logach kubeleta) - aplikacja byla zajeta/zawieszona (GC, pula watkow, blokada na zaleznosci), a nie zwracala bledu."
    if [[ $(fv HAS_STARTUP) == 0 && -n $(fv START_MAX) && -n $(fv LIV_BUDGET) ]] && ge "$(fv START_MAX)" "$(awk -v b="$(fv LIV_BUDGET)" 'BEGIN{print b*0.5}')"; then
      finding OSTR KONFIG "Start trwa do $(fv START_MAX)s, a budzet liveness to $(fv LIV_BUDGET)s i brak startupProbe - przy wolniejszym starcie (obciazony worker) kubelet zabije kontener w trakcie startu (petla restartow). Dodaj startupProbe."
    fi
    ge "$(fv N_LOAD)" 1.5 && finding OSTR PLATFORMA "Worker byl przeciazony (load15/rdzen do $(fv N_LOAD)) - moze spowalniac odpowiedzi na probe."
  elif (( $(fn K137_API) > 0 && OOMN == 0 )); then
    finding OSTR APLIKACJA "Kontenery konczone SIGKILL (exit 137) bez OOMKilled ($(fn K137_API)) - typowo zabicie przez kubelet po liveness lub po przekroczeniu terminationGracePeriod przy zatrzymaniu. Brak logow kubeleta, by to rozstrzygnac$( (( NL_DONE == 0 )) && echo " (logi workerow nie byly czytane)")."
  fi
  if (( ERRN > 0 )); then
    msg="Proces aplikacji sam konczyl sie bledem (Error$( [[ -n $(fv EXITS_ERR) ]] && echo ", kody wyjscia: $(fv EXITS_ERR)")) - przyczyna jest w kodzie/konfiguracji aplikacji lub jej zaleznosciach."
    (( ${F[AL_CONN]} > 0 )) && msg+=" W logach poprzedniej instancji widac problemy z polaczeniem (${F[AL_CONN]}) - aplikacja konczy sie, gdy zaleznosc (baza, kolejka, inna usluga) nie odpowiada."
    (( ${F[AL_JVMOOM]} > 0 )) && msg+=" W logach jest brak pamieci wewnatrz aplikacji (${F[AL_JVMOOM]}, np. OutOfMemoryError) - heap/limit za maly albo wyciek."
    (( ${F[AL_DISK]} > 0 )) && msg+=" Brak miejsca na dysku (${F[AL_DISK]})."
    (( ${F[AL_PERM]} > 0 )) && msg+=" Bledy uprawnien / systemu plikow tylko do odczytu (${F[AL_PERM]})."
    finding KRYT APLIKACJA "$msg"
  fi
  if (( $(fn K143_API) > 0 || $(fn COMPL_KSM) > 0 )); then
    finding INFO - "Czesc zakonczen to SIGTERM/Completed ($(fn K143_API)/$(fn COMPL_KSM)) - zatrzymanie na zadanie (wdrozenie, skalowanie, drain, ewikcja) albo proces sam sie zakonczyl z kodem 0, a nie awaria."
  fi
  [[ -n $(fv WAITS) ]] && finding OSTR APLIKACJA "Stany oczekiwania kontenerow w oknie: $(fv WAITS) (CrashLoopBackOff = powtarzajace sie awarie; ImagePull/CreateContainerConfigError = problem konfiguracji)."
  [[ -n $(fv OTHER_REASONS) ]] && finding INFO - "Inne powody zakonczen: $(fv OTHER_REASONS)."
fi

# --- pamiec / CPU bez restartow
if (( OOMN == 0 )) && [[ -n $(fv MEM_PCT) ]] && (( $(fn MEM_PCT) >= 90 )); then
  finding OSTR APLIKACJA "Pamiec dochodzila do $(fn MEM_PCT)% limitu ($(fv MEM_PCT_K)) - bez zapasu, kolejny wzrost skonczy sie OOMKilled."
fi
if (( OOMN == 0 )) && [[ -n $(fv GROW_MBH) ]] && ge "$(fv GROW_MBH)" 20; then
  finding OSTR APLIKACJA "Pamiec rosnie ok. $(fv GROW_MBH) MiB/h ($(fv GROW_K))$([[ -n $(fv GROW_ETA) ]] && echo " - limit za ok. $(fv GROW_ETA)h") - obserwuj, mozliwy wyciek."
fi
(( $(fn NOLIM_MEM) > 0 )) && finding OSTR KONFIG "Kontenery bez limitu pamieci: $(fn NOLIM_MEM) - przy wycieku zjedza pamiec workera (OOM calego wezla zamiast jednego kontenera)."
(( $(fn NOREQ_MEM) > 0 )) && finding OSTR KONFIG "Kontenery bez requestu pamieci: $(fn NOREQ_MEM) - scheduler nie wie, ile pamieci potrzebuja; przy braku pamieci sa ewakuowane pierwsze."
if (( LIVK == 0 )) && ge "$(fv THR_MAX)" 50; then
  finding INFO APLIKACJA "Throttling CPU dochodzil do $(fv THR_MAX)% (CPU uzycie do $(fv CPU_PCT)% limitu) - spowalnia aplikacje (zwlaszcza start i szczyty)."
fi
[[ -n $(fv H_NET_PEAK_X) ]] && ge "$(fv H_NET_PEAK_X)" 3 && finding INFO - "Ruch przychodzacy mial szczyt $(fv H_NET_PEAK_X)x mediany (godzina konczaca sie o $(fdate "$(fv H_NET_PEAK_T)")) - porownaj z restartami i zuzyciem w sekcji 4."
[[ -n $(fv THD_MAX) ]] && (( $(fn THD_MAX) >= 1000 )) && finding INFO APLIKACJA "Liczba watkow do $(fn THD_MAX) - kazdy watek to stos (ok. 1 MiB) poza heapem; rosnaca liczba watkow to typowy wyciek."

# --- platforma
(( ${F[KO_NODE]} > 0 )) && finding KRYT PLATFORMA "Na workerach aplikacji OOM killer dzialal z powodu braku pamieci CALEGO WEZLA (${F[KO_NODE]}) - to nie limit kontenera, tylko przepelniony worker (za niskie requesty podow, za male rezerwacje systemowe)."
(( $(fn N_REBOOT) > 0 )) && finding OSTR PLATFORMA "Reboot workera w oknie ($(fn N_REBOOT)) - pody zostaly uruchomione ponownie (aktualizacja MCO / awaria)."
(( $(fn N_NOTREADY) > 0 )) && finding OSTR PLATFORMA "Worker byl NotReady w oknie ($(fn N_NOTREADY)) - kubelet nie raportowal, pody mogly byc ewakuowane lub restartowane."
[[ -n $(fv N_PRESS) ]] && finding OSTR PLATFORMA "Presja zasobow na workerach: $(fv N_PRESS) - kubelet ewakuuje pody (najpierw te przekraczajace requesty)."
(( $(fn UNK_KSM) > 0 )) && finding OSTR PLATFORMA "Kontenery zakonczone ze stanem Unknown/ContainerStatusUnknown ($(fn UNK_KSM)) - kontener zginal razem z workerem (reboot, awaria, utrata kontaktu), a nie z winy aplikacji."
(( NEVICT > 0 )) && finding OSTR PLATFORMA "Ewikcje podow aplikacji: $NEVICT - worker mial brak pamieci/dysku; pody przekraczajace request pamieci ida pierwsze."
[[ -n $(fv N_MEMMAX) ]] && (( $(fn N_MEMMAX) >= 95 )) && finding OSTR PLATFORMA "Pamiec workera dochodzila do $(fn N_MEMMAX)% - worker bez zapasu."
[[ -n $(fv N_STEAL) ]] && (( $(fn N_STEAL) >= 10 )) && finding OSTR PLATFORMA "Steal time do $(fn N_STEAL)% - VM workera czeka na CPU hosta (wirtualizacja przeciazona)."
(( ${F[KO_OTHER]} > 0 && ${F[KO_OURS]} == 0 )) && finding INFO PLATFORMA "Na workerach byly zabicia OOM innych kontenerow (${F[KO_OTHER]}) - nie dotyczyly tej aplikacji."
(( ${F[EV_FailedScheduling]:-0} > 0 )) && finding OSTR PLATFORMA "FailedScheduling (${F[EV_FailedScheduling]}) - brak workera spelniajacego requesty/selektory; pody czekaly na miejsce."
(( ${F[KL_MOUNT]} + ${F[EV_FailedMount]:-0} > 0 )) && finding OSTR PLATFORMA "Problemy z montowaniem wolumenow ($(( F[KL_MOUNT] + ${F[EV_FailedMount]:-0} ))) - wydluzaja start / blokuja pody."
(( NODELOGS && NL_DONE == 0 && NNODES > 0 )) && finding INFO - "Logi workerow nie zostaly odczytane (brak uprawnien?) - wnioski o zabiciach przez kubelet i kernel opieraja sie tylko na metrykach i eventach."

# --- wypisanie
for side in "KRYT" "OSTR" "INFO" "OK"; do
  case $side in KRYT) t="KRYTYCZNE";; OSTR) t="OSTRZEZENIA";; INFO) t="INFORMACJE";; OK) t="W PORZADKU";; esac
  n=$(awk -F'\t' -v s="$side" '$1==s' "$TMP/findings" | wc -l); (( n == 0 )) && continue
  sub "$t ($n)"
  awk -F'\t' -v s="$side" '$1==s { print ($2 == "-" ? "" : "[" $2 "] ") $3 }' "$TMP/findings" | while IFS= read -r l; do say "$l"; echo; done
done

sub "NAJBARDZIEJ PRAWDOPODOBNA PRZYCZYNA RESTARTOW"
if (( RST == 0 && $(fn RST_API) == 0 )); then
  say "Restartow nie bylo. Jesli aplikacja zle dziala, sprawdz sekcje 4 (zuzycie) i 6 (eventy)."
else
  best="nieustalona"; why=""
  sc_oom=$(( OOMN * 3 )); sc_liv=$(( LIVK * 2 )); sc_err=$(( ERRN * 2 + F[AL_CONN] / 50 )); sc_node=$NODEP
  max=0
  (( sc_oom  > max )) && { max=$sc_oom;  best="BRAK PAMIECI W LIMICIE KONTENERA (OOMKilled) - strona APLIKACJI"; why="Kontener zuzywa wiecej pamieci niz pozwala limit. Dzialanie: ustal, czy to wzrost z ruchem (podnies limit/HPA), wyciek (zespol aplikacji, heap dump) czy zle ustawione -Xmx/MaxRAMPercentage. Ile pamieci potrzeba - sekcja 10."; }
  (( sc_liv  > max )) && { max=$sc_liv;  best="ZABIJANIE PRZEZ KUBELET PO NIEUDANEJ PROBE LIVENESS/STARTUP - strona APLIKACJI/KONFIGURACJI probe"; why="Aplikacja nie odpowiada na probe w zadanym czasie. Dzialanie: sprawdz co ja blokuje (throttling CPU, GC, zaleznosci), dodaj startupProbe, zwieksz timeoutSeconds/failureThreshold; liveness nie powinna sprawdzac zaleznosci zewnetrznych."; }
  (( sc_err  > max )) && { max=$sc_err;  best="PROCES APLIKACJI KONCZY SIE BLEDEM - strona APLIKACJI"; why="Kontener sam sie zamyka z kodem bledu. Dzialanie: logi poprzedniej instancji (sekcja 8) - wyjatek, brak zaleznosci, konfiguracja."; }
  (( sc_node > max )) && { max=$sc_node; best="PROBLEM WORKERA (brak pamieci wezla / reboot / NotReady / ewikcja) - strona PLATFORMY"; why="Pody gina z powodu stanu workera, nie aplikacji. Dzialanie: sekcja 5 i 7 - pamiec i rezerwacje workera, requesty podow na nim, przyczyna rebootu/NotReady."; }
  if (( max == 0 )); then
    say "Nie udalo sie jednoznacznie ustalic przyczyny na podstawie metryk i eventow (eventy znikaja po ok. 3h, API pamieta tylko ostatnie zakonczenie). Uruchom skrypt z uprawnieniami do logow workerow (bez -N) i/lub zaraz po kolejnym restarcie."
  else
    say "$best"; say "$why"
    echo
    say "Wagi dowodow: OOM=$sc_oom, probe=$sc_liv, blad aplikacji=$sc_err, worker=$sc_node (im wiecej, tym wiecej niezaleznych sladow)."
  fi
fi
echo
echo "Koniec audytu. Nic nie zostalo zmienione w klastrze."
