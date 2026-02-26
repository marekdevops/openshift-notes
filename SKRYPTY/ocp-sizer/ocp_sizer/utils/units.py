"""Konwersja jednostek CPU i pamięci Kubernetes."""

import re


def parse_cpu(value: str | None) -> int:
    """Konwertuje string CPU na millicores (int).

    Przykłady:
        "500m"  -> 500
        "1"     -> 1000
        "0.5"   -> 500
        "2.5"   -> 2500
        None    -> 0
    """
    if not value:
        return 0
    value = str(value).strip()
    if value.endswith("m"):
        return int(value[:-1])
    return int(float(value) * 1000)


def parse_memory(value: str | None) -> int:
    """Konwertuje string pamięci na bajty (int).

    Obsługuje przyrostki Ki, Mi, Gi, Ti (binary) oraz K, M, G, T (SI).
    Przykłady:
        "512Mi"    -> 536870912
        "2Gi"      -> 2147483648
        "1000M"    -> 1000000000
        None       -> 0
    """
    if not value:
        return 0
    value = str(value).strip()

    BINARY = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}
    SI = {"K": 1000, "M": 1000**2, "G": 1000**3, "T": 1000**4}

    for suffix, multiplier in BINARY.items():
        if value.endswith(suffix):
            return int(float(value[: -len(suffix)]) * multiplier)

    for suffix, multiplier in SI.items():
        if value.endswith(suffix):
            return int(float(value[: -len(suffix)]) * multiplier)

    return int(value)


def fmt_cpu(millicores: int) -> str:
    """Formatuje millicores do czytelnej formy.

    Przykłady:
        1500  -> "1.50 cores"
        500   -> "500m"
        12000 -> "12.00 cores"
    """
    if millicores >= 1000:
        return f"{millicores / 1000:.2f} cores"
    return f"{millicores}m"


def fmt_mem(bytes_val: int) -> str:
    """Formatuje bajty do GiB z 1 miejscem po przecinku.

    Przykłady:
        536870912   -> "0.5 GiB"
        4294967296  -> "4.0 GiB"
        1073741824  -> "1.0 GiB"
    """
    gib = bytes_val / (1024**3)
    if gib >= 1:
        return f"{gib:.1f} GiB"
    mib = bytes_val / (1024**2)
    return f"{mib:.0f} MiB"


def fmt_pct(value: float) -> str:
    """Formatuje wartość float jako procenty.

    Przykłady:
        0.75  -> "75.0%"
        1.0   -> "100.0%"
    """
    return f"{value * 100:.1f}%"
