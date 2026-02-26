"""Analiza PDB i anti-affinity — oblicza minimalną liczbę node'ów."""

import math
from ..models.constraints import PDBInfo, AffinityConstraint
from ..models.workload import WorkloadInfo


class ConstraintAnalyzer:
    """Przetwarza PDB i affinity/anti-affinity — zwraca min_nodes_required."""

    HOSTNAME_KEYS = {"kubernetes.io/hostname", "kubernetes.io/hostname"}

    def analyze_pdbs(
        self, pdbs: list[PDBInfo], workloads: list[WorkloadInfo]
    ) -> list[PDBInfo]:
        """Oblicza min_nodes_required dla każdego PDB.

        Logika:
          minAvailable=M  → pdb_min_nodes = M + 1
          maxUnavailable=U → effective_min = replicas - U
                             pdb_min_nodes = effective_min + 1
        """
        # Zbuduj mapę workload name → replicas per namespace
        workload_map: dict[tuple[str, str], int] = {
            (w.namespace, w.name): w.replicas for w in workloads
        }

        for pdb in pdbs:
            # Szacuj replicas przez selector — uproszczone podejście
            # Bierzemy max replicas z workloadów w tym samym namespace
            ns_workloads = [
                w for w in workloads if w.namespace == pdb.namespace
            ]
            matched_replicas = max(
                (w.replicas for w in ns_workloads), default=1
            )
            pdb.matched_replicas = matched_replicas

            min_avail = self._resolve_value(
                pdb.min_available_raw, matched_replicas
            )
            max_unavail = self._resolve_value(
                pdb.max_unavailable_raw, matched_replicas
            )

            pdb.min_available_resolved = min_avail
            pdb.max_unavailable_resolved = max_unavail

            if min_avail > 0:
                # Żeby drain był możliwy, potrzeba min_avail + 1 node'ów
                pdb.min_nodes_required = min_avail + 1
            elif max_unavail > 0:
                effective_min = matched_replicas - max_unavail
                pdb.min_nodes_required = max(effective_min + 1, 2)
            else:
                pdb.min_nodes_required = 2

        return pdbs

    def analyze_anti_affinity(
        self, workloads: list[WorkloadInfo]
    ) -> list[AffinityConstraint]:
        """Wyciąga ograniczenia anti-affinity i topology spread.

        required anti-affinity + hostname → min_nodes = replicas
        preferred anti-affinity + hostname → min_nodes = ceil(replicas * 0.5)
        topologySpreadConstraints DoNotSchedule → min_nodes = replicas
        """
        constraints: list[AffinityConstraint] = []

        for w in workloads:
            if w.kind == "DaemonSet":
                continue  # DaemonSet zawsze na każdym node

            if w.has_required_anti_affinity:
                constraints.append(
                    AffinityConstraint(
                        workload_name=w.name,
                        namespace=w.namespace,
                        kind="anti-affinity",
                        topology_key="kubernetes.io/hostname",
                        replicas=w.replicas,
                        is_required=True,
                        min_distinct_nodes=w.replicas,
                    )
                )
            elif w.has_preferred_anti_affinity:
                constraints.append(
                    AffinityConstraint(
                        workload_name=w.name,
                        namespace=w.namespace,
                        kind="anti-affinity",
                        topology_key="kubernetes.io/hostname",
                        replicas=w.replicas,
                        is_required=False,
                        min_distinct_nodes=math.ceil(w.replicas * 0.5),
                    )
                )

            for key, when in zip(
                w.topology_spread_keys, w.topology_spread_when_unsatisfiable
            ):
                if key == "kubernetes.io/hostname" and when == "DoNotSchedule":
                    constraints.append(
                        AffinityConstraint(
                            workload_name=w.name,
                            namespace=w.namespace,
                            kind="topology-spread",
                            topology_key=key,
                            replicas=w.replicas,
                            is_required=True,
                            min_distinct_nodes=w.replicas,
                        )
                    )

        return constraints

    def get_namespace_min_nodes(
        self,
        namespace: str,
        pdbs: list[PDBInfo],
        constraints: list[AffinityConstraint],
    ) -> int:
        """Zwraca max(pdb_min, anti_affinity_min) dla danego namespace'a."""
        pdb_min = max(
            (p.min_nodes_required for p in pdbs if p.namespace == namespace),
            default=0,
        )
        aa_min = max(
            (c.min_distinct_nodes for c in constraints if c.namespace == namespace),
            default=0,
        )
        return max(pdb_min, aa_min)

    def _resolve_value(self, raw: str | None, total: int) -> int:
        """Przelicza minAvailable/maxUnavailable na liczbę całkowitą.

        Obsługuje liczby całkowite i procenty (np. "50%").
        """
        if raw is None:
            return 0
        raw = str(raw).strip()
        if raw.endswith("%"):
            pct = float(raw[:-1]) / 100.0
            return math.ceil(total * pct)
        try:
            return int(raw)
        except ValueError:
            return 0
