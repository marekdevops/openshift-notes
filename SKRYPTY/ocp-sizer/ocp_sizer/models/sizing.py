"""Modele wyników analizy i rekomendacji sizingu."""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional
from .resources import ResourceSpec


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


@dataclass
class ClusterSizing:
    """Kompletny wynik analizy — dane wejściowe do renderera."""

    namespaces: list[NamespaceSummary]
    cluster_totals_requests: ResourceSpec
    cluster_totals_limits: ResourceSpec
    daemonset_overhead_per_node: ResourceSpec
    sizing_variants: list[SizingVariant]
    generated_at: str
    source_cluster_context: str
    metrics_available: bool
    global_min_nodes_from_constraints: int
