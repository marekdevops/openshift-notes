#!/usr/bin/env python3
"""
OCP / K8s  —  Scheduling Feasibility Analyzer
==============================================
Zbiera Deployment / DeploymentConfig / StatefulSet z klastra,
dla każdego sprawdza: nodeSelector, nodeAffinity, tolerations
i resource requests, a następnie wypisuje:
  • ile nodów pasuje do workloada
  • ile wolnego CPU/RAM jest na każdym z nich
  • ile replik faktycznie zmieści się na klastrze
  • podsumowanie (tabela) + overview wszystkich nodów

Użycie:
    # konkretny namespace
    python ocp_sched_analyzer.py -n my-namespace

    # wszystkie namespace'y
    python ocp_sched_analyzer.py -A

    # symuluj drain (np. podczas update'u OCP)
    python ocp_sched_analyzer.py -n my-ns --drain worker-1 --drain worker-2

    # filtruj konkretny workload
    python ocp_sched_analyzer.py -n my-ns --name my-deployment

    # zmień kubeconfig / context
    python ocp_sched_analyzer.py -n my-ns --context my-cluster

Wymagania:
    pip install kubernetes rich
"""

import argparse
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# ─── Dependency check ────────────────────────────────────────────────────────

try:
    from kubernetes import client, config, dynamic
    from kubernetes.client.rest import ApiException
except ImportError:
    print("BRAK ZALEŻNOŚCI: pip install kubernetes")
    sys.exit(1)

try:
    from rich.console import Console
    from rich.table import Table
    from rich.panel import Panel
    from rich import box
except ImportError:
    print("BRAK ZALEŻNOŚCI: pip install rich")
    sys.exit(1)

console = Console()

# ─── Resource helpers ────────────────────────────────────────────────────────

def cpu_to_m(val: Optional[str]) -> int:
    """Konwertuje string CPU na milicores (np. '500m'→500, '2'→2000)."""
    if not val:
        return 0
    val = str(val).strip()
    if val.endswith('m'):
        return int(val[:-1])
    return int(float(val) * 1000)


def mem_to_mib(val: Optional[str]) -> int:
    """Konwertuje string pamięci na MiB (np. '512Mi'→512, '1Gi'→1024)."""
    if not val:
        return 0
    val = str(val).strip()
    table = [
        ('Ki', 1 / 1024), ('Mi', 1), ('Gi', 1024),
        ('Ti', 1024 ** 2), ('Pi', 1024 ** 3),
        ('K',  1000 / 1024 ** 2),
        ('M',  1000 ** 2 / 1024 ** 2),
        ('G',  1000 ** 3 / 1024 ** 2),
    ]
    for suffix, factor in sorted(table, key=lambda x: -len(x[0])):
        if val.endswith(suffix):
            return max(1, int(float(val[:-len(suffix)]) * factor))
    return max(1, int(val) // (1024 ** 2))


def fmt_cpu(m: int) -> str:
    if m >= 1000:
        s = f"{m / 1000:.2f}".rstrip('0').rstrip('.')
        return f"{s} CPU"
    return f"{m}m"


def fmt_mem(mib: int) -> str:
    if mib >= 1024:
        return f"{mib / 1024:.1f} GiB"
    return f"{mib} MiB"


def _get(obj, *keys, default=None):
    """Odczyt atrybutu z obiektu SDK (attr) lub słownika (dict)."""
    for key in keys:
        if obj is None:
            return default
        if isinstance(obj, dict):
            obj = obj.get(key, default)
        else:
            obj = getattr(obj, key, default)
    return obj

# ─── Dataclasses ─────────────────────────────────────────────────────────────

@dataclass
class WorkloadInfo:
    name: str
    namespace: str
    kind: str
    replicas: int
    node_selector: Dict[str, str]
    affinity: object          # V1Affinity | dict | None
    tolerations: List[object]
    cpu_request: int          # millicores per pod
    mem_request: int          # MiB per pod

    @property
    def total_cpu(self) -> int:
        return self.cpu_request * self.replicas

    @property
    def total_mem(self) -> int:
        return self.mem_request * self.replicas


@dataclass
class NodeInfo:
    name: str
    labels: Dict[str, str]
    taints: List[object]
    alloc_cpu: int            # millicores
    alloc_mem: int            # MiB
    req_cpu: int = 0          # suma requests z podów
    req_mem: int = 0
    drained: bool = False     # symulacja drain

    @property
    def free_cpu(self) -> int:
        return 0 if self.drained else max(0, self.alloc_cpu - self.req_cpu)

    @property
    def free_mem(self) -> int:
        return 0 if self.drained else max(0, self.alloc_mem - self.req_mem)

# ─── Node matching ────────────────────────────────────────────────────────────

def matches_selector(node: NodeInfo, selector: Dict[str, str]) -> bool:
    for k, v in selector.items():
        if node.labels.get(k) != v:
            return False
    return True


def _match_expressions(node: NodeInfo, expressions) -> bool:
    """Ewaluuje listę matchExpressions (AND między wyrażeniami)."""
    if not expressions:
        return True
    for expr in expressions:
        key    = _get(expr, 'key',      'key')
        op     = _get(expr, 'operator', 'operator')
        values = list(_get(expr, 'values', 'values') or [])

        label_val = node.labels.get(key)

        if op == 'In':
            if label_val not in values:
                return False
        elif op == 'NotIn':
            if label_val in values:
                return False
        elif op == 'Exists':
            if key not in node.labels:
                return False
        elif op == 'DoesNotExist':
            if key in node.labels:
                return False
        elif op == 'Gt':
            try:
                if not (label_val and int(label_val) > int(values[0])):
                    return False
            except (ValueError, IndexError):
                return False
        elif op == 'Lt':
            try:
                if not (label_val and int(label_val) < int(values[0])):
                    return False
            except (ValueError, IndexError):
                return False
    return True


def matches_affinity(node: NodeInfo, affinity) -> bool:
    if affinity is None:
        return True

    na = _get(affinity, 'node_affinity', 'nodeAffinity')
    if na is None:
        return True

    required = _get(na,
                    'required_during_scheduling_ignored_during_execution',
                    'requiredDuringSchedulingIgnoredDuringExecution')
    if required is None:
        return True

    terms = list(_get(required, 'node_selector_terms', 'nodeSelectorTerms') or [])
    if not terms:
        return True

    # OR pomiędzy termami
    for term in terms:
        exprs = list(_get(term, 'match_expressions', 'matchExpressions') or [])
        if _match_expressions(node, exprs):
            return True
    return False


def is_tolerated(node: NodeInfo, tolerations: List) -> Tuple[bool, List[str]]:
    """Zwraca (wszystko_tolerowane, lista_kluczy_nietolerowanych)."""
    untolerated = []
    for taint in node.taints:
        t_key    = _get(taint, 'key',    'key')
        t_value  = _get(taint, 'value',  'value')
        t_effect = _get(taint, 'effect', 'effect')

        if t_effect == 'PreferNoSchedule':
            continue

        tolerated = False
        for tol in tolerations:
            tol_key    = _get(tol, 'key',    'key')
            tol_value  = _get(tol, 'value',  'value')
            tol_effect = _get(tol, 'effect', 'effect')
            tol_op     = _get(tol, 'operator', 'operator') or 'Equal'

            if tol_effect and tol_effect != t_effect:
                continue
            if tol_op == 'Exists':
                if tol_key is None or tol_key == t_key:
                    tolerated = True
                    break
            elif tol_op == 'Equal':
                if tol_key == t_key and tol_value == t_value:
                    tolerated = True
                    break

        if not tolerated:
            untolerated.append(str(t_key))

    return len(untolerated) == 0, untolerated

# ─── Kubernetes data loading ──────────────────────────────────────────────────

def load_nodes(v1: client.CoreV1Api) -> List[NodeInfo]:
    result = []
    for n in v1.list_node().items:
        alloc = n.status.allocatable or {}
        result.append(NodeInfo(
            name=n.metadata.name,
            labels=n.metadata.labels or {},
            taints=n.spec.taints or [],
            alloc_cpu=cpu_to_m(alloc.get('cpu')),
            alloc_mem=mem_to_mib(alloc.get('memory')),
        ))
    return result


def load_node_requests(v1: client.CoreV1Api, nodes: List[NodeInfo]):
    """Sumuje requests ze wszystkich running podów i przypisuje do nodów."""
    pods = v1.list_pod_for_all_namespaces(
        field_selector="status.phase!=Failed,status.phase!=Succeeded"
    ).items

    cpu_sum: Dict[str, int] = defaultdict(int)
    mem_sum: Dict[str, int] = defaultdict(int)

    for pod in pods:
        node_name = pod.spec.node_name
        if not node_name:
            continue
        for container in pod.spec.containers:
            req = _get(container, 'resources', 'requests') or {}
            if isinstance(req, dict):
                cpu_sum[node_name] += cpu_to_m(req.get('cpu'))
                mem_sum[node_name] += mem_to_mib(req.get('memory'))
            else:
                cpu_sum[node_name] += cpu_to_m(_get(req, 'cpu'))
                mem_sum[node_name] += mem_to_mib(_get(req, 'memory'))

    for node in nodes:
        node.req_cpu = cpu_sum[node.name]
        node.req_mem = mem_sum[node.name]


def _extract_pod_resources(containers) -> Tuple[int, int]:
    """Sumuje CPU i RAM requests ze wszystkich kontenerów poda."""
    total_cpu = total_mem = 0
    for c in containers:
        req = _get(c, 'resources', 'requests') or {}
        if isinstance(req, dict):
            total_cpu += cpu_to_m(req.get('cpu'))
            total_mem += mem_to_mib(req.get('memory'))
        else:
            total_cpu += cpu_to_m(_get(req, 'cpu'))
            total_mem += mem_to_mib(_get(req, 'memory'))
    return total_cpu, total_mem


def extract_workload(obj, kind: str) -> WorkloadInfo:
    """Wspólny ekstraktor dla Deployment / StatefulSet (obiekty SDK)."""
    spec     = obj.spec
    tmpl     = spec.template.spec
    replicas = spec.replicas or 1

    cpu, mem = _extract_pod_resources(tmpl.containers or [])

    return WorkloadInfo(
        name=obj.metadata.name,
        namespace=obj.metadata.namespace,
        kind=kind,
        replicas=replicas,
        node_selector=tmpl.node_selector or {},
        affinity=tmpl.affinity,
        tolerations=tmpl.tolerations or [],
        cpu_request=cpu,
        mem_request=mem,
    )


def extract_dc(dc) -> WorkloadInfo:
    """Ekstraktor dla DeploymentConfig (dynamic client)."""
    spec     = dc.spec
    tmpl     = spec.template.spec
    replicas = int(spec.replicas or 1)

    containers = list(tmpl.containers or [])
    cpu, mem   = _extract_pod_resources(containers)

    node_selector = {}
    raw_sel = getattr(tmpl, 'nodeSelector', None)
    if raw_sel:
        node_selector = dict(raw_sel)

    return WorkloadInfo(
        name=dc.metadata.name,
        namespace=dc.metadata.namespace,
        kind='DeploymentConfig',
        replicas=replicas,
        node_selector=node_selector,
        affinity=getattr(tmpl, 'affinity', None),
        tolerations=list(getattr(tmpl, 'tolerations', None) or []),
        cpu_request=cpu,
        mem_request=mem,
    )


def load_workloads(
    apps_v1: client.AppsV1Api,
    dyn_client,
    namespace: Optional[str],
    all_ns: bool,
    kinds: List[str],
    name_filter: Optional[str],
) -> List[WorkloadInfo]:

    workloads: List[WorkloadInfo] = []

    def maybe_filter(items):
        if name_filter:
            return [i for i in items if i.metadata.name == name_filter]
        return items

    if 'Deployment' in kinds:
        items = (apps_v1.list_deployment_for_all_namespaces() if all_ns
                 else apps_v1.list_namespaced_deployment(namespace)).items
        for d in maybe_filter(items):
            workloads.append(extract_workload(d, 'Deployment'))

    if 'StatefulSet' in kinds:
        items = (apps_v1.list_stateful_set_for_all_namespaces() if all_ns
                 else apps_v1.list_namespaced_stateful_set(namespace)).items
        for s in maybe_filter(items):
            workloads.append(extract_workload(s, 'StatefulSet'))

    if 'DeploymentConfig' in kinds and dyn_client:
        try:
            dc_res = dyn_client.resources.get(
                api_version='apps.openshift.io/v1',
                kind='DeploymentConfig'
            )
            raw = dc_res.get() if all_ns else dc_res.get(namespace=namespace)
            for dc in raw.items:
                if name_filter and dc.metadata.name != name_filter:
                    continue
                workloads.append(extract_dc(dc))
        except Exception as e:
            console.print(f"[yellow]⚠  DeploymentConfig niedostępny: {e}[/yellow]")

    return workloads

# ─── Analysis ─────────────────────────────────────────────────────────────────

def analyze(workload: WorkloadInfo, all_nodes: List[NodeInfo]) -> dict:
    matching  = []
    excluded  = defaultdict(list)

    for node in all_nodes:
        if workload.node_selector and not matches_selector(node, workload.node_selector):
            excluded['selector'].append(node.name)
            continue
        if not matches_affinity(node, workload.affinity):
            excluded['affinity'].append(node.name)
            continue
        ok, untolerated = is_tolerated(node, workload.tolerations)
        if not ok:
            excluded['taint'].append((node.name, untolerated))
            continue
        matching.append(node)

    req_cpu = workload.cpu_request
    req_mem = workload.mem_request

    # Ile replik zmieści się na KAŻDYM nodzie (best-effort, bez bin-packingu)
    max_replicas = 0
    for node in matching:
        fits_cpu = node.free_cpu // req_cpu if req_cpu > 0 else 9999
        fits_mem = node.free_mem // req_mem if req_mem > 0 else 9999
        max_replicas += min(fits_cpu, fits_mem)

    total_free_cpu = sum(n.free_cpu for n in matching)
    total_free_mem = sum(n.free_mem for n in matching)

    return {
        'matching_nodes': matching,
        'excluded': excluded,
        'total_free_cpu': total_free_cpu,
        'total_free_mem': total_free_mem,
        'can_fit': max_replicas >= workload.replicas,
        'max_replicas': max_replicas,
    }

# ─── Display ──────────────────────────────────────────────────────────────────

def _bar(used: int, total: int, width: int = 12) -> str:
    pct  = used / total if total else 0
    fill = int(pct * width)
    bar  = '█' * fill + '░' * (width - fill)
    color = 'green' if pct < 0.70 else ('yellow' if pct < 0.90 else 'red')
    return f"[{color}]{bar}[/{color}] {int(pct * 100):3d}%"


def display_workload(workload: WorkloadInfo, analysis: dict, all_nodes: List[NodeInfo]):
    feasible     = analysis['can_fit']
    status_color = 'green' if feasible else 'red'
    status_text  = '✓  SCHEDULABLE' if feasible else '✗  NOT SCHEDULABLE'
    total_nodes  = len(all_nodes)
    matching     = analysis['matching_nodes']

    title = (f"[bold]{workload.kind}[/bold]: [cyan]{workload.name}[/cyan]"
             f"  [dim]({workload.namespace})[/dim]"
             f"  [{status_color}]{status_text}[/{status_color}]")

    lines = [
        f"  Replicas :   [bold]{workload.replicas}[/bold]",
    ]
    if workload.node_selector:
        sel = ', '.join(f"[yellow]{k}[/yellow]=[cyan]{v}[/cyan]"
                        for k, v in workload.node_selector.items())
        lines.append(f"  Selector :   {sel}")
    if workload.affinity:
        lines.append("  Affinity :   [yellow]zdefiniowana[/yellow]")
    if workload.tolerations:
        lines.append(f"  Toleracje:   {len(workload.tolerations)} szt.")

    lines += [
        f"  Per pod  :   CPU [bold]{fmt_cpu(workload.cpu_request)}[/bold]"
        f"  |  RAM [bold]{fmt_mem(workload.mem_request)}[/bold]",
        f"  Łącznie  :   CPU [bold]{fmt_cpu(workload.total_cpu)}[/bold]"
        f"  |  RAM [bold]{fmt_mem(workload.total_mem)}[/bold]",
        f"  Max fits :   [{status_color}]{analysis['max_replicas']} replik[/{status_color}]"
        f"  (potrzeba {workload.replicas})",
        f"  Nody     :   [bold]{len(matching)}[/bold] pasujących"
        f" z {total_nodes} dostępnych",
    ]

    # Excluded breakdown
    excl = analysis['excluded']
    if excl:
        parts = []
        if 'selector' in excl:
            parts.append(f"[yellow]{len(excl['selector'])} nodeSelector[/yellow]")
        if 'affinity' in excl:
            parts.append(f"[yellow]{len(excl['affinity'])} affinity[/yellow]")
        if 'taint' in excl:
            parts.append(f"[red]{len(excl['taint'])} taint[/red]")
        lines.append(f"  Wykluczone:  {', '.join(parts)}")

    console.print(Panel('\n'.join(lines), title=title, border_style=status_color))

    if not matching:
        console.print("  [red]Brak pasujących nodów — pod nie zostanie zaschedulowany.[/red]\n")
        return

    # Tabela nodów
    t = Table(box=box.SIMPLE_HEAVY, show_header=True, header_style='bold cyan',
              title=f"[bold]Pasujące nody ({len(matching)})[/bold]")
    t.add_column("Node",         style='white', no_wrap=True)
    t.add_column("Status",       justify='center')
    t.add_column("Alloc CPU",    justify='right')
    t.add_column("Req CPU",      justify='right')
    t.add_column("Free CPU",     justify='right')
    t.add_column("CPU%",         justify='center', min_width=18)
    t.add_column("Alloc RAM",    justify='right')
    t.add_column("Req RAM",      justify='right')
    t.add_column("Free RAM",     justify='right')
    t.add_column("RAM%",         justify='center', min_width=18)
    t.add_column("Fits (pody)",  justify='center')

    for node in sorted(matching, key=lambda n: n.name):
        req_cpu = workload.cpu_request
        req_mem = workload.mem_request
        fits_cpu = node.free_cpu // req_cpu if req_cpu > 0 else 9999
        fits_mem = node.free_mem // req_mem if req_mem > 0 else 9999
        fits     = min(fits_cpu, fits_mem)

        cpu_ok = node.free_cpu >= req_cpu
        mem_ok = node.free_mem >= req_mem

        free_cpu_s = f"[{'green' if cpu_ok else 'red'}]{fmt_cpu(node.free_cpu)}[/]"
        free_mem_s = f"[{'green' if mem_ok else 'red'}]{fmt_mem(node.free_mem)}[/]"
        fits_s     = f"[{'green' if fits > 0 else 'red'}]{fits}[/]"
        status_s   = "[red]DRAINED[/red]" if node.drained else "[green]OK[/green]"

        t.add_row(
            node.name,
            status_s,
            fmt_cpu(node.alloc_cpu),
            fmt_cpu(node.req_cpu),
            free_cpu_s,
            _bar(node.req_cpu, node.alloc_cpu),
            fmt_mem(node.alloc_mem),
            fmt_mem(node.req_mem),
            free_mem_s,
            _bar(node.req_mem, node.alloc_mem),
            fits_s,
        )

    console.print(t)
    console.print()


def display_summary(workloads: List[WorkloadInfo],
                    analyses: List[dict],
                    all_nodes: List[NodeInfo]):

    console.rule("[bold white]PODSUMOWANIE WORKLOADÓW[/bold white]")

    t = Table(box=box.ROUNDED, header_style='bold white on navy_blue')
    t.add_column("Workload",    style='cyan',   no_wrap=True)
    t.add_column("NS",          style='dim',    no_wrap=True)
    t.add_column("Kind",        style='dim')
    t.add_column("Repliki",     justify='center')
    t.add_column("CPU/pod",     justify='right')
    t.add_column("RAM/pod",     justify='right')
    t.add_column("CPU łącznie", justify='right')
    t.add_column("RAM łącznie", justify='right')
    t.add_column("Pasuj. nody", justify='center')
    t.add_column("Max fits",    justify='center')
    t.add_column("Status",      justify='center')

    for w, a in zip(workloads, analyses):
        ok    = a['can_fit']
        color = 'green' if ok else 'red'
        mf    = a['max_replicas']
        t.add_row(
            w.name, w.namespace, w.kind,
            str(w.replicas),
            fmt_cpu(w.cpu_request), fmt_mem(w.mem_request),
            fmt_cpu(w.total_cpu),   fmt_mem(w.total_mem),
            str(len(a['matching_nodes'])),
            f"[{color}]{mf}[/{color}]",
            f"[{color}]{'✓ OK' if ok else '✗ FAIL'}[/{color}]",
        )

    console.print(t)

    # ── Cluster overview ──────────────────────────────────────────────────────
    console.print()
    console.rule("[bold white]OVERVIEW KLASTRA (wszystkie nody)[/bold white]")

    ct = Table(box=box.SIMPLE, header_style='bold cyan')
    ct.add_column("Node",     no_wrap=True)
    ct.add_column("Status",   justify='center')
    ct.add_column("AllocCPU", justify='right')
    ct.add_column("ReqCPU",   justify='right')
    ct.add_column("FreeCPU",  justify='right')
    ct.add_column("CPU%",     justify='center', min_width=18)
    ct.add_column("AllocRAM", justify='right')
    ct.add_column("ReqRAM",   justify='right')
    ct.add_column("FreeRAM",  justify='right')
    ct.add_column("RAM%",     justify='center', min_width=18)

    for node in sorted(all_nodes, key=lambda n: n.name):
        status_s = "[red]DRAINED[/red]" if node.drained else "[green]OK[/green]"
        ct.add_row(
            node.name,
            status_s,
            fmt_cpu(node.alloc_cpu),
            fmt_cpu(node.req_cpu),
            fmt_cpu(node.free_cpu),
            _bar(node.req_cpu, node.alloc_cpu),
            fmt_mem(node.alloc_mem),
            fmt_mem(node.req_mem),
            fmt_mem(node.free_mem),
            _bar(node.req_mem, node.alloc_mem),
        )

    console.print(ct)

# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='OCP/K8s Scheduling Feasibility Analyzer',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    ns_group = parser.add_mutually_exclusive_group(required=True)
    ns_group.add_argument('-n', '--namespace',      metavar='NS',
                          help='Namespace do analizy')
    ns_group.add_argument('-A', '--all-namespaces', action='store_true',
                          help='Wszystkie namespace\'y')

    parser.add_argument('--kinds',
                        default='Deployment,DeploymentConfig,StatefulSet',
                        metavar='KIND,...',
                        help='Rodzaje workloadów (domyślnie: Deployment,DeploymentConfig,StatefulSet)')
    parser.add_argument('--name',       metavar='NAME',
                        help='Filtruj po nazwie workloada')
    parser.add_argument('--drain',      metavar='NODE', action='append', default=[],
                        help='Symuluj drain noda (powtarzaj dla wielu)')
    parser.add_argument('--kubeconfig', metavar='PATH',
                        help='Ścieżka do kubeconfig')
    parser.add_argument('--context',    metavar='CTX',
                        help='Context kubeconfig')

    args = parser.parse_args()

    # Ładowanie konfiguracji
    try:
        config.load_kube_config(config_file=args.kubeconfig, context=args.context)
    except Exception:
        try:
            config.load_incluster_config()
        except Exception as e:
            console.print(f"[red]Nie można załadować kubeconfig: {e}[/red]")
            sys.exit(1)

    kinds = [k.strip() for k in args.kinds.split(',')]

    v1      = client.CoreV1Api()
    apps_v1 = client.AppsV1Api()
    try:
        dyn_client = dynamic.DynamicClient(client.ApiClient())
    except Exception:
        dyn_client = None

    console.print("[bold cyan]Ładowanie danych z klastra…[/bold cyan]")

    with console.status("[dim]Pobieranie nodów…[/dim]"):
        nodes = load_nodes(v1)

    with console.status("[dim]Liczenie requests na nodach…[/dim]"):
        load_node_requests(v1, nodes)

    # Oznacz drained nody
    drained_set = set(args.drain)
    for node in nodes:
        if node.name in drained_set:
            node.drained = True

    if drained_set:
        console.print(f"[yellow]⚠  Symulacja drain: {', '.join(sorted(drained_set))}[/yellow]")

    with console.status("[dim]Pobieranie workloadów…[/dim]"):
        namespace  = None if args.all_namespaces else args.namespace
        workloads  = load_workloads(
            apps_v1, dyn_client, namespace,
            args.all_namespaces, kinds, args.name
        )

    if not workloads:
        console.print("[yellow]Nie znaleziono żadnych workloadów.[/yellow]")
        sys.exit(0)

    console.print(
        f"[green]Znaleziono {len(nodes)} nodów"
        f" ({len(drained_set)} drained)"
        f" i {len(workloads)} workloadów.[/green]\n"
    )

    analyses = []
    for w in workloads:
        a = analyze(w, nodes)
        analyses.append(a)
        display_workload(w, a, nodes)

    display_summary(workloads, analyses, nodes)


if __name__ == '__main__':
    main()