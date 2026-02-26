"""Główny algorytm sizingu klastra — N+1 z uwzględnieniem constraints."""

import math
from ..models.resources import ResourceSpec
from ..models.workload import WorkloadInfo
from ..models.sizing import NodeVariant, SizingVariant

# Red Hat best practices — stałe
SYSTEM_RESERVED_CPU_MC = 1000          # 1 CPU per node (OCP system overhead)
SYSTEM_RESERVED_MEM_BYTES = 4 * 1024**3  # 4 GiB per node
TARGET_UTILIZATION = 0.75              # 75% — środek przedziału 70-80%
MIN_NODES = 3                          # minimum sensownego klastra

DEFAULT_NODE_VARIANTS = [
    NodeVariant(label="small",  cpu_cores=8,  memory_gib=32),
    NodeVariant(label="medium", cpu_cores=16, memory_gib=64),
    NodeVariant(label="large",  cpu_cores=32, memory_gib=128),
    NodeVariant(label="xlarge", cpu_cores=48, memory_gib=192),
]


class ClusterSizer:
    """Oblicza rekomendowaną liczbę i rozmiar node'ów workera."""

    def __init__(
        self,
        cluster_totals: ResourceSpec,
        daemonset_overhead_per_node: ResourceSpec,
        global_min_nodes_from_constraints: int,
        node_variants: list[NodeVariant] | None = None,
        target_utilization: float = TARGET_UTILIZATION,
    ):
        self.cluster_totals = cluster_totals
        self.daemonset_overhead = daemonset_overhead_per_node
        self.global_min_nodes = global_min_nodes_from_constraints
        self.node_variants = node_variants or DEFAULT_NODE_VARIANTS
        self.target_utilization = target_utilization

    @staticmethod
    def compute_daemonset_overhead(daemonsets: list[WorkloadInfo]) -> ResourceSpec:
        """Suma requests wszystkich DaemonSetów = overhead per node."""
        overhead = ResourceSpec.zero()
        for ds in daemonsets:
            if ds.kind == "DaemonSet":
                overhead += ds.pod_template_requests
        return overhead

    def compute_allocatable(self, variant: NodeVariant) -> tuple[int, int]:
        """Oblicza efektywne allocatable CPU i RAM po odjęciu overhead.

        Returns:
            (alloc_cpu_millicores, alloc_memory_bytes)
            Jeśli wynik <= 0 — wariant nieużywalny, zwraca (0, 0).
        """
        raw_cpu = variant.cpu_cores * 1000
        raw_mem = variant.memory_gib * (1024**3)

        alloc_cpu = raw_cpu - SYSTEM_RESERVED_CPU_MC - self.daemonset_overhead.cpu_millicores
        alloc_mem = raw_mem - SYSTEM_RESERVED_MEM_BYTES - self.daemonset_overhead.memory_bytes

        if alloc_cpu <= 0 or alloc_mem <= 0:
            return 0, 0

        return alloc_cpu, alloc_mem

    def size_for_variant(self, variant: NodeVariant) -> SizingVariant:
        """Oblicza N+1 sizing dla jednego wariantu node'a."""
        reasoning: list[str] = []
        warnings: list[str] = []

        alloc_cpu, alloc_mem = self.compute_allocatable(variant)
        variant.allocatable_cpu_millicores = alloc_cpu
        variant.allocatable_memory_bytes = alloc_mem

        if alloc_cpu == 0 or alloc_mem == 0:
            return SizingVariant(
                node_variant=variant,
                worker_count=0,
                reasoning=["Wariant zbyt mały — DaemonSet overhead przekracza pojemność node'a"],
                driver="unusable",
                utilization_cpu_pct=0.0,
                utilization_mem_pct=0.0,
                fits_quotas=True,
                warnings=["Wariant nieużywalny"],
            )

        reasoning.append(
            f"Allocatable po odjęciu system ({SYSTEM_RESERVED_CPU_MC}m CPU, "
            f"{SYSTEM_RESERVED_MEM_BYTES // (1024**3)}GiB RAM) "
            f"i DaemonSet overhead: "
            f"{alloc_cpu}m CPU, {alloc_mem // (1024**3):.1f}GiB RAM"
        )

        # Ile node'ów potrzeba na zasoby (bez N+1)
        needed_for_cpu = math.ceil(
            self.cluster_totals.cpu_millicores / self.target_utilization / alloc_cpu
        )
        needed_for_mem = math.ceil(
            self.cluster_totals.memory_bytes / self.target_utilization / alloc_mem
        )
        needed_resources = max(needed_for_cpu, needed_for_mem)

        reasoning.append(
            f"Wymagane node'y dla zasobów (przy {self.target_utilization*100:.0f}% target): "
            f"CPU→{needed_for_cpu}, RAM→{needed_for_mem}, max={needed_resources}"
        )

        # N+1: jeden node zawsze wolny do drainowania
        n = needed_resources + 1
        driver = "resources"
        reasoning.append(f"N+1 dla drain/upgrade: {needed_resources} + 1 = {n}")

        # Ograniczenia PDB / anti-affinity
        if self.global_min_nodes > n:
            reasoning.append(
                f"Podniesiono do {self.global_min_nodes} "
                f"(PDB / anti-affinity constraint)"
            )
            n = self.global_min_nodes
            driver = "pdb/anti-affinity"

        # Minimum klastra
        if n < MIN_NODES:
            reasoning.append(f"Podniesiono do minimum klastra: {MIN_NODES}")
            n = MIN_NODES
            if driver == "resources":
                driver = "minimum"

        # Faktyczny utilization przy N node'ach (N-1 aktywnych podczas drain)
        active = n - 1
        util_cpu = self.cluster_totals.cpu_millicores / (active * alloc_cpu)
        util_mem = self.cluster_totals.memory_bytes / (active * alloc_mem)

        reasoning.append(
            f"Utilization przy {n} node'ach ({active} aktywnych): "
            f"CPU={util_cpu*100:.1f}%, RAM={util_mem*100:.1f}%"
        )

        # Ostrzeżenia
        if util_cpu < 0.4 and util_mem < 0.4:
            warnings.append(
                "Niskie wykorzystanie (<40%) — rozważ mniejszy wariant lub mniej node'ów"
            )
        if util_cpu > 0.95 or util_mem > 0.95:
            warnings.append(
                "Wysokie wykorzystanie (>95%) — rozważ większy wariant lub więcej node'ów"
            )

        return SizingVariant(
            node_variant=variant,
            worker_count=n,
            reasoning=reasoning,
            driver=driver,
            utilization_cpu_pct=util_cpu,
            utilization_mem_pct=util_mem,
            fits_quotas=True,
            warnings=warnings,
        )

    def compute_all_variants(self) -> list[SizingVariant]:
        """Oblicza sizing dla wszystkich wariantów i wybiera rekomendowany."""
        variants = [self.size_for_variant(v) for v in self.node_variants]

        # Rekomenduj wariant najbliższy target utilization (75%)
        usable = [v for v in variants if v.driver != "unusable"]
        if usable:
            best = min(
                usable,
                key=lambda v: abs(
                    max(v.utilization_cpu_pct, v.utilization_mem_pct) - self.target_utilization
                ),
            )
            best.is_recommended = True

        return variants
