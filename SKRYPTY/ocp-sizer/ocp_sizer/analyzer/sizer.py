"""Główny algorytm sizingu klastra — N+1 z uwzględnieniem constraints."""

from __future__ import annotations

import math
from ..models.resources import ResourceSpec
from ..models.workload import WorkloadInfo
from ..models.sizing import NodeVariant, PeakMetrics, SizingVariant, WorkerSizingOption

# Red Hat best practices — stałe
SYSTEM_RESERVED_CPU_MC = 1000          # 1 CPU per node (OCP system overhead)
SYSTEM_RESERVED_MEM_BYTES = 4 * 1024**3  # 4 GiB per node
TARGET_UTILIZATION = 0.75              # 75% — środek przedziału 70-80%
MIN_NODES = 3                          # minimum sensownego klastra

DEFAULT_NODE_VARIANTS = [
    NodeVariant(label="small",      cpu_cores=8,  memory_gib=32),
    NodeVariant(label="medium",     cpu_cores=16, memory_gib=64),
    NodeVariant(label="large",      cpu_cores=32, memory_gib=128),
    NodeVariant(label="xlarge",     cpu_cores=48, memory_gib=192),
    # Warstwa pośrednia 8 GiB/core (popularne konfiguracje serwerów fizycznych)
    NodeVariant(label="mem-std-m",  cpu_cores=32, memory_gib=256),
    NodeVariant(label="mem-std-l",  cpu_cores=48, memory_gib=384),
    NodeVariant(label="mem-std-xl", cpu_cores=64, memory_gib=512),
    # Warstwa 16 GiB/core — memory-intensive workloady (bazy danych, JVM, ML)
    NodeVariant(label="mem-large",  cpu_cores=32, memory_gib=512),
    NodeVariant(label="mem-xlarge", cpu_cores=48, memory_gib=768),
    NodeVariant(label="mem-2xl",    cpu_cores=64, memory_gib=1024),
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
        peak_metrics: dict[str, PeakMetrics] | None = None,
    ):
        self.cluster_totals = cluster_totals
        self.daemonset_overhead = daemonset_overhead_per_node
        self.global_min_nodes = global_min_nodes_from_constraints
        self.node_variants = node_variants or DEFAULT_NODE_VARIANTS
        self.target_utilization = target_utilization
        self.peak_metrics = peak_metrics or {}
        # Efektywne totale (max requests vs peak) — ustawiane przez compute_all_variants()
        self._effective_totals: ResourceSpec = cluster_totals
        self._basis_label: str = "requests (brak Prometheus)"

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

        # Informacja o podstawie obliczeń (requests vs peak)
        reasoning.append(f"Podstawa obliczeń: {self._basis_label}")

        reasoning.append(
            f"Allocatable po odjęciu system ({SYSTEM_RESERVED_CPU_MC}m CPU, "
            f"{SYSTEM_RESERVED_MEM_BYTES // (1024**3)}GiB RAM) "
            f"i DaemonSet overhead: "
            f"{alloc_cpu}m CPU, {alloc_mem // (1024**3):.1f}GiB RAM"
        )

        # Ile node'ów potrzeba na zasoby (bez N+1)
        needed_for_cpu = math.ceil(
            self._effective_totals.cpu_millicores / self.target_utilization / alloc_cpu
        )
        needed_for_mem = math.ceil(
            self._effective_totals.memory_bytes / self.target_utilization / alloc_mem
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
        util_cpu = self._effective_totals.cpu_millicores / (active * alloc_cpu)
        util_mem = self._effective_totals.memory_bytes / (active * alloc_mem)

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

    def _compute_effective_totals(self) -> None:
        """Wyznacza efektywne totale — max(requests, peak). Ustawia _effective_totals i _basis_label."""
        if self.peak_metrics:
            total_peak_cpu = sum(p.peak_cpu_millicores for p in self.peak_metrics.values())
            total_peak_mem = sum(p.peak_memory_bytes for p in self.peak_metrics.values())
            eff_cpu = max(self.cluster_totals.cpu_millicores, total_peak_cpu)
            eff_mem = max(self.cluster_totals.memory_bytes, total_peak_mem)
            self._effective_totals = ResourceSpec(cpu_millicores=eff_cpu, memory_bytes=eff_mem)
            lookback = next(iter(self.peak_metrics.values())).lookback
            if eff_cpu > self.cluster_totals.cpu_millicores or eff_mem > self.cluster_totals.memory_bytes:
                self._basis_label = (
                    f"peak (Prometheus {lookback}) — "
                    f"CPU: {eff_cpu / 1000:.1f} cores, RAM: {eff_mem / (1024**3):.1f} GiB"
                )
            else:
                self._basis_label = (
                    f"requests (peak < requests) — "
                    f"CPU: {eff_cpu / 1000:.1f} cores, RAM: {eff_mem / (1024**3):.1f} GiB"
                )
        else:
            self._effective_totals = self.cluster_totals
            self._basis_label = (
                f"requests (brak Prometheus) — "
                f"CPU: {self.cluster_totals.cpu_millicores / 1000:.1f} cores, "
                f"RAM: {self.cluster_totals.memory_bytes / (1024**3):.1f} GiB"
            )

    def compute_all_variants(self) -> list[SizingVariant]:
        """Oblicza sizing dla wszystkich wariantów i wybiera rekomendowany."""
        self._compute_effective_totals()

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

    # ------------------------------------------------------------------
    # Tryb VM: optymalny rozmiar VM workera dla zakresu liczby node'ów
    # ------------------------------------------------------------------

    def compute_optimal_worker_sizes(self, max_count: int | None = None) -> list[WorkerSizingOption]:
        """Oblicza optymalny rozmiar VM workera dla zakresu liczby node'ów.

        Zamiast dopasowywać liczbę node'ów do stałych wariantów,
        dla każdej kandydującej liczby workerów oblicza dokładne
        parametry VM (cores, GiB RAM) zapewniające docelowe utilization.

        Args:
            max_count: maksymalna liczba workerów do zbadania.
                       Domyślnie min_count + 7.
        """
        self._compute_effective_totals()

        min_count = max(self.global_min_nodes, MIN_NODES)
        if max_count is None:
            max_count = min_count + 7

        options = [self._size_for_worker_count(n, min_count) for n in range(min_count, max_count + 1)]

        # Rekomenduj opcję, której max(util_cpu, util_mem) jest najbliższy target
        if options:
            best = min(
                options,
                key=lambda o: abs(
                    max(o.utilization_cpu_pct, o.utilization_mem_pct) - self.target_utilization
                ),
            )
            best.is_recommended = True

        return options

    def _size_for_worker_count(self, n: int, min_count: int) -> WorkerSizingOption:
        """Oblicza rozmiar VM workera dla dokładnie N node'ów."""
        reasoning: list[str] = []

        reasoning.append(f"Podstawa obliczeń: {self._basis_label}")

        active = n - 1  # N+1: jeden node zawsze wolny do drainowania
        reasoning.append(f"Przy {n} workerach — {active} aktywnych (N+1 dla drain/upgrade)")

        # Ile allocatable potrzeba per node przy docelowym utilization
        if active > 0 and self._effective_totals.cpu_millicores > 0:
            cpu_alloc_needed = self._effective_totals.cpu_millicores / (active * self.target_utilization)
            mem_alloc_needed = self._effective_totals.memory_bytes / (active * self.target_utilization)
        else:
            cpu_alloc_needed = 0.0
            mem_alloc_needed = 0.0

        # Dodaj system reserved i DaemonSet overhead → raw capacity per VM
        cpu_raw = cpu_alloc_needed + SYSTEM_RESERVED_CPU_MC + self.daemonset_overhead.cpu_millicores
        mem_raw = mem_alloc_needed + SYSTEM_RESERVED_MEM_BYTES + self.daemonset_overhead.memory_bytes

        # Zaokrąglij w górę do całkowitych rdzeni / GiB
        cpu_cores = max(math.ceil(cpu_raw / 1000), 4)    # minimum 4 cores (OCP worker)
        mem_gib = max(math.ceil(mem_raw / (1024 ** 3)), 16)  # minimum 16 GiB

        reasoning.append(
            f"Wymagane allocatable per node (target {self.target_utilization*100:.0f}%): "
            f"CPU {cpu_alloc_needed/1000:.1f} cores + overhead → raw {cpu_raw/1000:.1f} cores → {cpu_cores} cores"
        )
        reasoning.append(
            f"RAM {mem_alloc_needed/(1024**3):.1f} GiB + overhead → raw {mem_raw/(1024**3):.1f} GiB → {mem_gib} GiB"
        )

        # Faktyczne allocatable po zaokrągleniu
        alloc_cpu = cpu_cores * 1000 - SYSTEM_RESERVED_CPU_MC - self.daemonset_overhead.cpu_millicores
        alloc_mem = mem_gib * (1024 ** 3) - SYSTEM_RESERVED_MEM_BYTES - self.daemonset_overhead.memory_bytes

        # Faktyczny utilization
        if alloc_cpu > 0 and alloc_mem > 0 and active > 0:
            util_cpu = self._effective_totals.cpu_millicores / (active * alloc_cpu)
            util_mem = self._effective_totals.memory_bytes / (active * alloc_mem)
        else:
            util_cpu = 0.0
            util_mem = 0.0

        reasoning.append(
            f"Faktyczny utilization: CPU={util_cpu*100:.1f}%, RAM={util_mem*100:.1f}%"
        )

        # Driver: powód dlaczego nie można zejść poniżej min_count
        if n == min_count:
            driver = "pdb/anti-affinity" if self.global_min_nodes > MIN_NODES else "minimum"
        else:
            driver = "resources"

        return WorkerSizingOption(
            worker_count=n,
            cpu_per_worker_cores=cpu_cores,
            mem_per_worker_gib=mem_gib,
            utilization_cpu_pct=util_cpu,
            utilization_mem_pct=util_mem,
            driver=driver,
            reasoning=reasoning,
        )
