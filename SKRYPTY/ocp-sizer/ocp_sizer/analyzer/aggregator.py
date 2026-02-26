"""Agregacja danych per namespace."""

from ..models.resources import ResourceSpec, ResourceUsage
from ..models.workload import PodInfo
from ..models.constraints import QuotaInfo, PDBInfo
from ..models.sizing import NamespaceSummary


class NamespaceAggregator:
    """Agreguje surowe dane z collectorów do NamespaceSummary per namespace."""

    def __init__(
        self,
        pods: list[PodInfo],
        quotas: list[QuotaInfo],
        pdbs: list[PDBInfo],
        pod_metrics: dict[str, ResourceUsage],
    ):
        self.pods = pods
        self.quotas = {q.namespace: q for q in quotas}
        self.pdbs = pdbs
        self.pod_metrics = pod_metrics

    def aggregate(self, namespaces: list[str]) -> list[NamespaceSummary]:
        summaries = []
        for ns in namespaces:
            summaries.append(self._aggregate_namespace(ns))
        return summaries

    def _aggregate_namespace(self, namespace: str) -> NamespaceSummary:
        ns_pods = [
            p for p in self.pods
            if p.namespace == namespace and p.phase == "Running"
        ]

        total_requests = ResourceSpec.zero()
        total_limits = ResourceSpec.zero()
        active_nodes: set[str] = set()
        node_selectors: set[str] = set()

        for pod in ns_pods:
            total_requests += pod.requests
            total_limits += pod.limits
            if pod.node_name:
                active_nodes.add(pod.node_name)
            for k, v in pod.node_selector.items():
                node_selectors.add(f"{k}={v}")

        # Faktyczne zużycie z metrics (suma podów w namespace)
        actual_usage: ResourceUsage | None = None
        ns_metrics = [
            m for key, m in self.pod_metrics.items()
            if key.startswith(f"{namespace}/")
        ]
        if ns_metrics:
            actual_usage = ResourceUsage(
                cpu_millicores=sum(m.cpu_millicores for m in ns_metrics),
                memory_bytes=sum(m.memory_bytes for m in ns_metrics),
            )

        # PDB min nodes (max z wszystkich PDB w namespace)
        ns_pdbs = [p for p in self.pdbs if p.namespace == namespace]
        pdb_min = max((p.min_nodes_required for p in ns_pdbs), default=0)

        # Anti-affinity min nodes (obsługiwane przez ConstraintAnalyzer wcześniej)
        # Wartość pobierana z PDB po analyze — tu przekazujemy 0, uzupełniane w CLI
        return NamespaceSummary(
            namespace=namespace,
            total_requests=total_requests,
            total_limits=total_limits,
            actual_usage=ResourceSpec(
                cpu_millicores=actual_usage.cpu_millicores,
                memory_bytes=actual_usage.memory_bytes,
            )
            if actual_usage
            else None,
            pod_count=len([p for p in self.pods if p.namespace == namespace]),
            running_pod_count=len(ns_pods),
            active_nodes=sorted(active_nodes),
            quota=self.quotas.get(namespace),
            pdb_min_nodes=pdb_min,
            anti_affinity_min_nodes=0,  # uzupełniane po ConstraintAnalyzer
            node_selectors=sorted(node_selectors),
        )

    def compute_cluster_totals(
        self, summaries: list[NamespaceSummary]
    ) -> tuple[ResourceSpec, ResourceSpec]:
        """Zwraca (total_requests, total_limits) dla wszystkich namespace'ów."""
        req = ResourceSpec.zero()
        lim = ResourceSpec.zero()
        for s in summaries:
            req += s.total_requests
            lim += s.total_limits
        return req, lim
