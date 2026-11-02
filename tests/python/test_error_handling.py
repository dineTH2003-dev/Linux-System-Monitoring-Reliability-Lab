"""Unit tests for error handling, fault containment, and missing interface resilience."""

from agent.collector.cpu import CPUCollector
from agent.collector.disk_io import DiskIOCollector
from agent.collector.memory import MemoryCollector
from agent.collector.network import NetworkCollector
from agent.collector.swap import SwapCollector
from agent.models import MetricFamily, MetricType
from agent.registry import MetricRegistry


def test_registry_fault_isolation():
    """Verify that a crashing collector does not abort scrape of other collectors."""
    registry = MetricRegistry()

    class FaultyCollector:
        name = "faulty_collector"

        def collect(self):
            raise RuntimeError("Hardware bus failure or unexpected panic")

    class HealthyCollector:
        name = "healthy_collector"

        def collect(self):
            fam = MetricFamily(
                name="healthy_metric",
                type=MetricType.GAUGE,
                documentation="Should be collected successfully.",
            )
            fam.add_sample(value=100.0)
            return [fam]

    registry.register(FaultyCollector())
    registry.register(HealthyCollector())

    output = registry.format_prometheus()

    # Healthy metric should be present in output
    assert "healthy_metric 100.0" in output

    # Faulty collector telemetry
    assert 'linux_agent_collector_success{collector="faulty_collector"} 0.0' in output
    assert 'linux_agent_collector_success{collector="healthy_collector"} 1.0' in output
    assert 'linux_agent_collector_errors_total{collector="faulty_collector"} 1.0' in output
    assert 'linux_agent_collector_errors_total{collector="healthy_collector"} 0.0' in output


def test_collectors_missing_proc_files():
    """Verify all collectors handle nonexistent proc paths without unhandled crashes."""
    nonexistent_path = "/nonexistent/test/proc"

    cpu_col = CPUCollector(proc_path=nonexistent_path)
    assert cpu_col.collect() == []

    mem_col = MemoryCollector(proc_path=nonexistent_path)
    assert mem_col.collect() == []

    swap_col = SwapCollector(proc_path=nonexistent_path)
    assert swap_col.collect() == []

    disk_col = DiskIOCollector(proc_path=nonexistent_path)
    assert disk_col.collect() == []

    net_col = NetworkCollector(proc_path=nonexistent_path)
    assert net_col.collect() == []
