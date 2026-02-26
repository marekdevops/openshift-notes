"""Modele podów i workloadów (Deployment, StatefulSet, DaemonSet)."""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional
from .resources import ResourceSpec


@dataclass
class PodInfo:
    """Dane pojedynczego poda."""

    name: str
    namespace: str
    node_name: Optional[str]
    phase: str
    requests: ResourceSpec
    limits: ResourceSpec
    owner_kind: Optional[str]
    owner_name: Optional[str]
    node_selector: dict[str, str]
    has_required_affinity: bool
    has_preferred_affinity: bool
    has_required_anti_affinity: bool
    has_preferred_anti_affinity: bool
    has_topology_spread: bool
    is_daemonset: bool


@dataclass
class WorkloadInfo:
    """Zagregowany widok jednego Deployment / StatefulSet / DaemonSet."""

    kind: str
    name: str
    namespace: str
    replicas: int
    ready_replicas: int
    pod_template_requests: ResourceSpec
    pod_template_limits: ResourceSpec
    node_selector: dict[str, str]
    has_required_anti_affinity: bool
    has_preferred_anti_affinity: bool
    topology_spread_keys: list[str] = field(default_factory=list)
    topology_spread_when_unsatisfiable: list[str] = field(default_factory=list)
