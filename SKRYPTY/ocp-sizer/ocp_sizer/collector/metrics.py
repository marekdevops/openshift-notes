"""Kolekcja faktycznego zużycia z metrics-server (opcjonalna)."""

from __future__ import annotations

from kubernetes import client
from ..models.resources import ResourceUsage
from ..utils.units import parse_cpu, parse_memory


class MetricsCollector:
    """Pobiera metryki z metrics.k8s.io/v1beta1 jeśli dostępne."""

    def __init__(self, custom_api: client.CustomObjectsApi, namespaces: list[str]):
        self.custom_api = custom_api
        self.namespaces = namespaces
        self._available: bool | None = None

    def is_available(self) -> bool:
        if self._available is not None:
            return self._available
        try:
            self.custom_api.get_cluster_custom_object(
                group="metrics.k8s.io",
                version="v1beta1",
                plural="nodes",
                name="",
            )
            self._available = True
        except Exception:
            # Próbuj przez list
            try:
                self.custom_api.list_cluster_custom_object(
                    group="metrics.k8s.io",
                    version="v1beta1",
                    plural="nodes",
                )
                self._available = True
            except Exception:
                self._available = False
        return self._available

    def collect_pod_metrics(self) -> dict[str, ResourceUsage]:
        """Zwraca {namespace/pod_name: ResourceUsage}."""
        result: dict[str, ResourceUsage] = {}
        if not self.is_available():
            return result

        for ns in self.namespaces:
            try:
                data = self.custom_api.list_namespaced_custom_object(
                    group="metrics.k8s.io",
                    version="v1beta1",
                    namespace=ns,
                    plural="pods",
                )
                for pod_metric in data.get("items", []):
                    pod_name = pod_metric["metadata"]["name"]
                    cpu_total = 0
                    mem_total = 0
                    for container in pod_metric.get("containers", []):
                        usage = container.get("usage", {})
                        cpu_total += parse_cpu(usage.get("cpu"))
                        mem_total += parse_memory(usage.get("memory"))
                    result[f"{ns}/{pod_name}"] = ResourceUsage(
                        cpu_millicores=cpu_total,
                        memory_bytes=mem_total,
                    )
            except Exception as e:
                print(f"[WARN] Metrics {ns}: {e}")

        return result

    def collect_node_metrics(self) -> dict[str, ResourceUsage]:
        """Zwraca {node_name: ResourceUsage}."""
        result: dict[str, ResourceUsage] = {}
        if not self.is_available():
            return result
        try:
            data = self.custom_api.list_cluster_custom_object(
                group="metrics.k8s.io",
                version="v1beta1",
                plural="nodes",
            )
            for node_metric in data.get("items", []):
                name = node_metric["metadata"]["name"]
                usage = node_metric.get("usage", {})
                result[name] = ResourceUsage(
                    cpu_millicores=parse_cpu(usage.get("cpu")),
                    memory_bytes=parse_memory(usage.get("memory")),
                )
        except Exception as e:
            print(f"[WARN] Node metrics: {e}")
        return result
