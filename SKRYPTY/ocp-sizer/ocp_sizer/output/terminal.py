"""Renderowanie wyników w terminalu — rich tables + kolory."""

from __future__ import annotations

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.text import Text
from rich import box

from ..models.sizing import ClusterSizing, NamespaceSummary, SizingVariant
from ..utils.units import fmt_cpu, fmt_mem


class TerminalRenderer:
    """Wyświetla wyniki analizy w terminalu przy użyciu rich."""

    def __init__(self, console: Console | None = None, no_color: bool = False):
        self.console = console or Console(highlight=False, no_color=no_color)

    def render(self, sizing: ClusterSizing) -> None:
        self._render_header(sizing)
        self._render_namespace_table(sizing)
        self._render_cluster_totals(sizing)
        self._render_daemonset_overhead(sizing)
        self._render_sizing_table(sizing)
        self._render_warnings(sizing)

    def _render_header(self, sizing: ClusterSizing) -> None:
        prom_status = (
            f"[green]dostępne ({sizing.lookback})[/green]"
            if sizing.prometheus_available
            else "[dim]niedostępne[/dim]"
        )
        content = (
            f"[bold]ocp-sizer[/bold]  |  "
            f"Cluster: [cyan]{sizing.source_cluster_context}[/cyan]\n"
            f"Wygenerowano: [dim]{sizing.generated_at}[/dim]  |  "
            f"Namespace'y: [yellow]{len(sizing.namespaces)}[/yellow]  |  "
            f"Metrics: {'[green]dostępne[/green]' if sizing.metrics_available else '[dim]niedostępne[/dim]'}  |  "
            f"Prometheus: {prom_status}"
        )
        self.console.print(Panel(content, border_style="blue"))

    def _render_namespace_table(self, sizing: ClusterSizing) -> None:
        self.console.print("\n[bold]Namespace Summary[/bold]")
        table = Table(box=box.ROUNDED, show_header=True, header_style="bold cyan")
        table.add_column("Namespace", style="bold")
        table.add_column("Pods\n(all/run)", justify="right")
        table.add_column("Req CPU", justify="right")
        table.add_column("Req RAM", justify="right")
        table.add_column("Lim CPU", justify="right")
        table.add_column("Lim RAM", justify="right")
        table.add_column("Act CPU", justify="right")
        table.add_column("Act RAM", justify="right")

        # Kolumny peak — tylko jeśli Prometheus dostępny
        if sizing.prometheus_available:
            table.add_column(f"Peak CPU\n({sizing.lookback})", justify="right")
            table.add_column(f"Peak RAM\n({sizing.lookback})", justify="right")

        table.add_column("Nodes", justify="right")
        table.add_column("PDB\nmin", justify="right")
        table.add_column("AA\nmin", justify="right")
        table.add_column("NodeSelector", style="dim")

        for ns in sizing.namespaces:
            act_cpu = "-"
            act_mem = "-"
            if ns.actual_usage and ns.total_requests.cpu_millicores > 0:
                cpu_pct = ns.actual_usage.cpu_millicores / ns.total_requests.cpu_millicores
                mem_pct = ns.actual_usage.memory_bytes / max(ns.total_requests.memory_bytes, 1)
                act_cpu = self._colorize_pct(cpu_pct)
                act_mem = self._colorize_pct(mem_pct)

            selectors = ", ".join(ns.node_selectors[:2])
            if len(ns.node_selectors) > 2:
                selectors += f" +{len(ns.node_selectors)-2}"

            row = [
                ns.namespace,
                f"{ns.pod_count}/{ns.running_pod_count}",
                fmt_cpu(ns.total_requests.cpu_millicores),
                fmt_mem(ns.total_requests.memory_bytes),
                fmt_cpu(ns.total_limits.cpu_millicores),
                fmt_mem(ns.total_limits.memory_bytes),
                act_cpu,
                act_mem,
            ]

            if sizing.prometheus_available:
                if ns.peak_metrics:
                    row.append(fmt_cpu(ns.peak_metrics.peak_cpu_millicores))
                    row.append(fmt_mem(ns.peak_metrics.peak_memory_bytes))
                else:
                    row.append("-")
                    row.append("-")

            row.extend([
                str(len(ns.active_nodes)),
                str(ns.pdb_min_nodes) if ns.pdb_min_nodes else "-",
                str(ns.anti_affinity_min_nodes) if ns.anti_affinity_min_nodes else "-",
                selectors or "-",
            ])

            table.add_row(*row)

        self.console.print(table)

    def _render_cluster_totals(self, sizing: ClusterSizing) -> None:
        req = sizing.cluster_totals_requests
        lim = sizing.cluster_totals_limits
        self.console.print(
            f"\n[bold]Cluster totals[/bold]  "
            f"Requests: [green]{fmt_cpu(req.cpu_millicores)}[/green] CPU, "
            f"[green]{fmt_mem(req.memory_bytes)}[/green] RAM  |  "
            f"Limits: [yellow]{fmt_cpu(lim.cpu_millicores)}[/yellow] CPU, "
            f"[yellow]{fmt_mem(lim.memory_bytes)}[/yellow] RAM"
        )

    def _render_daemonset_overhead(self, sizing: ClusterSizing) -> None:
        ds = sizing.daemonset_overhead_per_node
        self.console.print(
            f"[dim]DaemonSet overhead per node: "
            f"{fmt_cpu(ds.cpu_millicores)} CPU, {fmt_mem(ds.memory_bytes)} RAM[/dim]"
        )
        self.console.print(
            f"[dim]Global min nodes (PDB/anti-affinity): "
            f"{sizing.global_min_nodes_from_constraints}[/dim]"
        )

    def _render_sizing_table(self, sizing: ClusterSizing) -> None:
        self.console.print("\n[bold]Sizing Recommendations[/bold]")
        table = Table(box=box.ROUNDED, show_header=True, header_style="bold cyan")
        table.add_column("Wariant", style="bold")
        table.add_column("Rozmiar node'a", justify="center")
        table.add_column("Liczba\nworkerów", justify="center")
        table.add_column("CPU util\n(N-1 active)", justify="right")
        table.add_column("RAM util\n(N-1 active)", justify="right")
        table.add_column("Driver", style="dim")

        for v in sizing.sizing_variants:
            if v.driver == "unusable":
                continue

            label = f"[bold green][★] {v.node_variant.label}[/bold green]" if v.is_recommended else v.node_variant.label
            node_size = f"{v.node_variant.cpu_cores}CPU / {v.node_variant.memory_gib}GiB"
            count = f"[bold]{v.worker_count}[/bold]" if v.is_recommended else str(v.worker_count)
            cpu_pct = self._colorize_pct(v.utilization_cpu_pct)
            mem_pct = self._colorize_pct(v.utilization_mem_pct)

            table.add_row(label, node_size, count, cpu_pct, mem_pct, v.driver)

        self.console.print(table)
        self.console.print("[dim][★] = rekomendowany wariant (najbliżej 75% target utilization)[/dim]")

    def _render_warnings(self, sizing: ClusterSizing) -> None:
        all_warnings = []
        for v in sizing.sizing_variants:
            for w in v.warnings:
                all_warnings.append(f"[{v.node_variant.label}] {w}")

        if all_warnings:
            self.console.print("\n[bold yellow]Ostrzeżenia:[/bold yellow]")
            for w in all_warnings:
                self.console.print(f"  [yellow]⚠[/yellow]  {w}")

    @staticmethod
    def _colorize_pct(pct: float) -> str:
        p = pct * 100
        if p >= 90:
            return f"[red]{p:.1f}%[/red]"
        if p >= 75:
            return f"[yellow]{p:.1f}%[/yellow]"
        if p > 0:
            return f"[green]{p:.1f}%[/green]"
        return "-"
