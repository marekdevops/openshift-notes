#!/usr/bin/env python3
"""
deployment_worker_scheduler_estimator.py
========================================

Cel:
  Dla wskazanego Deploymentu w OpenShift określa:
  - na których workerach scheduler może uruchomić jego pody,
  - ile workerów przechodzi twarde kryteria schedulera,
  - ile replik da się oszacować na bazie bieżących requests CPU/RAM.

Skrypt działa wyłącznie w trybie odczytu:
  - pobiera namespace, deployment, worker nodes i aktualne pody,
  - nie wykonuje żadnych zmian w klastrze.

Uwzględniane twarde kryteria:
  - namespace annotation: openshift.io/node-selector
  - spec.template.spec.nodeSelector
  - required nodeAffinity
  - NoSchedule / NoExecute taints vs tolerations
  - requests CPU / memory względem bieżącego allocatable/free

Ograniczenia:
  - preferredDuringSchedulingIgnoredDuringExecution jest raportowane jako informacja,
    ale nie blokuje noda.
  - podAffinity / podAntiAffinity i topologySpreadConstraints są oznaczane jako ostrzeżenie,
    bo ich pełna symulacja wymaga głębszego modelowania bieżącego rozkładu podów.

Przykłady:
  python3 deployment_worker_scheduler_estimator.py -n my-ns -d my-app
  python3 deployment_worker_scheduler_estimator.py -n my-ns -d my-app --details
  python3 deployment_worker_scheduler_estimator.py -n my-ns -d my-app --replicas 6
  python3 deployment_worker_scheduler_estimator.py -n my-ns --all-deployments
"""

import argparse
import json
import subprocess
import sys
from collections import defaultdict


MEMORY_MULTIPLIERS = {
    "Ki": 1 / 1024,
    "Mi": 1,
    "Gi": 1024,
    "Ti": 1024 * 1024,
    "Pi": 1024 * 1024 * 1024,
    "K": 1000 / (1024 * 1024),
    "M": (1000 ** 2) / (1024 * 1024),
    "G": (1000 ** 3) / (1024 * 1024),
    "T": (1000 ** 4) / (1024 * 1024),
}


def die(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)


def oc_json(args):
    cmd = ["oc"] + args + ["-o", "json"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        die("Blad: brak polecenia 'oc' w PATH.")
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        die(f"Blad wykonania: {' '.join(cmd)}\n{stderr}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        die(f"Blad parsowania JSON dla: {' '.join(cmd)}\n{exc}")


def cpu_to_m(value):
    if not value:
        return 0
    value = str(value).strip()
    try:
        if value.endswith("n"):
            return int(float(value[:-1]) / 1_000_000)
        if value.endswith("u"):
            return int(float(value[:-1]) / 1_000)
        if value.endswith("m"):
            return int(float(value[:-1]))
        return int(float(value) * 1000)
    except ValueError:
        return 0


def mem_to_mib(value):
    if not value:
        return 0
    value = str(value).strip()
    for suffix, factor in sorted(MEMORY_MULTIPLIERS.items(), key=lambda x: -len(x[0])):
        if value.endswith(suffix):
            try:
                return max(0, int(float(value[:-len(suffix)]) * factor))
            except ValueError:
                return 0
    try:
        return max(0, int(float(value) / (1024 * 1024)))
    except ValueError:
        return 0


def fmt_cpu(millicores):
    if millicores >= 1000:
        return f"{millicores / 1000:.2f} CPU"
    return f"{millicores}m"


def fmt_mem(mib):
    if mib >= 1024:
        return f"{mib / 1024:.1f} GiB"
    return f"{mib} MiB"


def parse_selector(selector_string):
    selector = {}
    if not selector_string:
        return selector
    for part in selector_string.split(","):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            key, value = part.split("=", 1)
            selector[key.strip()] = value.strip()
        else:
            selector[part] = ""
    return selector


def merge_selectors(namespace_selector, deployment_selector):
    merged = dict(namespace_selector)
    conflicts = []
    for key, value in deployment_selector.items():
        if key in merged and merged[key] != value:
            conflicts.append((key, merged[key], value))
        merged[key] = value
    return merged, conflicts


def get_namespace(namespace):
    return oc_json(["get", "namespace", namespace])


def get_deployment(namespace, name):
    return oc_json(["get", "deployment", name, "-n", namespace])


def get_deployments(namespace):
    data = oc_json(["get", "deployments", "-n", namespace])
    return data.get("items", [])


def get_worker_nodes():
    data = oc_json(["get", "nodes"])
    workers = []
    for item in data.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        if "node-role.kubernetes.io/worker" not in labels:
            continue
        workers.append(item)
    return workers


def get_active_pods():
    data = oc_json(
        [
            "get",
            "pods",
            "--all-namespaces",
            "--field-selector",
            "status.phase!=Succeeded,status.phase!=Failed",
        ]
    )
    return data.get("items", [])


def pod_requests(pod_spec):
    total_cpu = 0
    total_mem = 0
    for container in pod_spec.get("containers", []):
        requests = container.get("resources", {}).get("requests", {})
        total_cpu += cpu_to_m(requests.get("cpu"))
        total_mem += mem_to_mib(requests.get("memory"))
    for container in pod_spec.get("initContainers", []):
        requests = container.get("resources", {}).get("requests", {})
        total_cpu = max(total_cpu, cpu_to_m(requests.get("cpu")))
        total_mem = max(total_mem, mem_to_mib(requests.get("memory")))
    return total_cpu, total_mem


def build_node_usage(active_pods):
    usage = defaultdict(lambda: {"cpu_m": 0, "mem_mib": 0, "pods": 0})
    for pod in active_pods:
        node_name = pod.get("spec", {}).get("nodeName")
        if not node_name:
            continue
        cpu_m, mem_mib = pod_requests(pod.get("spec", {}))
        usage[node_name]["cpu_m"] += cpu_m
        usage[node_name]["mem_mib"] += mem_mib
        usage[node_name]["pods"] += 1
    return usage


def match_selector(node_labels, selector):
    for key, value in selector.items():
        if node_labels.get(key) != value:
            return False
    return True


def match_expressions(node_labels, expressions):
    if not expressions:
        return True
    for expr in expressions:
        key = expr.get("key")
        operator = expr.get("operator")
        values = expr.get("values", [])
        label_value = node_labels.get(key)

        if operator == "In":
            if label_value not in values:
                return False
        elif operator == "NotIn":
            if label_value in values:
                return False
        elif operator == "Exists":
            if key not in node_labels:
                return False
        elif operator == "DoesNotExist":
            if key in node_labels:
                return False
        elif operator == "Gt":
            try:
                if label_value is None or int(label_value) <= int(values[0]):
                    return False
            except (ValueError, IndexError):
                return False
        elif operator == "Lt":
            try:
                if label_value is None or int(label_value) >= int(values[0]):
                    return False
            except (ValueError, IndexError):
                return False
        else:
            return False
    return True


def match_required_node_affinity(node_labels, affinity):
    if not affinity:
        return True

    node_affinity = affinity.get("nodeAffinity", {})
    required = node_affinity.get("requiredDuringSchedulingIgnoredDuringExecution")
    if not required:
        return True

    terms = required.get("nodeSelectorTerms", [])
    if not terms:
        return True

    for term in terms:
        if match_expressions(node_labels, term.get("matchExpressions", [])):
            return True
    return False


def taint_is_tolerated(taint, tolerations):
    effect = taint.get("effect")
    if effect == "PreferNoSchedule":
        return True

    for tol in tolerations:
        tol_effect = tol.get("effect")
        tol_key = tol.get("key")
        tol_value = tol.get("value")
        operator = tol.get("operator", "Equal")

        if tol_effect and tol_effect != effect:
            continue
        if operator == "Exists":
            if not tol_key or tol_key == taint.get("key"):
                return True
        elif operator == "Equal":
            if tol_key == taint.get("key") and tol_value == taint.get("value"):
                return True

    return False


def node_taints_ok(taints, tolerations):
    blocking = []
    for taint in taints or []:
        if not taint_is_tolerated(taint, tolerations):
            blocking.append(
                f"{taint.get('key')}={taint.get('value', '')}:{taint.get('effect')}"
            )
    return len(blocking) == 0, blocking


def node_ready(status):
    for condition in status.get("conditions", []):
        if condition.get("type") == "Ready":
            return condition.get("status") == "True"
    return False


def node_report(worker_node, selector, affinity, tolerations, req_cpu_m, req_mem_mib, usage):
    metadata = worker_node.get("metadata", {})
    status = worker_node.get("status", {})
    spec = worker_node.get("spec", {})
    name = metadata.get("name")
    labels = metadata.get("labels", {})
    alloc = status.get("allocatable", {})
    alloc_cpu_m = cpu_to_m(alloc.get("cpu"))
    alloc_mem_mib = mem_to_mib(alloc.get("memory"))
    used_cpu_m = usage[name]["cpu_m"]
    used_mem_mib = usage[name]["mem_mib"]
    free_cpu_m = max(0, alloc_cpu_m - used_cpu_m)
    free_mem_mib = max(0, alloc_mem_mib - used_mem_mib)

    reasons = []

    if selector and not match_selector(labels, selector):
        reasons.append("nodeSelector")

    if not match_required_node_affinity(labels, affinity):
        reasons.append("required nodeAffinity")

    if spec.get("unschedulable"):
        reasons.append("node cordoned/unschedulable")

    if not node_ready(status):
        reasons.append("node NotReady")

    taints_ok, blocking_taints = node_taints_ok(spec.get("taints", []), tolerations)
    if not taints_ok:
        reasons.append("taints/tolerations: " + "; ".join(blocking_taints))

    if req_cpu_m > 0 and free_cpu_m < req_cpu_m:
        reasons.append("za malo wolnego CPU")

    if req_mem_mib > 0 and free_mem_mib < req_mem_mib:
        reasons.append("za malo wolnej pamieci")

    max_replicas_cpu = 999999 if req_cpu_m == 0 else free_cpu_m // req_cpu_m
    max_replicas_mem = 999999 if req_mem_mib == 0 else free_mem_mib // req_mem_mib
    max_replicas = min(max_replicas_cpu, max_replicas_mem)

    return {
        "name": name,
        "labels": labels,
        "alloc_cpu_m": alloc_cpu_m,
        "alloc_mem_mib": alloc_mem_mib,
        "used_cpu_m": used_cpu_m,
        "used_mem_mib": used_mem_mib,
        "free_cpu_m": free_cpu_m,
        "free_mem_mib": free_mem_mib,
        "eligible": len(reasons) == 0,
        "reasons": reasons,
        "max_replicas": max_replicas,
    }


def print_summary(namespace, deployment_name, replicas, selector, req_cpu_m, req_mem_mib):
    print("\n=== Analiza schedulowalnosci deploymentu ===")
    print(f"Namespace       : {namespace}")
    print(f"Deployment      : {deployment_name}")
    print(f"Docelowe repliki: {replicas}")
    print(
        "Per pod requests: "
        f"CPU {fmt_cpu(req_cpu_m)} | RAM {fmt_mem(req_mem_mib)}"
    )
    print(
        "Efektywny selector: "
        + (", ".join(f"{k}={v}" for k, v in selector.items()) if selector else "brak")
    )


def print_node_table(eligible_nodes, blocked_nodes, show_details):
    print("\n--- Workery spelniajace twarde kryteria ---")
    if not eligible_nodes:
        print("Brak workerow, na ktorych scheduler moze uruchomic ten pod w obecnym stanie klastra.")
    else:
        for node in eligible_nodes:
            print(
                f"{node['name']}: free CPU {fmt_cpu(node['free_cpu_m'])}, "
                f"free RAM {fmt_mem(node['free_mem_mib'])}, "
                f"szacowany max replik {node['max_replicas']}"
            )

    print("\n--- Workery odrzucone ---")
    if not blocked_nodes:
        print("Brak odrzuconych workerow.")
    else:
        for node in blocked_nodes:
            print(f"{node['name']}: {', '.join(node['reasons'])}")

    if show_details and eligible_nodes:
        print("\n--- Szczegoly dopasowanych workerow ---")
        for node in eligible_nodes:
            print(
                f"{node['name']}: alloc CPU {fmt_cpu(node['alloc_cpu_m'])}, "
                f"used CPU {fmt_cpu(node['used_cpu_m'])}, "
                f"alloc RAM {fmt_mem(node['alloc_mem_mib'])}, "
                f"used RAM {fmt_mem(node['used_mem_mib'])}"
            )


def analyze_deployment(
    namespace,
    deployment_data,
    namespace_selector,
    worker_nodes,
    usage,
    replicas_override=None,
    show_details=False,
):
    deployment_name = deployment_data.get("metadata", {}).get("name", "<unknown>")
    deployment_spec = deployment_data.get("spec", {})
    pod_spec = deployment_spec.get("template", {}).get("spec", {})
    deployment_selector = pod_spec.get("nodeSelector", {}) or {}
    effective_selector, selector_conflicts = merge_selectors(
        namespace_selector, deployment_selector
    )
    req_cpu_m, req_mem_mib = pod_requests(pod_spec)
    replicas = replicas_override if replicas_override is not None else deployment_spec.get("replicas", 1)
    affinity = pod_spec.get("affinity", {}) or {}
    tolerations = pod_spec.get("tolerations", []) or []

    print_summary(
        namespace,
        deployment_name,
        replicas,
        effective_selector,
        req_cpu_m,
        req_mem_mib,
    )

    if selector_conflicts:
        print("\nKrytyczny konflikt selectorow namespace vs deployment:")
        for key, ns_value, dep_value in selector_conflicts:
            print(
                f"- {key}: namespace wymusza '{ns_value}', deployment wymusza '{dep_value}'"
            )
        print("Wynik: 0 workerow. Pod nie bedzie schedulowalny.")
        return {
            "deployment": deployment_name,
            "requested_replicas": replicas,
            "eligible_nodes": [],
            "blocked_nodes": [],
            "total_capacity": 0,
            "schedulable": False,
            "conflict": True,
        }

    if affinity.get("podAffinity") or affinity.get("podAntiAffinity"):
        print(
            "\nOstrzezenie: deployment ma podAffinity/podAntiAffinity. "
            "Ten skrypt nie wykonuje pelnej symulacji tych regul."
        )

    if pod_spec.get("topologySpreadConstraints"):
        print(
            "Ostrzezenie: deployment ma topologySpreadConstraints. "
            "Wynik nalezy traktowac jako estymacje twardych filtrow node-level."
        )

    if affinity.get("nodeAffinity", {}).get("preferredDuringSchedulingIgnoredDuringExecution"):
        print(
            "Informacja: preferred nodeAffinity zostalo pominiete w decyzji binarnej "
            "eligible/blocked, bo to preferencja a nie twardy filtr."
        )

    reports = [
        node_report(
            worker_node=node,
            selector=effective_selector,
            affinity=affinity,
            tolerations=tolerations,
            req_cpu_m=req_cpu_m,
            req_mem_mib=req_mem_mib,
            usage=usage,
        )
        for node in worker_nodes
    ]

    eligible_nodes = [report for report in reports if report["eligible"]]
    blocked_nodes = [report for report in reports if not report["eligible"]]
    eligible_nodes.sort(key=lambda item: (-item["max_replicas"], item["name"]))
    blocked_nodes.sort(key=lambda item: item["name"])

    total_capacity = sum(node["max_replicas"] for node in eligible_nodes)
    schedulable = total_capacity >= replicas

    print(f"\nLiczba workerow spelniajacych kryteria: {len(eligible_nodes)} / {len(worker_nodes)}")
    print(f"Szacowana laczna pojemnosc dla tego deploymentu: {total_capacity} replik")
    print(
        "Werdykt: "
        + (
            f"TAK, deployment powinien zmiescic {replicas} replik."
            if schedulable
            else f"NIE, w obecnym stanie klastra estymacja daje tylko {total_capacity} replik."
        )
    )

    print_node_table(eligible_nodes, blocked_nodes, show_details)

    return {
        "deployment": deployment_name,
        "requested_replicas": replicas,
        "eligible_nodes": eligible_nodes,
        "blocked_nodes": blocked_nodes,
        "total_capacity": total_capacity,
        "schedulable": schedulable,
        "conflict": False,
    }


def print_namespace_summary(namespace, results):
    print("\n=== Podsumowanie namespace ===")
    print(f"Namespace: {namespace}")
    print(f"Liczba przeanalizowanych deploymentow: {len(results)}")

    ok_count = sum(1 for item in results if item["schedulable"])
    failed = [item for item in results if not item["schedulable"]]
    print(f"Schedulowalne: {ok_count}")
    print(f"Nieschedulowalne: {len(failed)}")

    if failed:
        print("\nDeploymenty wymagajace uwagi:")
        for item in failed:
            print(
                f"- {item['deployment']}: potrzebne {item['requested_replicas']}, "
                f"szacowana pojemnosc {item['total_capacity']}"
                + (" (konflikt selectorow)" if item["conflict"] else "")
            )


def main():
    parser = argparse.ArgumentParser(
        description="Szacuje na ilu i na jakich workerach OpenShift moze uruchomic pody z Deploymentu."
    )
    parser.add_argument("-n", "--namespace", required=True, help="Namespace projektu.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("-d", "--deployment", help="Nazwa Deploymentu.")
    group.add_argument(
        "--all-deployments",
        action="store_true",
        help="Przeanalizuj wszystkie Deploymenty w namespace.",
    )
    parser.add_argument(
        "--replicas",
        type=int,
        help="Opcjonalne nadpisanie liczby replik do estymacji. Dziala tylko dla pojedynczego deploymentu.",
    )
    parser.add_argument(
        "--details",
        action="store_true",
        help="Pokaz dodatkowe szczegoly wykorzystania CPU/RAM na workerach.",
    )
    args = parser.parse_args()

    namespace_data = get_namespace(args.namespace)
    namespace_selector = parse_selector(
        namespace_data.get("metadata", {})
        .get("annotations", {})
        .get("openshift.io/node-selector", "")
    )
    worker_nodes = get_worker_nodes()
    active_pods = get_active_pods()
    usage = build_node_usage(active_pods)

    if args.all_deployments and args.replicas is not None:
        die("Opcja --replicas moze byc uzyta tylko razem z --deployment.")

    if args.deployment:
        deployment_data = get_deployment(args.namespace, args.deployment)
        analyze_deployment(
            namespace=args.namespace,
            deployment_data=deployment_data,
            namespace_selector=namespace_selector,
            worker_nodes=worker_nodes,
            usage=usage,
            replicas_override=args.replicas,
            show_details=args.details,
        )
        return

    deployments = get_deployments(args.namespace)
    if not deployments:
        die(f"Brak deploymentow w namespace {args.namespace}.", code=0)

    results = []
    for deployment_data in sorted(
        deployments, key=lambda item: item.get("metadata", {}).get("name", "")
    ):
        results.append(
            analyze_deployment(
                namespace=args.namespace,
                deployment_data=deployment_data,
                namespace_selector=namespace_selector,
                worker_nodes=worker_nodes,
                usage=usage,
                show_details=args.details,
            )
        )

    print_namespace_summary(args.namespace, results)


if __name__ == "__main__":
    main()
