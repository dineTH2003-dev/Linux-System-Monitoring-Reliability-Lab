"""Unit tests for Swap telemetry collector."""

from agent.collector.swap import SwapCollector
from agent.models import MetricType


def test_swap_collector_parsing(mock_proc_dir):
    """Test swap metrics collection and page counter parsing against synthetic procfs."""
    collector = SwapCollector(proc_path=mock_proc_dir)
    families = collector.collect()

    fam_dict = {f.name: f for f in families}

    # 1. Total Swap: 4194300 kB * 1024
    assert "linux_swap_total_bytes" in fam_dict
    assert fam_dict["linux_swap_total_bytes"].type == MetricType.GAUGE
    assert fam_dict["linux_swap_total_bytes"].samples[0].value == 4194300 * 1024

    # 2. Free Swap: 3552200 kB * 1024
    assert "linux_swap_free_bytes" in fam_dict
    assert fam_dict["linux_swap_free_bytes"].samples[0].value == 3552200 * 1024

    # 3. Used Swap: (4194300 - 3552200) * 1024
    assert "linux_swap_used_bytes" in fam_dict
    expected_used = (4194300 - 3552200) * 1024
    assert fam_dict["linux_swap_used_bytes"].samples[0].value == expected_used

    # 4. Swap In/Out Pages
    assert "linux_swap_in_pages_total" in fam_dict
    assert fam_dict["linux_swap_in_pages_total"].type == MetricType.COUNTER
    assert fam_dict["linux_swap_in_pages_total"].samples[0].value == 989217

    assert "linux_swap_out_pages_total" in fam_dict
    assert fam_dict["linux_swap_out_pages_total"].type == MetricType.COUNTER
    assert fam_dict["linux_swap_out_pages_total"].samples[0].value == 2369821
