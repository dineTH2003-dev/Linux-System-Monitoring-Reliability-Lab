"""Collector registry, fault containment orchestrator, and Prometheus exposition formatter."""

import platform
import time
from typing import Dict, List

from agent import __version__
from agent.collector.base import BaseCollector
from agent.logger import setup_logger
from agent.models import MetricFamily, MetricType


class MetricRegistry:
    """Orchestrates collectors, isolates faults, and serializes metrics into Prometheus exposition format."""

    def __init__(self) -> None:
        self._collectors: List[BaseCollector] = []
        self._logger = setup_logger("agent.registry")
        self._error_counts: Dict[str, int] = {}

    def register(self, collector: BaseCollector) -> None:
        """Register a new telemetry collector."""
        self._collectors.append(collector)
        self._error_counts[collector.name] = 0

    def collect_all(self) -> List[MetricFamily]:
        """Execute all collectors with fault isolation, recording health and duration telemetry."""
        all_families: List[MetricFamily] = []

        success_fam = MetricFamily(
            name="linux_agent_collector_success",
            type=MetricType.GAUGE,
            documentation="Collector execution outcome (1 = success, 0 = failure).",
        )
        duration_fam = MetricFamily(
            name="linux_agent_collector_duration_seconds",
            type=MetricType.GAUGE,
            documentation="Execution duration of each collector in seconds.",
        )
        errors_fam = MetricFamily(
            name="linux_agent_collector_errors_total",
            type=MetricType.COUNTER,
            documentation="Cumulative count of unhandled collector execution failures.",
        )

        for collector in self._collectors:
            start_time = time.time()
            collector_success = 1.0
            try:
                families = collector.collect()
                all_families.extend(families)
            except Exception as e:
                collector_success = 0.0
                self._error_counts[collector.name] = self._error_counts.get(collector.name, 0) + 1
                self._logger.error(
                    f"Collector '{collector.name}' encountered an unhandled exception: {e}",
                    exc_info=True,
                    extra={"collector": collector.name},
                )
            finally:
                duration = time.time() - start_time
                success_fam.add_sample(labels={"collector": collector.name}, value=collector_success)
                duration_fam.add_sample(labels={"collector": collector.name}, value=duration)
                errors_fam.add_sample(
                    labels={"collector": collector.name},
                    value=self._error_counts.get(collector.name, 0),
                )

        # Agent build metadata
        info_fam = MetricFamily(
            name="linux_agent_build_info",
            type=MetricType.GAUGE,
            documentation="Agent build and runtime environment metadata.",
        )
        info_fam.add_sample(
            labels={
                "version": __version__,
                "python_version": platform.python_version(),
                "system": platform.system(),
            },
            value=1.0,
        )

        all_families.extend([success_fam, duration_fam, errors_fam, info_fam])
        return all_families

    @staticmethod
    def _escape_label_value(val: str) -> str:
        """Escape backslashes, double quotes, and newlines in Prometheus label values."""
        return val.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

    @staticmethod
    def _escape_help(text: str) -> str:
        """Escape backslashes and newlines in Prometheus HELP documentation."""
        return text.replace("\\", "\\\\").replace("\n", "\\n")

    def format_prometheus(self) -> str:
        """Serialize all collected metric families into Prometheus 0.0.4 text format."""
        families = self.collect_all()
        lines: List[str] = []

        for family in families:
            if not family.samples:
                continue

            # # HELP <name> <doc>
            escaped_doc = self._escape_help(family.documentation)
            lines.append(f"# HELP {family.name} {escaped_doc}")

            # # TYPE <name> <type>
            lines.append(f"# TYPE {family.name} {family.type.value}")

            # Metric samples
            for sample in family.samples:
                if sample.labels:
                    label_str = ",".join(
                        f'{k}="{self._escape_label_value(str(v))}"'
                        for k, v in sorted(sample.labels.items())
                    )
                    sample_line = f"{sample.name}{{{label_str}}} {sample.value}"
                else:
                    sample_line = f"{sample.name} {sample.value}"

                if sample.timestamp is not None:
                    sample_line += f" {int(sample.timestamp * 1000)}"

                lines.append(sample_line)

        # Prometheus text format requires a trailing newline
        return "\n".join(lines) + "\n"
