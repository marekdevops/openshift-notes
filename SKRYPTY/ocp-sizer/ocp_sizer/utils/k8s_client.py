"""Fabryka klientów Kubernetes — ładuje aktywny kubeconfig."""

import sys
import urllib3
from kubernetes import client, config
from kubernetes.config.config_exception import ConfigException

# Wycisz ostrzeżenia o self-signed certach (typowe dla klastrów OpenShift dev)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


def build_k8s_clients() -> tuple[
    client.CoreV1Api,
    client.AppsV1Api,
    client.PolicyV1Api,
    client.CustomObjectsApi,
    str,
]:
    """Inicjalizuje klientów K8s z aktywnego kubeconfig.

    Próbuje kolejno:
    1. Aktywny kontekst z ~/.kube/config
    2. In-cluster config (jeśli narzędzie uruchomione w podzie)

    Zwraca tuple: (core_v1, apps_v1, policy_v1, custom_api, context_name)
    """
    context_name = "unknown"
    try:
        contexts, active = config.list_kube_config_contexts()
        context_name = active["name"] if active else "unknown"
        config.load_kube_config()
    except ConfigException:
        try:
            config.load_incluster_config()
            context_name = "in-cluster"
        except ConfigException:
            print(
                "[ERROR] Brak kubeconfig. Zaloguj się przez 'oc login' lub 'kubectl config use-context'.",
                file=sys.stderr,
            )
            sys.exit(1)

    return (
        client.CoreV1Api(),
        client.AppsV1Api(),
        client.PolicyV1Api(),
        client.CustomObjectsApi(),
        context_name,
    )


def get_current_context() -> str:
    """Zwraca nazwę aktywnego kontekstu kubeconfig."""
    try:
        _, active = config.list_kube_config_contexts()
        return active["name"] if active else "unknown"
    except ConfigException:
        return "unknown"
