#!/usr/bin/env python3
"""
ns_resource_report.py
OpenShift Namespace Resource Usage Reporter

Cel:
    Oblicza faktyczne zużycie zasobów (CPU/RAM) per namespace na podstawie
    aktualnie URUCHOMIONYCH podów (status.phase=Running). Uwzględnia wszystkie
    typy workloadów: Deployment, StatefulSet, DaemonSet, Job, standalone Pod itp.

    Wynik służy do planowania migracji klastra i projektowania nowych workerów.

Źródła danych:
    1. Requests/Limits  — z definicji Running Podów (co scheduler zarezerwował)
    2. Faktyczne użycie — z 'oc adm top pods' (migawka z metrics-server, opcjonalne)

Wymagania:
    - Zalogowany użytkownik: oc login
    - pip install tabulate

Przykłady:
    python3 ns_resource_report.py                          # wszystkie namespaces
    python3 ns_resource_report.py -n my-app               # tylko jeden namespace
    python3 ns_resource_report.py --skip-system           # pomiń openshift-*, kube-*
    python3 ns_resource_report.py --no-top                # bez metryk real-time
    python3 ns_resource_report.py --sort mem-req          # sortuj po MEM Request
    python3 ns_resource_report.py --exclude kube-system --exclude monitoring
"""

import sys
import argparse
import json
import subprocess
from datetime import datetime

# ---------------------------------------------------------------------------
# Konwersja jednostek
# ---------------------------------------------------------------------------

MEMORY_MULTIPLIERS = {
    'Ki': 1 / 1024,
    'Mi': 1,
    'Gi': 1024,
    'Ti': 1024 * 1024,
    # Warianty bez 'i' (np. K8s API może zwrócić '512K' zamiast '512Ki')
    'K': 1 / 1024,
    'M': 1,
    'G': 1024,
    'T': 1024 * 1024,
}


def convert_memory_to_mib(value_str):
    """Konwertuje wartość pamięci (np. '1Gi', '256Mi', '512K') na MiB (float)."""
    if not value_str:
        return 0.0
    # Normalizacja: usuń 'i' żeby obsłużyć oba warianty jedną tabelą
    temp = value_str.replace('i', '')
    for unit, mult in MEMORY_MULTIPLIERS.items():
        if temp.endswith(unit):
            try:
                return float(temp[:-len(unit)]) * mult
            except ValueError:
                return 0.0
    # Gołe liczby traktujemy jako bajty (K8s storage format)
    try:
        return float(value_str) / (1024 * 1024)
    except ValueError:
        return 0.0


def convert_cpu_to_m(value_str):
    """Konwertuje wartość CPU (np. '1', '500m', '1200m') na millicores (float)."""
    if not value_str:
        return 0.0
    if value_str.endswith('m'):
        try:
            return float(value_str[:-1])
        except ValueError:
            return 0.0
    try:
        return float(value_str) * 1000.0
    except ValueError:
        return 0.0


# ---------------------------------------------------------------------------
# Warstwa komunikacji z oc
# ---------------------------------------------------------------------------

def run_oc(args):
    """
    Uruchamia polecenie 'oc' z podanymi argumentami.
    Zwraca (stdout, stderr, returncode).
    """
    try:
        result = subprocess.run(
            ['oc'] + args,
            capture_output=True,
            text=True
        )
        return result.stdout, result.stderr, result.returncode
    except FileNotFoundError:
        print("BLAD: Nie znaleziono polecenia 'oc'. Upewnij się, że jest w PATH.")
        sys.exit(1)


def check_login():
    """Sprawdza czy użytkownik jest zalogowany. Zwraca (username, server_url)."""
    stdout, stderr, rc = run_oc(['whoami'])
    if rc != 0:
        print("BLAD: Nie jesteś zalogowany. Wykonaj najpierw: oc login <server>")
        sys.exit(1)
    username = stdout.strip()

    stdout2, _, _ = run_oc(['whoami', '--show-server'])
    server = stdout2.strip()

    return username, server


def get_namespaces(target_ns=None):
    """
    Zwraca listę namespace'ów do analizy.
    Jeśli target_ns podany — weryfikuje jego istnienie i zwraca listę jednoelementową.
    """
    if target_ns:
        stdout, stderr, rc = run_oc(['get', 'namespace', target_ns, '-o', 'name'])
        if rc != 0:
            print(f"BLAD: Namespace '{target_ns}' nie istnieje lub brak uprawnień.")
            print(f"      {stderr.strip()}")
            sys.exit(1)
        return [target_ns]

    stdout, stderr, rc = run_oc(['get', 'namespaces', '-o', 'jsonpath={.items[*].metadata.name}'])
    if rc != 0:
        print(f"BLAD: Nie można pobrać listy namespace'ów: {stderr.strip()}")
        sys.exit(1)

    namespaces = stdout.strip().split()
    if not namespaces:
        print("BLAD: Brak namespace'ów lub brak uprawnień do ich listowania.")
        sys.exit(1)
    return namespaces


def get_running_pods_resources(namespace):
    """
    Pobiera sumy CPU/RAM Requests i Limits dla wszystkich Running podów w namespace.

    Pobiera z RUNNING podów — nie z definicji Deploymentów. Dzięki temu wynik
    uwzględnia każdy typ workloadu i odzwierciedla faktyczną rezerwację schedulera.

    Zwraca słownik:
        pods      — liczba Running podów
        cpu_req_m — CPU Requests w millicores
        cpu_lim_m — CPU Limits w millicores (0 = brak limitu)
        mem_req_mib — Memory Requests w MiB
        mem_lim_mib — Memory Limits w MiB (0 = brak limitu)
        no_req_pods — liczba podów bez żadnych requests (nieoptymalne)
        error       — komunikat błędu lub None
    """
    stdout, stderr, rc = run_oc([
        'get', 'pods',
        '-n', namespace,
        '--field-selector=status.phase=Running',
        '-o', 'json'
    ])

    if rc != 0:
        return {
            'pods': 0, 'cpu_req_m': 0.0, 'cpu_lim_m': 0.0,
            'mem_req_mib': 0.0, 'mem_lim_mib': 0.0,
            'no_req_pods': 0, 'error': stderr.strip()
        }

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        return {
            'pods': 0, 'cpu_req_m': 0.0, 'cpu_lim_m': 0.0,
            'mem_req_mib': 0.0, 'mem_lim_mib': 0.0,
            'no_req_pods': 0, 'error': 'blad parsowania JSON'
        }

    pods_count = 0
    no_req_pods = 0
    total_cpu_req_m = 0.0
    total_cpu_lim_m = 0.0
    total_mem_req_mib = 0.0
    total_mem_lim_mib = 0.0

    for pod in data.get('items', []):
        pods_count += 1
        pod_has_req = False

        # Liczymy tylko zwykłe kontenery — init containers działają sekwencyjnie
        # i nie współbieżnie z głównymi, więc nie doliczamy ich do sumy zasobów.
        containers = pod.get('spec', {}).get('containers', [])
        for container in containers:
            resources = container.get('resources', {})
            requests = resources.get('requests', {})
            limits = resources.get('limits', {})

            cpu_req = requests.get('cpu', '')
            mem_req = requests.get('memory', '')
            cpu_lim = limits.get('cpu', '')
            mem_lim = limits.get('memory', '')

            if cpu_req or mem_req:
                pod_has_req = True

            total_cpu_req_m += convert_cpu_to_m(cpu_req)
            total_cpu_lim_m += convert_cpu_to_m(cpu_lim)
            total_mem_req_mib += convert_memory_to_mib(mem_req)
            total_mem_lim_mib += convert_memory_to_mib(mem_lim)

        if not pod_has_req:
            no_req_pods += 1

    return {
        'pods': pods_count,
        'cpu_req_m': total_cpu_req_m,
        'cpu_lim_m': total_cpu_lim_m,
        'mem_req_mib': total_mem_req_mib,
        'mem_lim_mib': total_mem_lim_mib,
        'no_req_pods': no_req_pods,
        'error': None
    }


def get_top_pods(namespace):
    """
    Pobiera faktyczne użycie CPU/RAM przez 'oc adm top pods'.
    Wymaga działającego metrics-server na klastrze.

    Zwraca słownik {'cpu_m': float, 'mem_mib': float} lub None jeśli niedostępne.
    """
    stdout, stderr, rc = run_oc([
        'adm', 'top', 'pods',
        '-n', namespace,
        '--no-headers'
    ])

    if rc != 0:
        return None

    total_cpu_m = 0.0
    total_mem_mib = 0.0
    parsed = 0

    for line in stdout.strip().splitlines():
        parts = line.split()
        # Oczekiwany format: NAME  CPU(cores)  MEMORY(bytes)
        if len(parts) < 3:
            continue
        total_cpu_m += convert_cpu_to_m(parts[1])
        total_mem_mib += convert_memory_to_mib(parts[2])
        parsed += 1

    if parsed == 0:
        return None

    return {'cpu_m': total_cpu_m, 'mem_mib': total_mem_mib}


# ---------------------------------------------------------------------------
# Formatowanie wartości
# ---------------------------------------------------------------------------

def fmt_cpu(millicores, pad=True):
    """
    Formatuje CPU: jeśli >= 1000m -> cores (np. '1.50 c'),
                   jeśli < 1000m  -> millicores (np. '250 m').
    """
    if millicores == 0:
        return "  -   "
    if millicores >= 1000:
        val = f"{millicores / 1000:.2f} c"
    else:
        val = f"{millicores:.0f} m"
    return val.rjust(8) if pad else val


def fmt_mem(mib, pad=True):
    """
    Formatuje pamięć: jeśli >= 1024 MiB -> GiB (np. '2.50 GiB'),
                       jeśli < 1024 MiB  -> MiB (np. '512 MiB').
    """
    if mib == 0:
        return "  -    "
    if mib >= 1024:
        val = f"{mib / 1024:.2f} GiB"
    else:
        val = f"{mib:.0f} MiB"
    return val.rjust(9) if pad else val


def fmt_pct(value, total, warn_threshold=70, crit_threshold=90):
    """Formatuje procent użycia z wizualnym ostrzeżeniem."""
    if total == 0 or value == 0:
        return "   N/A"
    pct = (value / total) * 100
    mark = ""
    if pct >= crit_threshold:
        mark = " (!)"
    elif pct >= warn_threshold:
        mark = "  (*)"
    return f"{pct:5.1f}%{mark}"


# ---------------------------------------------------------------------------
# Generowanie raportu
# ---------------------------------------------------------------------------

SORT_KEYS = {
    'cpu-req':  lambda d: d['cpu_req_m'],
    'cpu-lim':  lambda d: d['cpu_lim_m'],
    'mem-req':  lambda d: d['mem_req_mib'],
    'mem-lim':  lambda d: d['mem_lim_mib'],
    'pods':     lambda d: d['pods'],
    'name':     None,  # obsługiwane osobno
}

SYSTEM_PREFIXES = (
    'openshift-', 'kube-', 'default', 'kube-public', 'kube-node-lease',
)


def generate_report(ns_data, show_top, sort_by):
    """Generuje i wypisuje kompletny raport."""

    try:
        from tabulate import tabulate
    except ImportError:
        print("\nBLAD: Wymagana biblioteka 'tabulate'.")
        print("      Zainstaluj: pip install tabulate")
        sys.exit(1)

    # --- Sortowanie ---
    if sort_by == 'name':
        sorted_items = sorted(ns_data.items(), key=lambda x: x[0])
    else:
        sorted_items = sorted(
            ns_data.items(),
            key=lambda x: SORT_KEYS[sort_by](x[1]),
            reverse=True
        )

    # --- Sumy globalne ---
    valid_data = [d for _, d in ns_data.items() if not d.get('error')]
    grand_pods     = sum(d['pods']        for d in valid_data)
    grand_cpu_req  = sum(d['cpu_req_m']   for d in valid_data)
    grand_cpu_lim  = sum(d['cpu_lim_m']   for d in valid_data)
    grand_mem_req  = sum(d['mem_req_mib'] for d in valid_data)
    grand_mem_lim  = sum(d['mem_lim_mib'] for d in valid_data)
    grand_no_req   = sum(d['no_req_pods'] for d in valid_data)

    top_available = show_top and any(d.get('top') for _, d in ns_data.items())
    if top_available:
        grand_top_cpu = sum(d['top']['cpu_m']   for _, d in ns_data.items() if d.get('top'))
        grand_top_mem = sum(d['top']['mem_mib'] for _, d in ns_data.items() if d.get('top'))

    # --- Budowa wierszy tabeli ---
    if show_top:
        headers = [
            "NAMESPACE",
            "PODS",
            "CPU REQ",
            "CPU LIM",
            "CPU ACTUAL",
            "MEM REQ",
            "MEM LIM",
            "MEM ACTUAL",
        ]
    else:
        headers = [
            "NAMESPACE",
            "PODS",
            "CPU REQ",
            "CPU LIM",
            "MEM REQ",
            "MEM LIM",
        ]

    rows = []
    for ns, d in sorted_items:
        if d.get('error'):
            err_marker = f"ERR: {d['error'][:30]}"
            if show_top:
                rows.append([ns, err_marker, "-", "-", "-", "-", "-", "-"])
            else:
                rows.append([ns, err_marker, "-", "-", "-", "-"])
            continue

        warn = " (*)" if d['no_req_pods'] > 0 else ""
        pods_str = f"{d['pods']}{warn}"

        row = [
            ns,
            pods_str,
            fmt_cpu(d['cpu_req_m']),
            fmt_cpu(d['cpu_lim_m']),
        ]

        if show_top:
            top = d.get('top')
            row.append(fmt_cpu(top['cpu_m']) if top else "   N/A  ")

        row += [
            fmt_mem(d['mem_req_mib']),
            fmt_mem(d['mem_lim_mib']),
        ]

        if show_top:
            top = d.get('top')
            row.append(fmt_mem(top['mem_mib']) if top else "   N/A   ")

        rows.append(row)

    # Separator + wiersz sumy
    rows.append([""] * len(headers))

    sum_row = [
        f"SUMA KLASTRA  ({len(ns_data)} NS)",
        grand_pods,
        fmt_cpu(grand_cpu_req),
        fmt_cpu(grand_cpu_lim),
    ]
    if show_top:
        sum_row.append(fmt_cpu(grand_top_cpu) if top_available else "   N/A  ")
    sum_row += [
        fmt_mem(grand_mem_req),
        fmt_mem(grand_mem_lim),
    ]
    if show_top:
        sum_row.append(fmt_mem(grand_top_mem) if top_available else "   N/A   ")

    rows.append(sum_row)

    # --- Drukuj raport ---
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    print()
    print("=" * 90)
    print("  OPENSHIFT NAMESPACE RESOURCE REPORT")
    print(f"  Wygenerowano : {now}")
    print(f"  Sortowanie   : {sort_by} DESC")
    print(f"  Podstawa     : Running Pods (faktyczne rezerwacje schedulera)")
    print("=" * 90)
    print()
    print(tabulate(rows, headers=headers, tablefmt="fancy_grid", numalign="right"))

    # --- Sekcja sumaryczna ---
    print()
    print("┌─────────────────────────────────────────────────────────────────┐")
    print("│  PODSUMOWANIE KLASTRA — DO PLANOWANIA MIGRACJI                  │")
    print("├─────────────────────────────────────────────────────────────────┤")
    print(f"│  Running Pods łącznie : {grand_pods:<8}                               │")
    print(f"│  CPU Requests SUMA    : {fmt_cpu(grand_cpu_req, pad=False):<10}  ({grand_cpu_req/1000:.2f} Core)              │")
    print(f"│  CPU Limits   SUMA    : {fmt_cpu(grand_cpu_lim, pad=False):<10}  ({grand_cpu_lim/1000:.2f} Core)              │")
    print(f"│  MEM Requests SUMA    : {fmt_mem(grand_mem_req, pad=False):<10}  ({grand_mem_req/1024:.2f} GiB)               │")
    print(f"│  MEM Limits   SUMA    : {fmt_mem(grand_mem_lim, pad=False):<10}  ({grand_mem_lim/1024:.2f} GiB)               │")
    if top_available:
        print(f"│  CPU Actual   (top)   : {fmt_cpu(grand_top_cpu, pad=False):<10}  ({grand_top_cpu/1000:.2f} Core)              │")
        print(f"│  MEM Actual   (top)   : {fmt_mem(grand_top_mem, pad=False):<10}  ({grand_top_mem/1024:.2f} GiB)               │")
    if grand_no_req > 0:
        print(f"│  (*) Pody bez Requests: {grand_no_req:<8}  — wartości niedoszacowane!       │")
    print("└─────────────────────────────────────────────────────────────────┘")

    # --- Legenda ---
    print()
    print("LEGENDA:")
    print("  CPU REQ    = CPU Requests  — zasoby zarezerwowane przez scheduler (gwarantowane)")
    print("  CPU LIM    = CPU Limits    — maks. CPU jakie pod może zużyć (0/-  = brak limitu)")
    print("  MEM REQ    = Mem Requests  — RAM zarezerwowany przez scheduler")
    print("  MEM LIM    = Mem Limits    — maks. RAM (po przekroczeniu -> OOMKill)")
    if show_top:
        print("  CPU/MEM ACTUAL = Faktyczne użycie w chwili uruchomienia (metrics-server)")
    print("  (*)        = Namespace zawiera pody BEZ zdefiniowanych Requests")
    print("  c  = Core  |  m = millicores  |  GiB / MiB = jednostki pamięci")
    print()
    print("WSKAZÓWKA DO PLANOWANIA:")
    print("  Rozmiar workerów dobieraj wg CPU/MEM REQUESTS (to widzi scheduler).")
    print("  Dodaj ok. 20-30% narzut na system OS + OpenShift components.")
    print("  Jeśli CPU ACTUAL << CPU REQ — rozważ optymalizację requests w aplikacjach.")

    # --- Ostrzeżenia ---
    errors = [(ns, d['error']) for ns, d in ns_data.items() if d.get('error')]
    if errors:
        print()
        print(f"OSTRZEZENIA ({len(errors)} namespace'ow z bledami dostępu):")
        for ns, err in errors:
            print(f"  - {ns}: {err}")


# ---------------------------------------------------------------------------
# Główna funkcja
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description=(
            "OpenShift Namespace Resource Usage Reporter\n"
            "Oblicza zużycie CPU/RAM per namespace na podstawie Running Podów.\n"
            "Uruchamiaj jako użytkownik zalogowany przez 'oc login'."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument(
        '--namespace', '-n',
        help='Ogranicz raport do jednego namespace (domyślnie: wszystkie)'
    )
    parser.add_argument(
        '--skip-system',
        action='store_true',
        help=(
            'Pomiń systemowe namespace OpenShifta '
            '(openshift-*, kube-*, default, kube-public, kube-node-lease)'
        )
    )
    parser.add_argument(
        '--exclude',
        action='append',
        metavar='NAMESPACE',
        default=[],
        help='Wyklucz wskazany namespace (można podać wielokrotnie)'
    )
    parser.add_argument(
        '--no-top',
        action='store_true',
        help=(
            'Nie pobieraj metryk real-time (oc adm top pods). '
            'Szybsze wykonanie, nie wymaga metrics-server.'
        )
    )
    parser.add_argument(
        '--sort',
        default='cpu-req',
        choices=list(SORT_KEYS.keys()),
        help='Kryterium sortowania tabeli (domyślnie: cpu-req DESC)'
    )

    args = parser.parse_args()

    # Weryfikacja logowania
    username, server = check_login()
    print(f"Zalogowany jako : {username}")
    print(f"Klaster         : {server}")
    print()

    # Pobierz listę namespace'ów
    print("Pobieranie listy namespace'ów...")
    namespaces = get_namespaces(args.namespace)

    # Filtrowanie
    if args.skip_system and not args.namespace:
        before = len(namespaces)
        namespaces = [ns for ns in namespaces if not ns.startswith(SYSTEM_PREFIXES)]
        print(f"  Pominięto {before - len(namespaces)} systemowych namespace'ów.")

    if args.exclude:
        exclude_set = set(args.exclude)
        namespaces = [ns for ns in namespaces if ns not in exclude_set]
        print(f"  Wykluczono namespace'y: {', '.join(args.exclude)}")

    if not namespaces:
        print("Brak namespace'ów do analizy.")
        sys.exit(0)

    print(f"Analizuję {len(namespaces)} namespace'ów...")
    if not args.no_top:
        print("  (pobieranie metryk 'oc adm top' — użyj --no-top aby przyspieszyć)")
    print()

    # Zbieranie danych
    ns_data = {}
    for i, ns in enumerate(namespaces, 1):
        print(f"  [{i:>3}/{len(namespaces)}] {ns:<45}", end='', flush=True)

        data = get_running_pods_resources(ns)

        if not args.no_top:
            data['top'] = get_top_pods(ns)

        ns_data[ns] = data

        if data.get('error'):
            print(f"BLAD: {data['error'][:40]}")
        else:
            top_info = ""
            if not args.no_top and data.get('top'):
                top_info = f"  actual: {fmt_cpu(data['top']['cpu_m'], pad=False)} / {fmt_mem(data['top']['mem_mib'], pad=False)}"
            warn = f"  [{data['no_req_pods']} podów bez requests!]" if data['no_req_pods'] else ""
            print(f"{data['pods']} pods  req: {fmt_cpu(data['cpu_req_m'], pad=False)} CPU / {fmt_mem(data['mem_req_mib'], pad=False)} RAM{top_info}{warn}")

    # Generuj raport końcowy
    generate_report(ns_data, show_top=not args.no_top, sort_by=args.sort)


if __name__ == '__main__':
    main()
