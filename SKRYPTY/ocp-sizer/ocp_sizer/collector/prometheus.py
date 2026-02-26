"""Kolekcja historycznych peak metrics z Prometheusa OpenShift (Thanos Querier)."""

from __future__ import annotations

import json
import sys

from kubernetes import client as k8s_client

from ..models.sizing import PeakMetrics


class PrometheusCollector:
    """Pobiera peak CPU i RAM per namespace z wbudowanego Prometheusa OpenShift.

    Łączy się przez Kubernetes API proxy — bez potrzeby znania route.
    Wymaga uprawnień do: /api/v1/namespaces/openshift-monitoring/services/.../proxy
    """

    # Thanos Querier dostępny przez K8s API proxy (HTTPS service)
    PROXY_PATH = (
        "/api/v1/namespaces/openshift-monitoring/services/"
        "https:thanos-querier:9091/proxy/api/v1/query"
    )

    def __init__(
        self,
        api_client: k8s_client.ApiClient,
        namespaces: list[str],
        lookback: str = "7d",
    ):
        self.api_client = api_client
        self.namespaces = namespaces
        self.lookback = lookback
        self._available: bool | None = None

    def _query(self, promql: str) -> list[dict]:
        """Wykonuje instant query PromQL przez K8s API proxy.

        Returns:
            Lista wyników z pola data.result odpowiedzi Prometheusa.

        Raises:
            RuntimeError: przy błędzie HTTP lub nieprawidłowej odpowiedzi.
        """
        response = self.api_client.call_api(
            self.PROXY_PATH,
            "GET",
            query_params=[("query", promql)],
            header_params={"Accept": "application/json"},
            auth_settings=["BearerToken"],
            _preload_content=False,
            _return_http_data_only=True,
        )
        body = json.loads(response.data)
        if body.get("status") != "success":
            error = body.get("error", "nieznany błąd")
            raise RuntimeError(f"Prometheus zwrócił błąd: {error}")
        return body.get("data", {}).get("result", [])

    def is_available(self) -> bool:
        """Sprawdza czy Prometheus jest dostępny przez API proxy."""
        if self._available is not None:
            return self._available
        try:
            # Prosta próba — zapytanie o metrykę 'up' (zawsze dostępna)
            self._query('up{job="prometheus-k8s"}')
            self._available = True
        except Exception:
            self._available = False
        return self._available

    def collect_peak_metrics(self) -> dict[str, PeakMetrics]:
        """Zwraca {namespace: PeakMetrics} dla każdego namespace'a.

        Dla każdego namespace wykonuje 2 zapytania PromQL:
        - max_over_time CPU rate (rdzenie → millicores)
        - max_over_time RAM working set (bajty)

        Przy błędzie dla konkretnego namespace — pomija go z ostrzeżeniem.
        """
        if not self.is_available():
            return {}

        result: dict[str, PeakMetrics] = {}

        for ns in self.namespaces:
            try:
                peak_cpu_mc, peak_mem_bytes = self._collect_namespace(ns)
                result[ns] = PeakMetrics(
                    namespace=ns,
                    peak_cpu_millicores=peak_cpu_mc,
                    peak_memory_bytes=peak_mem_bytes,
                    lookback=self.lookback,
                )
            except Exception as e:
                print(f"[WARN] Peak metrics {ns}: {e}", file=sys.stderr)

        return result

    def _collect_namespace(self, ns: str) -> tuple[int, int]:
        """Zwraca (peak_cpu_millicores, peak_memory_bytes) dla namespace'a."""
        cpu_query = (
            f"max_over_time("
            f"sum by (namespace) ("
            f'rate(container_cpu_usage_seconds_total{{namespace="{ns}",container!=""}}[5m])'
            f")[{self.lookback}:5m])"
        )
        mem_query = (
            f"max_over_time("
            f"sum by (namespace) ("
            f'container_memory_working_set_bytes{{namespace="{ns}",container!=""}}'
            f")[{self.lookback}:5m])"
        )

        cpu_results = self._query(cpu_query)
        mem_results = self._query(mem_query)

        # Wynik instant query: [{metric: {...}, value: [timestamp, "value_string"]}]
        peak_cpu_cores = float(cpu_results[0]["value"][1]) if cpu_results else 0.0
        peak_mem_bytes = int(float(mem_results[0]["value"][1])) if mem_results else 0

        return int(peak_cpu_cores * 1000), peak_mem_bytes
