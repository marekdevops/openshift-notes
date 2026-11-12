#!/usr/bin/env bash
# =============================================================================
# infra-traffic-audit.sh - audyt pamieci i ruchu na infranode'ach OpenShift
#
# TYLKO ODCZYT. Skrypt wykonuje wylacznie:
#   - oc get / oc whoami / oc logs            (funkcja oc_ro blokuje inne czasowniki)
#   - HTTP GET do API zapytan Prometheusa     (route thanos-querier)
# Nie uzywa: oc debug, oc exec, oc create token, oc apply/patch/delete.
# Pliki tymczasowe powstaja tylko lokalnie (mktemp) i sa usuwane na koncu.
#
# Jak dziala:
#   1. Znajduje infranode'y i pobiera przebieg zuzycia pamieci w zadanym oknie.
#   2. Wyznacza SZCZYT (max pamieci) i BAZE (minimum przed szczytem) na wezle
#      o najwiekszym skoku.
#   3. Porownuje BAZA vs SZCZYT: pody, namespace'y, slice'y systemowe, pamiec
#      jadra, ruch na routerach (namespace / route / pod docelowy), siec podow.
#   4. Opcjonalnie: zrodlowe IP z access logow routera (jesli sa wlaczone).
#
# Wymagania: oc, jq, curl, column, GNU date. Zalogowanie tokenem (oc login --token)
# albo zmienna TOKEN. Uprawnienia: cluster-reader + cluster-monitoring-view wystarcza.
# =============================================================================
set -uo pipefail

WINDOW="6h"; TOPN=15; SELECTOR="node-role.kubernetes.io/infra"; END_STR="now"
RATE="5m"; CURL_K=""; FOCUS=""; PEAK_STR=""; BASE_STR=""; NODE_DEV_RE="br-ex"
ACCESS_LOGS=1

usage() { cat <<EOF
Uzycie: $0 [opcje]
  -w OKNO      okno analizy wstecz od konca, np. 90m, 6h, 2d   (domyslnie: $WINDOW)
  -e CZAS      koniec okna, np. "2026-11-12 14:00"             (domyslnie: teraz)
  -p CZAS      wymus moment SZCZYTU (zamiast autodetekcji)
  -b CZAS      wymus moment BAZY do porownania
  -n WEZEL     wymus wezel, na ktorym szukac szczytu
  -l SELEKTOR  selektor etykiet infranode'ow                   (domyslnie: $SELECTOR)
  -t N         liczba wierszy w zestawieniach                  (domyslnie: $TOPN)
  -r ZAKRES    okno rate() dla ruchu                           (domyslnie: $RATE)
  -d REGEX     interfejs sieciowy wezla do pomiaru ruchu       (domyslnie: $NODE_DEV_RE)
  -k           nie weryfikuj certyfikatu TLS route'a thanos-querier
  -A           pomin analize access logow routera
Przyklad:  $0 -w 8h -t 20 -k | tee raport-\$(date +%F_%H%M).txt
EOF
exit "${1:-0}"; }

while getopts "w:e:p:b:n:l:t:r:d:kAh" o; do case $o in
  w) WINDOW=$OPTARG;; e) END_STR=$OPTARG;; p) PEAK_STR=$OPTARG;; b) BASE_STR=$OPTARG;;
  n) FOCUS=$OPTARG;; l) SELECTOR=$OPTARG;; t) TOPN=$OPTARG;; r) RATE=$OPTARG;;
  d) NODE_DEV_RE=$OPTARG;; k) CURL_K="-k";; A) ACCESS_LOGS=0;; h) usage 0;; *) usage 1;;
esac; done

die()  { echo "BLAD: $*" >&2; exit 1; }
warn() { echo "UWAGA: $*" >&2; }
hdr()  { printf '\n%s\n== %s\n%s\n' "$LINE" "$1" "$LINE"; }
sub()  { printf '\n--- %s\n' "$1"; }
LINE=$(printf '=%.0s' {1..100})

# Jedyna droga do klastra - tylko czasowniki odczytu.
oc_ro() { case "${1:-}" in get|whoami|logs) command oc "$@";;
          *) die "oc_ro: zablokowano 'oc $1' (skrypt jest tylko do odczytu)";; esac; }

for c in oc jq curl column date; do command -v "$c" >/dev/null || die "brak polecenia: $c"; done

to_sec() { case $1 in *d) echo $(( ${1%d}*86400 ));; *h) echo $(( ${1%h}*3600 ));;
                      *m) echo $(( ${1%m}*60 ));; *) die "zly format okna: $1 (np. 90m, 6h, 2d)";; esac; }
ts()  { date -d "$1" +%s 2>/dev/null || die "nie rozumiem czasu: $1"; }
fts() { date -d "@$1" '+%Y-%m-%d %H:%M'; }

WIN_S=$(to_sec "$WINDOW"); T_END=$(ts "$END_STR"); T_START=$(( T_END - WIN_S ))
STEP=$(( WIN_S / 300 )); (( STEP < 30 )) && STEP=30

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- dostep ------------------------------------------------------------------
oc_ro whoami >/dev/null 2>&1 || die "brak sesji oc - zaloguj sie do klastra"
TOKEN=${TOKEN:-$(oc_ro whoami -t 2>/dev/null || true)}
[[ -n $TOKEN ]] || die "brak tokenu (logowanie certyfikatem?). Uzyj 'oc login --token=...' albo ustaw zmienna TOKEN"
THANOS=$(oc_ro get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
[[ -n $THANOS ]] || die "nie znaleziono route thanos-querier w openshift-monitoring"

EMPTY='{"status":"success","data":{"result":[]}}'
prom() { # $1=query|query_range  $2=plik wynikowy  reszta: parametry
  local ep=$1 out=$2; shift 2; local args=() p
  for p in "$@"; do args+=(--data-urlencode "$p"); done
  # shellcheck disable=SC2086
  if ! curl -sS $CURL_K --max-time 120 -G -H "Authorization: Bearer $TOKEN" \
        "${args[@]}" "https://$THANOS/api/v1/$ep" >"$out" 2>"$TMP/err"; then
    warn "curl: $(cat "$TMP/err") $([[ -z $CURL_K ]] && echo '(problem z certyfikatem? sprobuj -k)')"
    echo "$EMPTY" >"$out"; return 1
  fi
  jq -e '.status=="success"' "$out" >/dev/null 2>&1 || {
    warn "zapytanie odrzucone: $(head -c 300 "$out") :: ${1}"; echo "$EMPTY" >"$out"; return 1; }
}

JQ_DEFS='
def r2: (.*100|round)/100;
def hb: (if .<0 then "-" else "" end) as $s | (if .<0 then (0 - .) else . end) as $v |
  if   $v>=1073741824 then "\($s)\($v/1073741824|r2) GiB"
  elif $v>=1048576    then "\($s)\(($v/1048576*10|round)/10) MiB"
  elif $v>=1024       then "\($s)\(($v/1024*10|round)/10) KiB"
  else "\($s)\($v|round) B" end;
def fmt($u): if $u=="bytes" then hb elif $u=="bps" then (hb+"/s")
             elif $u=="rate" then ((r2|tostring)+"/s") else (r2|tostring) end;
def key($keys): . as $m | [$keys|split(",")[] | ($m[.] // "-")] | join("\t");
def tomap($keys): reduce .[0].data.result[] as $r ({};
      .[$r.metric|key($keys)] = ($r.value[1]|tonumber));
'
table() { local rows; rows=$(cat)
  if [[ $(wc -l <<<"$rows") -le 1 ]]; then echo "  (brak danych)"; else column -t -s $'\t' <<<"$rows" | sed 's/^/  /'; fi; }
keyhdr() { tr 'a-z,' 'A-Z\t' <<<"$1" | sed 's/EXPORTED_//g'; }

# Porownanie BAZA vs SZCZYT.  $1=tytul $2=etykiety $3=jednostka $4=sort(delta|peak) $5=PromQL
compare() {
  sub "$1"
  prom query "$TMP/b.json" "query=$5" "time=$T_BASE"
  prom query "$TMP/p.json" "query=$5" "time=$T_PEAK"
  { printf '%s\tBAZA\tSZCZYT\tZMIANA\tKROTNOSC\n' "$(keyhdr "$2")"
    jq -rn --slurpfile b "$TMP/b.json" --slurpfile p "$TMP/p.json" \
       --arg keys "$2" --arg unit "$3" --arg sort "$4" --argjson n "$TOPN" "$JQ_DEFS"'
      ($b|tomap($keys)) as $bm | ($p|tomap($keys)) as $pm
      | [ ($bm+$pm|keys[]) as $k | {k:$k, b:($bm[$k]//0), p:($pm[$k]//0)} | .d=(.p-.b) ]
      | (if $sort=="peak" then sort_by(-.p) else sort_by(-.d) end) | .[:$n][]
      | (.k|split("\t")) + [(.b|fmt($unit)), (.p|fmt($unit)),
         ((if .d>0 then "+" else "" end)+(.d|fmt($unit))),
         (if .b>0 then ((.p/.b|r2|tostring)+"x") elif .p>0 then "nowe" else "-" end)] | @tsv'
  } | table
}
# Pojedynczy odczyt.  $1=tytul $2=etykiety $3=jednostka $4=PromQL $5=czas
show() {
  sub "$1"
  prom query "$TMP/s.json" "query=$4" "time=$5"
  { printf '%s\tWARTOSC\n' "$(keyhdr "$2")"
    jq -rn --slurpfile s "$TMP/s.json" --arg keys "$2" --arg unit "$3" --argjson n "$TOPN" "$JQ_DEFS"'
      [$s[0].data.result[] | {k:(.metric|key($keys)), v:(.value[1]|tonumber)}]
      | sort_by(-.v) | .[:$n][] | (.k|split("\t")) + [(.v|fmt($unit))] | @tsv'
  } | table
}

# --- 1. wezly ------------------------------------------------------------------
mapfile -t NODES < <(oc_ro get nodes -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
(( ${#NODES[@]} )) || die "brak wezlow dla selektora '$SELECTOR' (uzyj -l)"
NODE_RE=$(IFS='|'; echo "${NODES[*]}")

echo "$LINE"
echo "AUDYT PAMIECI I RUCHU NA INFRANODE'ACH  (tryb: tylko odczyt)"
echo "Klaster : $(oc_ro whoami --show-server)   uzytkownik: $(oc_ro whoami)"
echo "Okno    : $(fts "$T_START") -> $(fts "$T_END")  ($WINDOW, krok ${STEP}s)   wygenerowano: $(date '+%F %T %Z')"
echo "Wezly   : ${NODES[*]}"

hdr "1. PAMIEC WEZLOW W OKNIE  (uzyte = MemTotal - MemAvailable)"
prom query_range "$TMP/range.json" \
  "query=node_memory_MemTotal_bytes{instance=~\"$NODE_RE\"} - node_memory_MemAvailable_bytes{instance=~\"$NODE_RE\"}" \
  "start=$T_START" "end=$T_END" "step=$STEP"
prom query "$TMP/total.json" "query=node_memory_MemTotal_bytes{instance=~\"$NODE_RE\"}" "time=$T_END"

jq -n --slurpfile r "$TMP/range.json" --slurpfile t "$TMP/total.json" '
  (reduce $t[0].data.result[] as $x ({}; .[$x.metric.instance]=($x.value[1]|tonumber))) as $tot
  | [ $r[0].data.result[] | .metric.instance as $i
      | [.values[] | [(.[0]|floor), (.[1]|tonumber)]] as $v
      | ($v|max_by(.[1])) as $mx
      | ([$v[]|select(.[0] <= $mx[0])]|min_by(.[1])) as $mn
      | {node:$i, total:($tot[$i]//0), min:($v|map(.[1])|min), avg:($v|map(.[1])|add/length),
         max:$mx[1], last:($v|last|.[1]), swing:($mx[1]-$mn[1]), tpeak:$mx[0], tbase:$mn[0]} ]' >"$TMP/nodes.json"
[[ $(jq length "$TMP/nodes.json") -gt 0 ]] || die "brak metryk node_memory_* dla wezlow: $NODE_RE"

{ printf 'WEZEL\tRAM\tMIN\tSREDNIO\tMAX\t%%RAM\tNA KONCU\tSKOK\tDOLEK PRZED\tSZCZYT\n'
  jq -r "$JQ_DEFS"'sort_by(-.swing)[] | [.node, (.total|hb), (.min|hb), (.avg|hb), (.max|hb),
     (if .total>0 then "\(.max/.total*100|round)%" else "-" end), (.last|hb), ("+"+(.swing|hb)),
     (.tbase|strflocaltime("%m-%d %H:%M")), (.tpeak|strflocaltime("%m-%d %H:%M"))] | @tsv' "$TMP/nodes.json"
} | table

[[ -n $FOCUS ]] || FOCUS=$(jq -r 'max_by(.swing).node' "$TMP/nodes.json")
jq -e --arg n "$FOCUS" 'any(.[]; .node==$n)' "$TMP/nodes.json" >/dev/null || die "wezel '$FOCUS' nie jest na liscie infranode'ow"
T_PEAK=$(jq -r --arg n "$FOCUS" '.[]|select(.node==$n).tpeak' "$TMP/nodes.json")
T_BASE=$(jq -r --arg n "$FOCUS" '.[]|select(.node==$n).tbase' "$TMP/nodes.json")
[[ -n $PEAK_STR ]] && T_PEAK=$(ts "$PEAK_STR")
[[ -n $BASE_STR ]] && T_BASE=$(ts "$BASE_STR")
(( T_BASE >= T_PEAK )) && T_BASE=$T_START

echo
echo "  >>> Wezel z najwiekszym skokiem: $FOCUS"
echo "  >>> Porownanie ponizej:  BAZA = $(fts "$T_BASE")   SZCZYT = $(fts "$T_PEAK")"
echo "      (zmiana przez -p / -b / -n; tabele sortowane wg ZMIANY, czyli kto urosl najbardziej)"

NF="node=~\"$NODE_RE\""; CF="$NF,container!=\"\",container!=\"POD\""

# --- 2. kto zjadl pamiec --------------------------------------------------------
hdr "2. CO KONSUMUJE PAMIEC  (BAZA vs SZCZYT, wszystkie infranode'y)"
compare "Pody - najwiekszy WZROST pamieci (working set)" "node,namespace,pod" bytes delta \
  "sum by (node,namespace,pod)(container_memory_working_set_bytes{$CF})"
compare "Pody - najwieksze zuzycie w SZCZYCIE" "node,namespace,pod" bytes peak \
  "sum by (node,namespace,pod)(container_memory_working_set_bytes{$CF})"
compare "Namespace'y - wzrost pamieci" "node,namespace" bytes delta \
  "sum by (node,namespace)(container_memory_working_set_bytes{$CF})"
compare "Pody vs system (RSS; system.slice to m.in. kubelet, crio, ovs - patrz SystemMemoryExceedsReservation)" "node,id" bytes delta \
  "container_memory_rss{$NF,id=~\"/system.slice|/kubepods.slice\"}"
compare "Uslugi w system.slice (RSS)" "node,id" bytes delta \
  "container_memory_rss{$NF,id=~\"/system.slice/.+\"}"

IF="instance=~\"$NODE_RE\""
sub "Rozbicie pamieci jadra na wezlach (Slab/SUnreclaim rosnie zwykle razem z liczba polaczen)"
for m in AnonPages Cached Shmem SUnreclaim SReclaimable; do
  prom query "$TMP/b.json" "query=node_memory_${m}_bytes{$IF}" "time=$T_BASE"
  prom query "$TMP/p.json" "query=node_memory_${m}_bytes{$IF}" "time=$T_PEAK"
  jq -rn --slurpfile b "$TMP/b.json" --slurpfile p "$TMP/p.json" --arg m "$m" "$JQ_DEFS"'
    ($b|tomap("instance")) as $bm | ($p|tomap("instance")) as $pm
    | $pm|keys[] as $k | [$k, $m, (($bm[$k]//0)|hb), ($pm[$k]|hb),
        ((if $pm[$k]>($bm[$k]//0) then "+" else "" end)+(($pm[$k]-($bm[$k]//0))|hb))] | @tsv'
done | sort | { printf 'WEZEL\tTYP\tBAZA\tSZCZYT\tZMIANA\n'; cat; } | table

# --- 3. czy urosl ruch ------------------------------------------------------------
hdr "3. RUCH SIECIOWY NA WEZLACH  (BAZA vs SZCZYT, rate $RATE)"
compare "Ruch przychodzacy na wezel (interfejs: $NODE_DEV_RE)" "instance" bps delta \
  "sum by (instance)(rate(node_network_receive_bytes_total{$IF,device=~\"$NODE_DEV_RE\"}[$RATE]))"
compare "Ruch wychodzacy z wezla (interfejs: $NODE_DEV_RE)" "instance" bps delta \
  "sum by (instance)(rate(node_network_transmit_bytes_total{$IF,device=~\"$NODE_DEV_RE\"}[$RATE]))"
compare "Wpisy conntrack (liczba sledzonych polaczen)" "instance" num delta "node_nf_conntrack_entries{$IF}"
compare "Otwarte gniazda TCP" "instance" num delta "node_sockstat_TCP_inuse{$IF}"
compare "Pody na infranode'ach - ruch przychodzacy (takze poza routerem: scrape, logi itd.)" "node,namespace,pod" bps delta \
  "sum by (node,namespace,pod)(rate(container_network_receive_bytes_total{$NF}[$RATE]))"
compare "Pody na infranode'ach - ruch wychodzacy" "node,namespace,pod" bps delta \
  "sum by (node,namespace,pod)(rate(container_network_transmit_bytes_total{$NF}[$RATE]))"

# --- 4. router: dokad idzie ruch -----------------------------------------------------
hdr "4. INGRESS / ROUTER - DOKAD KIEROWANY JEST RUCH  (BAZA vs SZCZYT, rate $RATE)"
compare "Zadania HTTP wg namespace docelowego" "exported_namespace" rate delta \
  "sum by (exported_namespace)(rate(haproxy_backend_http_responses_total[$RATE]))"
compare "Zadania HTTP wg route" "exported_namespace,route" rate delta \
  "sum by (exported_namespace,route)(rate(haproxy_backend_http_responses_total[$RATE]))"
compare "Zadania HTTP wg poda docelowego" "exported_namespace,exported_service,exported_pod" rate delta \
  "sum by (exported_namespace,exported_service,exported_pod)(rate(haproxy_server_http_responses_total[$RATE]))"
compare "Zadania HTTP wg kodu odpowiedzi" "code" rate peak \
  "sum by (code)(rate(haproxy_backend_http_responses_total[$RATE]))"
compare "Nowe polaczenia wg route (obejmuje tez passthrough/TCP)" "exported_namespace,route" rate delta \
  "sum by (exported_namespace,route)(rate(haproxy_backend_connections_total[$RATE]))"
compare "Transfer wg route (in+out)" "exported_namespace,route" bps delta \
  "sum by (exported_namespace,route)(rate(haproxy_server_bytes_in_total[$RATE]) + rate(haproxy_server_bytes_out_total[$RATE]))"
compare "Aktywne sesje wg route (dlugo zyjace polaczenia, websockety)" "exported_namespace,route" num delta \
  "sum by (exported_namespace,route)(haproxy_server_current_sessions)"
compare "Aktywne sesje na frontendach wg poda routera" "pod,frontend" num delta \
  "sum by (pod,frontend)(haproxy_frontend_current_sessions)"
show "Przeladowania konfiguracji routera w oknie (kazdy reload przy dlugich polaczeniach zostawia stary proces haproxy w pamieci)" \
  "pod" num "sum by (pod)(increase(template_router_reload_seconds_count[$WINDOW]))" "$T_END"

# --- 5. skad przychodzi ruch -----------------------------------------------------------
hdr "5. ZRODLA RUCHU (adresy klientow)"
LOGGING=$(oc_ro get ingresscontroller -n openshift-ingress-operator -o json 2>/dev/null |
  jq -r '.items[]|select(.spec.logging.access.destination.type=="Container")|.metadata.name')
if (( ! ACCESS_LOGS )); then
  echo "  pominieto (-A)"
elif [[ -z $LOGGING ]]; then
  cat <<'EOF'
  Access logi routera nie sa wlaczone w trybie Container, a metryki HAProxy nie zawieraja
  adresow zrodlowych - z samego Prometheusa nie da sie ustalic, SKAD przyszedl ruch.
  Zrodla da sie uzyskac po wlaczeniu spec.logging.access na IngressController albo
  z Network Observability (to zmiana konfiguracji - ten skrypt jej nie wykonuje).
  Jesli logi ida na syslog, zrodel szukaj w systemie docelowym (Loki/Splunk/SIEM).
EOF
else
  echo "  Uwaga: logi obejmuja to, co jeszcze jest w buforze kontenera 'logs' (max 200k linii na pod), nie cale okno."
  for ic in $LOGGING; do
    for p in $(oc_ro get pods -n openshift-ingress -l "ingresscontroller.operator.openshift.io/deployment-ingresscontroller=$ic" -o name); do
      oc_ro logs -n openshift-ingress "$p" -c logs --since="$WINDOW" --tail=200000 2>/dev/null
    done
  done >"$TMP/access.log"
  echo "  Przeanalizowano linii: $(wc -l <"$TMP/access.log")"
  sub "Top adresy zrodlowe"
  grep -oE 'haproxy\[[0-9]+\]: [0-9a-fA-F.:]+:[0-9]+ ' "$TMP/access.log" | awk '{print $2}' | sed -E 's/:[0-9]+$//' |
    sort | uniq -c | sort -rn | head -n "$TOPN" | awk 'BEGIN{print "ZADANIA\tZRODLO"}{print $1"\t"$2}' | table
  sub "Top pary zrodlo -> backend (namespace:route)"
  sed -nE 's/.*haproxy\[[0-9]+\]: ([0-9a-fA-F.:]+):[0-9]+ \[[^]]+\] [^ ]+ ([^ /]+)\/.*/\1\t\2/p' "$TMP/access.log" |
    sort | uniq -c | sort -rn | head -n "$TOPN" | awk 'BEGIN{print "ZADANIA\tZRODLO\tBACKEND"}{print $1"\t"$2"\t"$3}' | table
fi

# --- 6. kontekst --------------------------------------------------------------------------
hdr "6. KONTEKST: RESTARTY, OOM, ALERTY"
sub "Kontenery na infranode'ach z restartami"
{ printf 'WEZEL\tNAMESPACE\tPOD\tKONTENER\tRESTARTY\tOSTATNI POWOD\tZAKONCZONY\n'
  for n in "${NODES[@]}"; do
    oc_ro get pods -A --field-selector "spec.nodeName=$n" -o json | jq -r --arg n "$n" '
      .items[] | . as $p | (.status.containerStatuses // [])[] | select(.restartCount>0)
      | [$n, $p.metadata.namespace, $p.metadata.name, .name, .restartCount,
         (.lastState.terminated.reason // "-"), (.lastState.terminated.finishedAt // "-")] | @tsv'
  done | sort -t$'\t' -k7,7r | head -n "$TOPN"; } | table

sub "Zdarzenia OOM / eviction / presja pamieci (to, co jeszcze jest w API)"
{ printf 'OSTATNIO\tNAMESPACE\tOBIEKT\tPOWOD\tKOMUNIKAT\n'
  oc_ro get events -A -o json | jq -r --arg re "$NODE_RE" '
    .items[] | select((.reason // "")|test("OOM|Evict|MemoryPressure|SystemOOM|NodeHasInsufficientMemory";"i"))
    | select(((.source.host // "") + " " + (.involvedObject.name // "") + " " + (.message // ""))|test($re))
    | [(.lastTimestamp // .eventTime // "-"), (.metadata.namespace // "-"),
       "\(.involvedObject.kind)/\(.involvedObject.name)", .reason, ((.message // "")[:90])] | @tsv' |
  sort -r | head -n "$TOPN"; } | table

show "Alerty aktywne w SZCZYCIE dotyczace infranode'ow" "alertname,severity,namespace,instance,node" num \
  "ALERTS{alertstate=\"firing\",instance=~\"$NODE_RE\"} or ALERTS{alertstate=\"firing\",node=~\"$NODE_RE\"}" "$T_PEAK"

printf '\n%s\nKoniec raportu. Na klastrze nic nie zostalo zmienione.\n' "$LINE"
