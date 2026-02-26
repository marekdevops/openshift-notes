"""Kolekcja ResourceQuota i LimitRange."""

from ..models.constraints import QuotaInfo, LimitRangeInfo
from ..utils.units import parse_cpu, parse_memory
from .base import BaseCollector


class QuotaCollector(BaseCollector):
    """Zbiera ResourceQuota i LimitRange dla wszystkich namespace'ów."""

    def collect(self) -> tuple[list[QuotaInfo], list[LimitRangeInfo]]:
        quotas: list[QuotaInfo] = []
        limitranges: list[LimitRangeInfo] = []

        for ns in self.namespaces:
            try:
                for rq in self.core_v1.list_namespaced_resource_quota(namespace=ns).items:
                    quotas.append(self._parse_quota(rq, ns))
            except Exception as e:
                print(f"[WARN] ResourceQuota {ns}: {e}")

            try:
                for lr in self.core_v1.list_namespaced_limit_range(namespace=ns).items:
                    limitranges.append(self._parse_limitrange(lr, ns))
            except Exception as e:
                print(f"[WARN] LimitRange {ns}: {e}")

        return quotas, limitranges

    def _parse_quota(self, rq, namespace: str) -> QuotaInfo:
        hard = rq.status.hard or {} if rq.status else {}
        used = rq.status.used or {} if rq.status else {}
        return QuotaInfo(
            name=rq.metadata.name,
            namespace=namespace,
            hard_cpu_requests=parse_cpu(hard.get("requests.cpu")) or None,
            hard_cpu_limits=parse_cpu(hard.get("limits.cpu")) or None,
            hard_memory_requests=parse_memory(hard.get("requests.memory")) or None,
            hard_memory_limits=parse_memory(hard.get("limits.memory")) or None,
            used_cpu_requests=parse_cpu(used.get("requests.cpu")) or None,
            used_cpu_limits=parse_cpu(used.get("limits.cpu")) or None,
            used_memory_requests=parse_memory(used.get("requests.memory")) or None,
            used_memory_limits=parse_memory(used.get("limits.memory")) or None,
        )

    def _parse_limitrange(self, lr, namespace: str) -> LimitRangeInfo:
        info = LimitRangeInfo(name=lr.metadata.name, namespace=namespace)
        for item in lr.spec.limits or []:
            default = item.default or {}
            default_req = item.default_request or {}
            max_vals = item.max or {}
            info.default_cpu_limit = parse_cpu(default.get("cpu")) or info.default_cpu_limit
            info.default_memory_limit = (
                parse_memory(default.get("memory")) or info.default_memory_limit
            )
            info.default_cpu_request = (
                parse_cpu(default_req.get("cpu")) or info.default_cpu_request
            )
            info.default_memory_request = (
                parse_memory(default_req.get("memory")) or info.default_memory_request
            )
            info.max_cpu = parse_cpu(max_vals.get("cpu")) or info.max_cpu
            info.max_memory = parse_memory(max_vals.get("memory")) or info.max_memory
        return info
