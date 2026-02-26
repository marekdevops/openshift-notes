"""Kolekcja PodDisruptionBudget."""

from ..models.constraints import PDBInfo
from .base import BaseCollector


class PolicyCollector(BaseCollector):
    """Zbiera PodDisruptionBudget dla wszystkich namespace'ów."""

    def collect(self) -> list[PDBInfo]:
        pdbs: list[PDBInfo] = []
        for ns in self.namespaces:
            try:
                items = self.policy_v1.list_namespaced_pod_disruption_budget(namespace=ns).items
                for pdb in items:
                    pdbs.append(self._parse_pdb(pdb, ns))
            except Exception as e:
                print(f"[WARN] PDB {ns}: {e}")
        return pdbs

    def _parse_pdb(self, pdb, namespace: str) -> PDBInfo:
        spec = pdb.spec or {}
        status = pdb.status

        selector: dict[str, str] = {}
        if hasattr(spec, "selector") and spec.selector:
            selector = spec.selector.match_labels or {}

        min_avail = None
        max_unavail = None
        if hasattr(spec, "min_available") and spec.min_available is not None:
            min_avail = str(spec.min_available)
        if hasattr(spec, "max_unavailable") and spec.max_unavailable is not None:
            max_unavail = str(spec.max_unavailable)

        current_healthy = 0
        desired_healthy = 0
        if status:
            current_healthy = getattr(status, "current_healthy", 0) or 0
            desired_healthy = getattr(status, "desired_healthy", 0) or 0

        return PDBInfo(
            name=pdb.metadata.name,
            namespace=namespace,
            selector=selector,
            min_available_raw=min_avail,
            max_unavailable_raw=max_unavail,
            current_healthy=current_healthy,
            desired_healthy=desired_healthy,
        )
