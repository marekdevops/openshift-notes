"""Modele wyników analizy i rekomendacji sizingu."""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional
from .resources import ResourceSpec


@dataclass
class PeakMetrics:
    """Historyczne maksimum zużycia zasobów dla namespace'a (z Prometheusa)."""

    namespace: str
    peak_cpu_millicores: int   # max z okresu lookback
    peak_memory_bytes: int     # max z okresu lookback
    lookback: str              # np. "7d"
    source: str = "prometheus"


@dataclass
class NodeVariant:
    """Jeden wariant rozmiaru node'a (np. 16CPU / 64GiB)."""

    label: str
    cpu_cores: int
    memory_gib: int
    allocatable_cpu_millicores: int = 0
    allocatable_memory_bytes: int = 0


@dataclass
class SizingVariant:
    """Rekomendacja sizingu dla jednego NodeVariant."""

    node_variant: NodeVariant
    worker_count: int
    reasoning: list[str]
    driver: str
    utilization_cpu_pct: float
    utilization_mem_pct: float
    fits_quotas: bool
    warnings: list[str]
    is_recommended: bool = False


@dataclass
class NamespaceSummary:
    """Zagregowane dane per namespace."""

    namespace: str
    total_requests: ResourceSpec
    total_limits: ResourceSpec
    actual_usage: Optional[ResourceSpec]
    pod_count: int
    running_pod_count: int
    active_nodes: list[str]
    quota: Optional[object]
    pdb_min_nodes: int
    anti_affinity_min_nodes: int
    node_selectors: list[str]
    peak_metrics: Optional[PeakMetrics] = None


@dataclass
class WorkerSizingOption:
    """Opcja sizingu VM workerów dla konkretnej liczby node'ów.

    Używana w trybie 'vm' — oblicza optymalny rozmiar VM workera
    zamiast dobierać liczbę node'ów do stałych wariantów.
    """

    worker_count: int
    cpu_per_worker_cores: int
    mem_per_worker_gib: int
    utilization_cpu_pct: float
    utilization_mem_pct: float
    driver: str
    reasoning: list[str]
    is_recommended: bool = False


@dataclass
class ClusterSizing:
    """Kompletny wynik analizy — dane wejściowe do renderera."""

    namespaces: list[NamespaceSummary]
    cluster_totals_requests: ResourceSpec
    cluster_totals_limits: ResourceSpec
    daemonset_overhead_per_node: ResourceSpec
    generated_at: str
    source_cluster_context: str
    metrics_available: bool
    global_min_nodes_from_constraints: int
    # Wyniki sizingu — jedno z dwóch, zależnie od sizing_mode
    sizing_variants: list[SizingVariant] = field(default_factory=list)
    worker_sizing_options: list[WorkerSizingOption] = field(default_factory=list)
    sizing_mode: str = "vm"
    prometheus_available: bool = False
    lookback: str = "7d"
