"""Bazowa klasa dla collectorów danych z K8s API."""

from abc import ABC, abstractmethod
from kubernetes import client


class BaseCollector(ABC):
    """Abstrakcja collectora — zapewnia dostęp do klientów K8s API."""

    def __init__(
        self,
        core_v1: client.CoreV1Api,
        apps_v1: client.AppsV1Api,
        policy_v1: client.PolicyV1Api,
        namespaces: list[str],
    ):
        self.core_v1 = core_v1
        self.apps_v1 = apps_v1
        self.policy_v1 = policy_v1
        self.namespaces = namespaces

    @abstractmethod
    def collect(self) -> list:
        """Pobiera dane z API i zwraca listę dataclass."""
        ...
