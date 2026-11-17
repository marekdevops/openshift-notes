#!/usr/bin/env bash
# =============================================================================
# infra-mem-now.sh - CO TERAZ zjada pamiec na infranode + kondycja routerow
#
# Odpowiada na pytania:
#   - ile pamieci jest naprawde zajete (a ile to odzyskiwalny cache)?
#   - ktore pody / namespace'y / uslugi systemowe / procesy ja zajmuja i czy rosna?
#   - jaki ruch idzie teraz przez routery: ktore route, ile polaczen, ile zadan/s?
#   - jak skonfigurowany jest IngressController (maxconn, watki, bufory, timeouty)
#     i jaka czesc puli polaczen jest wykorzystana / wyczerpana?
#   - jakie sa bledy: zdarzenia, restarty/OOM, alerty, bledy w logach routera?
#   Na koncu: PODSUMOWANIE z wnioskami w zwyklym jezyku.
#
# TYLKO ODCZYT. Skrypt wykonuje wylacznie:
#   - oc get / oc whoami / oc logs            (funkcja oc_ro blokuje inne czasowniki)
#   - HTTP GET do API zapytan Prometheusa     (route thanos-querier)
#   - TYLKO z opcja -x: oc exec do podow routera, gdzie czyta /proc oraz wysyla
#     do gniazda HAProxy polecenia "show info", "show pools", "show sess"
#     (polecenia podgladu - niczego nie zmieniaja). Wymaga uprawnien pods/exec.
# Pliki tymczasowe powstaja tylko lokalnie (mktemp) i sa usuwane na koncu.
#
# Wymagania: oc, jq (>=1.6), curl, column, awk. Zalogowanie tokenem (oc login
# --token) albo zmienna TOKEN. Uprawnienia: cluster-reader + cluster-monitoring-view.
# =============================================================================
set -uo pipefail
export LC_ALL=C   # kropka dziesietna w awk/printf/sort niezaleznie od locale

SELECTOR="node-role.kubernetes.io/infra"; TOPN=15; RATE="5m"; TREND="24h"; LOGWIN="1h"
CURL_K=""; OC_K=(); FOCUS=""; EXEC=0
HTML=""; HDAYS=14; HSTEP="1h"; BASE="7d"; CWIN="1d"; CAPTURE=""
# Wartosci domyslne szablonu routera OpenShift 4.x (gdy IngressController ich nie ustawia)
DEF_MAXCONN=50000; DEF_BUF=32768

usage() { cat <<EOF
Uzycie: $0 [opcje]
  -n WEZEL     analizowany infranode            (domyslnie: ten z najwyzszym % pamieci)
  -l SELEKTOR  selektor etykiet infranode'ow    (domyslnie: $SELECTOR)
  -t N         liczba wierszy w zestawieniach   (domyslnie: $TOPN)
  -r ZAKRES    okno rate() dla "teraz"          (domyslnie: $RATE)
  -T OKNO      z czym porownac wzrost pamieci   (domyslnie: $TREND temu)
  -L OKNO      okno bledow/logow/reloadow       (domyslnie: $LOGWIN)
  -k, --insecure
               nie weryfikuj certyfikatow TLS (API klastra przez oc oraz route
               thanos-querier przez curl) - dla certyfikatow self-signed / wlasnego CA
  -x           zajrzyj do podow routera (oc exec, tylko polecenia podgladu):
               procesy haproxy, "show info", pule pamieci, aktywne sesje
  -B OKRES     z kiedy porownac stan (sekcja 0)   (domyslnie: $BASE temu - ten sam dzien tygodnia)
  -W OKNO      okno porownania, max z okna       (domyslnie: ostatnie $CWIN)
  -H PLIK, --html PLIK
               dodatkowo zapisz raport HTML z wykresami historii (MAKSIMA z kazdego
               kroku) + caly raport tekstowy; plik otwiera sie w przegladarce offline
  -D DNI       ile dni historii na wykresach     (domyslnie: $HDAYS; retencja
               Prometheusa w OpenShift to zwykle 15 dni)
  -S KROK      krok wykresow - kazdy punkt = maksimum z tego okna (domyslnie: $HSTEP)
Przyklady: $0 -k -x | tee mem-now-\$(date +%F_%H%M).txt
           $0 -k -H infra-mem-\$(date +%F_%H%M).html
EOF
exit "${1:-0}"; }

# Opcje dlugie -> krotkie (getopts obsluguje tylko krotkie)
args=()
for a in "$@"; do case $a in
  --insecure|--insecure-skip-tls-verify|--insecure-skip-tls-verify=true) args+=(-k);;
  --help) args+=(-h);;
  --html) args+=(-H);;
  --html=*) args+=(-H "${a#--html=}");;
  *) args+=("$a");;
esac; done
set -- "${args[@]+"${args[@]}"}"

while getopts "n:l:t:r:T:L:H:D:S:B:W:kxh" o; do case $o in
  n) FOCUS=$OPTARG;; l) SELECTOR=$OPTARG;; t) TOPN=$OPTARG;; r) RATE=$OPTARG;;
  T) TREND=$OPTARG;; L) LOGWIN=$OPTARG;; k) CURL_K="-k"; OC_K=(--insecure-skip-tls-verify=true);; x) EXEC=1;;
  H) HTML=$OPTARG;; D) HDAYS=$OPTARG;; S) HSTEP=$OPTARG;; B) BASE=$OPTARG;; W) CWIN=$OPTARG;; h) usage 0;; *) usage 1;;
esac; done

die()  { echo "BLAD: $*" >&2; exit 1; }
warn() { echo "UWAGA: $*" >&2; }
LINE=$(printf '=%.0s' {1..100})
hdr()  { printf '\n%s\n== %s\n%s\n' "$LINE" "$1" "$LINE"; }
# CAPTURE=1: tabele i komentarze trafiaja tez do raportu HTML (sekcja "co sie zmienilo")
cap()  { [[ -n $CAPTURE && -n $HTML ]] || { cat >/dev/null; return 0; }
  jq -Rsc --arg t "$1" '{type:$t, text:(if $t=="table" then (split("\n")|map(select(length>0)|split("\t"))) else rtrimstr("\n") end)}' >>"$TMP/cap.jsonl"; }
sub()  { printf '\n--- %s\n' "$1"; cap h <<<"$1"; }
# Przyjazny komentarz pod tabela/sekcja
say()  { fold -s -w 96 <<<"$*" | sed 's/^/  | /'; cap note <<<"$*"; }

# Jedyna droga do klastra.
oc_ro() { case "${1:-}" in
  get|whoami|logs) command oc "${OC_K[@]+"${OC_K[@]}"}" "$@";;
  exec) (( EXEC )) || die "oc_ro: 'oc exec' dozwolone tylko z opcja -x"; command oc "${OC_K[@]+"${OC_K[@]}"}" "$@";;
  *) die "oc_ro: zablokowano 'oc $1' (skrypt jest tylko do odczytu)";; esac; }

for c in oc jq curl column awk; do command -v "$c" >/dev/null || die "brak polecenia: $c"; done
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: >"$TMP/findings"; : >"$TMP/cap.jsonl"

# --- pomocnicze -----------------------------------------------------------------
# finding POZIOM TEKST   (1 = krytyczne, 2 = uwaga, 3 = informacja)
finding() { printf '%s\t%s\n' "$1" "$2" >>"$TMP/findings"; }
hbs() { awk -v v="${1:-0}" 'BEGIN{a=v<0?-v:v; s=v<0?"-":"";
  if(a>=1073741824) printf "%s%.2f GiB",s,a/1073741824; else if(a>=1048576) printf "%s%.1f MiB",s,a/1048576;
  else if(a>=1024) printf "%s%.1f KiB",s,a/1024; else printf "%s%d B",s,a}'; }
ge()  { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
# czas trwania (30s, 5m, 1h, 2d, 1h30m) -> sekundy
dur2s() { awk -v d="$1" 'BEGIN{ t=0; while (match(d, /^[0-9]+[smhdw]/)) { n=substr(d,1,RLENGTH-1)+0; u=substr(d,RLENGTH,1);
  t+=n*(u=="s"?1:u=="m"?60:u=="h"?3600:u=="d"?86400:604800); d=substr(d,RLENGTH+1) } if (d!="" || t==0) exit 1; print t }'; }
pct() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if(b+0>0) printf "%.0f", a/b*100; else printf "0"}'; }

dur2s "$BASE" >/dev/null || die "-B: niepoprawny okres '$BASE' (np. 7d, 14d)"
dur2s "$CWIN" >/dev/null || die "-W: niepoprawne okno '$CWIN' (np. 1d, 6h)"
if [[ -n $HTML ]]; then
  [[ $HDAYS =~ ^[0-9]+$ ]] && (( HDAYS > 0 )) || die "-D: podaj liczbe dni (np. 14)"
  HSTEP_S=$(dur2s "$HSTEP") || die "-S: niepoprawny krok '$HSTEP' (np. 30m, 1h, 2h)"
  (( HDAYS * 86400 / HSTEP_S <= 11000 )) || die "za duzo punktow na wykresie (max 11000) - zwieksz -S albo zmniejsz -D"
  : >"$HTML" 2>/dev/null || die "nie moge zapisac pliku $HTML"
  # kopia calego raportu tekstowego do osadzenia w HTML
  exec 3>&1 > >(tee "$TMP/report.txt" >&3); TEE_PID=$!
fi

# --- dostep do Prometheusa ---------------------------------------------------------
if ! oc_ro whoami >/dev/null 2>"$TMP/err"; then
  if grep -qiE 'x509|certificate|tls' "$TMP/err" && [[ -z $CURL_K ]]; then
    die "blad certyfikatu TLS API klastra: $(head -c 200 "$TMP/err") - uruchom ponownie z -k (--insecure)"
  fi
  die "brak sesji oc - zaloguj sie do klastra ($(head -c 200 "$TMP/err"))"
fi
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
def num: (if type=="string" then (tonumber? // .) else . end)
         | if type=="number" and isnan then null else . end;
def hb: (if .<0 then "-" else "" end) as $s | (if .<0 then (0 - .) else . end) as $v |
  if   $v>=1073741824 then "\($s)\($v/1073741824|r2) GiB"
  elif $v>=1048576    then "\($s)\(($v/1048576*10|round)/10) MiB"
  elif $v>=1024       then "\($s)\(($v/1024*10|round)/10) KiB"
  else "\($s)\($v|round) B" end;
def fmt($u): if .==null then "-" elif type!="number" then tostring
  elif $u=="bytes" then hb elif $u=="dbytes" then ((if .>0 then "+" else "" end)+hb)
  elif $u=="bps" then (hb+"/s") elif $u=="rate" then ((r2|tostring)+"/s")
  elif $u=="pct" then "\(round)%" elif $u=="ms" then "\(round) ms"
  elif $u=="int" then (round|tostring) else (r2|tostring) end;
def key($keys): . as $m | [$keys|split(",")[] | ($m[.] // "-")] | join("\t");
def tomap($keys): reduce .data.result[] as $r ({}; .[$r.metric|key($keys)] = ($r.value[1]|num));
def mem2b: if .==null then null else (tostring | capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$") as $c
  | ($c.n|tonumber) * ({"":1,"k":1000,"K":1000,"M":1000000,"G":1000000000,"T":1000000000000,
      "Ki":1024,"Mi":1048576,"Gi":1073741824,"Ti":1099511627776,"m":0.001}[$c.u] // 1)) end;
def fake($keys): {data:{result:[ .[] | {metric:(.[0] as $k | [$keys|split(",")[]] as $ks
      | reduce range(0; $ks|length) as $i ({}; .[$ks[$i]] = ($k|split("\t"))[$i])), value:[0, .[1]]} ]}};
'
table() { local rows; rows=$(cat); cap table <<<"$rows"
  if [[ $(wc -l <<<"$rows") -le 1 ]]; then echo "  (brak danych)"; else column -t -s $'\t' <<<"$rows" | sed 's/^/  /'; fi; }
keyhdr() { tr 'a-z,' 'A-Z\t' <<<"$1" | sed 's/EXPORTED_//g'; }

# Tabela z kilku zapytan polaczonych po etykietach.
# multi TYTUL ETYKIETY KOLUMNA_SORTOWANIA  [NAZWA JEDNOSTKA ZAPYTANIE]...
#   ZAPYTANIE "@plik" = gotowa odpowiedz w formacie Prometheusa (np. dane z API)
multi() {
  local title=$1 keys=$2 sc=$3; shift 3
  local names=() units=() files=() i=0
  while (( $# >= 3 )); do
    names+=("$1"); units+=("$2")
    if [[ $3 == @* ]]; then files+=("${3#@}")
    else prom query "$TMP/m$i.json" "query=$3"; files+=("$TMP/m$i.json"); fi
    i=$((i+1)); shift 3
  done
  sub "$title"
  { printf '%s' "$(keyhdr "$keys")"; printf '\t%s' "${names[@]}"; echo
    jq -rs --arg keys "$keys" --argjson sc "$sc" --argjson n "$TOPN" \
       --argjson units "$(printf '%s\n' "${units[@]}" | jq -R . | jq -s .)" "$JQ_DEFS"'
      [ .[] | tomap($keys) ] as $maps
      | [ $maps[] | keys[] ] | unique
      | map(. as $k | {k:$k, v:[ $maps[] | .[$k] ]})
      | sort_by(-(.v[$sc] | if type=="number" then . else -1e18 end)) | .[:$n][]
      | (.k|split("\t")) + [ range(0; $units|length) as $i | (.v[$i] | fmt($units[$i])) ] | @tsv' "${files[@]}"
  } | table
}
pv() { prom query "$TMP/pv.json" "query=$1"; jq -r '.data.result[0].value[1] // empty' "$TMP/pv.json"; }
plist() { prom query "$TMP/pl.json" "query=$2"
  jq -r --arg keys "$1" "$JQ_DEFS"'.data.result[] | [(.metric|key($keys)), .value[1]] | @tsv' "$TMP/pl.json"; }

# =============================================================================
# 0. WEZLY
# =============================================================================
mapfile -t NODES < <(oc_ro get nodes -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
(( ${#NODES[@]} )) || die "brak wezlow dla selektora '$SELECTOR' (uzyj -l)"
NODE_RE=$(IFS='|'; echo "${NODES[*]}")
IF="instance=~\"$NODE_RE\""
USED="(node_memory_MemTotal_bytes{$IF} - node_memory_MemAvailable_bytes{$IF})"
USEDPCT="100 * (1 - node_memory_MemAvailable_bytes{$IF} / node_memory_MemTotal_bytes{$IF})"

echo "$LINE"
echo "PAMIEC I ROUTERY NA INFRANODE'ACH - STAN BIEZACY  (tryb: tylko odczyt$( ((EXEC)) && echo ' + oc exec do routerow'))"
echo "Klaster : $(oc_ro whoami --show-server)   uzytkownik: $(oc_ro whoami)"
echo "Czas    : $(date '+%F %T %Z')   'teraz' = srednia z ostatnich $RATE, trend = porownanie z $TREND temu"
echo "Wezly   : ${NODES[*]}"
cat <<'EOF'

Jak czytac: kazda sekcja ma tabele i pod nia komentarz "| ...". Najwazniejsze wnioski sa
zebrane na samym koncu w sekcji PODSUMOWANIE - mozna zaczac czytanie od niej.
EOF

# =============================================================================
# 0. CO SIE ZMIENILO: OSTATNIE OKNO vs TO SAMO OKNO $BASE TEMU
# =============================================================================
hdr "0. CO SIE ZMIENILO OD $BASE TEMU  (ostatnie $CWIN vs te same $CWIN sprzed $BASE)"
say "Kazdy wiersz to MAKSIMUM z okna $CWIN: teraz oraz dokladnie $BASE wczesniej (ten sam dzien tygodnia i pory dnia, wiec ruch jest porownywalny). Jesli $BASE temu bylo dobrze, to wiersze oznaczone '!! DUZY WZROST' wskazuja, co sie zmienilo."
CAPTURE=1
NS_R='namespace="openshift-ingress"'
# metryki routerow tylko z podow, ktore w danym momencie dzialaly na infranode'ach
ON_INFRA="* on (namespace,pod) group_left() max by (namespace,pod)(kube_pod_info{$NS_R,node=~\"$NODE_RE\"})"
RE_N="node=~\"$NODE_RE\""
WSC="container!=\"\",container!=\"POD\""
: >"$TMP/cmp.raw"
# crow OBSZAR NAZWA JEDNOSTKA WYRAZENIE
crow() {
  local now base
  now=$(pv "max_over_time(($4)[$CWIN:5m])")
  base=$(pv "max_over_time(($4)[$CWIN:5m] offset $BASE)")
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$base" "$now" >>"$TMP/cmp.raw"
}
echo "  (pobieram porownanie - kilkadziesiat zapytan, chwile to potrwa)" >&2
crow "Wezly"   "Zajeta pamiec infranode'ow (suma)"          bytes "sum(node_memory_MemTotal_bytes{$IF} - node_memory_MemAvailable_bytes{$IF})"
crow "Wezly"   "Najbardziej zajety infranode"               pct   "max($USEDPCT)"
crow "Wezly"   "Pamiec jadra nieodzyskiwalna (SUnreclaim)"  bytes "sum(node_memory_SUnreclaim_bytes{$IF})"
crow "Wezly"   "Gniazda TCP w uzyciu"                       int   "sum(node_sockstat_TCP_inuse{$IF})"
crow "Wezly"   "Wpisy conntrack"                            int   "sum(node_nf_conntrack_entries{$IF})"
crow "Wezly"   "Procesy w kontenerach na infranode'ach"     int   "sum(container_processes{$RE_N,$WSC})"
crow "Pody"    "Pody na infranode'ach"                      int   "count(kube_pod_info{$RE_N})"
crow "Pody"    "Pamiec podow na infranode'ach"              bytes "sum(container_memory_working_set_bytes{$RE_N,$WSC})"
crow "Pody"    "Pamiec monitoringu na infranode'ach"        bytes "sum(container_memory_working_set_bytes{namespace=\"openshift-monitoring\",$RE_N,$WSC})"
crow "Pody"    "Serie w Prometheusie (head)"                int   "max(prometheus_tsdb_head_series)"
crow "Klaster" "Pody w klastrze"                            int   "count(kube_pod_info)"
crow "Klaster" "Namespace'y"                                int   "count(kube_namespace_created)"
crow "Klaster" "Serwisy"                                    int   "count(kube_service_info)"
crow "Klaster" "Restarty kontenerow (na godzine)"           int   "sum(increase(kube_pod_container_status_restarts_total[1h]))"
crow "Klaster" "Zmiany gotowosci podow (na godzine)"        int   "sum(changes(kube_pod_status_ready{condition=\"true\"}[1h]))"
crow "Router"  "Pamiec routerow na infranode'ach"           bytes "sum(container_memory_working_set_bytes{$NS_R,container=\"router\",$RE_N})"
crow "Router"  "Procesy w kontenerach routera (haproxy)"    int   "sum(container_processes{$NS_R,container=\"router\",$RE_N})"
crow "Router"  "Route w HAProxy"                            int   "count(count by (exported_namespace,route)(haproxy_server_up{$NS_R} $ON_INFRA))"
crow "Router"  "Endpointy (pody) za route"                  int   "count(count by (exported_namespace,route,server)(haproxy_server_up{$NS_R} $ON_INFRA))"
crow "Router"  "Reloady routerow (na godzine)"              int   "sum(increase(template_router_reload_seconds_count{$NS_R}[1h]) $ON_INFRA)"
crow "Router"  "Aktywne polaczenia"                         int   "sum(haproxy_frontend_current_sessions{$NS_R} $ON_INFRA)"
crow "Router"  "Nowe polaczenia/s"                          rate  "sum(rate(haproxy_frontend_connections_total{$NS_R}[5m]) $ON_INFRA)"
crow "Router"  "Zadania HTTP/s"                             rate  "sum(rate(haproxy_backend_http_responses_total{$NS_R}[5m]) $ON_INFRA)"
crow "Router"  "Transfer (wejscie+wyjscie)"                 bps   "sum((rate(haproxy_frontend_bytes_in_total{$NS_R}[5m]) + rate(haproxy_frontend_bytes_out_total{$NS_R}[5m])) $ON_INFRA)"
crow "Router"  "Bledy polaczen do aplikacji (na godzine)"   int   "sum(increase(haproxy_backend_connection_errors_total{$NS_R}[1h]) $ON_INFRA)"
crow "Router"  "Odpowiedzi 5xx (na godzine)"                int   "sum(increase(haproxy_backend_http_responses_total{$NS_R,code=\"5xx\"}[1h]) $ON_INFRA)"

CMP_JQ="$JQ_DEFS"'
def n0: if .=="" then null else num end;
def sgn($u): if .==null then "-" elif $u=="pct" then "\(if .>0 then "+" else "" end)\(r2) p.p."
  else (if .>0 then "+" else "" end) + fmt($u) end;
split("\t") | {a:.[0], n:.[1], u:.[2], o:(.[3]|n0), c:(.[4]|n0)}
| .d = (if .o!=null and .c!=null then .c - .o else null end)
| .p = (if .d!=null and .o>0 then .d/.o*100 else null end)
| .f = (if .o==null and .c==null then "brak metryki"
        elif .o==null then "brak danych sprzed '"$BASE"'"
        elif .c==null then "brak danych teraz"
        elif (.u=="pct" and .d>=10) or (.u!="pct" and .p!=null and .p>=50) then "!! DUZY WZROST"
        elif (.u=="pct" and .d>=3)  or (.u!="pct" and .p!=null and .p>=15) then "!  wzrost"
        elif (.u=="pct" and .d<=-3) or (.u!="pct" and .p!=null and .p<=-15) then "spadek"
        elif .o==0 and .c>0 then "!! DUZY WZROST" else "bez zmian" end)'
sub "Porownanie: $BASE temu -> teraz"
{ printf 'OBSZAR\tMETRYKA\t%s_TEMU\tTERAZ\tZMIANA\tZMIANA_%%\tOCENA\n' "$BASE"
  jq -Rr "$CMP_JQ"' | . as $r | [.a, .n, ($r.o|fmt($r.u)), ($r.c|fmt($r.u)), ($r.d|sgn($r.u)),
        (if .p==null then "-" elif .p>=0 then "+\(.p|round)%" else "\(.p|round)%" end), .f] | @tsv' "$TMP/cmp.raw"
} | table
jq -Rr "$CMP_JQ"' | select(.f|startswith("!!")) | . as $r | "\(.n): \($r.o|fmt($r.u)) -> \($r.c|fmt($r.u)) (\(if .p==null then ($r.d|sgn($r.u)) else "+\(.p|round)%" end))"' \
  "$TMP/cmp.raw" | while read -r l; do finding 2 "Od $BASE temu wzroslo: $l"; done
say "Jak czytac: jesli wzrosly 'Reloady', 'Endpointy' lub 'Zmiany gotowosci podow', a wraz z nimi 'Pamiec routerow' i 'Procesy w kontenerach routera' - pamiec zjadaja stare procesy HAProxy po reloadach (przyczyna: rotacja podow za route). Jesli wzrosly 'Zadania HTTP/s', 'Aktywne polaczenia', 'Transfer' - to po prostu wiecej ruchu. 'Serie w Prometheusie' i 'Pamiec monitoringu' - wiecej metryk (nowe aplikacje/ServiceMonitory)."

# --- Co nowego: namespace'y i route utworzone w oknie --------------------------------
BASE_S=$(dur2s "$BASE"); CUT=$(( $(date +%s) - BASE_S ))
oc_ro get ns -o json >"$TMP/ns.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/ns.json"
oc_ro get routes -A -o json >"$TMP/routes.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/routes.json"
prom query "$TMP/nspods.json" "query=count by (namespace)(kube_pod_info)"
sub "Namespace'y utworzone w ostatnich $BASE"
{ printf 'NAMESPACE\tUTWORZONY\tPODY_TERAZ\tROUTE\n'
  jq -r --argjson cut "$CUT" --slurpfile p "$TMP/nspods.json" --slurpfile r "$TMP/routes.json" '
    ([$p[0].data.result[] | select(.metric.namespace != null) | {(.metric.namespace): .value[1]}] | add // {}) as $pc
    | ([$r[0].items[].metadata.namespace | select(. != null)] | group_by(.) | map({(.[0]): length}) | add // {}) as $rc
    | [.items[] | select(((.metadata.creationTimestamp // "1970-01-01T00:00:00Z")|fromdateiso8601) >= $cut)]
    | sort_by(.metadata.creationTimestamp) | reverse | .[]
    | [.metadata.name, .metadata.creationTimestamp, ($pc[.metadata.name] // "0"), (($rc[.metadata.name] // 0)|tostring)] | @tsv' "$TMP/ns.json"
} | table
NEWR=$(jq --argjson cut "$CUT" '[.items[] | select(((.metadata.creationTimestamp // "1970-01-01T00:00:00Z")|fromdateiso8601) >= $cut)] | length' "$TMP/routes.json")
sub "Route utworzone w ostatnich $BASE  (lacznie: ${NEWR:-0}, pokazuje najnowsze $TOPN)"
{ printf 'NAMESPACE\tROUTE\tUTWORZONA\tTLS\tROUTER\n'
  jq -r --argjson cut "$CUT" --argjson n "$TOPN" '
    [.items[] | select(((.metadata.creationTimestamp // "1970-01-01T00:00:00Z")|fromdateiso8601) >= $cut)]
    | sort_by(.metadata.creationTimestamp) | reverse | .[:$n][]
    | [.metadata.namespace, .metadata.name, .metadata.creationTimestamp, (.spec.tls.termination // "brak (http)"),
       ([.status.ingress[]?.routerName] | unique | join(","))] | @tsv' "$TMP/routes.json"
} | table
ge "${NEWR:-0}" 1 && finding 3 "W ostatnich $BASE utworzono $NEWR nowych route (sekcja 0) - kazda to nowy backend w HAProxy."

# --- Kto urosl: tabele "przed -> teraz" z kolumna ZMIANA ------------------------------
# A - (B or A*0): roznica takze dla serii, ktorych wczesniej nie bylo (wtedy ZMIANA = calosc)
dlt() { echo "($1) - (($2) or ($1) * 0)"; }
OFF="offset $BASE"
RK="exported_namespace,route"

A="sum by ($RK)(rate(haproxy_backend_http_responses_total{$NS_R}[$CWIN]))"
B="sum by ($RK)(rate(haproxy_backend_http_responses_total{$NS_R}[$CWIN] $OFF))"
S="max_over_time(sum by ($RK)(haproxy_server_current_sessions{$NS_R})[$CWIN:5m])"
SB="max_over_time(sum by ($RK)(haproxy_server_current_sessions{$NS_R})[$CWIN:5m] $OFF)"
E="count by ($RK)(count by ($RK,server)(haproxy_server_up{$NS_R}))"
EB="count by ($RK)(count by ($RK,server)(haproxy_server_up{$NS_R} $OFF))"
route_cmp=(
  "ZAD/s_TEMU"   rate "$B"  "ZAD/s_TERAZ"   rate "$A"  "ZMIANA_ZAD/s" rate "$(dlt "$A" "$B")"
  "SESJE_TEMU"   int  "$SB" "SESJE_TERAZ"   int  "$S"  "ZMIANA_SESJI" int  "$(dlt "$S" "$SB")"
  "ENDP_TEMU"    int  "$EB" "ENDP_TERAZ"    int  "$E"
)
multi "Route z najwiekszym WZROSTEM RUCHU (srednie zadania/s z $CWIN; wszystkie routery)" "$RK" 2 "${route_cmp[@]}"
multi "Route z najwiekszym WZROSTEM AKTYWNYCH SESJI (max z $CWIN; dlugie polaczenia trzymaja pamiec)" "$RK" 5 "${route_cmp[@]}"
say "Route, ktorej $BASE temu nie bylo, ma w kolumnach *_TEMU '-' i cala wartosc w ZMIANA. ENDP = liczba podow za route - duzy wzrost oznacza wiecej backendow do przeladowania przy kazdej zmianie."

W="max_over_time(sum by (namespace)(container_memory_working_set_bytes{$RE_N,$WSC})[$CWIN:5m])"
WB="max_over_time(sum by (namespace)(container_memory_working_set_bytes{$RE_N,$WSC})[$CWIN:5m] $OFF)"
P="max_over_time(count by (namespace)(kube_pod_info{$RE_N})[$CWIN:5m])"
PB="max_over_time(count by (namespace)(kube_pod_info{$RE_N})[$CWIN:5m] $OFF)"
multi "Namespace'y NA INFRANODE'ACH - kto urosl w pamieci" "namespace" 2 \
  "PAMIEC_TEMU" bytes "$WB" "PAMIEC_TERAZ" bytes "$W" "ZMIANA" dbytes "$(dlt "$W" "$WB")" \
  "PODY_TEMU" int "$PB" "PODY_TERAZ" int "$P"

PC="count by (namespace)(kube_pod_info)"; PCB="count by (namespace)(kube_pod_info $OFF)"
RS="sum by (namespace)(increase(kube_pod_container_status_restarts_total[$CWIN]))"
RSB="sum by (namespace)(increase(kube_pod_container_status_restarts_total[$CWIN] $OFF))"
CH="sum by (namespace)(changes(kube_pod_status_ready{condition=\"true\"}[$CWIN]))"
CHB="sum by (namespace)(changes(kube_pod_status_ready{condition=\"true\"}[$CWIN] $OFF))"
ns_cmp=(
  "PODY_TEMU" int "$PCB" "PODY_TERAZ" int "$PC" "ZMIANA_PODOW" int "$(dlt "$PC" "$PCB")"
  "RESTARTY_TEMU" int "$RSB" "RESTARTY_TERAZ" int "$RS"
  "ZM_READY_TEMU" int "$CHB" "ZM_READY_TERAZ" int "$CH" "ZMIANA_ZM_READY" int "$(dlt "$CH" "$CHB")"
)
multi "Namespace'y w KLASTRZE z najwiekszym przyrostem podow" "namespace" 2 "${ns_cmp[@]}"
multi "Namespace'y w KLASTRZE z najwiekszym przyrostem ROTACJI podow (zmiany gotowosci w $CWIN)" "namespace" 7 "${ns_cmp[@]}"
say "ZM_READY = ile razy pody zmienily stan gotowosci w $CWIN. Kazda taka zmiana poda za route zmienia endpointy i wymusza reload routera - to najczestsza przyczyna rosnacej pamieci routerow. RESTARTY = restarty kontenerow w $CWIN."
CAPTURE=""

hdr "1. PAMIEC INFRANODE'OW TERAZ"
multi "Zuzycie pamieci (posortowane wg %UZYTE)" "instance" 2 \
  "RAM"          bytes  "node_memory_MemTotal_bytes{$IF}" \
  "UZYTE"        bytes  "$USED" \
  "%UZYTE"       pct    "$USEDPCT" \
  "%Z_CACHE"     pct    "100 * (1 - node_memory_MemFree_bytes{$IF} / node_memory_MemTotal_bytes{$IF})" \
  "%1h_TEMU"     pct    "100 * (1 - node_memory_MemAvailable_bytes{$IF} offset 1h / node_memory_MemTotal_bytes{$IF} offset 1h)" \
  "%${TREND}_TEMU" pct  "100 * (1 - node_memory_MemAvailable_bytes{$IF} offset $TREND / node_memory_MemTotal_bytes{$IF} offset $TREND)" \
  "TEMPO/h(6h)"  dbytes "deriv(${USED}[6h:5m]) * 3600" \
  "MAX_${TREND}" pct    "max_over_time((${USEDPCT})[$TREND:5m])"
say "UZYTE / %UZYTE = MemTotal - MemAvailable. Tak liczy konsola OpenShift i alerty. To pamiec, ktorej jadro NIE moze szybko odzyskac."
say "%Z_CACHE = MemTotal - MemFree, czyli razem z cache plikow. Tak liczy np. 'free' w kolumnie used+buff/cache i czesc dashboardow. Jesli Twoje 75% pochodzi z takiego widoku, realne zuzycie jest nizsze (kolumna %UZYTE)."
say "TEMPO/h = sredni przyrost na godzine w ostatnich 6h. Stale dodatnie tempo przy stalym ruchu moze oznaczac wyciek."

while IFS=$'\t' read -r n p; do
  [[ -n $n ]] || continue
  if ge "$p" 90; then finding 1 "Wezel $n ma zajete ${p%.*}% RAM (wg MemAvailable) - blisko progu presji pamieci i ewikcji podow."
  elif ge "$p" 75; then finding 2 "Wezel $n ma zajete ${p%.*}% RAM (wg MemAvailable)."; fi
done < <(plist instance "$USEDPCT")
while IFS=$'\t' read -r n s; do
  [[ -n $n ]] || continue
  t=$(pv "node_memory_MemTotal_bytes{instance=\"$n\"}")
  ge "$s" "$(awk -v t="${t:-0}" 'BEGIN{print t*0.01}')" && \
    finding 2 "Pamiec na $n rosnie o $(hbs "$s")/h (srednio z 6h) - sprawdz kolumne ZMIANA w sekcji 3, ktory pod rosnie."
done < <(plist instance "deriv(${USED}[6h:5m]) * 3600")

if [[ -z $FOCUS ]]; then
  FOCUS=$(plist instance "$USEDPCT" | sort -t$'\t' -k2,2 -gr | head -1 | cut -f1)
  [[ -n $FOCUS ]] || FOCUS=${NODES[0]}
fi
printf '%s\n' "${NODES[@]}" | grep -qxF "$FOCUS" || die "wezel '$FOCUS' nie jest na liscie infranode'ow"
echo
echo "  >>> Szczegolowa analiza dotyczy wezla: $FOCUS   (inny: -n WEZEL)"

FF="node=\"$FOCUS\""; FI="instance=\"$FOCUS\""; CF="$FF,container!=\"\",container!=\"POD\""
TOTAL=$(pv "node_memory_MemTotal_bytes{$FI}"); TOTAL=${TOTAL:-0}

# =============================================================================
# 2. Z CZEGO SKLADA SIE ZAJETA PAMIEC
# =============================================================================
hdr "2. Z CZEGO SKLADA SIE PAMIEC WEZLA $FOCUS"
prom query "$TMP/mi.json" "query={__name__=~\"node_memory_.+_bytes\",$FI}"
MI_MAP='(reduce .data.result[] as $r ({}; .[$r.metric.__name__|sub("^node_memory_";"")|sub("_bytes$";"")] = ($r.value[1]|num)))'
sub "Rozbicie wg /proc/meminfo"
{ printf 'SKLADNIK\tROZMIAR\t%%RAM\tCO TO ZNACZY\n'
  jq -r "$JQ_DEFS$MI_MAP"' as $m | ($m.MemTotal // 0) as $t | select($t > 0)
   | [ ["Procesy - pamiec anonimowa (heap, stosy)", ($m.AnonPages//0), "NIE odzyskiwalne - to realnie zuzywaja aplikacje i uslugi"],
       ["Page cache (pliki)", (($m.Cached//0)-($m.Shmem//0)), "odzyskiwalne - jadro odda, gdy aplikacje potrzebuja"],
       ["Bufory blokowe", ($m.Buffers//0), "odzyskiwalne"],
       ["Shmem / tmpfs (emptyDir Memory, /dev/shm)", ($m.Shmem//0), "NIE odzyskiwalne, poki pliki istnieja"],
       ["Slab odzyskiwalny (cache katalogow, inode)", ($m.SReclaimable//0), "odzyskiwalne"],
       ["Slab NIEodzyskiwalny (gniazda, conntrack)", ($m.SUnreclaim//0), "rosnie z liczba polaczen i obiektow jadra"],
       ["Stosy jadra + tablice stron", (($m.KernelStack//0)+($m.PageTables//0)), "rosnie z liczba procesow/watkow"],
       ["Hugepages (zarezerwowane)", ($m.Hugetlb//0), "zarezerwowane na stale"],
       ["Wolne", ($m.MemFree//0), "nieuzywane wcale"] ] as $rows
   | ($rows + [["Pozostale (vmalloc, sterowniki, ...)", ($t - ($rows|map(.[1])|add)), ""]])[]
   | [.[0], (.[1]|hb), "\(.[1]/$t*100|round)%", .[2]] | @tsv' "$TMP/mi.json"
} | table
read -r MT UA UF REC SUN SHM < <(jq -r "$JQ_DEFS$MI_MAP"' as $m
  | [($m.MemTotal//0), (($m.MemTotal//0)-($m.MemAvailable//0)), (($m.MemTotal//0)-($m.MemFree//0)),
     (($m.Cached//0)-($m.Shmem//0)+($m.Buffers//0)+($m.SReclaimable//0)), ($m.SUnreclaim//0), ($m.Shmem//0)]
  | map(tostring) | join(" ")' "$TMP/mi.json")
if ge "${MT:-0}" 1; then
  PA=$(pct "$UA" "$MT"); PF=$(pct "$UF" "$MT")
  echo
  say "Zajete wg MemAvailable (konsola, alerty): $(hbs "$UA") = $PA% RAM."
  say "Zajete wg MemTotal-MemFree (z cache):    $(hbs "$UF") = $PF% RAM."
  say "Cache, ktory jadro moze oddac od reki:   ~$(hbs "$REC"). Wysoki cache sam w sobie NIE jest problemem."
  ge "$(pct "$SUN" "$MT")" 5 && finding 2 "Na $FOCUS pamiec jadra nieodzyskiwalna (SUnreclaim) to $(hbs "$SUN") ($(pct "$SUN" "$MT")% RAM) - zwykle duzo gniazd TCP / wpisow conntrack (patrz sekcja 6)."
  ge "$(pct "$SHM" "$MT")" 5 && finding 2 "Na $FOCUS tmpfs/shmem zajmuje $(hbs "$SHM") - sprawdz pody z emptyDir medium: Memory."
  ge "$PF" $((PA + 10)) && \
    finding 3 "Na $FOCUS 'zajete z cache' to $PF%, a realne zuzycie $PA% - roznica to odzyskiwalny cache plikow, nie wymaga dzialania."
fi

multi "Pody (kubepods) vs system (system.slice: kubelet, crio, ovs, ...)" "id" 0 \
  "WORKING_SET" bytes "container_memory_working_set_bytes{$FF,id=~\"/kubepods.slice|/system.slice\"}" \
  "RSS"         bytes "container_memory_rss{$FF,id=~\"/kubepods.slice|/system.slice\"}" \
  "%RAM"        pct   "100 * container_memory_working_set_bytes{$FF,id=~\"/kubepods.slice|/system.slice\"} / scalar(node_memory_MemTotal_bytes{$FI})"

oc_ro get node "$FOCUS" -o json >"$TMP/node.json"
oc_ro get pods -A --field-selector "spec.nodeName=$FOCUS,status.phase!=Succeeded,status.phase!=Failed" -o json >"$TMP/pods.json" \
  || echo '{"items":[]}' >"$TMP/pods.json"
oc_ro get --raw "/api/v1/nodes/$FOCUS/proxy/configz" >"$TMP/configz.json" 2>/dev/null || echo '{}' >"$TMP/configz.json"
sub "Rezerwacje i requesty na wezle"
{ printf 'POZYCJA\tWARTOSC\tKOMENTARZ\n'
  jq -rn --slurpfile n "$TMP/node.json" --slurpfile p "$TMP/pods.json" --slurpfile k "$TMP/configz.json" "$JQ_DEFS"'
    (($n[0].status.capacity.memory // "0")|mem2b) as $cap | (($n[0].status.allocatable.memory // "0")|mem2b) as $alloc
    | [$p[0].items[] | [.spec.containers[] | (.resources.requests.memory // "0" | mem2b)] | add] as $reqs
    | ($k[0].kubeletconfig // {}) as $kc
    | ["Pojemnosc wezla", ($cap|hb), ""],
      ["Allocatable (dla podow)", ($alloc|hb), "pojemnosc minus rezerwacje systemowe i prog ewikcji"],
      ["Zarezerwowane dla systemu", (($cap-$alloc)|hb), "system-reserved + kube-reserved + eviction-hard"],
      ["systemReserved.memory", ($kc.systemReserved.memory // "?"), "z kubelet configz (? = brak dostepu)"],
      ["Prog ewikcji memory.available", ($kc.evictionHard["memory.available"] // "?"), "ponizej tej wolnej pamieci kubelet zaczyna usuwac pody"],
      ["Suma requestow pamieci podow", (($reqs|add // 0)|hb), "\(if $alloc>0 then (($reqs|add // 0)/$alloc*100|round) else "?" end)% allocatable - tylko to gwarantuje scheduler"],
      ["Liczba podow na wezle", ($p[0].items|length|tostring), ""]
    | @tsv'
} | table
say "Jesli pody zuzywaja wyraznie wiecej niz suma requestow, wezel jest przeciazony 'na kredyt': przy presji pamieci kubelet usunie najpierw pody BestEffort/Burstable przekraczajace request."

# =============================================================================
# 3. KTO ZUZYWA PAMIEC
# =============================================================================
hdr "3. KTO ZUZYWA PAMIEC NA $FOCUS"
WSQ="sum by (namespace,pod)(container_memory_working_set_bytes{$CF})"
prom query "$TMP/ws.json" "query=$WSQ"
jq "$JQ_DEFS"'[.items[] | ["\(.metadata.namespace)\t\(.metadata.name)",
    ([.spec.containers[] | (.resources.requests.memory // "0" | mem2b)] | add)]] | fake("namespace,pod")' "$TMP/pods.json" >"$TMP/req.json"
jq "$JQ_DEFS"'[.items[] | ["\(.metadata.namespace)\t\(.metadata.name)",
    (if all(.spec.containers[]; .resources.limits.memory != null)
     then ([.spec.containers[] | (.resources.limits.memory | mem2b)] | add) else "brak" end)]] | fake("namespace,pod")' "$TMP/pods.json" >"$TMP/lim.json"
jq "$JQ_DEFS"'[.items[] | ["\(.metadata.namespace)\t\(.metadata.name)", .status.qosClass]] | fake("namespace,pod")' "$TMP/pods.json" >"$TMP/qos.json"
jq "$JQ_DEFS"'[.items[] | ["\(.metadata.namespace)\t\(.metadata.name)",
    ([.status.containerStatuses[]?.restartCount] | add // 0)]] | fake("namespace,pod")' "$TMP/pods.json" >"$TMP/rst.json"
jq -n --slurpfile w "$TMP/ws.json" --slurpfile l "$TMP/lim.json" "$JQ_DEFS"'
  ($l[0]|tomap("namespace,pod")) as $lm
  | [$w[0]|tomap("namespace,pod")|to_entries[] | select(($lm[.key]|type)=="number" and $lm[.key]>0)
     | [.key, (.value/$lm[.key]*100)]] | fake("namespace,pod")' >"$TMP/plim.json"

multi "Pody - najwieksze zuzycie teraz" "namespace,pod" 0 \
  "WORKING_SET" bytes  "@$TMP/ws.json" \
  "%RAM"        pct    "100 * $WSQ / scalar(node_memory_MemTotal_bytes{$FI})" \
  "RSS"         bytes  "sum by (namespace,pod)(container_memory_rss{$CF})" \
  "REQUEST"     bytes  "@$TMP/req.json" \
  "LIMIT"       bytes  "@$TMP/lim.json" \
  "%LIMITU"     pct    "@$TMP/plim.json" \
  "ZMIANA_$TREND" dbytes "$WSQ - (sum by (namespace,pod)(container_memory_working_set_bytes{$CF} offset $TREND) or $WSQ * 0)" \
  "QOS"         str    "@$TMP/qos.json" \
  "RESTARTY"    int    "@$TMP/rst.json"
say "WORKING_SET = pamiec liczona przez kubelet do limitow i ewikcji (RSS + aktywny cache plikow). RSS = sama pamiec procesow."
say "%LIMITU blisko 100% = ryzyko OOMKill. LIMIT 'brak' = pod moze rosnac bez ograniczen. ZMIANA = wzrost od $TREND (pod nowszy niz $TREND pokazuje caly swoj rozmiar)."

multi "Pody - najwiekszy WZROST od $TREND" "namespace,pod" 0 \
  "ZMIANA"      dbytes "$WSQ - (sum by (namespace,pod)(container_memory_working_set_bytes{$CF} offset $TREND) or $WSQ * 0)" \
  "TERAZ"       bytes  "@$TMP/ws.json" \
  "${TREND}_TEMU" bytes "sum by (namespace,pod)(container_memory_working_set_bytes{$CF} offset $TREND)"

multi "Namespace'y" "namespace" 0 \
  "WORKING_SET" bytes  "sum by (namespace)(container_memory_working_set_bytes{$CF})" \
  "%RAM"        pct    "100 * sum by (namespace)(container_memory_working_set_bytes{$CF}) / scalar(node_memory_MemTotal_bytes{$FI})" \
  "ZMIANA_$TREND" dbytes "sum by (namespace)(container_memory_working_set_bytes{$CF}) - sum by (namespace)(container_memory_working_set_bytes{$CF} offset $TREND)" \
  "PODY"        int    "count by (namespace)($WSQ)"

multi "Uslugi systemowe (system.slice) - poza podami" "id" 0 \
  "RSS"         bytes  "container_memory_rss{$FF,id=~\"/system.slice/.+\"}" \
  "WORKING_SET" bytes  "container_memory_working_set_bytes{$FF,id=~\"/system.slice/.+\"}" \
  "ZMIANA_$TREND" dbytes "container_memory_rss{$FF,id=~\"/system.slice/.+\"} - container_memory_rss{$FF,id=~\"/system.slice/.+\"} offset $TREND"
say "Tu widac kubelet, crio, ovs-vswitchd/ovsdb-server, NetworkManager. Ich suma powinna miescic sie w systemReserved (inaczej alert SystemMemoryExceedsReservation)."

# wnioski z sekcji 3
jq -rn --slurpfile w "$TMP/ws.json" --slurpfile l "$TMP/lim.json" --slurpfile q "$TMP/qos.json" \
       --argjson t "$TOTAL" --arg n "$FOCUS" "$JQ_DEFS"'
  ($w[0]|tomap("namespace,pod")) as $wm | ($l[0]|tomap("namespace,pod")) as $lm | ($q[0]|tomap("namespace,pod")) as $qm
  | ($wm|to_entries|map(select(.value|type=="number"))|sort_by(-.value)) as $top
  | (if ($top|length)>0 and $t>0 then
       "3\tNajwiecej pamieci na \($n): " + ([$top[:3][] | "\(.key|sub("\t";"/")) \(.value|hb) (\(.value/$t*100|round)%)"] | join(", ")) + "."
     else empty end),
    ($top[] | select(($lm[.key]|type)=="number" and $lm[.key]>0 and .value/$lm[.key] >= 0.9)
       | "2\tPod \(.key|sub("\t";"/")) uzywa \(.value/$lm[.key]*100|round)% swojego limitu (\(.value|hb) z \($lm[.key]|hb)) - ryzyko OOMKill."),
    ([$top[] | select($lm[.key]=="brak")] as $nl | if ($nl|length)>0 then
       "3\t\($nl|length) podow na \($n) nie ma limitu pamieci; najwiekszy z nich: \($nl[0].key|sub("\t";"/")) (\($nl[0].value|hb))." else empty end),
    ([$top[] | select($qm[.key]=="BestEffort")] | if length>0 then
       "3\t\(length) podow BestEffort na \($n) (bez requestow) - zostana usuniete jako pierwsze przy presji pamieci." else empty end)' \
  >>"$TMP/findings"
while IFS=$'\t' read -r ns pod d; do
  [[ -n $pod ]] || continue
  ge "$d" "$(awk -v t="$TOTAL" 'BEGIN{print t*0.05}')" && \
    finding 2 "Pod $ns/$pod urosl o $(hbs "$d") w ciagu $TREND (>5% RAM wezla) - sprawdz, czy to wzrost ruchu/danych, czy wyciek."
done < <(plist "namespace,pod" "$WSQ - sum by (namespace,pod)(container_memory_working_set_bytes{$CF} offset $TREND)")

# =============================================================================
# 4. PROCESY
# =============================================================================
hdr "4. PROCESY  (pamiec procesow, ktore same raportuja metryki)"
multi "Procesy w podach na $FOCUS (process_resident_memory_bytes)" "namespace,pod,job" 0 \
  "RSS_PROCESU"  bytes "max by (namespace,pod,job)(process_resident_memory_bytes) * on (namespace,pod) group_left() max by (namespace,pod)(kube_pod_info{$FF})" \
  "WATKI_GO"     int   "max by (namespace,pod,job)(go_threads) * on (namespace,pod) group_left() max by (namespace,pod)(kube_pod_info{$FF})" \
  "OTWARTE_FD"   int   "max by (namespace,pod,job)(process_open_fds) * on (namespace,pod) group_left() max by (namespace,pod)(kube_pod_info{$FF})"
multi "Prometheus na $FOCUS - liczba serii w pamieci (glowny czynnik jego zuzycia RAM)" "namespace,pod" 0 \
  "SERIE_HEAD"   int   "max by (namespace,pod)(prometheus_tsdb_head_series) * on (namespace,pod) group_left() max by (namespace,pod)(kube_pod_info{$FF})" \
  "ZMIANA_$TREND" int  "(max by (namespace,pod)(prometheus_tsdb_head_series) - max by (namespace,pod)(prometheus_tsdb_head_series offset $TREND)) * on (namespace,pod) group_left() max by (namespace,pod)(kube_pod_info{$FF})" \
  "PROBKI/s"     rate  "sum by (namespace,pod)(rate(prometheus_tsdb_head_samples_appended_total[$RATE])) * on (namespace,pod) group_left() max by (namespace,pod)(kube_pod_info{$FF})"
say "Na infranode'ach zwykle najwiecej RAM bierze Prometheus: ~ liczba serii x kilka KiB. Wzrost serii = nowe metryki/etykiety (np. pody z losowymi nazwami, duzo route)."
say "Pelna lista procesow systemu wymaga 'oc debug node' - tego skrypt nie robi. Procesy wewnatrz routerow: opcja -x (sekcja 6)."

# =============================================================================
# 5. INGRESS - KONFIGURACJA
# =============================================================================
hdr "5. INGRESS CONTROLLER - KONFIGURACJA I PULA POLACZEN"
oc_ro get ingresscontroller -n openshift-ingress-operator -o json >"$TMP/ic.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/ic.json"
oc_ro get deploy -n openshift-ingress -o json >"$TMP/rdep.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/rdep.json"
oc_ro get pods -n openshift-ingress -o json >"$TMP/rpods.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/rpods.json"
[[ -s $TMP/routes.json ]] || oc_ro get routes -A -o json >"$TMP/routes.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/routes.json"

# Konfiguracja efektywna per IngressController: env kontenera router w deploymencie
jq -n --slurpfile ic "$TMP/ic.json" --slurpfile d "$TMP/rdep.json" --slurpfile r "$TMP/routes.json" \
      --argjson defmc "$DEF_MAXCONN" --argjson defbuf "$DEF_BUF" "$JQ_DEFS"'
  [ $ic[0].items[] | .metadata.name as $n | . as $i
    | ([$d[0].items[] | select(.metadata.name==("router-"+$n))] | .[0]) as $dep
    | (($dep.spec.template.spec.containers // []) | map(select(.name=="router")) | .[0]) as $c
    | (($c.env // []) | map({(.name): (.value // "(z referencji)")}) | add // {}) as $e
    | {ic:$n, env:$e, dep:$dep, spec:$i.spec, status:$i.status,
       maxconn:(($e.ROUTER_MAX_CONNECTIONS // "") as $v | if $v=="" then $defmc else ($v|tonumber? // $v) end),
       maxconn_def:(($e.ROUTER_MAX_CONNECTIONS // "")==""),
       buf:(($e.ROUTER_BUF_SIZE // "") as $v | if $v=="" then $defbuf else ($v|tonumber? // $defbuf) end),
       mem_req:($c.resources.requests.memory // "brak"), mem_lim:($c.resources.limits.memory // "brak"),
       cpu_req:($c.resources.requests.cpu // "brak"), cpu_lim:($c.resources.limits.cpu // "brak"),
       routes:([$r[0].items[] | select(any(.status.ingress[]?; .routerName==$n and
                 any(.conditions[]?; .type=="Admitted" and .status=="True")))] | length)} ]' >"$TMP/iccfg.json"

jq -r '.[].ic' "$TMP/iccfg.json" | while read -r ic; do
  sub "IngressController: $ic"
  { printf 'PARAMETR\tWARTOSC\tCO TO ZNACZY\n'
    jq -r --arg ic "$ic" "$JQ_DEFS"'.[] | select(.ic==$ic) | .env as $e
     | def ev($k; $d): ($e[$k] // "\($d) (domyslne)");
       ["Repliki (zadane / gotowe)", "\(.dep.spec.replicas // "?") / \(.dep.status.readyReplicas // 0)", ""],
       ["Publikacja", (.status.endpointPublishingStrategy.type // .spec.endpointPublishingStrategy.type // "?"), "jak ruch trafia do routerow"],
       ["Route obslugiwane (Admitted)", (.routes|tostring), "kazda route = backend w HAProxy (pamiec + czas reloadu)"],
       ["maxconn (pula polaczen)", "\(.maxconn)\(if .maxconn_def then " (domyslne)" else "" end)", "max. jednoczesnych polaczen na proces HAProxy; po wyczerpaniu nowe czekaja w kolejce jadra"],
       ["Watki HAProxy", ev("ROUTER_THREADS"; 4), "watki obslugujace ruch"],
       ["Bufor na polaczenie (tune.bufsize)", "\(.buf) B", "kazde aktywne polaczenie moze zajac ~2 takie bufory"],
       ["maxrewrite", ev("ROUTER_MAX_REWRITE_SIZE"; 8192), "czesc bufora na naglowki"],
       ["Timeout klienta / serwera", "\(ev("ROUTER_DEFAULT_CLIENT_TIMEOUT"; "30s")) / \(ev("ROUTER_DEFAULT_SERVER_TIMEOUT"; "30s"))", "ile bezczynne polaczenie HTTP trzyma pamiec"],
       ["Timeout tunelu (websocket/TCP)", ev("ROUTER_DEFAULT_TUNNEL_TIMEOUT"; "1h"), "dlugie polaczenia trzymaja bufory i stare procesy po reloadzie"],
       ["hard-stop-after", ($e.ROUTER_HARD_STOP_AFTER // "BRAK"), "po tym czasie stary proces HAProxy jest ubijany po reloadzie; BRAK = zyje az klienci sie rozlacza"],
       ["Minimalny odstep reloadow", ev("RELOAD_INTERVAL"; "5s"), "czestsze zmiany route sa grupowane"],
       ["Interwal healthcheckow", ev("ROUTER_BACKEND_CHECK_INTERVAL"; "5s"), ""],
       ["Access log", (.spec.logging.access.destination.type // "wylaczony"), ""],
       ["Pamiec routera request / limit", "\(.mem_req) / \(.mem_lim)", "brak limitu = router moze zajac dowolnie duzo RAM wezla"],
       ["CPU routera request / limit", "\(.cpu_req) / \(.cpu_lim)", ""],
       ["tuningOptions (spec)", ((.spec.tuningOptions // {}) | to_entries | map("\(.key)=\(.value)") | join(", ") | if .=="" then "(brak - wartosci domyslne)" else . end), ""],
       ["unsupportedConfigOverrides", (if .spec.unsupportedConfigOverrides then (.spec.unsupportedConfigOverrides|tojson) else "brak" end), ""],
       ["Szacunek buforow przy pelnym maxconn", (if (.maxconn|type)=="number" then (.maxconn*2*.buf|hb) else "?" end), "gorna granica na JEDEN proces HAProxy (realnie mniej - bufory sa przydzielane tylko aktywnym transferom)"]
     | @tsv' "$TMP/iccfg.json"
  } | table
  jq -e --arg ic "$ic" '.[] | select(.ic==$ic) | .env.ROUTER_HARD_STOP_AFTER == null' "$TMP/iccfg.json" >/dev/null && \
    finding 3 "IngressController $ic nie ma hard-stop-after: po kazdym reloadzie stary proces HAProxy zyje (i trzyma pamiec), dopoki ostatni klient long-lived (websocket) sie nie rozlaczy. Rozwazyc adnotacje ingress.operator.openshift.io/hard-stop-after."
  jq -e --arg ic "$ic" '.[] | select(.ic==$ic) | .mem_lim == "brak"' "$TMP/iccfg.json" >/dev/null && \
    finding 3 "Routery '$ic' nie maja limitu pamieci (domyslne w OpenShift) - ich zuzycie trzeba sledzic na poziomie wezla."
done

# Pody routerow na infranode'ach (do filtrowania metryk)
jq -n --slurpfile p "$TMP/rpods.json" --slurpfile c "$TMP/iccfg.json" --arg re "^($NODE_RE)$" '
  ($c[0] | map({(.ic): .}) | add // {}) as $cm
  | [$p[0].items[] | select(.status.phase=="Running")
     | (.metadata.labels["ingresscontroller.operator.openshift.io/deployment-ingresscontroller"] // empty) as $ic
     | select((.spec.nodeName // "")|test($re))
     | {key:.metadata.name, value:{node:.spec.nodeName, ic:$ic, maxconn:($cm[$ic].maxconn // null), buf:($cm[$ic].buf // null)}}]
  | from_entries' >"$TMP/rmap.json"
mapfile -t RPODS < <(jq -r 'keys[]' "$TMP/rmap.json")
RPOD_RE=$(IFS='|'; echo "${RPODS[*]}")
BUF=$(jq -r '[.[].buf] | map(select(.!=null)) | .[0] // empty' "$TMP/rmap.json"); BUF=${BUF:-$DEF_BUF}

# =============================================================================
# 6. ROUTERY - WYDAJNOSC TERAZ
# =============================================================================
hdr "6. ROUTERY NA INFRANODE'ACH - RUCH I WYDAJNOSC TERAZ  (rate $RATE)"
if (( ${#RPODS[@]} == 0 )); then
  echo "  Na infranode'ach nie dziala zaden pod routera (openshift-ingress) - pomijam."
else
RF="namespace=\"openshift-ingress\",pod=~\"$RPOD_RE\""
RC="$RF,container!=\"\",container!=\"POD\""
jq '{data:{result:[to_entries[] | {metric:{pod:.key}, value:[0, .value.node]}]}}' "$TMP/rmap.json" >"$TMP/rnode.json"
jq '{data:{result:[to_entries[] | {metric:{pod:.key}, value:[0, .value.ic]}]}}' "$TMP/rmap.json" >"$TMP/ric.json"
jq '{data:{result:[to_entries[] | {metric:{pod:.key}, value:[0, (.value.maxconn // "?")]}]}}' "$TMP/rmap.json" >"$TMP/rmc.json"
prom query "$TMP/rsess.json" "query=sum by (pod)(haproxy_frontend_current_sessions{$RF})"
jq --slurpfile m "$TMP/rmap.json" '{data:{result:[.data.result[] | .metric.pod as $p | $m[0][$p] as $c | select($c != null)
   | {metric:{pod:$p}, value:[0, (if ($c.maxconn|type)=="number" and $c.maxconn>0
       then (.value[1]|tonumber)/$c.maxconn*100 else "?" end)]}]}}' "$TMP/rsess.json" >"$TMP/rpool.json"
jq --slurpfile m "$TMP/rmap.json" '{data:{result:[.data.result[] | .metric.pod as $p | $m[0][$p] as $c | select($c != null)
   | {metric:{pod:$p}, value:[0, ((.value[1]|tonumber) * 2 * ($c.buf // 32768))]}]}}' "$TMP/rsess.json" >"$TMP/rbuf.json"

multi "Pody routerow - pamiec, CPU i pula polaczen" "pod" 3 \
  "WEZEL"       str   "@$TMP/rnode.json" \
  "IC"          str   "@$TMP/ric.json" \
  "PAMIEC(WS)"  bytes "sum by (pod)(container_memory_working_set_bytes{$RC})" \
  "POLACZENIA"  int   "@$TMP/rsess.json" \
  "MAXCONN"     int   "@$TMP/rmc.json" \
  "%PULI"       pct   "@$TMP/rpool.json" \
  "SZAC.BUFORY" bytes "@$TMP/rbuf.json" \
  "NOWE_POL/s"  rate  "sum by (pod)(rate(haproxy_frontend_connections_total{$RF}[$RATE]))" \
  "ZADANIA/s"   rate  "sum by (pod)(rate(haproxy_backend_http_responses_total{$RF}[$RATE]))" \
  "CPU(rdzenie)" num  "sum by (pod)(rate(container_cpu_usage_seconds_total{$RC}[$RATE]))" \
  "RELOADY_$LOGWIN" int "sum by (pod)(increase(template_router_reload_seconds_count{$RF}[$LOGWIN]))"
say "POLACZENIA = suma aktywnych sesji na frontendach = to, co HAProxy liczy do maxconn. Polaczenie HTTPS z terminacja na routerze (edge/reencrypt) liczy sie dwa razy: na public_ssl i na wewnetrznym fe_sni/fe_no_sni."
say "%PULI = POLACZENIA / maxconn. Przy 100% pula jest wyczerpana: nowe polaczenia czekaja w kolejce jadra, klienci widza timeouty."
say "SZAC.BUFORY = polaczenia x 2 x bufsize ($BUF B) - gorne oszacowanie pamieci buforow. Jesli PAMIEC(WS) jest duzo wieksza, reszte trzymaja stare procesy po reloadach, mapy route i TLS."

while IFS=$'\t' read -r p v; do
  [[ -n $p && $v != "?" ]] || continue
  if ge "$v" 80; then finding 1 "Router $p wykorzystuje ${v%.*}% puli maxconn - pula prawie wyczerpana, rozwazyc zwiekszenie tuningOptions.maxConnections lub replik."
  elif ge "$v" 50; then finding 2 "Router $p wykorzystuje ${v%.*}% puli maxconn."; fi
done < <(jq -r '.data.result[] | [.metric.pod, (.value[1]|tostring)] | @tsv' "$TMP/rpool.json")
plist pod "sum by (pod)(increase(template_router_reload_seconds_count{$RF}[$LOGWIN]))" >"$TMP/rreload.tsv"
while IFS=$'\t' read -r p v; do
  [[ -n $p ]] || continue
  ge "$v" 30 && finding 2 "Router $p przeladowal konfiguracje ${v%.*} razy w $LOGWIN - czeste zmiany route/endpointow; kazdy reload uruchamia nowy proces HAProxy, a stary zostaje, dopoki ma polaczenia."
done <"$TMP/rreload.tsv"
while IFS=$'\t' read -r p w; do
  [[ -n $p ]] || continue
  s=$(jq -r --arg p "$p" '.data.result[] | select(.metric.pod==$p) | .value[1]' "$TMP/rsess.json"); s=${s:-0}
  eb=$(awk -v s="$s" -v b="$BUF" 'BEGIN{print s*2*b}')
  rl=$(awk -F'\t' -v p="$p" '$1==p{print $2}' "$TMP/rreload.tsv"); rl=${rl:-0}
  finding 3 "Router $p: pamiec $(hbs "$w"), aktywnych polaczen ${s%.*} (szac. bufory $(hbs "$eb"))."
  # Pamiec duzo wieksza niz bufory aktywnych polaczen + czeste reloady = stare procesy HAProxy
  if ge "$w" 2147483648 && awk -v w="$w" -v e="$eb" 'BEGIN{exit !(w > 20*e)}' && ge "$rl" 30; then
    finding 1 "Router $p zajmuje $(hbs "$w"), a bufory aktywnych polaczen to tylko ok. $(hbs "$eb"); przy ${rl%.*} reloadach w $LOGWIN reszte niemal na pewno trzymaja STARE procesy HAProxy po reloadach. Co zrobic: (1) ustawic hard-stop-after na IngressController (adnotacja ingress.operator.openshift.io/hard-stop-after, np. 30m-1h - stare procesy beda ubijane, klienci long-lived dostana rozlaczenie); (2) zwiekszyc spec.tuningOptions.reloadInterval (np. 30s-60s; grupuje zmiany w mniej reloadow); (3) znalezc zrodlo zmian endpointow - tabela 'Skad biora sie reloady' w sekcji 6; (4) potwierdzic liczbe procesow haproxy opcja -x."
  fi
done < <(plist pod "sum by (pod)(container_memory_working_set_bytes{$RC})")

multi "Frontendy (punkty wejscia HAProxy)" "pod,frontend" 2 \
  "AKTYWNE"     int  "sum by (pod,frontend)(haproxy_frontend_current_sessions{$RF})" \
  "MAX_OD_STARTU" int "max by (pod,frontend)(haproxy_frontend_max_sessions{$RF})" \
  "NOWE_POL/s"  rate "sum by (pod,frontend)(rate(haproxy_frontend_connections_total{$RF}[$RATE]))" \
  "WEJSCIE"     bps  "sum by (pod,frontend)(rate(haproxy_frontend_bytes_in_total{$RF}[$RATE]))" \
  "WYJSCIE"     bps  "sum by (pod,frontend)(rate(haproxy_frontend_bytes_out_total{$RF}[$RATE]))"
say "public = HTTP (80), public_ssl = HTTPS (443, rozdzial po SNI), fe_sni / fe_no_sni = wewnetrzna terminacja TLS dla route edge/reencrypt."

RK="exported_namespace,route"
route_cols=(
  "SESJE_TERAZ" int   "sum by ($RK)(haproxy_server_current_sessions{$RF})"
  "ZADANIA/s"   rate  "sum by ($RK)(rate(haproxy_backend_http_responses_total{$RF}[$RATE]))"
  "NOWE_POL/s"  rate  "sum by ($RK)(rate(haproxy_backend_connections_total{$RF}[$RATE]))"
  "TRANSFER"    bps   "sum by ($RK)(rate(haproxy_backend_bytes_in_total{$RF}[$RATE]) + rate(haproxy_backend_bytes_out_total{$RF}[$RATE]))"
  "SR.CZAS_ODP" ms    "max by ($RK)(haproxy_backend_http_average_response_latency_milliseconds{$RF})"
  "5xx/s"       rate  "sum by ($RK)(rate(haproxy_backend_http_responses_total{$RF,code=\"5xx\"}[$RATE]))"
  "SZAC.BUFORY" bytes "sum by ($RK)(haproxy_server_current_sessions{$RF}) * 2 * $BUF"
)
multi "Route z najwieksza liczba AKTYWNYCH SESJI (to one trzymaja pamiec routera)" "$RK" 0 "${route_cols[@]}"
multi "Route z najwieksza liczba ZADAN/s (aktualny ruch)" "$RK" 1 "${route_cols[@]}"
multi "Route generujace najwiekszy TRANSFER" "$RK" 3 "${route_cols[@]}"
say "Sesje dlugo zyjace (websockety, streaming, long-polling) trzymaja bufory i nie pozwalaja zakonczyc sie staremu procesowi HAProxy po reloadzie - to najczestsza przyczyna rosnacej pamieci routera."

multi "Kody odpowiedzi HTTP (wszystkie routery na infranode'ach)" "code" 0 \
  "ZADANIA/s" rate "sum by (code)(rate(haproxy_backend_http_responses_total{$RF}[$RATE]))" \
  "%"         pct  "100 * sum by (code)(rate(haproxy_backend_http_responses_total{$RF}[$RATE])) / scalar(sum(rate(haproxy_backend_http_responses_total{$RF}[$RATE])))"

multi "Route z problemami (bledy w ostatnich $LOGWIN, kolejki, serwery niedostepne)" "$RK" 0 \
  "BLEDY_POLACZEN" int "sum by ($RK)(increase(haproxy_backend_connection_errors_total{$RF}[$LOGWIN])) > 0" \
  "BLEDY_ODPOW"   int  "sum by ($RK)(increase(haproxy_backend_response_errors_total{$RF}[$LOGWIN])) > 0" \
  "5xx"           int  "sum by ($RK)(increase(haproxy_backend_http_responses_total{$RF,code=\"5xx\"}[$LOGWIN])) > 0" \
  "NIEUDANE_HC"   int  "sum by ($RK)(increase(haproxy_server_check_failures_total{$RF}[$LOGWIN])) > 0" \
  "SERWERY_DOWN"  int  "count by ($RK)(max by ($RK,server)(haproxy_server_up{$RF}) == 0)" \
  "KOLEJKA_TERAZ" int  "sum by ($RK)(haproxy_backend_current_queue{$RF}) > 0" \
  "MAX_KOLEJKA"   int  "max by ($RK)(haproxy_backend_max_queue{$RF}) > 0"
say "BLEDY_POLACZEN = router nie mogl polaczyc sie z podem aplikacji. KOLEJKA > 0 = zadania czekaja, bo serwery osiagnely swoj limit polaczen. SERWERY_DOWN = pody nie przechodza healthchecka."

Q=$(pv "sum(haproxy_backend_current_queue{$RF})"); ge "${Q:-0}" 1 && finding 2 "W backendach routerow czeka teraz ${Q%.*} zadan w kolejce - czesc aplikacji nie nadaza (tabela 'Route z problemami')."
D=$(pv "count(max by ($RK,server)(haproxy_server_up{$RF}) == 0)"); ge "${D:-0}" 1 && finding 2 "${D%.*} serwerow (podow) za route jest oznaczonych jako DOWN."
F5=$(pv "100 * sum(rate(haproxy_backend_http_responses_total{$RF,code=\"5xx\"}[$RATE])) / sum(rate(haproxy_backend_http_responses_total{$RF}[$RATE]))")
ge "${F5:-0}" 5 && finding 2 "$(printf '%.1f' "$F5")% odpowiedzi przez routery to 5xx - sprawdz tabele 'Route z problemami'."
CE=$(pv "sum(increase(haproxy_backend_connection_errors_total{$RF}[$LOGWIN]))"); ge "${CE:-0}" 100 && \
  finding 2 "Routery mialy ${CE%.*} bledow polaczen do aplikacji w $LOGWIN."

# Kazda zmiana listy gotowych podow za route (restart, readiness w gore/w dol, nowy pod)
# zmienia endpointy i wymusza reload routera. Ponizej: kto w klastrze najczesciej je zmienia.
jq '{data:{result:[ [.items[].metadata.namespace] | group_by(.)[] | {metric:{namespace:.[0]}, value:[0, length]} ]}}' \
  "$TMP/routes.json" >"$TMP/nsroutes.json"
multi "Skad biora sie reloady - namespace'y z najwieksza rotacja podow w $LOGWIN (caly klaster)" "namespace" 0 \
  "ZMIANY_READY" int "sum by (namespace)(changes(kube_pod_status_ready{condition=\"true\"}[$LOGWIN])) > 0" \
  "RESTARTY"     int "sum by (namespace)(increase(kube_pod_container_status_restarts_total[$LOGWIN])) > 0" \
  "NOWE_PODY"    int "count by (namespace)((time() - kube_pod_created) < $(dur2s "$LOGWIN" || echo 3600))" \
  "ROUTE"        int "@$TMP/nsroutes.json"
say "Router przeladowuje konfiguracje, gdy zmieni sie route albo lista gotowych podow za nia. Namespace z duza liczba ZMIANY_READY/RESTARTY i ROUTE > 0 (crashloop, flapujaca readiness, czeste wdrozenia, autoskalowanie) to najczestsze zrodlo setek reloadow na godzine."
fi

# --- 6b. zaglad do srodka routera (opcja -x) ---------------------------------------
if (( EXEC )) && (( ${#RPODS[@]} )); then
hdr "6b. WNETRZE PODOW ROUTERA  (oc exec: /proc + gniazdo HAProxy, tylko polecenia 'show')"
# shellcheck disable=SC2016
POD_SCRIPT='
now_t=$(cut -d" " -f1 /proc/uptime); now_t=${now_t%.*}; hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
echo "### PROC"
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  c=$(tr "\0\n\t" "   " <"$d/cmdline" 2>/dev/null); [ -n "$c" ] || continue
  r=0; while read -r k v _; do [ "$k" = "VmRSS:" ] && r=$v; done <"$d/status" 2>/dev/null
  st=$(cat "$d/stat" 2>/dev/null); st=${st##*) }; set -- $st; age=$(( now_t - ${20:-0} / hz ))
  printf "%s\t%s\t%s\t%s\n" "${d#/proc/}" "$r" "$age" "${c:0:100}"
done
S=/var/lib/haproxy/run/haproxy.sock
if command -v socat >/dev/null 2>&1 && [ -S "$S" ]; then
  echo "### INFO";  echo "show info"  | socat -t 10 stdio "unix-connect:$S" 2>&1
  echo "### POOLS"; echo "show pools" | socat -t 10 stdio "unix-connect:$S" 2>&1
  echo "### SESS";  echo "show sess"  | socat -t 30 stdio "unix-connect:$S" 2>/dev/null >/tmp/.sess$$
  echo "TOTAL $(grep -c "^0x" /tmp/.sess$$)"
  grep -o " be=[^ ]*" /tmp/.sess$$ | sort | uniq -c | sort -rn | head -n '"$TOPN"' | sed "s/^/BE/"
  grep -o " src=[^ ]*" /tmp/.sess$$ | sed -E "s/:[0-9]+$//" | sort | uniq -c | sort -rn | head -n '"$TOPN"' | sed "s/^/SRC/"
  rm -f /tmp/.sess$$
else echo "### NOSOCK"; fi
'
for p in "${RPODS[@]}"; do
  sub "Router $p  (wezel $(jq -r --arg p "$p" '.[$p].node' "$TMP/rmap.json"))"
  if ! oc_ro exec -n openshift-ingress "$p" -c router -- bash -c "$POD_SCRIPT" >"$TMP/x.out" 2>"$TMP/x.err"; then
    echo "  oc exec nie powiodl sie: $(head -c 200 "$TMP/x.err")"; continue
  fi
  section() { awk -v s="### $1" '/^### /{on=($0==s); next} on' "$TMP/x.out"; }

  echo "  Procesy w kontenerze router:"
  { printf 'PID\tRSS\tWIEK\tKOMENDA\n'
    section PROC | awk -F'\t' '$4 !~ /^bash -c /' | sort -t$'\t' -k3,3n | head -n 30 | awk -F'\t' '{a=$3; w=(a>=86400? sprintf("%dd%dh",a/86400,a%86400/3600): a>=3600? sprintf("%dh%dm",a/3600,a%3600/60): sprintf("%dm",a/60));
      printf "%s\t%.1f MiB\t%s\t%s\n",$1,$2/1024,w,$4}'; } | table
  read -r NHA RHA < <(section PROC | awk -F'\t' '$4 ~ /haproxy/ {n++; r+=$2} END{printf "%d %d\n", n, r*1024}')
  if (( NHA > 1 )); then
    finding 2 "W routerze $p dziala $NHA procesow haproxy (razem $(hbs "$RHA")): $((NHA-1)) to stare procesy po reloadach, czekajace na zamkniecie swoich polaczen."
    say "Procesy haproxy starsze od najmlodszego to stare instancje po reloadach. Trzymaja swoje polaczenia i pamiec az klienci sie rozlacza (albo do hard-stop-after)."
  fi

  if section NOSOCK | grep -q . || ! grep -q '^### INFO' "$TMP/x.out"; then
    echo "  (brak socat lub gniazda HAProxy w kontenerze - pomijam show info/pools/sess)"; continue
  fi
  section INFO | sed -n 's/^\([^:]*\): *\(.*\)$/\1\t\2/p' >"$TMP/info.tsv"
  iv() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$TMP/info.tsv"; }
  echo; echo "  Stan HAProxy (show info, najnowszy proces):"
  { printf 'POLE\tWARTOSC\tCO OZNACZA\n'
    while IFS='|' read -r k d; do v=$(iv "$k"); [[ -n $v ]] && printf '%s\t%s\t%s\n' "$k" "$v" "$d"; done <<'EOF'
Uptime|czas od ostatniego reloadu
Nbthread|watki
Maxconn|pula polaczen (maxconn)
CurrConns|aktywne polaczenia teraz
CumConns|polaczen od startu procesu
ConnRate|nowe polaczenia/s teraz
MaxConnRate|szczyt nowych polaczen/s
SessRate|nowe sesje/s
CurrSslConns|aktywne polaczenia TLS
SslRate|nowe sesje TLS/s
SslFrontendKeyRate|pelne handshake TLS/s (kosztowne CPU)
SslCacheLookups|odwolania do cache sesji TLS
SslCacheMisses|chybienia cache TLS
PoolAlloc_bytes|pamiec przydzielona w pulach
PoolUsed_bytes|pamiec uzywana w pulach
PoolAlloc_MB|pamiec przydzielona w pulach (MB)
PoolUsed_MB|pamiec uzywana w pulach (MB)
PoolFailed|NIEUDANE przydzialy pamieci (>0 = brakuje pamieci)
Memmax_bytes|limit pamieci (0 = brak)
Memmax_MB|limit pamieci MB (0 = brak)
Ulimit-n|limit deskryptorow plikow
Idle_pct|% czasu bezczynnosci (niski = HAProxy nie nadaza z CPU)
Run_queue|zadania czekajace na CPU
Stopping|1 = proces w trakcie zamykania
Jobs|aktywne zadania (polaczenia + nasluchy)
EOF
  } | table
  MC=$(iv Maxconn); CC=$(iv CurrConns); PF=$(iv PoolFailed); IP=$(iv Idle_pct)
  if [[ -n $MC && -n $CC ]] && (( MC > 0 )); then
    ge "$(pct "$CC" "$MC")" 80 && finding 1 "HAProxy w $p: $CC z $MC polaczen ($(pct "$CC" "$MC")% maxconn) - pula prawie wyczerpana."
  fi
  ge "${PF:-0}" 1 && finding 1 "HAProxy w $p zglasza PoolFailed=$PF - nieudane przydzialy pamieci (brak pamieci lub limit)."
  [[ -n $IP ]] && ! ge "$IP" 20 && finding 2 "HAProxy w $p ma tylko $IP% czasu bezczynnosci - jest blisko nasycenia CPU (rozwazyc wiecej watkow/replik)."

  echo; echo "  Pule pamieci HAProxy (show pools) - najwieksze:"
  { printf 'PULA\tROZMIAR_OBIEKTU\tPRZYDZIELONE\tPAMIEC\tUZYWANE\tBLEDY\n'
    section POOLS | sed -nE 's/^ *- Pool ([^ ]+) \(([0-9]+) bytes\) : ([0-9]+) allocated \(([0-9]+) bytes\), ([0-9]+) used.*, ([0-9]+) failures.*/\1\t\2\t\3\t\4\t\5\t\6/p' |
      sort -t$'\t' -k4,4nr | head -n 10 | awk -F'\t' '{printf "%s\t%s B\t%s\t%.1f MiB\t%s\t%s\n",$1,$2,$3,$4/1048576,$5,$6}'; } | table
  section POOLS | grep -E '^Total' | sed 's/^/  /'

  echo; echo "  Aktywne sesje teraz (show sess): $(section SESS | awk '/^TOTAL/{print $2}')"
  { printf 'SESJE\tBACKEND (be_*:namespace:route)\n'
    section SESS | awk '/^BE/{sub(/^BE */,""); sub(/ be=/,"\t"); print}'; } | table
  { printf 'SESJE\tADRES ZRODLOWY\n'
    section SESS | awk '/^SRC/{sub(/^SRC */,""); sub(/ src=/,"\t"); print}'; } | table
  say "To migawka zadan/polaczen obslugiwanych TERAZ przez najnowszy proces haproxy (stare procesy po reloadzie nie sa tu widoczne). be_sni/be_no_sni to wewnetrzny etap terminacji TLS. Adres zrodlowy to klient albo load balancer przed routerem."
done
fi

# =============================================================================
# 7. BLEDY, ZDARZENIA, ALERTY
# =============================================================================
hdr "7. BLEDY, ZDARZENIA I ALERTY"
sub "Stan wezla $FOCUS"
{ printf 'WARUNEK\tSTAN\tOD\tKOMUNIKAT\n'
  jq -r '.status.conditions[] | [.type, .status, .lastTransitionTime, ((.message // "")[:80])] | @tsv' "$TMP/node.json"; } | table
jq -e '.status.conditions[] | select(.type=="MemoryPressure" and .status=="True")' "$TMP/node.json" >/dev/null && \
  finding 1 "Wezel $FOCUS zglasza MemoryPressure=True - kubelet usuwa (eviction) pody."

sub "ClusterOperator ingress i IngressControllery"
{ printf 'OBIEKT\tAvailable\tProgressing\tDegraded\tKOMUNIKAT\n'
  oc_ro get clusteroperator ingress -o json 2>/dev/null | jq -r '
    (.status.conditions // []) as $c | def st($t): ([$c[] | select(.type==$t) | .status] | .[0] // "?");
    ["co/ingress", st("Available"), st("Progressing"), st("Degraded"),
     ([$c[] | select(.type=="Degraded" and .status=="True") | .message] | .[0] // "" | .[:80])] | @tsv'
  jq -r '.[] | (.status.conditions // []) as $c | def st($t): ([$c[] | select(.type==$t) | .status] | .[0] // "?");
    ["ic/\(.ic)", st("Available"), st("Progressing"), st("Degraded"),
     ([$c[] | select(.type=="Degraded" and .status=="True") | .message] | .[0] // "" | .[:80])] | @tsv' "$TMP/iccfg.json"
} | table
jq -r '.[] | select(any(.status.conditions[]?; .type=="Degraded" and .status=="True")) | .ic' "$TMP/iccfg.json" |
  while read -r ic; do finding 1 "IngressController $ic jest Degraded."; done

oc_ro get events -A -o json >"$TMP/ev.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/ev.json"
jq '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"]' "$TMP/pods.json" >"$TMP/podkeys.json"
EVF='($k[0] | map({(.): true}) | add // {}) as $set
  | [.items[] | select(
      (.involvedObject.kind=="Node" and .involvedObject.name==$node) or (.source.host // "")==$node
      or $set["\(.involvedObject.namespace)/\(.involvedObject.name)"] == true
      or ((.involvedObject.namespace // "")|startswith("openshift-ingress")))]'
sub "Zdarzenia dotyczace $FOCUS, jego podow i ingress - podsumowanie (to, co jest jeszcze w API, zwykle ~1-3h)"
{ printf 'TYP\tPOWOD\tLICZBA\tOBIEKTOW\n'
  jq -r --arg node "$FOCUS" --slurpfile k "$TMP/podkeys.json" "$EVF"'
    | group_by([.type, .reason])[] | [.[0].type, .[0].reason, (map(.count // 1)|add),
        ([.[] | .involvedObject.name] | unique | length)] | @tsv' "$TMP/ev.json" | sort -t$'\t' -k1,1r -k3,3nr | head -n "$TOPN"
} | table
sub "Ostatnie zdarzenia typu Warning"
{ printf 'OSTATNIO\tLICZBA\tNAMESPACE\tOBIEKT\tPOWOD\tKOMUNIKAT\n'
  jq -r --arg node "$FOCUS" --slurpfile k "$TMP/podkeys.json" "$EVF"' | .[] | select(.type=="Warning")
    | [(.lastTimestamp // .eventTime // .metadata.creationTimestamp // "-"), (.count // 1), (.metadata.namespace // "-"),
       "\(.involvedObject.kind)/\(.involvedObject.name)", .reason, ((.message // "") | gsub("\\s+";" ") | .[:90])] | @tsv' \
    "$TMP/ev.json" | sort -r | head -n "$TOPN"
} | table
NW=$(jq -r --arg node "$FOCUS" --slurpfile k "$TMP/podkeys.json" "$EVF"' | map(select(.type=="Warning")) | length' "$TMP/ev.json")
OOMEV=$(jq -r --arg node "$FOCUS" --slurpfile k "$TMP/podkeys.json" "$EVF"' | map(select((.reason // "")|test("OOM|Evict";"i"))) | length' "$TMP/ev.json")
(( NW > 0 )) && finding 3 "$NW zdarzen typu Warning dotyczy $FOCUS / jego podow / ingress (sekcja 7)."
(( OOMEV > 0 )) && finding 1 "Sa zdarzenia OOM/Evicted ($OOMEV) dotyczace $FOCUS lub jego podow."

sub "Kontenery na $FOCUS z restartami"
{ printf 'NAMESPACE\tPOD\tKONTENER\tRESTARTY\tOSTATNI_POWOD\tKIEDY\n'
  jq -r '.items[] | . as $p | (.status.containerStatuses // [])[] | select(.restartCount>0)
    | [$p.metadata.namespace, $p.metadata.name, .name, .restartCount,
       (.lastState.terminated.reason // "-"), (.lastState.terminated.finishedAt // "-")] | @tsv' "$TMP/pods.json" |
    sort -t$'\t' -k6,6r | head -n "$TOPN"; } | table
jq -r '.items[] | . as $p | (.status.containerStatuses // [])[] | select(.lastState.terminated.reason=="OOMKilled")
  | "1\tKontener \($p.metadata.namespace)/\($p.metadata.name)/\(.name) byl zabity przez OOM (\(.lastState.terminated.finishedAt)) - limit pamieci za niski lub wyciek."' \
  "$TMP/pods.json" >>"$TMP/findings"

sub "Alerty aktywne teraz (dotyczace $FOCUS, jego podow lub ingress)"
prom query "$TMP/al.json" 'query=ALERTS{alertstate="firing"}'
{ printf 'ALERT\tWAGA\tNAMESPACE\tOBIEKT\n'
  jq -r --arg node "$FOCUS" --slurpfile k "$TMP/podkeys.json" '
    ($k[0] | map({(.): true}) | add // {}) as $set
    | [.data.result[].metric | select((.node // "")==$node or ((.instance // "")|startswith($node))
        or $set["\(.namespace // "")/\(.pod // "")"] == true or ((.namespace // "")|startswith("openshift-ingress")))]
    | unique_by([.alertname, .namespace, .pod, .instance, .node])[]
    | [.alertname, (.severity // "-"), (.namespace // "-"), (.pod // .node // .instance // .route // "-")] | @tsv' "$TMP/al.json" |
    sort -t$'\t' -k2,2 | head -n "$TOPN"; } >"$TMP/al.tsv"
table <"$TMP/al.tsv"
NA=$(( $(wc -l <"$TMP/al.tsv") - 1 ))
(( NA > 0 )) && finding 2 "$NA aktywnych alertow dotyczy $FOCUS / jego podow / ingress: $(tail -n +2 "$TMP/al.tsv" | cut -f1 | sort -u | head -5 | paste -sd, -)."

if (( ${#RPODS[@]} )); then
  sub "Bledy i ostrzezenia w logach routerow (ostatnie $LOGWIN)"
  for p in "${RPODS[@]}"; do oc_ro logs -n openshift-ingress "$p" -c router --since="$LOGWIN" 2>/dev/null; done >"$TMP/rlog.txt"
  RLD=$(grep -ciE 'router reloaded' "$TMP/rlog.txt")
  { printf 'LICZBA\tPOZIOM\tKOMUNIKAT (liczby zastapione #)\n'
    grep -E '^[EW][0-9]{4} |\[(ALERT|WARNING)\]' "$TMP/rlog.txt" |
      sed -E 's/^([EW])[0-9]{4} [0-9:.]+ +[0-9]+ [^]]+\] /\1\t/; s/^.*\[(ALERT|WARNING)\][^:]*: */\1\t/' |
      sed -E 's/[0-9a-f]{8,}/#/g; s/[0-9]+/#/g' | cut -c1-140 | sort | uniq -c | sort -rn | head -n "$TOPN" |
      sed -E 's/^ *([0-9]+) /\1\t/'; } | table
  NE=$(grep -cE '^E[0-9]{4} |\[ALERT\]' "$TMP/rlog.txt")
  echo "  Linii logu: $(wc -l <"$TMP/rlog.txt"), bledow (E/ALERT): $NE, wpisow 'router reloaded': $RLD"
  (( NE > 0 )) && finding 2 "W logach routerow jest $NE bledow w ostatnich $LOGWIN (sekcja 7)."
fi

# =============================================================================
# 8. PODSUMOWANIE
# =============================================================================
hdr "8. PODSUMOWANIE - CO WPLYWA NA PAMIEC I CO WYMAGA UWAGI"
if [[ ! -s $TMP/findings ]]; then
  echo "  Nie wykryto niczego niepokojacego."
else
  sort -t$'\t' -k1,1n -s "$TMP/findings" | awk -F'\t' '!seen[$2]++' | while IFS=$'\t' read -r lvl txt; do
    case $lvl in 1) tag="[KRYTYCZNE]";; 2) tag="[UWAGA]     ";; *) tag="[INFO]      ";; esac
    fold -s -w 84 <<<"$txt" | awk -v t="$tag" 'NR==1{print "  " t " " $0; next}{print "                " $0}'
  done
fi
cat <<'EOF'

  Jak zwykle wyglada pamiec infranode'a:
   - najwiecej biora Prometheus/Thanos (liczba serii), Alertmanager, logowanie (jesli jest tu),
     a router zwykle mniej - chyba ze ma duzo dlugich polaczen i czeste reloady;
   - cache plikow (page cache) wypelnia wolna pamiec i jest oddawany na zadanie - to nie problem;
   - jesli ZMIANA w sekcji 3 rosnie stale dla jednego poda przy stalym ruchu - podejrzenie wycieku.
EOF
printf '\n%s\nKoniec raportu. Na klastrze nic nie zostalo zmienione.\n' "$LINE"

# =============================================================================
# 9. RAPORT HTML Z WYKRESAMI HISTORII (opcja -H)
# =============================================================================
[[ -n $HTML ]] || exit 0
exec 1>&3 3>&-; wait "$TEE_PID" 2>/dev/null || sleep 1   # domknij kopie raportu tekstowego
echo "Raport HTML: pobieram historie z $HDAYS dni (krok $HSTEP, kazdy punkt = maksimum z kroku)..." >&2

H_END=$(date +%s); H_END=$(( H_END / HSTEP_S * HSTEP_S )); H_START=$(( H_END - HDAYS * 86400 ))
: >"$TMP/charts.jsonl"

# hchart ID JEDNOSTKA ETYKIETY TYTUL OPIS ZAPYTANIE [half]
#   JEDNOSTKA: pct | bytes | int | rate ; ETYKIETY: etykiety tworzace nazwe serii (po przecinku)
#   half = maly wykres (dwa w rzedzie)
hchart() {
  local id=$1 unit=$2 keys=$3 title=$4 desc=$5 q=$6 half=${7:-}
  echo "  - $title" >&2
  prom query_range "$TMP/h_$id.json" "query=$q" "start=$H_START" "end=$H_END" "step=$HSTEP_S" || true
  jq -c --arg id "$id" --arg unit "$unit" --arg keys "$keys" --arg title "$title" --arg desc "$desc" --arg half "$half" "$JQ_DEFS"'
    { id:$id, unit:$unit, title:$title, desc:$desc, half:($half!=""),
      series: ( [ .data.result[]
                  | { name: ((.metric | key($keys) | gsub("\t"; " / ")) as $n | if $keys=="" then $title else $n end),
                      pts: [ .values[] | [ (.[0]|floor), (.[1]|num) ] | select(.[1]|type=="number") ] }
                  | select(.pts|length > 0)
                  | . + { peak: ([.pts[][1]] | max) } ]
                | sort_by(-.peak)
                # max. 8 serii (8 rozroznialnych kolorow); reszta jako jedna seria "pozostale (max)"
                | if length > 8 then .[:7] + [ { name: "pozostale \(length-7) (max z nich)",
                      pts: ( [ .[7:][].pts[] ] | group_by(.[0]) | map([ .[0][0], ([ .[][1] ] | max) ]) ) }
                      | . + { peak: ([.pts[][1]] | max) } ]
                  else . end ) }' "$TMP/h_$id.json" >>"$TMP/charts.jsonl"
}

hchart node_pct pct instance "Zajeta pamiec infranode'ow (%)" \
  "Szczyt w kazdym kroku: 100% minus najnizsza MemAvailable. Cache plikow NIE jest tu liczony (oddaje sie na zadanie). Powyzej ~90% kubelet zaczyna usuwac pody." \
  "100 * (1 - min_over_time(node_memory_MemAvailable_bytes{$IF}[${HSTEP_S}s]) / max_over_time(node_memory_MemTotal_bytes{$IF}[${HSTEP_S}s]))"

hchart node_used bytes instance "Zajeta pamiec infranode'ow (bajty)" \
  "To samo co wyzej w GiB - latwo porownac z pamiecia routerow i podow ponizej." \
  "max_over_time(node_memory_MemTotal_bytes{$IF}[${HSTEP_S}s]) - min_over_time(node_memory_MemAvailable_bytes{$IF}[${HSTEP_S}s])"

hchart router_mem bytes pod "Pamiec podow routera (working set)" \
  "Maksimum pamieci kontenera router w kazdym kroku. Stale rosnaca linia, ktora spada tylko przy restarcie/nowym wdrozeniu, to typowy obraz starych procesow HAProxy po reloadach." \
  "max by (pod)(max_over_time(container_memory_working_set_bytes{$NS_R,container=\"router\",node=~\"$NODE_RE\"}[${HSTEP_S}s]))"

hchart top_pods bytes namespace,pod "Najwieksze pody na infranode'ach (working set)" \
  "8 podow o najwyzszym szczycie w calym okresie (suma maksimow kontenerow poda w kroku)." \
  "sum by (namespace,pod)(max_over_time(container_memory_working_set_bytes{node=~\"$NODE_RE\",container!=\"\",container!=\"POD\"}[${HSTEP_S}s]))"

hchart router_conn int pod "Aktywne polaczenia routerow (maksimum)" \
  "Najwyzsza w kroku suma aktywnych sesji na frontendach (to, co liczy sie do maxconn; domyslnie 50000 na proces)." \
  "max_over_time((sum by (namespace,pod)(haproxy_frontend_current_sessions{$NS_R}) $ON_INFRA)[${HSTEP_S}s:2m])"

hchart router_reload int pod "Reloady konfiguracji routera (na krok $HSTEP)" \
  "Liczba przeladowan HAProxy w kazdym kroku. Kazdy reload startuje nowy proces; stary zyje, dopoki ma polaczenia (albo do hard-stop-after)." \
  "sum by (pod)(increase(template_router_reload_seconds_count{$NS_R}[${HSTEP_S}s]) $ON_INFRA)"

hchart router_cerr int pod "Bledy polaczen routera do aplikacji (na krok $HSTEP)" \
  "Ile razy router nie mogl polaczyc sie z podem aplikacji (pod niegotowy/zrestartowany, odrzucone polaczenie)." \
  "sum by (pod)(increase(haproxy_backend_connection_errors_total{$NS_R}[${HSTEP_S}s]) $ON_INFRA)"

hchart router_5xx int pod "Odpowiedzi 5xx przez routery (na krok $HSTEP)" \
  "Liczba odpowiedzi z bledem serwera w kazdym kroku." \
  "sum by (pod)(increase(haproxy_backend_http_responses_total{$NS_R,code=\"5xx\"}[${HSTEP_S}s]) $ON_INFRA)"

# Male wykresy: liczniki, ktore moga tlumaczyc wzrost pamieci (kiedy zaczal sie wzrost?)
HS="[${HSTEP_S}s:5m]"
hchart cnt_proc int pod "Procesy w kontenerze routera" \
  "Wiecej procesow niz zwykle = stare procesy HAProxy po reloadach (metryka cAdvisora; moze byc niedostepna)." \
  "max by (pod)(max_over_time(container_processes{$NS_R,container=\"router\",node=~\"$NODE_RE\"}[${HSTEP_S}s]))" half
hchart cnt_req rate "" "Zadania HTTP/s przez routery (suma)" "Ruch: ile zadan na sekunde obsluguja routery na infranode'ach (max w kroku)." \
  "max_over_time((sum(rate(haproxy_backend_http_responses_total{$NS_R}[5m]) $ON_INFRA))$HS)" half
hchart cnt_routes int "" "Route w HAProxy" "Liczba route (backendow) zaladowanych w routerach." \
  "max_over_time(count(count by (exported_namespace,route)(haproxy_server_up{$NS_R} $ON_INFRA))$HS)" half
hchart cnt_endp int "" "Endpointy (pody) za route" "Liczba serwerow w backendach HAProxy - kazda zmiana to reload." \
  "max_over_time(count(count by (exported_namespace,route,server)(haproxy_server_up{$NS_R} $ON_INFRA))$HS)" half
hchart cnt_ready int "" "Zmiany gotowosci podow w klastrze (na krok $HSTEP)" "Rotacja podow: restarty, flapujaca readiness, wdrozenia. Napedza reloady routerow." \
  "sum(changes(kube_pod_status_ready{condition=\"true\"}[${HSTEP_S}s]))" half
hchart cnt_pods int "" "Pody w klastrze" "Ile podow istnialo (max w kroku)." "max_over_time(count(kube_pod_info)$HS)" half
hchart cnt_ns int "" "Namespace'y" "Ile namespace'ow istnialo (max w kroku)." "max_over_time(count(kube_namespace_created)$HS)" half
hchart cnt_series int "" "Serie w Prometheusie (head)" "Wiecej serii = wiecej pamieci Prometheusa na infranode'ach." \
  "max_over_time(max(prometheus_tsdb_head_series)$HS)" half

# --- zlozenie danych i strony --------------------------------------------------------
sort -t$'\t' -k1,1n -s "$TMP/findings" | awk -F'\t' '!seen[$2]++' >"$TMP/findings.sorted"
jq -nc --slurpfile charts "$TMP/charts.jsonl" --slurpfile cap "$TMP/cap.jsonl" --argjson baseS "$(dur2s "$BASE")" \
  --arg base "$BASE" --arg cwin "$CWIN" --rawfile report "$TMP/report.txt" --rawfile fnd "$TMP/findings.sorted" \
  --arg server "$(oc_ro whoami --show-server 2>/dev/null)" --arg gen "$(date '+%F %T %Z')" \
  --arg nodes "${NODES[*]}" --arg focus "$FOCUS" --arg step "$HSTEP" \
  --argjson stepS "$HSTEP_S" --argjson days "$HDAYS" --argjson t0 "$H_START" --argjson t1 "$H_END" '
  { meta: {server:$server, generated:$gen, nodes:$nodes, focus:$focus, step:$step, stepS:$stepS,
           days:$days, start:$t0, end:$t1, base:$base, baseS:$baseS, cwin:$cwin},
    changes: $cap,
    findings: [ $fnd | split("\n")[] | select(length>0) | split("\t") | {level:(.[0]|tonumber), text:.[1]} ],
    charts: $charts, report: $report }' | sed 's#</#<\\/#g' >"$TMP/data.json"
[[ -s $TMP/data.json ]] || die "nie udalo sie zlozyc danych do raportu HTML (blad jq powyzej)"

html_template() { cat <<'HTMLEOF'
<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pamiec infranode'ow</title>
<style>
:root {
  color-scheme: light;
  --page:#f9f9f7; --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,0.10);
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a; --s4:#eda100; --s5:#e87ba4; --s6:#008300; --s7:#6250d6; --s8:#e34948;
  --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --page:#0d0d0d; --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10);
    --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; --s6:#0ca30c; --s7:#9085e9; --s8:#e66767;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page:#0d0d0d; --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10);
  --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; --s6:#0ca30c; --s7:#9085e9; --s8:#e66767;
}
* { box-sizing: border-box; }
body { margin:0; background:var(--page); color:var(--ink);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 1240px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 16px; margin: 0 0 2px; }
.meta { color: var(--ink2); font-size: 13px; }
.meta code { font-size: 12px; }
.tiles { display:grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap:12px; margin:20px 0; }
.tile, .card { background:var(--surface); border:1px solid var(--border); border-radius:10px; }
.tile { padding:14px 16px; }
.tile .lbl { color:var(--ink2); font-size:12px; }
.tile .val { font-size:26px; font-weight:650; font-variant-numeric: tabular-nums; margin:2px 0; }
.tile .sub { color:var(--muted); font-size:12px; overflow-wrap:anywhere; }
.card { padding:16px; margin:0 0 16px; }
.card .desc { color:var(--ink2); font-size:13px; margin:0 0 10px; max-width:90ch; }
.findings { list-style:none; padding:0; margin:0; }
.findings li { display:flex; gap:10px; padding:8px 0; border-top:1px solid var(--grid); }
.findings li:first-child { border-top:0; }
.badge { flex:none; display:inline-flex; align-items:center; gap:5px; font-size:11px; font-weight:650;
  padding:2px 8px; border-radius:999px; height:20px; margin-top:1px; color:#0b0b0b; }
.badge.l1 { background:var(--critical); color:#fff; } .badge.l2 { background:var(--warning); } .badge.l3 { background:var(--grid); color:var(--ink); }
.legend { display:flex; flex-wrap:wrap; gap:4px 14px; margin:0 0 6px; }
.legend button { all:unset; cursor:pointer; display:inline-flex; align-items:center; gap:6px; font-size:12px;
  color:var(--ink2); padding:2px 0; overflow-wrap:anywhere; }
.legend button[aria-pressed="false"] { opacity:.4; text-decoration: line-through; }
.legend button:focus-visible { outline:2px solid var(--s1); outline-offset:2px; border-radius:3px; }
.key { width:14px; height:0; border-top:2px solid; border-radius:2px; flex:none; }
.plot { position:relative; }
.plot svg { display:block; width:100%; overflow:visible; }
.plot svg text { fill: var(--muted); font-size:11px; font-variant-numeric: tabular-nums; }
.plot svg .peak-label { fill: var(--ink); font-weight:600; }
.tip { position:absolute; pointer-events:none; background:var(--surface); border:1px solid var(--border);
  border-radius:8px; padding:8px 10px; font-size:12px; box-shadow:0 4px 16px rgba(0,0,0,.12);
  min-width:180px; max-width:360px; display:none; z-index:2; }
.tip .t { color:var(--ink2); margin-bottom:4px; }
.tip .row { display:flex; align-items:center; gap:8px; }
.tip .row b { font-variant-numeric: tabular-nums; min-width:72px; }
.tip .row span:last-child { color:var(--ink2); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.empty { color:var(--muted); padding:24px 0; }
details { margin-top:10px; }
summary { cursor:pointer; color:var(--ink2); font-size:13px; }
.tbl { overflow-x:auto; }
table { border-collapse:collapse; font-size:12px; margin-top:8px; width:100%; }
th, td { text-align:left; padding:4px 10px 4px 0; border-bottom:1px solid var(--grid); white-space:nowrap; }
td.n, th.n { text-align:right; font-variant-numeric: tabular-nums; }
#charts { display:grid; grid-template-columns: 1fr 1fr; gap:0 16px; }
#charts > .card { grid-column: 1 / -1; min-width:0; }
#charts > .card.half { grid-column: auto; }
@media (max-width: 760px) { #charts { grid-template-columns: 1fr; } }
.changes h3 { font-size:14px; margin:18px 0 0; }
.changes h3:first-of-type { margin-top:8px; }
.changes .note { color:var(--ink2); font-size:12px; margin:6px 0 0; max-width:110ch; }
.changes tr.hot td { font-weight:650; }
.changes tr.hot td:first-child { box-shadow: inset 3px 0 0 var(--warning); padding-left:8px; }
.changes td.flag-hot { color:var(--ink); }
pre.report { background:var(--surface); border:1px solid var(--border); border-radius:10px; padding:12px;
  overflow:auto; font-size:12px; line-height:1.35; max-height:80vh; }
</style>
</head>
<body>
<main>
  <h1>Pamiec infranode'ow i routery</h1>
  <div class="meta" id="meta"></div>
  <section class="tiles" id="tiles"></section>
  <section class="card changes" id="changes"></section>
  <section class="card"><h2>Wnioski z raportu biezacego</h2><ul class="findings" id="findings"></ul></section>
  <div id="charts"></div>
  <section class="card"><h2>Pelny raport tekstowy</h2>
    <details><summary>Pokaz (to samo, co skrypt wypisal w terminalu)</summary><pre class="report" id="report"></pre></details>
  </section>
</main>
<script id="data" type="application/json">
__DATA__
</script>
<script>
(function () {
  const D = JSON.parse(document.getElementById('data').textContent);
  const M = D.meta;
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const svgEl = (tag, attrs) => { const e = document.createElementNS('http://www.w3.org/2000/svg', tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; };
  const pad = n => String(n).padStart(2, '0');
  const fdate = t => { const d = new Date(t * 1000); return pad(d.getDate()) + '.' + pad(d.getMonth() + 1); };
  const fdt = t => { const d = new Date(t * 1000); return fdate(t) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()); };
  function fmt(v, u) {
    if (v == null || isNaN(v)) return '-';
    if (u === 'pct') return v.toFixed(1) + '%';
    if (u === 'rate') return (v >= 100 ? Math.round(v) : v.toFixed(v >= 10 ? 1 : 2)) + '/s';
    if (u === 'bytes') { const a = Math.abs(v);
      if (a >= 1073741824) return (v / 1073741824).toFixed(2) + ' GiB';
      if (a >= 1048576) return (v / 1048576).toFixed(1) + ' MiB';
      if (a >= 1024) return (v / 1024).toFixed(1) + ' KiB';
      return Math.round(v) + ' B'; }
    if (Math.abs(v) >= 1e9) return (v / 1e9).toFixed(1) + ' mld';
    if (Math.abs(v) >= 1e6) return (v / 1e6).toFixed(1) + ' mln';
    if (Math.abs(v) >= 10000) return (v / 1000).toFixed(1) + ' tys.';
    return String(Math.round(v));
  }
  function niceMax(v, u) {
    if (u === 'pct') return 100;
    if (!(v > 0)) return 1;
    if (u === 'bytes') { const g = 1073741824; if (v >= g) { const s = [1, 2, 4, 5, 8, 10, 16, 20, 25, 32, 40, 50, 64, 80, 100, 128, 160, 200, 256, 320, 400, 512];
      for (const x of s) if (x * g >= v * 1.05) return x * g; } }
    const e = Math.pow(10, Math.floor(Math.log10(v * 1.05))); const f = v * 1.05 / e;
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * e;
  }

  // --- naglowek ---
  const meta = document.getElementById('meta');
  meta.append('Klaster ', el('code', null, M.server), ' · wygenerowano ', M.generated,
    ' · wezly: ' + M.nodes + ' · historia: ' + M.days + ' dni (' + fdt(M.start) + ' – ' + fdt(M.end) +
    '), krok ' + M.step + ' – kazdy punkt to MAKSIMUM z kroku.');
  document.getElementById('report').textContent = D.report || '(brak)';

  // --- wnioski ---
  const fl = document.getElementById('findings');
  const lv = { 1: ['l1', '⛔ KRYTYCZNE'], 2: ['l2', '⚠ UWAGA'], 3: ['l3', 'ℹ INFO'] };
  if (!D.findings.length) fl.append(el('li', null, 'Nie wykryto niczego niepokojacego.'));
  for (const f of D.findings) { const li = el('li'); const b = lv[f.level] || lv[3];
    li.append(el('span', 'badge ' + b[0], b[1]), el('span', null, f.text)); fl.append(li); }

  // --- kafelki: szczyty z calego okresu ---
  const byId = Object.fromEntries(D.charts.map(c => [c.id, c]));
  function peakOf(id) { const c = byId[id]; if (!c || !c.series.length) return null;
    let best = null; for (const s of c.series) for (const p of s.pts) if (!best || p[1] > best.v) best = { v: p[1], t: p[0], s: s.name };
    return best && Object.assign(best, { u: c.unit }); }
  const tiles = document.getElementById('tiles');
  [['node_pct', 'Szczyt zajetej pamieci wezla'], ['router_mem', 'Szczyt pamieci routera'],
   ['router_conn', 'Szczyt aktywnych polaczen routera'], ['router_reload', 'Najwiecej reloadow w kroku ' + M.step]]
  .forEach(([id, lbl]) => { const p = peakOf(id); const t = el('div', 'tile');
    t.append(el('div', 'lbl', lbl + ' (' + M.days + ' dni)'), el('div', 'val', p ? fmt(p.v, p.u) : '-'),
      el('div', 'sub', p ? fdt(p.t) + ' · ' + p.s : 'brak danych'));
    tiles.append(t); });

  // --- co sie zmienilo (tabele z sekcji 0 raportu) ---
  const ch = document.getElementById('changes');
  ch.append(el('h2', null, 'Co sie zmienilo: ostatnie ' + M.cwin + ' vs te same ' + M.cwin + ' sprzed ' + M.base));
  if (!D.changes.length) ch.append(el('div', 'empty', 'brak danych'));
  for (const b of D.changes) {
    if (b.type === 'h') ch.append(el('h3', null, b.text));
    else if (b.type === 'note') ch.append(el('p', 'note', b.text));
    else if (b.type === 'table') {
      if (b.text.length <= 1) { ch.append(el('div', 'note', '(brak danych)')); continue; }
      const w = el('div', 'tbl'), t = el('table'); const [head, ...rows] = b.text;
      const num = head.map((h, i) => rows.some(r => /^[+-]?[0-9.]+( |%|\/|$)|^-$/.test(r[i] || '')) && !/^(OBSZAR|METRYKA|NAMESPACE|ROUTE|POD|OCENA|UTWORZ)/.test(h));
      const tr = el('tr'); head.forEach((h, i) => tr.append(el('th', num[i] ? 'n' : '', h))); t.append(tr);
      for (const r of rows) { const x = el('tr'); if (r.some(c => /^!!/.test(c))) x.className = 'hot';
        r.forEach((c, i) => x.append(el('td', num[i] ? 'n' : '', c))); t.append(x); }
      w.append(t); ch.append(w);
    }
  }

  // --- wykresy ---
  const host = document.getElementById('charts');
  const charts = [];
  for (const c of D.charts) {
    const card = el('section', 'card' + (c.half ? ' half' : '')); card.append(el('h2', null, c.title), el('p', 'desc', c.desc));
    host.append(card);
    if (!c.series.length) { card.append(el('div', 'empty', 'Brak danych w Prometheusie dla tego zapytania (metryka niedostepna albo krotsza retencja).')); continue; }
    c.series.forEach((s, i) => { s.color = 'var(--s' + (i + 1) + ')'; s.on = true; s.map = new Map(s.pts.map(p => [p[0], p[1]])); });
    if (c.series.length > 1) {
      const lg = el('div', 'legend');
      c.series.forEach(s => { const b = el('button'); b.type = 'button'; b.setAttribute('aria-pressed', 'true');
        const k = el('span', 'key'); k.style.borderTopColor = s.color; b.append(k, el('span', null, s.name + ' · max ' + fmt(s.peak, c.unit)));
        b.title = 'Pokaz/ukryj serie';
        b.onclick = () => { s.on = !s.on; b.setAttribute('aria-pressed', String(s.on)); draw(c); };
        lg.append(b); });
      card.append(lg);
    }
    const plot = el('div', 'plot'); card.append(plot); c.plot = plot;
    // tabela (widok dostepny bez najezdzania)
    const det = el('details'); det.append(el('summary', null, 'Tabela: maksimum, kiedy, ostatnia wartosc'));
    const wrap = el('div', 'tbl'); const tb = el('table'); const hr = el('tr');
    [['Seria', ''], ['Maksimum', 'n'], ['Kiedy', ''], ['Srednia', 'n'], ['Ostatnia', 'n']].forEach(([h, k]) => hr.append(el('th', k, h)));
    tb.append(hr);
    for (const s of c.series) { const tr = el('tr'); let pk = s.pts[0], sum = 0;
      for (const p of s.pts) { if (p[1] > pk[1]) pk = p; sum += p[1]; }
      tr.append(el('td', null, s.name), el('td', 'n', fmt(pk[1], c.unit)), el('td', null, fdt(pk[0])),
        el('td', 'n', fmt(sum / s.pts.length, c.unit)), el('td', 'n', fmt(s.pts[s.pts.length - 1][1], c.unit)));
      tb.append(tr); }
    wrap.append(tb); det.append(wrap); card.append(det);
    charts.push(c);
  }

  function draw(c) {
    const plot = c.plot; plot.textContent = '';
    const W = Math.max(320, plot.clientWidth), H = W < 600 ? 220 : 280;
    const m = { l: 64, r: 14, t: 22, b: 26 }, iw = W - m.l - m.r, ih = H - m.t - m.b;
    const vis = c.series.filter(s => s.on);
    const vmax = niceMax(Math.max(0, ...vis.map(s => s.peak)), c.unit);
    const X = t => m.l + (t - M.start) / (M.end - M.start) * iw;
    const Y = v => m.t + ih - Math.min(v, vmax) / vmax * ih;
    const svg = svgEl('svg', { viewBox: '0 0 ' + W + ' ' + H, height: H, role: 'img', 'aria-label': c.title });
    // siatka i os Y
    for (let i = 0; i <= 4; i++) { const v = vmax * i / 4, y = Y(v);
      svg.append(svgEl('line', { x1: m.l, x2: W - m.r, y1: y, y2: y, stroke: i ? 'var(--grid)' : 'var(--axis)', 'stroke-width': 1 }));
      const tx = svgEl('text', { x: m.l - 8, y: y + 4, 'text-anchor': 'end' }); tx.textContent = fmt(v, c.unit); svg.append(tx); }
    // os X: polnoce
    const days = (M.end - M.start) / 86400, every = days > 21 ? 7 : days > 10 ? 2 : 1;
    const d0 = new Date(M.start * 1000); d0.setHours(24, 0, 0, 0);
    for (let t = d0.getTime() / 1000, i = 0; t < M.end; t += 86400, i++) {
      const x = X(t); svg.append(svgEl('line', { x1: x, x2: x, y1: m.t, y2: m.t + ih, stroke: 'var(--grid)', 'stroke-width': 1, 'stroke-dasharray': '2 3' }));
      if (i % every === 0 && W >= 480 || i % (every * 2) === 0) { const tx = svgEl('text', { x: x, y: H - 6, 'text-anchor': 'middle' }); tx.textContent = fdate(t); svg.append(tx); } }
    // znacznik: punkt odniesienia porownania (np. 7 dni temu)
    const tb = M.end - M.baseS;
    if (tb > M.start) { const x = X(tb);
      svg.append(svgEl('line', { x1: x, x2: x, y1: m.t, y2: m.t + ih, stroke: 'var(--ink2)', 'stroke-width': 1, 'stroke-dasharray': '4 3' }));
      const tx = svgEl('text', { x: x + 4, y: m.t + ih - 6, 'text-anchor': 'start' }); tx.textContent = M.base + ' temu'; svg.append(tx); }
    // linie (przerwa, gdy brakuje punktow)
    const gap = M.stepS * 1.5;
    for (const s of vis) { let d = '', prev = null;
      for (const p of s.pts) { d += (prev === null || p[0] - prev > gap ? 'M' : 'L') + X(p[0]).toFixed(1) + ' ' + Y(p[1]).toFixed(1); prev = p[0]; }
      svg.append(svgEl('path', { d: d, fill: 'none', stroke: s.color, 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' })); }
    // jedna etykieta: globalny szczyt
    let pk = null; for (const s of vis) for (const p of s.pts) if (!pk || p[1] > pk.v) pk = { t: p[0], v: p[1], s: s };
    if (pk) { const x = X(pk.t), y = Y(pk.v);
      svg.append(svgEl('circle', { cx: x, cy: y, r: 4.5, fill: pk.s.color, stroke: 'var(--surface)', 'stroke-width': 2 }));
      const tx = svgEl('text', { x: Math.min(Math.max(x, m.l + 60), W - m.r - 60), y: Math.max(y - 9, 12), 'text-anchor': 'middle', class: 'peak-label' });
      tx.textContent = 'max ' + fmt(pk.v, c.unit) + ' · ' + fdt(pk.t); svg.append(tx); }
    // celownik + podpowiedz
    const cross = svgEl('line', { y1: m.t, y2: m.t + ih, stroke: 'var(--muted)', 'stroke-width': 1, visibility: 'hidden' });
    const dots = svgEl('g', {}); svg.append(cross, dots);
    const hit = svgEl('rect', { x: m.l, y: 0, width: iw, height: H, fill: 'transparent' }); svg.append(hit);
    const tip = el('div', 'tip'); plot.append(svg, tip);
    const hide = () => { cross.setAttribute('visibility', 'hidden'); dots.textContent = ''; tip.style.display = 'none'; };
    hit.addEventListener('pointerleave', hide);
    hit.addEventListener('pointermove', ev => {
      const r = svg.getBoundingClientRect(), px = (ev.clientX - r.left) * W / r.width;
      const t = M.start + Math.round(((px - m.l) / iw * (M.end - M.start)) / M.stepS) * M.stepS;
      if (t < M.start || t > M.end) return hide();
      const x = X(t); cross.setAttribute('x1', x); cross.setAttribute('x2', x); cross.setAttribute('visibility', 'visible');
      dots.textContent = '';
      const rows = vis.map(s => ({ s: s, v: s.map.get(t) })).filter(o => o.v != null).sort((a, b) => b.v - a.v);
      for (const o of rows) dots.append(svgEl('circle', { cx: x, cy: Y(o.v), r: 4, fill: o.s.color, stroke: 'var(--surface)', 'stroke-width': 2 }));
      tip.textContent = ''; tip.append(el('div', 't', fdt(t) + ' (max z ' + M.step + ')'));
      if (!rows.length) tip.append(el('div', null, 'brak danych'));
      for (const o of rows) { const row = el('div', 'row'); const k = el('span', 'key'); k.style.borderTopColor = o.s.color;
        row.append(k, el('b', null, fmt(o.v, c.unit)), el('span', null, o.s.name)); tip.append(row); }
      tip.style.display = 'block';
      const pw = plot.clientWidth, tw = tip.offsetWidth, sx = x * r.width / W;
      tip.style.left = (sx + 14 + tw > pw ? Math.max(0, sx - 14 - tw) : sx + 14) + 'px'; tip.style.top = '8px';
    });
  }
  const redraw = () => charts.forEach(draw);
  redraw();
  let rt; window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(redraw, 150); });
})();
</script>
</body>
</html>
HTMLEOF
}
html_template | awk -v f="$TMP/data.json" '$0=="__DATA__"{ while ((getline l < f) > 0) print l; next } { print }' >"$HTML"
echo "Raport HTML zapisany: $HTML  ($(du -h "$HTML" | cut -f1)). Zawiera nazwy z klastra - nie wrzucaj go do repozytorium." >&2
