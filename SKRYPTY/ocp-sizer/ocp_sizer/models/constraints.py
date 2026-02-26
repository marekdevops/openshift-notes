"""Modele ograniczeń: ResourceQuota, LimitRange, PDB, AffinityConstraint."""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class QuotaInfo:
    """ResourceQuota dla namespace'a."""

    name: str
    namespace: str
    hard_cpu_requests: Optional[int] = None
    hard_cpu_limits: Optional[int] = None
    hard_memory_requests: Optional[int] = None
    hard_memory_limits: Optional[int] = None
    used_cpu_requests: Optional[int] = None
    used_cpu_limits: Optional[int] = None
    used_memory_requests: Optional[int] = None
    used_memory_limits: Optional[int] = None


@dataclass
class LimitRangeInfo:
    """LimitRange dla namespace'a — domyślne wartości i limity max."""

    name: str
    namespace: str
    default_cpu_request: Optional[int] = None
    default_memory_request: Optional[int] = None
    default_cpu_limit: Optional[int] = None
    default_memory_limit: Optional[int] = None
    max_cpu: Optional[int] = None
    max_memory: Optional[int] = None


@dataclass
class PDBInfo:
    """PodDisruptionBudget — ograniczenie niedostępności podów."""

    name: str
    namespace: str
    selector: dict[str, str]
    min_available_raw: Optional[str]
    max_unavailable_raw: Optional[str]
    current_healthy: int
    desired_healthy: int
    # Wyliczane przez ConstraintAnalyzer
    min_available_resolved: int = 0
    max_unavailable_resolved: int = 0
    matched_replicas: int = 0
    min_nodes_required: int = 0


@dataclass
class AffinityConstraint:
    """Wyekstrahowane ograniczenie anti-affinity lub topology spread."""

    workload_name: str
    namespace: str
    kind: str
    topology_key: str
    replicas: int
    is_required: bool
    min_distinct_nodes: int
