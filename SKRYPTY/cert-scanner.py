#!/usr/bin/env python3
from __future__ import annotations
"""
OpenShift Certificate Scanner
==============================
Skanuje certyfikaty we wszystkich namespacach bez wchodzenia do podów.
Źródła: Secrets, ConfigMaps, Routes, zasoby cluster-level (APIServer, IngressController).

Wymagania: oc CLI z aktywną sesją, openssl w PATH
Użycie:    python3 cert-scanner.py [--warn-days 30] [--json] [--namespace NAMESPACE]
"""

import subprocess
import json
import base64
import re
import sys
import argparse
import time
from datetime import datetime, timezone
from collections import defaultdict

# ─── Kolory ANSI ────────────────────────────────────────────────────────────
RED     = "\033[0;31m"
YELLOW  = "\033[1;33m"
GREEN   = "\033[0;32m"
BLUE    = "\033[0;34m"
CYAN    = "\033[0;36m"
MAGENTA = "\033[0;35m"
BOLD    = "\033[1m"
NC      = "\033[0m"

WARN_DAYS_DEFAULT = 30
PEM_PATTERN = re.compile(
    r"-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----"
)
CERT_KEYS = re.compile(
    r"(crt|cert|certificate|pem|ca|bundle|tls)", re.IGNORECASE
)

# Namespaces systemowe OpenShift – skanowane osobno i oznaczane
SYSTEM_NS_PREFIXES = (
    "openshift-", "kube-", "default", "redhat-"
)


# ─── Pomocnicze ─────────────────────────────────────────────────────────────

def run_oc(*args, ignore_errors=True, rate_limit=0.05):
    """Wywołaj oc i zwróć sparsowany JSON lub None."""
    cmd = ["oc"] + list(args) + ["-o", "json"]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30
        )
        time.sleep(rate_limit)  # delikatny rate-limit, nie przeciążamy API
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None


def run_oc_raw(*args, ignore_errors=True):
    """Wywołaj oc bez -o json, zwróć stdout."""
    cmd = ["oc"] + list(args)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def parse_cert(pem: str) -> dict | None:
    """Parsuj certyfikat przez openssl x509. Zwraca słownik lub None."""
    cmd = [
        "openssl", "x509", "-noout",
        "-subject", "-issuer", "-dates",
        "-ext", "subjectAltName",
        "-fingerprint", "-sha256"
    ]
    try:
        result = subprocess.run(
            cmd, input=pem, capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            return None
        out = result.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None

    info = {}

    m = re.search(r"subject\s*=\s*(.+)", out)
    info["subject"] = m.group(1).strip() if m else "?"

    m = re.search(r"issuer\s*=\s*(.+)", out)
    info["issuer"] = m.group(1).strip() if m else "?"

    m = re.search(r"notBefore\s*=\s*(.+)", out)
    info["not_before"] = m.group(1).strip() if m else "?"

    m = re.search(r"notAfter\s*=\s*(.+)", out)
    info["not_after"] = m.group(1).strip() if m else "?"

    m = re.search(r"SHA256 Fingerprint\s*=\s*(.+)", out)
    info["fingerprint"] = m.group(1).strip() if m else ""

    # SANy
    san_block = re.search(
        r"X509v3 Subject Alternative Name[^\n]*\n\s*(.+)", out
    )
    info["san"] = san_block.group(1).strip() if san_block else ""

    # Dni do wygaśnięcia
    info["days_left"] = None
    try:
        expiry = datetime.strptime(info["not_after"], "%b %d %H:%M:%S %Y %Z")
        expiry = expiry.replace(tzinfo=timezone.utc)
        info["days_left"] = (expiry - datetime.now(timezone.utc)).days
    except ValueError:
        pass

    return info


def extract_pems(raw: str) -> list[str]:
    """Wyciągnij wszystkie bloki PEM z dowolnego stringa."""
    return PEM_PATTERN.findall(raw)


def decode_secret_value(value: str) -> str:
    """Base64-dekoduj wartość z Secretu."""
    try:
        return base64.b64decode(value).decode("utf-8", errors="ignore")
    except Exception:
        return ""


def is_system_ns(ns: str) -> bool:
    return ns.startswith(SYSTEM_NS_PREFIXES)


def status_color(days: int | None) -> str:
    if days is None:
        return BLUE
    if days < 0:
        return RED + BOLD
    if days < WARN_DAYS_DEFAULT:
        return YELLOW
    return GREEN


# ─── Skanery źródeł ─────────────────────────────────────────────────────────

def scan_secrets(ns: str, results: list):
    data = run_oc("get", "secrets", "-n", ns)
    if not data:
        return
    for secret in data.get("items", []):
        name = secret["metadata"]["name"]
        stype = secret.get("type", "")
        secret_data = secret.get("data", {})

        for key, val in secret_data.items():
            # Sprawdzaj tylko klucze wyglądające na certyfikaty
            if not CERT_KEYS.search(key) and stype != "kubernetes.io/tls":
                continue
            decoded = decode_secret_value(val)
            for pem in extract_pems(decoded):
                info = parse_cert(pem)
                if info:
                    results.append({
                        "ns": ns,
                        "source": f"Secret/{name}",
                        "key": key,
                        "type": stype,
                        **info,
                    })


def scan_configmaps(ns: str, results: list):
    data = run_oc("get", "configmaps", "-n", ns)
    if not data:
        return
    for cm in data.get("items", []):
        name = cm["metadata"]["name"]
        cm_data = cm.get("data", {})
        for key, val in cm_data.items():
            if not CERT_KEYS.search(key) and "BEGIN CERTIFICATE" not in val:
                continue
            for pem in extract_pems(val):
                info = parse_cert(pem)
                if info:
                    results.append({
                        "ns": ns,
                        "source": f"ConfigMap/{name}",
                        "key": key,
                        "type": "configmap",
                        **info,
                    })


def scan_routes(ns: str, results: list):
    data = run_oc("get", "routes", "-n", ns)
    if not data:
        return
    for route in data.get("items", []):
        name = route["metadata"]["name"]
        tls = route.get("spec", {}).get("tls", {})
        if not tls:
            continue
        for field in ("certificate", "caCertificate", "destinationCACertificate"):
            val = tls.get(field, "")
            if not val:
                continue
            for pem in extract_pems(val):
                info = parse_cert(pem)
                if info:
                    results.append({
                        "ns": ns,
                        "source": f"Route/{name}",
                        "key": field,
                        "type": "route-tls",
                        **info,
                    })


def scan_cluster_level(results: list):
    """
    Zasoby cluster-scoped: APIServer, IngressController, Proxy, ETCD.
    Nie wchodzimy do podów – tylko czytamy konfigurację.
    """
    checks = [
        # (resource, name, jsonpath-opis)
        ("apiserver", "cluster", "openshift apiserver config"),
        ("ingresscontroller", "default", "default ingresscontroller"),
    ]

    # APIServer – certyfikaty w spec.servingCerts.namedCertificates
    api = run_oc("get", "apiserver", "cluster",
                 "--ignore-not-found=true", ignore_errors=True)
    if api:
        named = (
            api.get("spec", {})
               .get("servingCerts", {})
               .get("namedCertificates", [])
        )
        for nc in named:
            secret_name = nc.get("servingCertificate", {}).get("name", "")
            names = ", ".join(nc.get("names", []))
            results.append({
                "ns": "cluster",
                "source": "APIServer/cluster",
                "key": f"namedCert → Secret/{secret_name}",
                "type": "cluster-config",
                "subject": f"SANs: {names}",
                "issuer": "custom (z Secretu w openshift-config)",
                "not_before": "?",
                "not_after": "?",
                "days_left": None,
                "san": names,
                "fingerprint": "",
                "_note": f"Sprawdź Secret/{secret_name} w openshift-config",
            })

    # IngressController – defaultCertificate
    ic = run_oc(
        "get", "ingresscontroller", "default",
        "-n", "openshift-ingress-operator",
        "--ignore-not-found=true", ignore_errors=True
    )
    if ic:
        default_cert = (
            ic.get("spec", {})
              .get("defaultCertificate", {})
              .get("name", "")
        )
        if default_cert:
            results.append({
                "ns": "openshift-ingress-operator",
                "source": "IngressController/default",
                "key": f"defaultCertificate → Secret/{default_cert}",
                "type": "cluster-config",
                "subject": "(certyfikat wildcard ingress)",
                "issuer": "custom",
                "not_before": "?",
                "not_after": "?",
                "days_left": None,
                "san": "*.apps.<cluster>",
                "fingerprint": "",
                "_note": f"Sprawdź Secret/{default_cert} w openshift-ingress",
            })

    # Certyfikaty zarządzane przez service-ca (service-ca.crt w każdym namespace)
    # – już będą złapane przez scan_secrets/scan_configmaps

    # ETCD – operator status
    etcd = run_oc(
        "get", "etcd", "cluster",
        "--ignore-not-found=true", ignore_errors=True
    )
    if etcd:
        conditions = etcd.get("status", {}).get("conditions", [])
        degraded = [c for c in conditions if "Degraded" in c.get("type", "")]
        status_str = "OK" if not degraded else "DEGRADED"
        results.append({
            "ns": "cluster",
            "source": "ETCD/cluster",
            "key": "etcd-certs (operator)",
            "type": "cluster-config",
            "subject": f"etcd (operator-managed) – status: {status_str}",
            "issuer": "etcd-signer (operator)",
            "not_before": "?",
            "not_after": "?",
            "days_left": None,
            "san": "",
            "fingerprint": "",
            "_note": "Certy ETCD rotuje operator; sprawdź openshift-etcd/Secrets",
        })


# ─── Deduplikacja ────────────────────────────────────────────────────────────

def deduplicate(results: list) -> list:
    """Usuwa duplikaty oparte na tym samym fingerprincie."""
    seen = {}
    unique = []
    for r in results:
        fp = r.get("fingerprint", "")
        if fp and fp in seen:
            # Dodaj alias
            seen[fp]["_also_in"] = seen[fp].get("_also_in", [])
            seen[fp]["_also_in"].append(f"{r['ns']}/{r['source']}")
            continue
        if fp:
            seen[fp] = r
        unique.append(r)
    return unique


# ─── Raport ─────────────────────────────────────────────────────────────────

def fmt_days(days: int | None) -> str:
    if days is None:
        return f"{BLUE}(brak parsowania){NC}"
    if days < 0:
        return f"{RED}{BOLD}WYGASŁ {abs(days)} dni temu{NC}"
    if days < WARN_DAYS_DEFAULT:
        return f"{YELLOW}UWAGA: {days} dni{NC}"
    return f"{GREEN}{days} dni{NC}"


def print_report(results: list, warn_days: int, output_json: bool):
    if output_json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return

    print(f"\n{BOLD}{BLUE}{'═'*70}{NC}")
    print(f"{BOLD}{BLUE}  OpenShift Certificate Scanner – Raport{NC}")
    print(f"{BOLD}{BLUE}{'═'*70}{NC}")
    print(f"  Przeskanowano: {len(results)} certyfikatów")
    print(f"  Data:          {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Próg ostrzeżenia: {warn_days} dni\n")

    expired   = [r for r in results if r.get("days_left") is not None and r["days_left"] < 0]
    warning   = [r for r in results if r.get("days_left") is not None and 0 <= r["days_left"] < warn_days]
    ok        = [r for r in results if r.get("days_left") is not None and r["days_left"] >= warn_days]
    no_parse  = [r for r in results if r.get("days_left") is None]

    def print_section(title: str, color: str, items: list):
        if not items:
            return
        print(f"{color}{BOLD}{'─'*70}{NC}")
        print(f"{color}{BOLD}  {title} ({len(items)}){NC}")
        print(f"{color}{BOLD}{'─'*70}{NC}")
        for r in items:
            ns_tag = f"{MAGENTA}[SYS]{NC}" if is_system_ns(r["ns"]) else f"{CYAN}[APP]{NC}"
            print(f"\n  {ns_tag} {BOLD}{r['ns']}{NC} / {r['source']}  ({r['key']})")
            print(f"      Subject : {r['subject']}")
            if r.get("san"):
                print(f"      SANs    : {r['san']}")
            print(f"      Issuer  : {r['issuer']}")
            print(f"      Ważny od: {r['not_before']}")
            print(f"      Ważny do: {r['not_after']}  →  {fmt_days(r['days_left'])}")
            if r.get("fingerprint"):
                print(f"      SHA256  : {r['fingerprint']}")
            if r.get("_also_in"):
                print(f"      Używany także w: {', '.join(r['_also_in'])}")
            if r.get("_note"):
                print(f"      {YELLOW}Uwaga: {r['_note']}{NC}")

    print_section("WYGASŁE CERTYFIKATY", RED, expired)
    print_section(f"CERTYFIKATY WYGASAJĄCE < {warn_days} DNI", YELLOW, warning)
    print_section("CERTYFIKATY OK", GREEN, ok)
    print_section("CERTYFIKATY (konfiguracja – brak parsowania PEM)", BLUE, no_parse)

    # Podsumowanie
    print(f"\n{BOLD}{BLUE}{'═'*70}{NC}")
    print(f"  {RED}{BOLD}Wygasłe:      {len(expired)}{NC}")
    print(f"  {YELLOW}{BOLD}Ostrzeżenia:  {len(warning)}{NC}")
    print(f"  {GREEN}{BOLD}OK:           {len(ok)}{NC}")
    print(f"  {BLUE}Config-only:  {len(no_parse)}{NC}")
    print(f"{BOLD}{BLUE}{'═'*70}{NC}\n")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="OpenShift Certificate Scanner – skanuje Secrets, ConfigMaps, Routes (bez exec do podów)"
    )
    parser.add_argument(
        "--warn-days", type=int, default=WARN_DAYS_DEFAULT,
        help=f"Ostrzeżenie gdy certyfikat wygasa za mniej niż N dni (default: {WARN_DAYS_DEFAULT})"
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Wyjście w formacie JSON zamiast czytelnego raportu"
    )
    parser.add_argument(
        "--namespace", "-n", default=None,
        help="Skanuj tylko ten namespace (domyślnie: wszystkie)"
    )
    parser.add_argument(
        "--skip-system", action="store_true",
        help="Pomiń systemowe namespacy openshift-* i kube-*"
    )
    parser.add_argument(
        "--skip-cluster", action="store_true",
        help="Pomiń zasoby cluster-scoped (APIServer, IngressController, ETCD)"
    )
    args = parser.parse_args()
    warn_days = args.warn_days

    # Sprawdź czy oc jest zalogowany
    whoami = run_oc_raw("whoami")
    if not whoami:
        print(f"{RED}Błąd: brak aktywnej sesji oc. Zaloguj się najpierw.{NC}", file=sys.stderr)
        sys.exit(1)
    print(f"{CYAN}Zalogowany jako: {whoami}{NC}")

    # Pobierz listę namespaców
    if args.namespace:
        namespaces = [args.namespace]
    else:
        ns_data = run_oc("get", "namespaces")
        if not ns_data:
            print(f"{RED}Błąd: nie można pobrać listy namespaców.{NC}", file=sys.stderr)
            sys.exit(1)
        namespaces = [item["metadata"]["name"] for item in ns_data.get("items", [])]

    if args.skip_system:
        namespaces = [ns for ns in namespaces if not is_system_ns(ns)]

    print(f"{CYAN}Namespaców do skanowania: {len(namespaces)}{NC}\n")

    results = []

    # Skanuj każdy namespace
    for i, ns in enumerate(namespaces, 1):
        tag = f"[SYS]" if is_system_ns(ns) else "[APP]"
        sys.stdout.write(f"\r  Skanowanie {i}/{len(namespaces)}: {tag} {ns:<50}")
        sys.stdout.flush()

        scan_secrets(ns, results)
        scan_configmaps(ns, results)
        scan_routes(ns, results)

    print()  # newline po progress

    # Zasoby cluster-level
    if not args.skip_cluster:
        print(f"{CYAN}Skanowanie zasobów cluster-level...{NC}")
        scan_cluster_level(results)

    # Deduplikacja po fingerprincie
    results = deduplicate(results)

    print_report(results, args.warn_days, args.json)


if __name__ == "__main__":
    main()
