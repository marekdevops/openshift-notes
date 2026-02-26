"""Renderowanie raportu HTML przez Jinja2."""

from __future__ import annotations

from pathlib import Path
from datetime import datetime
from jinja2 import Environment, FileSystemLoader

from ..models.sizing import ClusterSizing
from ..models.resources import ResourceSpec
from ..utils.units import fmt_cpu as _fmt_cpu, fmt_mem as _fmt_mem, fmt_pct


def _fmt_cpu_filter(spec_or_int) -> str:
    if isinstance(spec_or_int, ResourceSpec):
        return _fmt_cpu(spec_or_int.cpu_millicores)
    return _fmt_cpu(int(spec_or_int))


def _fmt_mem_filter(spec_or_int) -> str:
    if isinstance(spec_or_int, ResourceSpec):
        return _fmt_mem(spec_or_int.memory_bytes)
    return _fmt_mem(int(spec_or_int))


class HtmlRenderer:
    """Renderuje ClusterSizing do pliku HTML."""

    def __init__(self, template_dir: Path | None = None):
        if template_dir is None:
            template_dir = Path(__file__).parent.parent / "templates"
        self.env = Environment(
            loader=FileSystemLoader(str(template_dir)),
            autoescape=True,
        )
        self.env.filters["fmt_cpu"] = _fmt_cpu_filter
        self.env.filters["fmt_mem"] = _fmt_mem_filter
        self.env.filters["fmt_pct"] = fmt_pct

    def render(self, sizing: ClusterSizing, output_path: Path) -> None:
        """Renderuje raport i zapisuje do pliku."""
        template = self.env.get_template("report.html.j2")
        html = template.render(sizing=sizing)
        output_path.write_text(html, encoding="utf-8")
        print(f"Raport HTML zapisany: {output_path.resolve()}")
