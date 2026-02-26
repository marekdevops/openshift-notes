"""Punkt wejścia CLI — orchestracja całego pipeline'u analizy."""

import argparse
import sys
from datetime import datetime
from pathlib import Path

from kubernetes import client as k8s_client

from .utils.k8s_client import build_k8s_clients
from .collector.pods import PodCollector
from .collector.prometheus import PrometheusCollector
from .collector.workloads import WorkloadCollector
from .collector.quotas import QuotaCollector
from .collector.policies import PolicyCollector
from .collector.nodes import NodeCollector
from .collector.metrics import MetricsCollector
from .analyzer.aggregator import NamespaceAggregator
from .analyzer.constraint_analyzer import ConstraintAnalyzer
from .analyzer.sizer import ClusterSizer
from .models.sizing import ClusterSizing
from .models.resources import ResourceSpec
from .output.terminal import TerminalRenderer
from .output.html import HtmlRenderer


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ocp-sizer",
        description=(
            "Analizuje zasoby OpenShift per namespace i rekomenduje sizing nowego klastra.\n"
            "Używa aktywnego kubeconfig (oc login)."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Przykłady:\n"
            "  ocp-sizer my-namespace\n"
            "  ocp-sizer ns1 ns2 ns3 --html raport.html\n"
            "  ocp-sizer my-namespace --target-utilization 0.80\n"
            "  ocp-sizer my-namespace --node-variants '8:32,16:64,32:128'"
        ),
    )
    parser.add_argument(
        "namespaces",
        nargs="+",
        metavar="NAMESPACE",
        help="Jeden lub więcej namespace'ów do analizy",
    )
    parser.add_argument(
        "--html",
        metavar="FILE",
        type=Path,
        help="Zapisz raport HTML do pliku (np. raport.html)",
    )
    parser.add_argument(
        "--target-utilization",
        type=float,
        default=0.75,
        metavar="FLOAT",
        help="Docelowe wykorzystanie node'a 0.0-1.0 (domyślnie: 0.75)",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Wyłącz kolorowanie terminala",
    )
    parser.add_argument(
        "--node-variants",
        metavar="CSV",
        default=None,
        help="Własne warianty node'ów: 'CPU:GiB,CPU:GiB,...' (np. '8:32,16:64')",
    )
    parser.add_argument(
        "--lookback",
        default="7d",
        metavar="DURATION",
        help="Okres historyczny dla peak metrics z Prometheusa (np. 1d, 7d, 30d). Domyślnie: 7d",
    )
    return parser


def parse_node_variants(raw: str):
    """Parsuje string '8:32,16:64' do listy NodeVariant."""
    from .models.sizing import NodeVariant
    variants = []
    for part in raw.split(","):
        part = part.strip()
        if ":" not in part:
            print(f"[ERROR] Nieprawidłowy format wariantu: '{part}' (oczekiwano CPU:GiB)", file=sys.stderr)
            sys.exit(1)
        cpu_s, mem_s = part.split(":", 1)
        cpu = int(cpu_s.strip())
        mem = int(mem_s.strip())
        variants.append(NodeVariant(label=f"{cpu}cpu-{mem}gb", cpu_cores=cpu, memory_gib=mem))
    return variants


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not 0.1 <= args.target_utilization <= 1.0:
        print("[ERROR] --target-utilization musi być w zakresie 0.1-1.0", file=sys.stderr)
        sys.exit(1)

    # 1. Połączenie z klastrem
    core_v1, apps_v1, policy_v1, custom_api, context_name = build_k8s_clients()
    # ApiClient tworzy się po load_kube_config() wywołanym przez build_k8s_clients()
    api_client = k8s_client.ApiClient()
    namespaces = args.namespaces

    print(f"Łączę z klastrem: {context_name}")
    print(f"Analizuję namespace'y: {', '.join(namespaces)}")

    # 2. Kolekcja danych
    print("Pobieranie danych z API...")
    pod_collector = PodCollector(core_v1, apps_v1, policy_v1, namespaces)
    workload_collector = WorkloadCollector(core_v1, apps_v1, policy_v1, namespaces)
    quota_collector = QuotaCollector(core_v1, apps_v1, policy_v1, namespaces)
    policy_collector = PolicyCollector(core_v1, apps_v1, policy_v1, namespaces)
    node_collector = NodeCollector(core_v1, apps_v1, policy_v1, namespaces)

    pods = pod_collector.collect()
    workloads = workload_collector.collect()
    quotas, limitranges = quota_collector.collect()
    pdbs = policy_collector.collect()
    nodes = node_collector.collect()

    # Metrics (opcjonalne)
    metrics_collector = MetricsCollector(custom_api, namespaces)
    metrics_available = metrics_collector.is_available()
    pod_metrics = metrics_collector.collect_pod_metrics() if metrics_available else {}

    print(
        f"Pobrano: {len(pods)} podów, {len(workloads)} workloadów, "
        f"{len(pdbs)} PDB, {len(nodes)} node'ów"
        + (", metryki dostępne" if metrics_available else ", metryki niedostępne")
    )

    # Peak metrics z Prometheusa (opcjonalne)
    print(f"Sprawdzanie dostępności Prometheusa (lookback: {args.lookback})...")
    prom_collector = PrometheusCollector(api_client, namespaces, args.lookback)
    prometheus_available = prom_collector.is_available()
    peak_metrics = prom_collector.collect_peak_metrics() if prometheus_available else {}
    print(
        "Prometheus: "
        + (f"dostępny — pobrano peak metrics ({args.lookback})" if prometheus_available else "niedostępny — używam requests")
    )

    # 3. Analiza constraints
    constraint_analyzer = ConstraintAnalyzer()
    pdbs = constraint_analyzer.analyze_pdbs(pdbs, workloads)
    affinity_constraints = constraint_analyzer.analyze_anti_affinity(workloads)

    # 4. Agregacja per namespace
    aggregator = NamespaceAggregator(pods, quotas, pdbs, pod_metrics)
    ns_summaries = aggregator.aggregate(namespaces)

    # Uzupełnij anti_affinity_min_nodes i peak_metrics per namespace
    for summary in ns_summaries:
        summary.anti_affinity_min_nodes = constraint_analyzer.get_namespace_min_nodes(
            summary.namespace, pdbs, affinity_constraints
        )
        summary.peak_metrics = peak_metrics.get(summary.namespace)

    cluster_req, cluster_lim = aggregator.compute_cluster_totals(ns_summaries)

    # 5. DaemonSet overhead per node
    daemonsets = [w for w in workloads if w.kind == "DaemonSet"]
    ds_overhead = ClusterSizer.compute_daemonset_overhead(daemonsets)

    # Global min nodes (max z wszystkich namespace'ów)
    global_min_nodes = max(
        (
            constraint_analyzer.get_namespace_min_nodes(ns, pdbs, affinity_constraints)
            for ns in namespaces
        ),
        default=0,
    )

    # 6. Sizing
    node_variants = parse_node_variants(args.node_variants) if args.node_variants else None
    sizer = ClusterSizer(
        cluster_totals=cluster_req,
        daemonset_overhead_per_node=ds_overhead,
        global_min_nodes_from_constraints=global_min_nodes,
        node_variants=node_variants,
        target_utilization=args.target_utilization,
        peak_metrics=peak_metrics,
    )
    sizing_variants = sizer.compute_all_variants()

    # 7. Wynik
    sizing = ClusterSizing(
        namespaces=ns_summaries,
        cluster_totals_requests=cluster_req,
        cluster_totals_limits=cluster_lim,
        daemonset_overhead_per_node=ds_overhead,
        sizing_variants=sizing_variants,
        generated_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        source_cluster_context=context_name,
        metrics_available=metrics_available,
        global_min_nodes_from_constraints=global_min_nodes,
        prometheus_available=prometheus_available,
        lookback=args.lookback,
    )

    # 8. Output
    renderer = TerminalRenderer(no_color=args.no_color)
    renderer.render(sizing)

    if args.html:
        html_renderer = HtmlRenderer()
        html_renderer.render(sizing, args.html)
