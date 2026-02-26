"""Kolekcja danych o node'ach klastra."""

from ..models.resources import ResourceSpec, NodeProfile
from ..utils.units import parse_cpu, parse_memory
from .base import BaseCollector


class NodeCollector(BaseCollector):
    """Zbiera profile wszystkich schedulable node'ów."""

    def collect(self) -> list[NodeProfile]:
        nodes: list[NodeProfile] = []
        try:
            node_list = self.core_v1.list_node()
            for node in node_list.items:
                nodes.append(self._parse_node(node))
        except Exception as e:
            print(f"[WARN] Nodes: {e}")
        return nodes

    def _parse_node(self, node) -> NodeProfile:
        capacity = node.status.capacity or {} if node.status else {}
        allocatable = node.status.allocatable or {} if node.status else {}
        labels = node.metadata.labels or {}

        roles = [
            key.replace("node-role.kubernetes.io/", "")
            for key in labels
            if key.startswith("node-role.kubernetes.io/")
        ]

        # Sprawdź tainty NoSchedule — node jest efektywnie unschedulable
        taints = node.spec.taints or [] if node.spec else []
        has_noschedule = any(
            getattr(t, "effect", "") == "NoSchedule" for t in taints
        )
        is_schedulable = (
            not node.spec.unschedulable
            if node.spec
            else True
        ) and not has_noschedule

        return NodeProfile(
            name=node.metadata.name,
            capacity=ResourceSpec(
                cpu_millicores=parse_cpu(capacity.get("cpu")),
                memory_bytes=parse_memory(capacity.get("memory")),
            ),
            allocatable=ResourceSpec(
                cpu_millicores=parse_cpu(allocatable.get("cpu")),
                memory_bytes=parse_memory(allocatable.get("memory")),
            ),
            roles=roles,
            is_schedulable=is_schedulable,
            labels=labels,
        )
