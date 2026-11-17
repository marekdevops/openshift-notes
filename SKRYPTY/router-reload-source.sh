#!/usr/bin/env bash
# =============================================================================
# router-reload-source.sh - SKAD BIORA SIE RELOADY ROUTERA (HAProxy)?
#
# Router OpenShift przeladowuje HAProxy, gdy zmieni sie cos, co obserwuje:
#   - Route (spec, czasem status), Service, EndpointSlice/Endpoints (pody za serwisem),
#   - konfiguracja IngressControllera (nowe wdrozenie routera).
# Kazdy reload startuje nowy proces HAProxy; stary zyje, dopoki ma polaczenia
# (albo do hard-stop-after). Setki reloadow na godzine = setki procesow = GiB RAM.
#
# Skrypt odpowiada na pytania:
#   1. ile reloadow jest teraz i OD KIEDY ich przybylo (wykrycie poczatku skoku
#      z historii Prometheusa) + co zmienilo sie w klastrze w tym czasie
#      (aktualizacja klastra, nowe/zmienione route, IngressController, nowe pody);
#   2. jakie ZAPISY do API rosna (route, route/status, endpointslices, endpoints,
#      services...) - teraz vs tydzien temu (metryki apiservera);
#   3. NA ZYWO (obserwacja przez -s sekund): KTORE KONKRETNIE obiekty sie zmieniaja,
#      CO sie w nich zmienia (spec / status / pody za serwisem / tylko metadane)
#      i KTO je zmienia (managedFields: nazwa kontrolera/narzedzia);
#   4. konfiguracja routerow zwiazana z reloadami (reloadInterval, hard-stop-after,
#      shardy, route odrzucone / z wieloma wpisami status).
#   Na koncu: PODSUMOWANIE z wnioskiem, co najpewniej napedza reloady.
#
# TYLKO ODCZYT: oc get / oc whoami / oc get --watch (obserwacja) + HTTP GET do
# Prometheusa (thanos-querier). Niczego nie zmienia. Pliki tymczasowe - mktemp.
# Wymagania: oc, jq (>=1.6), curl, column, awk, timeout.
# Uprawnienia: cluster-reader + cluster-monitoring-view.
# =============================================================================
set -uo pipefail
export LC_ALL=C

WATCH=60; TOPN=20; BASE="7d"; HDAYS=14
CURL_K=""; OC_K=()

usage() { cat <<EOF
Uzycie: $0 [opcje]
  -s SEKUNDY   jak dlugo obserwowac zmiany obiektow na zywo (domyslnie: $WATCH)
  -t N         liczba wierszy w zestawieniach            (domyslnie: $TOPN)
  -B OKRES     z kiedy porownac zapisy do API            (domyslnie: $BASE temu)
  -D DNI       ile dni historii reloadow analizowac      (domyslnie: $HDAYS)
  -k, --insecure
               nie weryfikuj certyfikatow TLS (oc + thanos-querier)
Przyklad:  $0 -k -s 120 | tee reload-source-\$(date +%F_%H%M).txt
EOF
exit "${1:-0}"; }

args=()
for a in "$@"; do case $a in
  --insecure|--insecure-skip-tls-verify|--insecure-skip-tls-verify=true) args+=(-k);;
  --help) args+=(-h);;
  *) args+=("$a");;
esac; done
set -- "${args[@]+"${args[@]}"}"
while getopts "s:t:B:D:kh" o; do case $o in
  s) WATCH=$OPTARG;; t) TOPN=$OPTARG;; B) BASE=$OPTARG;; D) HDAYS=$OPTARG;;
  k) CURL_K="-k"; OC_K=(--insecure-skip-tls-verify=true);; h) usage 0;; *) usage 1;;
esac; done

die()  { echo "BLAD: $*" >&2; exit 1; }
warn() { echo "UWAGA: $*" >&2; }
LINE=$(printf '=%.0s' {1..100})
hdr()  { printf '\n%s\n== %s\n%s\n' "$LINE" "$1" "$LINE"; }
sub()  { printf '\n--- %s\n' "$1"; }
say()  { fold -s -w 96 <<<"$*" | sed 's/^/  | /'; }
table() { local rows; rows=$(cat)
  if [[ $(wc -l <<<"$rows") -le 1 ]]; then echo "  (brak danych)"; else column -t -s $'\t' <<<"$rows" | sed 's/^/  /'; fi; }

# Jedyna droga do klastra: tylko get/whoami. OC_TIMEOUT=N ogranicza czas (obserwacja --watch).
oc_ro() { case "${1:-}" in
  get|whoami)
    if [[ -n ${OC_TIMEOUT:-} ]]; then timeout "$OC_TIMEOUT" oc "${OC_K[@]+"${OC_K[@]}"}" "$@"
    else command oc "${OC_K[@]+"${OC_K[@]}"}" "$@"; fi;;
  *) die "oc_ro: zablokowano 'oc $1' (skrypt jest tylko do odczytu)";; esac; }

for c in oc jq curl column awk timeout; do command -v "$c" >/dev/null || die "brak polecenia: $c"; done
[[ $WATCH =~ ^[0-9]+$ ]] || die "-s: podaj liczbe sekund"
[[ $HDAYS =~ ^[0-9]+$ ]] && (( HDAYS > 0 )) || die "-D: podaj liczbe dni"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: >"$TMP/findings"
finding() { printf '%s\t%s\n' "$1" "$2" >>"$TMP/findings"; }
ge()  { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }

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
pv() { prom query "$TMP/pv.json" "query=$1"; jq -r '.data.result[0].value[1] // empty' "$TMP/pv.json"; }
fdate() { date -d "@$1" '+%F %H:%M' 2>/dev/null || date -r "$1" '+%F %H:%M'; }

NS_R='namespace="openshift-ingress"'
NOW=$(date +%s)

echo "$LINE"
echo "SKAD BIORA SIE RELOADY ROUTERA  (tylko odczyt)"
echo "Klaster : $(oc_ro whoami --show-server)   uzytkownik: $(oc_ro whoami)"
echo "Czas    : $(date '+%F %T %Z')   obserwacja na zywo: ${WATCH}s   porownanie z: $BASE temu"
cat <<'EOF'

Jak czytac: sekcja 1 mowi OD KIEDY jest problem, sekcja 2 - JAKI RODZAJ zmian rosnie,
sekcja 3 - KTORE OBIEKTY i KTO je zmienia. Wnioski zebrane na koncu (PODSUMOWANIE).
EOF

# =============================================================================
# 1. ILE RELOADOW I OD KIEDY
# =============================================================================
hdr "1. ILE RELOADOW I OD KIEDY  (historia $HDAYS dni)"
sub "Reloady na router teraz"
{ printf 'POD\tRELOADY_1h\tRELOADY_1h_%s_TEMU\tSR.CZAS_RELOADU\n' "$BASE"
  prom query "$TMP/r1.json" "query=sum by (pod)(increase(template_router_reload_seconds_count{$NS_R}[1h]))"
  prom query "$TMP/r2.json" "query=sum by (pod)(rate(template_router_reload_seconds_sum{$NS_R}[1h])) / sum by (pod)(rate(template_router_reload_seconds_count{$NS_R}[1h]))"
  B1=$(pv "avg(increase(template_router_reload_seconds_count{$NS_R}[1h] offset $BASE))")
  jq -r --slurpfile d "$TMP/r2.json" --arg b "${B1:-}" '
    ([$d[0].data.result[] | {(.metric.pod): (.value[1]|tonumber)}] | add // {}) as $dur
    | .data.result | sort_by(-(.value[1]|tonumber))[]
    | [.metric.pod, (.value[1]|tonumber|round|tostring),
       (if $b=="" then "-" else "\($b|tonumber|round) (srednio na router)" end),
       (($dur[.metric.pod] // null) | if .==null or isnan then "-" else "\(.*1000|round) ms" end)] | @tsv' "$TMP/r1.json"
} | table

# Historia: srednia liczba reloadow na router na godzine
STEP=3600; T1=$(( NOW / STEP * STEP )); T0=$(( T1 - HDAYS * 86400 ))
prom query_range "$TMP/hist.json" "query=avg(increase(template_router_reload_seconds_count{$NS_R}[1h]))" \
  "start=$T0" "end=$T1" "step=$STEP"
jq -c '[.data.result[0].values[]? | [(.[0]|floor), (.[1]|tonumber? // null)] | select(.[1]!=null and (.[1]|isnan|not))]' \
  "$TMP/hist.json" >"$TMP/hist.pts"
sub "Reloady na router na godzine - dzien po dniu"
{ printf 'DZIEN\tSREDNIO/h\tMAX/h\tWYKRES(max)\n'
  jq -r --argjson n 0 'map(. + [(.[0]|strftime("%Y-%m-%d"))]) | group_by(.[2])
    | (map(map(.[1])|max) | max // 1) as $top
    | .[] | (map(.[1])) as $v
    | [.[0][2], (($v|add)/($v|length)|round|tostring), ($v|max|round|tostring),
       ("#" * ((($v|max)/(if $top>0 then $top else 1 end)*40)|ceil|if .<1 then 1 else . end))] | @tsv' "$TMP/hist.pts"
} | table

# Poczatek skoku: pierwsza godzina, od ktorej 3 kolejne godziny > max(4 x mediana z pierwszych 2 dni, mediana + 20)
SURGE=$(jq -r 'if length < 60 then empty else
    (.[:48] | map(.[1]) | sort | .[length/2|floor]) as $med
    | ([($med*4), ($med+20)] | max) as $thr
    | . as $p | [range(48; length-2) | select($p[.][1] > $thr and $p[.+1][1] > $thr and $p[.+2][1] > $thr)] | first
    | if .==null then empty else "\($p[.][0])\t\($med)\t\($thr)" end end' "$TMP/hist.pts")
if [[ -n $SURGE ]]; then
  IFS=$'\t' read -r ST MED THR <<<"$SURGE"
  echo
  echo "  >>> Wyrazny wzrost reloadow zaczal sie ok.: $(fdate "$ST")"
  echo "      (wczesniej mediana $(printf '%.0f' "$MED")/h na router, od tego momentu stale > $(printf '%.0f' "$THR")/h)"
  finding 2 "Wzrost reloadow zaczal sie ok. $(fdate "$ST") - sprawdz sekcje 1b: co zmienilo sie w klastrze w tym czasie."
else
  echo; echo "  Nie wykryto wyraznego poczatku skoku w historii (reloady wysokie od poczatku okna albo brak danych)."
fi

# --- 1b. co zmienilo sie w okolicy poczatku skoku ------------------------------------
if [[ -n ${ST:-} ]]; then
  W0=$(( ST - 6*3600 )); W1=$(( ST + 3*3600 ))
  hdr "1b. CO ZMIENILO SIE W KLASTRZE OK. $(fdate "$ST")  (okno: -6h / +3h)"
  oc_ro get clusterversion -o json >"$TMP/cv.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/cv.json"
  oc_ro get routes -A -o json >"$TMP/routes.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/routes.json"
  oc_ro get ingresscontroller -n openshift-ingress-operator -o json >"$TMP/ic.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/ic.json"
  oc_ro get ns -o json >"$TMP/ns.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/ns.json"
  JT='def ts: (. // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      def inwin: ts >= $w0 and ts <= $w1;'
  sub "Aktualizacje klastra (ClusterVersion)"
  { printf 'WERSJA\tSTAN\tSTART\tKONIEC\n'
    jq -r --argjson w0 "$W0" --argjson w1 "$W1" "$JT"'.items[].status.history[]?
      | select((.startedTime|inwin) or ((.completionTime // "")|inwin) or ((.startedTime|ts) <= $w0 and ((.completionTime // "2999-01-01T00:00:00Z")|ts) >= $w0))
      | [.version, .state, .startedTime, (.completionTime // "trwa")] | @tsv' "$TMP/cv.json"
  } | table
  sub "IngressController zmieniony w tym oknie"
  { printf 'INGRESSCONTROLLER\tCZAS\tKTO\tOPERACJA\n'
    jq -r --argjson w0 "$W0" --argjson w1 "$W1" "$JT"'.items[] | .metadata.name as $n
      | .metadata.managedFields[]? | select(.time|inwin) | [$n, .time, .manager, .operation + (if .subresource then "/"+.subresource else "" end)] | @tsv' "$TMP/ic.json"
  } | table
  sub "Route utworzone lub zmienione w tym oknie (wg managedFields)"
  { printf 'NAMESPACE\tROUTE\tCZAS\tKTO\tOPERACJA\n'
    jq -r --argjson w0 "$W0" --argjson w1 "$W1" --argjson n "$TOPN" "$JT"'
      [.items[] | .metadata as $m | $m.managedFields[]? | select(.time|inwin)
        | [$m.namespace, $m.name, .time, .manager, .operation + (if .subresource then "/"+.subresource else "" end)]]
      | sort_by(.[2]) | .[:$n][] | @tsv' "$TMP/routes.json"
  } | table
  sub "Namespace'y utworzone w tym oknie"
  { printf 'NAMESPACE\tUTWORZONY\n'
    jq -r --argjson w0 "$W0" --argjson w1 "$W1" "$JT"'.items[] | select(.metadata.creationTimestamp|inwin) | [.metadata.name, .metadata.creationTimestamp] | @tsv' "$TMP/ns.json"
  } | table
  sub "Namespace'y z podami utworzonymi w tym oknie (istniejace dzis)"
  prom query "$TMP/pc.json" "query=count by (namespace)((kube_pod_created >= $W0) <= $W1)"
  { printf 'NAMESPACE\tPODY\n'
    jq -r --argjson n "$TOPN" '.data.result | sort_by(-(.value[1]|tonumber)) | .[:$n][] | [.metric.namespace, .value[1]] | @tsv' "$TMP/pc.json"
  } | table
  say "Szukaj tu zdarzenia, ktore zbiega sie z poczatkiem skoku: aktualizacja klastra, zmiana IngressControllera, wdrozenie nowej aplikacji z route, nowe narzedzie (np. GitOps) zarzadzajace route."
fi

# =============================================================================
# 2. JAKIE ZAPISY DO API ROSNA
# =============================================================================
hdr "2. ZAPISY DO API DLA OBIEKTOW OBSERWOWANYCH PRZEZ ROUTER  (na godzine: teraz vs $BASE temu)"
RES='resource=~"routes|endpoints|endpointslices|services|namespaces|ingresscontrollers|secrets"'
WV='verb=~"POST|PUT|PATCH|DELETE|APPLY|CREATE|UPDATE"'
Q="sum by (resource,subresource,verb)(increase(apiserver_request_total{$RES,$WV,code=~\"2..\"}[1h]))"
prom query "$TMP/a_now.json" "query=$Q"
prom query "$TMP/a_old.json" "query=sum by (resource,subresource,verb)(increase(apiserver_request_total{$RES,$WV,code=~\"2..\"}[1h] offset $BASE))"
jq -n --slurpfile a "$TMP/a_now.json" --slurpfile b "$TMP/a_old.json" '
  def k: "\(.metric.resource)\t\(.metric.subresource // "" | if .=="" then "-" else . end)\t\(.metric.verb)";
  def m($x): [$x[0].data.result[] | {(k): (.value[1]|tonumber)}] | add // {};
  m($a) as $n | m($b) as $o
  | [($n|keys[]), ($o|keys[])] | unique
  | map({k:., n:($n[.] // 0), o:($o[.] // 0)}) | map(select(.n >= 1 or .o >= 1))
  | sort_by(-.n) | .[]' >"$TMP/api.jsonl" 2>/dev/null
sub "Zapisy (udane) do API na godzine"
{ printf 'ZASOB\tPODZASOB\tOPERACJA\t%s_TEMU\tTERAZ\tZMIANA\n' "$BASE"
  jq -r --argjson n "$TOPN" -s '.[:$n][] | (.k|split("\t")) + [(.o|round|tostring), (.n|round|tostring),
     (if .o<1 then (if .n>=1 then "NOWE" else "-" end) else "x\(.n/.o*10|round/10)" end)] | @tsv' "$TMP/api.jsonl"
} | table
say "routes / status = router albo inny kontroler zapisuje status route (wiele zapisow statusu = spor o status, np. dwa routery/shardy). routes (bez podzasobu) = ktos zmienia definicje route (GitOps, operator, skrypt). endpointslices / endpoints = zmieniaja sie pody za serwisami. Zapisy endpoints bez zmian podow to czesto leader election starych komponentow (adnotacja na Endpoints)."
while IFS=$'\t' read -r k n o; do
  [[ -n $k ]] || continue
  if ge "$n" 100 && { ! ge "$o" 1 || awk -v n="$n" -v o="$o" 'BEGIN{exit !(n >= 3*o)}'; }; then
    finding 2 "Zapisy do API '$k' wzrosly z ${o%.*} do ${n%.*} na godzine (sekcja 2)."
  fi
done < <(jq -r '[(.k|gsub("\t";" ")), .n, .o] | @tsv' "$TMP/api.jsonl")

# =============================================================================
# 3. OBSERWACJA NA ZYWO - KTORE OBIEKTY SIE ZMIENIAJA I KTO JE ZMIENIA
# =============================================================================
hdr "3. OBSERWACJA NA ZYWO PRZEZ ${WATCH}s - KTORE OBIEKTY SIE ZMIENIAJA"
echo "  Obserwuje: routes, endpointslices, endpoints, services (oc get --watch, tylko odczyt)..." >&2
[[ -s $TMP/routes.json ]] || oc_ro get routes -A -o json >"$TMP/routes.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/routes.json"
R0=$(prom query "$TMP/rw0.json" "query=sum(template_router_reload_seconds_count{$NS_R})"; jq -r '.data.result[0].value[1] // empty' "$TMP/rw0.json")
KINDS=(routes endpointslices.discovery.k8s.io endpoints services)
for k in "${KINDS[@]}"; do
  ( oc_ro get "$k" -A -o json >"$TMP/w0_$k.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/w0_$k.json"
    OC_TIMEOUT=$WATCH oc_ro get "$k" -A --watch-only --output-watch-events -o json >"$TMP/w_$k.json" 2>"$TMP/w_$k.err" || true ) &
done
wait
R1=$(prom query "$TMP/rw1.json" "query=sum(template_router_reload_seconds_count{$NS_R})"; jq -r '.data.result[0].value[1] // empty' "$TMP/rw1.json")
[[ -n $R0 && -n $R1 ]] && echo "  W czasie obserwacji routery (lacznie) przeladowaly sie ok. $(awk -v a="$R0" -v b="$R1" 'BEGIN{printf "%d", b-a}') razy (metryka Prometheusa, z opoznieniem scrape'u)."

# Serwisy, na ktore wskazuja route (tylko zmiany ich podow maja znaczenie dla routera)
jq -c '[.items[] | .metadata.namespace as $n | ([.spec.to.name] + [.spec.alternateBackends[]?.name])[] | "\($n)/\(.)"] | unique
       | map({(.): true}) | add // {}' "$TMP/routes.json" >"$TMP/routed.json"

# Podpis obiektu - z czego sklada sie "zmiana"
SIG='
def mgr: ((.metadata.managedFields // []) | max_by(.time // "") // {}) as $f
  | if $f=={} then "-" else "\($f.manager // "?") (\($f.operation // "?")\(if $f.subresource then "/"+$f.subresource else "" end))" end;
def meta: {l:(.metadata.labels // {}), a:((.metadata.annotations // {}) | del(.["kubectl.kubernetes.io/last-applied-configuration"]))};
def sig($kind):
  if   $kind=="routes" then {spec:(.spec|tojson), status:(.status|tojson), meta:(meta|tojson)}
  elif $kind=="endpointslices.discovery.k8s.io" then
       {pody:([.endpoints[]? | {a:.addresses, r:.conditions.ready, s:.conditions.serving, t:.conditions.terminating}] | sort | tojson),
        porty:(.ports|tojson), meta:(meta|tojson)}
  elif $kind=="endpoints" then {pody:(.subsets|tojson), meta:(meta|tojson)}
  else {spec:(.spec|tojson), status:(.status|tojson), meta:(meta|tojson)} end;
def svc($kind):
  if   $kind=="endpointslices.discovery.k8s.io" then (.metadata.labels["kubernetes.io/service-name"] // "")
  else .metadata.name end;
'
NAMES='{"spec":"spec","status":"status","meta":"etykiety/adnotacje","pody":"PODY (adresy/gotowosc)","porty":"porty"}'
for k in "${KINDS[@]}"; do
  jq -c --arg kind "$k" "$SIG"'.items[] | {key:"\(.metadata.namespace)/\(.metadata.name)", s:sig($kind)}' \
    "$TMP/w0_$k.json" 2>/dev/null >"$TMP/s0_$k.jsonl"
  # strumien zdarzen -> dla kazdego obiektu: liczba zmian, co sie zmienialo, kto zmienial
  jq -c --arg kind "$k" "$SIG"'select(.object.metadata!=null) | {t:.type, key:"\(.object.metadata.namespace)/\(.object.metadata.name)",
       ns:.object.metadata.namespace, svc:(.object|svc($kind)), s:(.object|sig($kind)), mgr:(.object|mgr)}' \
    "$TMP/w_$k.json" 2>/dev/null >"$TMP/ev_$k.jsonl"
  jq -n --slurpfile init "$TMP/s0_$k.jsonl" --slurpfile ev "$TMP/ev_$k.jsonl" --slurpfile routed "$TMP/routed.json" \
        --argjson names "$NAMES" --arg kind "$k" '
    reduce $ev[] as $e ({prev:($init | map({(.key): .s}) | add // {}), out:{}};
      .prev[$e.key] as $p
      | (if $e.t=="ADDED" then ["NOWY"] elif $e.t=="DELETED" then ["USUNIETY"]
         elif $p==null then ["?"]
         else ([$e.s | keys[] | select($e.s[.] != $p[.]) | $names[.] // .] | if length==0 then ["nic istotnego (resourceVersion/managedFields)"] else . end) end) as $what
      | .prev[$e.key] = $e.s
      | .out[$e.key] |= ((. // {ns:$e.ns, svc:$e.svc, n:0, what:{}, mgr:{}})
           | .n += 1 | reduce $what[] as $w (.; .what[$w] += 1) | .mgr[$e.mgr] += 1))
    | .out | to_entries | map(.value + {key:.key,
        routed: ($routed[0]["\(.value.ns)/\(.value.svc)"] // false)})' >"$TMP/sum_$k.json"
done

show_kind() { # $1=kind $2=tytul $3=czy kolumna ZA_ROUTE
  local k=$1
  sub "$2  (zdarzen: $(jq 'map(.n)|add // 0' "$TMP/sum_$k.json"), obiektow: $(jq length "$TMP/sum_$k.json"))"
  { printf 'NAMESPACE/NAZWA\tZMIAN\tCO_SIE_ZMIENIA\tKTO_ZMIENIA\t%s\n' "$([[ -n $3 ]] && echo ZA_ROUTE)"
    jq -r --argjson n "$TOPN" --arg rc "$3" 'sort_by(-.n) | .[:$n][]
      | [.key, (.n|tostring),
         (.what | to_entries | sort_by(-.value) | map("\(.key) x\(.value)") | join(", ")),
         (.mgr | to_entries | sort_by(-.value) | .[:2] | map(.key) | join("; ")),
         (if $rc=="" then "" elif .routed then "TAK" else "nie" end)] | @tsv' "$TMP/sum_$k.json"
  } | table
}
show_kind routes "Route" ""
say "Zmiana spec route = reload. Czesta zmiana samego statusu tej samej route = spor o status (np. dwa IngressControllery/shardy albo stary wpis po usunietym routerze). KTO_ZMIENIA = ostatni wpis managedFields: nazwa kontrolera/narzedzia (np. kontroler GitOps, kubectl, operator)."
show_kind endpointslices.discovery.k8s.io "EndpointSlice (pody za serwisami)" yes
say "PODY = zmienil sie adres lub gotowosc poda za serwisem. Jesli ZA_ROUTE = TAK, to na pewno wymusza reload routera. Zmiany 'etykiety/adnotacje' lub 'nic istotnego' zwykle reloadu nie robia."
show_kind endpoints "Endpoints (stary API, rownolegle do EndpointSlice)" yes
say "Endpoints zmieniane bez zmian PODOW, z adnotacjami, to zwykle leader election (kontroler zapisuje co kilka sekund swoja dzierzawe) - halas w API, zwykle bez reloadu."
show_kind services "Service" yes

# Podsumowanie na namespace: tylko zmiany, ktore realnie dotycza routera
sub "Namespace'y generujace zmiany istotne dla routera (w ${WATCH}s)"
{ printf 'NAMESPACE\tROUTE_SPEC\tROUTE_STATUS\tPODY_ZA_ROUTE\tPODY_BEZ_ROUTE\tSERVICE_SPEC\n'
  jq -rn --slurpfile r "$TMP/sum_routes.json" --slurpfile e "$TMP/sum_endpointslices.discovery.k8s.io.json" \
         --slurpfile s "$TMP/sum_services.json" --argjson n "$TOPN" '
    ([ $r[0][] | {ns, rs:((.what.spec // 0) + (.what.NOWY // 0) + (.what.USUNIETY // 0)), st:(.what.status // 0)} ]
     + [ $e[0][] | ((.what["PODY (adresy/gotowosc)"] // 0) + (.what.NOWY // 0) + (.what.USUNIETY // 0)) as $p
         | {ns, pr:(if .routed then $p else 0 end), pn:(if .routed then 0 else $p end)} ]
     + [ $s[0][] | {ns, ss:((.what.spec // 0) + (.what.NOWY // 0) + (.what.USUNIETY // 0))} ])
    | group_by(.ns) | map({ns:.[0].ns, rs:(map(.rs//0)|add), st:(map(.st//0)|add), pr:(map(.pr//0)|add),
                           pn:(map(.pn//0)|add), ss:(map(.ss//0)|add)})
    | map(select(.rs+.st+.pr+.ss > 0)) | sort_by(-(.rs*3 + .pr*3 + .ss*3 + .st)) | .[:$n][]
    | [.ns, (.rs|tostring), (.st|tostring), (.pr|tostring), (.pn|tostring), (.ss|tostring)] | @tsv'
} | table
say "Kolumny ROUTE_SPEC, PODY_ZA_ROUTE i SERVICE_SPEC to zmiany, ktore wymuszaja reload. Namespace na gorze tej tabeli to najpewniejsze zrodlo reloadow. Zmiany, ktore przychodza czesciej niz reloadInterval, router laczy w jeden reload."

# Wnioski z obserwacji
RSPEC=$(jq '[.[] | (.what.spec // 0) + (.what.NOWY // 0) + (.what.USUNIETY // 0)] | add // 0' "$TMP/sum_routes.json")
RSTAT=$(jq '[.[] | .what.status // 0] | add // 0' "$TMP/sum_routes.json")
EPR=$(jq '[.[] | select(.routed) | (.what["PODY (adresy/gotowosc)"] // 0) + (.what.NOWY // 0) + (.what.USUNIETY // 0)] | add // 0' "$TMP/sum_endpointslices.discovery.k8s.io.json")
SSP=$(jq '[.[] | (.what.spec // 0) + (.what.NOWY // 0) + (.what.USUNIETY // 0)] | add // 0' "$TMP/sum_services.json")
top_of() { jq -r --arg f "$2" 'map(select(.what[$f] != null)) | sort_by(-.what[$f]) | .[:3] | map("\(.key) (x\(.what[$f]), \(.mgr|to_entries|max_by(.value)|.key))") | join("; ")' "$1"; }
ge "$RSPEC" 2 && finding 1 "W ${WATCH}s zmieniono spec route $RSPEC razy - kazda taka zmiana to reload. Najczesciej: $(top_of "$TMP/sum_routes.json" spec). Sprawdz, kto je zmienia (KTO_ZMIENIA, sekcja 3) - np. narzedzie GitOps walczace z wartosciami domyslnymi route (host, tls, wildcardPolicy) albo dwa narzedzia nadpisujace sie nawzajem."
ge "$RSTAT" 10 && finding 2 "W ${WATCH}s status route zmienil sie $RSTAT razy. Najczesciej: $(top_of "$TMP/sum_routes.json" status). Czeste zmiany statusu tych samych route = spor o status miedzy routerami (shardy z nakladajacymi sie selektorami, stary wpis status.ingress)."
ge "$EPR" 2 && finding 1 "W ${WATCH}s pody za route zmienily sie $EPR razy (EndpointSlice) - to wymusza reloady. Najczesciej: $(jq -r 'map(select(.routed and (.what["PODY (adresy/gotowosc)"] != null))) | sort_by(-.what["PODY (adresy/gotowosc)"]) | .[:3] | map("\(.key) (x\(.what["PODY (adresy/gotowosc)"]))") | join("; ")' "$TMP/sum_endpointslices.discovery.k8s.io.json"). Sprawdz te aplikacje: restarty, flapujace readinessProbe, autoskalowanie w gore/dol."
ge "$SSP" 2 && finding 2 "W ${WATCH}s zmieniono spec Service $SSP razy. Najczesciej: $(top_of "$TMP/sum_services.json" spec)."
if ! ge "$RSPEC" 2 && ! ge "$EPR" 2 && ! ge "$SSP" 2; then
  finding 2 "W ${WATCH}s nie zaobserwowano zmian route/podow/serwisow, ktore tlumacza reloady. Uruchom ponownie z dluzsza obserwacja (-s 300) albo sprawdz sekcje 2 (rodzaje zapisow) i 1b (co sie zmienilo, gdy zaczal sie skok)."
fi
for k in "${KINDS[@]}"; do
  [[ -s $TMP/w_$k.err ]] && grep -qiE 'forbidden|error' "$TMP/w_$k.err" && warn "obserwacja $k: $(head -c 200 "$TMP/w_$k.err")"
done

# =============================================================================
# 4. KONFIGURACJA ROUTEROW ZWIAZANA Z RELOADAMI
# =============================================================================
hdr "4. KONFIGURACJA ROUTEROW ZWIAZANA Z RELOADAMI"
[[ -s $TMP/ic.json ]] || oc_ro get ingresscontroller -n openshift-ingress-operator -o json >"$TMP/ic.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/ic.json"
oc_ro get deploy -n openshift-ingress -o json >"$TMP/rdep.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/rdep.json"
sub "IngressControllery"
{ printf 'IC\tREPLIKI\tRELOAD_INTERVAL\tHARD_STOP_AFTER\tNAMESPACE_SELECTOR\tROUTE_SELECTOR\tROUTE_ADMITTED\n'
  jq -r --slurpfile d "$TMP/rdep.json" --slurpfile r "$TMP/routes.json" '.items[] | .metadata.name as $n
    | ([$d[0].items[] | select(.metadata.name==("router-"+$n))][0]) as $dep
    | (($dep.spec.template.spec.containers // []) | map(select(.name=="router"))[0].env // [] | map({(.name): (.value // "")}) | add // {}) as $e
    | [$n, "\($dep.status.readyReplicas // 0)/\($dep.spec.replicas // "?")",
       ($e.RELOAD_INTERVAL // ((.spec.tuningOptions.reloadInterval // "5s") + " (domyslne)")),
       ($e.ROUTER_HARD_STOP_AFTER // "BRAK"),
       ((.spec.namespaceSelector // {}) | tojson | if .=="{}" then "-" else . end),
       ((.spec.routeSelector // {}) | tojson | if .=="{}" then "-" else . end),
       ([$r[0].items[] | select(any(.status.ingress[]?; .routerName==$n and any(.conditions[]?; .type=="Admitted" and .status=="True")))] | length | tostring)] | @tsv' "$TMP/ic.json"
} | table
say "RELOAD_INTERVAL = minimalny odstep miedzy reloadami (domyslnie 5s, czyli do 720/h). Zwiekszenie (spec.tuningOptions.reloadInterval, np. 30s-60s) laczy zmiany w mniej reloadow. HARD_STOP_AFTER = po jakim czasie stary proces HAProxy jest ubijany; BRAK = zyje, dopoki ma polaczenia."
jq -e '[.items[] | select(.spec.tuningOptions.reloadInterval == null)] | length > 0' "$TMP/ic.json" >/dev/null 2>&1 && \
  finding 3 "Co najmniej jeden IngressController ma domyslny reloadInterval (5s). Zwiekszenie do 30s-60s ograniczy liczbe reloadow niezaleznie od ich przyczyny: oc -n openshift-ingress-operator patch ingresscontroller/<nazwa> --type=merge -p '{\"spec\":{\"tuningOptions\":{\"reloadInterval\":\"30s\"}}}'"

sub "Route odrzucone lub z wieloma wpisami status.ingress"
{ printf 'NAMESPACE\tROUTE\tROUTERY_W_STATUSIE\tNIEPRZYJETA_PRZEZ\tPOWOD\n'
  jq -r --slurpfile ic "$TMP/ic.json" --argjson n "$TOPN" '
    ([$ic[0].items[].metadata.name]) as $ics
    | [.items[] | . as $r | (.status.ingress // []) as $s
      | ($s | map(select(any(.conditions[]?; .type=="Admitted" and .status!="True")))) as $bad
      | ($s | map(.routerName) | map(select(. as $x | $ics | index($x) | not))) as $stale
      | select(($bad|length) > 0 or ($stale|length) > 0)
      | [$r.metadata.namespace, $r.metadata.name, ($s|map(.routerName)|join(",")),
         (($bad|map(.routerName)) + ($stale|map(.+" (nie istnieje)")) | join(",")),
         ($bad|map(.conditions[]?|select(.type=="Admitted")|.reason // "")|unique|join(","))]] | .[:$n][] | @tsv' "$TMP/routes.json"
} | table
say "Route odrzucone (np. HostAlreadyClaimed) albo ze statusem od nieistniejacego routera bywaja zrodlem ciaglych zapisow statusu. Nie zawsze powoduja reload, ale warto je uporzadkowac."
NREJ=$(jq '[.items[] | select(any(.status.ingress[]?; any(.conditions[]?; .type=="Admitted" and .status!="True")))] | length' "$TMP/routes.json")
ge "${NREJ:-0}" 1 && finding 3 "$NREJ route jest odrzuconych przez co najmniej jeden router (sekcja 4)."

# =============================================================================
# 5. PODSUMOWANIE
# =============================================================================
hdr "5. PODSUMOWANIE - CO NAPEDZA RELOADY"
if [[ ! -s $TMP/findings ]]; then
  echo "  Nie wykryto niczego niepokojacego."
else
  sort -t$'\t' -k1,1n -s "$TMP/findings" | awk -F'\t' '!seen[$2]++' | while IFS=$'\t' read -r lvl txt; do
    case $lvl in 1) tag="[KRYTYCZNE]";; 2) tag="[UWAGA]     ";; *) tag="[INFO]      ";; esac
    fold -s -w 84 <<<"$txt" | awk -v t="$tag" 'NR==1{print "  " t " " $0; next}{print "                " $0}'
  done
fi
cat <<'EOF'

  Typowe przyczyny setek reloadow na godzine:
   - pody za route ciagle zmieniaja gotowosc (crashloop, zbyt ostra readinessProbe, HPA skaluje w kolko);
   - narzedzie GitOps / operator co chwile nadpisuje route (np. pole host, tls, adnotacje),
     bo stan w repo rozni sie od tego, co uzupelnia OpenShift;
   - dwa IngressControllery (shardy) obsluguja te same route i na zmiane zapisuja status;
   - masowe wdrozenia (CI/CD), CronJoby z serwisami, namespace'y tworzone i usuwane w petli.
  Doraznie (niezaleznie od przyczyny): zwiekszyc tuningOptions.reloadInterval i ustawic
  hard-stop-after, zeby stare procesy HAProxy nie zjadaly pamieci.
EOF
printf '\n%s\nKoniec raportu. Na klastrze nic nie zostalo zmienione.\n' "$LINE"
