"""Modele zasobów CPU i pamięci."""

from __future__ import annotations
from dataclasses import dataclass


@dataclass
class ResourceSpec:
    """Zasoby CPU (millicores) i pamięć (bajty)."""

    cpu_millicores: int
    memory_bytes: int

    @property
    def cpu_cores(self) -> float:
        return self.cpu_millicores / 1000

    @property
    def memory_gib(self) -> float:
        return self.memory_bytes / (1024**3)

    def __add__(self, other: ResourceSpec) -> ResourceSpec:
        return ResourceSpec(
            cpu_millicores=self.cpu_millicores + other.cpu_millicores,
            memory_bytes=self.memory_bytes + other.memory_bytes,
        )

    def __iadd__(self, other: ResourceSpec) -> ResourceSpec:
        return self.__add__(other)

    @classmethod
    def zero(cls) -> ResourceSpec:
        return cls(cpu_millicores=0, memory_bytes=0)


@dataclass
class NodeProfile:
    """Pojemność i dostępność zasobów pojedynczego node'a klastra."""

    name: str
    capacity: ResourceSpec
    allocatable: ResourceSpec
    roles: list[str]
    is_schedulable: bool
    labels: dict[str, str]


@dataclass
class ResourceUsage:
    """Faktyczne zużycie zasobów z metrics-server."""

    cpu_millicores: int
    memory_bytes: int
    source: str = "metrics-server"
