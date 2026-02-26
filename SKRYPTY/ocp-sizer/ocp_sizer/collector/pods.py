"""Kolekcja podów z K8s API — requests, limits, owner, affinity."""

from __future__ import annotations

from kubernetes import client
from ..models.resources import ResourceSpec
from ..models.workload import PodInfo
from ..utils.units import parse_cpu, parse_memory
from .base import BaseCollector


class PodCollector(BaseCollector):
    """Zbiera PodInfo dla wszystkich namespace'ów."""

    def collect(self) -> list[PodInfo]:
        pods: list[PodInfo] = []
        for ns in self.namespaces:
            try:
                pod_list = self.core_v1.list_namespaced_pod(namespace=ns)
                for pod in pod_list.items:
                    pods.append(self._parse_pod(pod))
            except Exception as e:
                print(f"[WARN] Nie można pobrać podów z {ns}: {e}")
        return pods

    def _parse_pod(self, pod: client.V1Pod) -> PodInfo:
        spec = pod.spec or client.V1PodSpec(containers=[])
        requests, limits = self._sum_container_resources(spec.containers or [])
        owner_kind, owner_name = self._resolve_owner(pod)

        affinity = spec.affinity or client.V1Affinity()
        pod_affinity = affinity.pod_affinity or client.V1PodAffinity()
        pod_anti_affinity = affinity.pod_anti_affinity or client.V1PodAntiAffinity()

        has_req_affinity = bool(
            getattr(pod_affinity, "required_during_scheduling_ignored_during_execution", None)
        )
        has_pref_affinity = bool(
            getattr(pod_affinity, "preferred_during_scheduling_ignored_during_execution", None)
        )
        has_req_anti = bool(
            getattr(pod_anti_affinity, "required_during_scheduling_ignored_during_execution", None)
        )
        has_pref_anti = bool(
            getattr(pod_anti_affinity, "preferred_during_scheduling_ignored_during_execution", None)
        )
        has_spread = bool(getattr(spec, "topology_spread_constraints", None))

        return PodInfo(
            name=pod.metadata.name,
            namespace=pod.metadata.namespace,
            node_name=pod.spec.node_name if pod.spec else None,
            phase=pod.status.phase if pod.status else "Unknown",
            requests=requests,
            limits=limits,
            owner_kind=owner_kind,
            owner_name=owner_name,
            node_selector=spec.node_selector or {},
            has_required_affinity=has_req_affinity,
            has_preferred_affinity=has_pref_affinity,
            has_required_anti_affinity=has_req_anti,
            has_preferred_anti_affinity=has_pref_anti,
            has_topology_spread=has_spread,
            is_daemonset=(owner_kind == "DaemonSet"),
        )

    def _sum_container_resources(
        self, containers: list[client.V1Container]
    ) -> tuple[ResourceSpec, ResourceSpec]:
        req = ResourceSpec.zero()
        lim = ResourceSpec.zero()
        for c in containers:
            res = c.resources or client.V1ResourceRequirements()
            r = res.requests or {}
            l = res.limits or {}
            req += ResourceSpec(
                cpu_millicores=parse_cpu(r.get("cpu")),
                memory_bytes=parse_memory(r.get("memory")),
            )
            lim += ResourceSpec(
                cpu_millicores=parse_cpu(l.get("cpu")),
                memory_bytes=parse_memory(l.get("memory")),
            )
        return req, lim

    def _resolve_owner(self, pod: client.V1Pod) -> tuple[str | None, str | None]:
        """Rozwiązuje ownerReference poda — śledzi ReplicaSet → Deployment."""
        refs = pod.metadata.owner_references or []
        if not refs:
            return None, None

        ref = refs[0]
        if ref.kind == "ReplicaSet":
            try:
                rs = self.apps_v1.read_namespaced_replica_set(
                    name=ref.name, namespace=pod.metadata.namespace
                )
                rs_refs = rs.metadata.owner_references or []
                if rs_refs:
                    return rs_refs[0].kind, rs_refs[0].name
            except Exception:
                pass
        return ref.kind, ref.name
