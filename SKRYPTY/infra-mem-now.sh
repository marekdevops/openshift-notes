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
CURL_K=""; FOCUS=""; EXEC=0
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
  -k           nie weryfikuj certyfikatu TLS route'a thanos-querier
  -x           zajrzyj do podow routera (oc exec, tylko polecenia podgladu):
               procesy haproxy, "show info", pule pamieci, aktywne sesje
Przyklad:  $0 -k -x | tee mem-now-\$(date +%F_%H%M).txt
EOF
exit "${1:-0}"; }

while getopts "n:l:t:r:T:L:kxh" o; do case $o in
  n) FOCUS=$OPTARG;; l) SELECTOR=$OPTARG;; t) TOPN=$OPTARG;; r) RATE=$OPTARG;;
  T) TREND=$OPTARG;; L) LOGWIN=$OPTARG;; k) CURL_K="-k";; x) EXEC=1;; h) usage 0;; *) usage 1;;
esac; done

die()  { echo "BLAD: $*" >&2; exit 1; }
warn() { echo "UWAGA: $*" >&2; }
LINE=$(printf '=%.0s' {1..100})
hdr()  { printf '\n%s\n== %s\n%s\n' "$LINE" "$1" "$LINE"; }
sub()  { printf '\n--- %s\n' "$1"; }
# Przyjazny komentarz pod tabela/sekcja
say()  { fold -s -w 96 <<<"$*" | sed 's/^/  | /'; }

# Jedyna droga do klastra.
oc_ro() { case "${1:-}" in
  get|whoami|logs) command oc "$@";;
  exec) (( EXEC )) || die "oc_ro: 'oc exec' dozwolone tylko z opcja -x"; command oc "$@";;
  *) die "oc_ro: zablokowano 'oc $1' (skrypt jest tylko do odczytu)";; esac; }

for c in oc jq curl column awk; do command -v "$c" >/dev/null || die "brak polecenia: $c"; done
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: >"$TMP/findings"

# --- pomocnicze -----------------------------------------------------------------
# finding POZIOM TEKST   (1 = krytyczne, 2 = uwaga, 3 = informacja)
finding() { printf '%s\t%s\n' "$1" "$2" >>"$TMP/findings"; }
hbs() { awk -v v="${1:-0}" 'BEGIN{a=v<0?-v:v; s=v<0?"-":"";
  if(a>=1073741824) printf "%s%.2f GiB",s,a/1073741824; else if(a>=1048576) printf "%s%.1f MiB",s,a/1048576;
  else if(a>=1024) printf "%s%.1f KiB",s,a/1024; else printf "%s%d B",s,a}'; }
ge()  { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
pct() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if(b+0>0) printf "%.0f", a/b*100; else printf "0"}'; }

# --- dostep do Prometheusa ---------------------------------------------------------
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
table() { local rows; rows=$(cat)
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
oc_ro get routes -A -o json >"$TMP/routes.json" 2>/dev/null || echo '{"items":[]}' >"$TMP/routes.json"

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
while IFS=$'\t' read -r p v; do
  [[ -n $p ]] || continue
  ge "$v" 30 && finding 2 "Router $p przeladowal konfiguracje ${v%.*} razy w $LOGWIN - czeste zmiany route/endpointow; kazdy reload uruchamia nowy proces HAProxy, a stary zostaje, dopoki ma polaczenia."
done < <(plist pod "sum by (pod)(increase(template_router_reload_seconds_count{$RF}[$LOGWIN]))")
while IFS=$'\t' read -r p w; do
  [[ -n $p ]] || continue
  s=$(jq -r --arg p "$p" '.data.result[] | select(.metric.pod==$p) | .value[1]' "$TMP/rsess.json"); s=${s:-0}
  finding 3 "Router $p: pamiec $(hbs "$w"), aktywnych polaczen ${s%.*} (szac. bufory $(hbs "$(awk -v s="$s" -v b="$BUF" 'BEGIN{print s*2*b}')"))."
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
