"""Kolekcja Deployment, StatefulSet, DaemonSet."""

from kubernetes import client
from ..models.resources import ResourceSpec
from ..models.workload import WorkloadInfo
from ..utils.units import parse_cpu, parse_memory
from .base import BaseCollector


class WorkloadCollector(BaseCollector):
    """Zbiera WorkloadInfo dla wszystkich namespace'ów."""

    def collect(self) -> list[WorkloadInfo]:
        workloads: list[WorkloadInfo] = []
        for ns in self.namespaces:
            workloads.extend(self._collect_deployments(ns))
            workloads.extend(self._collect_statefulsets(ns))
            workloads.extend(self._collect_daemonsets(ns))
        return workloads

    def _collect_deployments(self, namespace: str) -> list[WorkloadInfo]:
        result = []
        try:
            items = self.apps_v1.list_namespaced_deployment(namespace=namespace).items
            for dep in items:
                result.append(self._parse_workload("Deployment", dep, namespace))
        except Exception as e:
            print(f"[WARN] Deployment {namespace}: {e}")
        return result

    def _collect_statefulsets(self, namespace: str) -> list[WorkloadInfo]:
        result = []
        try:
            items = self.apps_v1.list_namespaced_stateful_set(namespace=namespace).items
            for ss in items:
                result.append(self._parse_workload("StatefulSet", ss, namespace))
        except Exception as e:
            print(f"[WARN] StatefulSet {namespace}: {e}")
        return result

    def _collect_daemonsets(self, namespace: str) -> list[WorkloadInfo]:
        result = []
        try:
            items = self.apps_v1.list_namespaced_daemon_set(namespace=namespace).items
            for ds in items:
                # DaemonSet nie ma spec.replicas — używamy desiredNumberScheduled
                replicas = (ds.status.desired_number_scheduled or 0) if ds.status else 0
                ready = (ds.status.number_ready or 0) if ds.status else 0
                req, lim = self._sum_template_resources(ds.spec.template if ds.spec else None)
                anti_req, anti_pref, spread_keys, spread_when = self._parse_affinity(
                    ds.spec.template.spec if ds.spec and ds.spec.template else None
                )
                result.append(
                    WorkloadInfo(
                        kind="DaemonSet",
                        name=ds.metadata.name,
                        namespace=namespace,
                        replicas=replicas,
                        ready_replicas=ready,
                        pod_template_requests=req,
                        pod_template_limits=lim,
                        node_selector=(
                            ds.spec.template.spec.node_selector
                            if ds.spec and ds.spec.template and ds.spec.template.spec
                            else {}
                        )
                        or {},
                        has_required_anti_affinity=anti_req,
                        has_preferred_anti_affinity=anti_pref,
                        topology_spread_keys=spread_keys,
                        topology_spread_when_unsatisfiable=spread_when,
                    )
                )
        except Exception as e:
            print(f"[WARN] DaemonSet {namespace}: {e}")
        return result

    def _parse_workload(self, kind: str, obj, namespace: str) -> WorkloadInfo:
        spec = obj.spec
        replicas = getattr(spec, "replicas", 1) or 1
        ready = 0
        if obj.status:
            ready = getattr(obj.status, "ready_replicas", 0) or 0

        template = spec.template if spec else None
        req, lim = self._sum_template_resources(template)
        pod_spec = template.spec if template else None
        anti_req, anti_pref, spread_keys, spread_when = self._parse_affinity(pod_spec)

        return WorkloadInfo(
            kind=kind,
            name=obj.metadata.name,
            namespace=namespace,
            replicas=replicas,
            ready_replicas=ready,
            pod_template_requests=req,
            pod_template_limits=lim,
            node_selector=(pod_spec.node_selector if pod_spec else {}) or {},
            has_required_anti_affinity=anti_req,
            has_preferred_anti_affinity=anti_pref,
            topology_spread_keys=spread_keys,
            topology_spread_when_unsatisfiable=spread_when,
        )

    def _sum_template_resources(self, template) -> tuple[ResourceSpec, ResourceSpec]:
        req = ResourceSpec.zero()
        lim = ResourceSpec.zero()
        if not template or not template.spec:
            return req, lim
        for c in template.spec.containers or []:
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

    def _parse_affinity(
        self, pod_spec
    ) -> tuple[bool, bool, list[str], list[str]]:
        """Zwraca (has_req_anti, has_pref_anti, spread_keys, spread_when)."""
        if not pod_spec:
            return False, False, [], []

        affinity = pod_spec.affinity or client.V1Affinity()
        anti = affinity.pod_anti_affinity or client.V1PodAntiAffinity()
        has_req = bool(
            getattr(anti, "required_during_scheduling_ignored_during_execution", None)
        )
        has_pref = bool(
            getattr(anti, "preferred_during_scheduling_ignored_during_execution", None)
        )

        spread_keys = []
        spread_when = []
        for tsc in getattr(pod_spec, "topology_spread_constraints", None) or []:
            spread_keys.append(getattr(tsc, "topology_key", ""))
            spread_when.append(getattr(tsc, "when_unsatisfiable", ""))

        return has_req, has_pref, spread_keys, spread_when
