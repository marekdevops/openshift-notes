# ocp-sizer

Narzędzie CLI do analizy zasobów OpenShift per namespace i rekomendacji sizingu nowego klastra.

## Instalacja

```bash
cd ocp-sizer
pip install -e .
```

## Użycie

```bash
# Analiza jednego namespace
ocp-sizer my-namespace
dnf install -y \
    python3-kubernetes \
    python3-jinja2 \
    python3-requests \
    python3-urllib3 \
    python3-pyyaml \
    python3-six \
    python3-dateutil \
    python3-certifi \
    python3-oauthlib \
    python3-google-auth \
    python3-websocket-client

# Analiza wielu namespace'ów + raport HTML
ocp-sizer ns1 ns2 ns3 --html raport.html

# Custom target utilization (domyślnie 75%)
ocp-sizer my-namespace --target-utilization 0.80

# Własne rozmiary node'ów (CPU:GiB)
ocp-sizer my-namespace --node-variants "8:32,16:64,32:128"

# Bez kolorów (do logów/pipe)
ocp-sizer my-namespace --no-color
```

## Wymagania

- Python 3.9+
- Aktywny `oc login` lub skonfigurowany kubeconfig
- Uprawnienia: `get`/`list` na pods, deployments, statefulsets, daemonsets,
  resourcequotas, limitranges, poddisruptionbudgets, nodes (cluster-level)

## Co analizuje

### Per namespace
- Suma requests i limits CPU/RAM ze wszystkich Running podów
- Faktyczne zużycie z metrics-server (jeśli dostępny)
- Lista node'ów na których działają pody
- ResourceQuoty i LimitRange
- PodDisruptionBudgets (min_available, max_unavailable)
- NodeSelectory podów
- Anti-affinity i TopologySpreadConstraints

### Rekomendacja sizingu
Zgodna z Red Hat best practices:
- **Target utilization 75%** (środek przedziału 70-80%)
- **N+1**: jeden node zawsze wolny do drainowania podczas update/maintenence
- **PDB aware**: jeśli minAvailable=2 to potrzeba min 3 node'ów
- **Anti-affinity aware**: required hostname anti-affinity → min nodes = replicas
- **System overhead**: 1 CPU + 4 GiB RAM zarezerwowane per node (OCP system)
- **DaemonSet overhead**: suma requests DaemonSetów odliczana od każdego node'a

## Warianty node'ów (domyślne)

| Wariant | CPU | RAM  |
|---------|-----|------|
| small   |  8  | 32Gi |
| medium  | 16  | 64Gi |
| large   | 32  | 128Gi|
| xlarge  | 48  | 192Gi|
