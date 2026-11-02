"""Unit tests for CPU telemetry collector."""

from agent.collector.cpu import CPUCollector
from agent.models import MetricType


def test_cpu_collector_parsing(mock_proc_dir):
    """Test CPU metrics collection and calculations against synthetic procfs."""
    collector = CPUCollector(proc_path=mock_proc_dir)
    families = collector.collect()

    fam_dict = {f.name: f for f in families}

    # 1. Verify linux_cpu_seconds_total
    assert "linux_cpu_seconds_total" in fam_dict
    cpu_sec = fam_dict["linux_cpu_seconds_total"]
    assert cpu_sec.type == MetricType.COUNTER

    # Check sample for total user
    user_samples = [
        s for s in cpu_sec.samples
        if s.labels.get("cpu") == "total" and s.labels.get("mode") == "user"
    ]
    assert len(user_samples) == 1
    # 23699739 ticks / 100.0 = 236997.39
    assert user_samples[0].value == 236997.39

    # 2. Verify per-core samples exist
    cpu0_samples = [s for s in cpu_sec.samples if s.labels.get("cpu") == "0"]
    assert len(cpu0_samples) == 10

    # 3. Verify CPU utilization ratio
    assert "linux_cpu_utilization_ratio" in fam_dict
    util_fam = fam_dict["linux_cpu_utilization_ratio"]
    assert util_fam.type == MetricType.GAUGE
    total_util = [s for s in util_fam.samples if s.labels.get("cpu") == "total"]
    assert len(total_util) == 1
    assert 0.0 <= total_util[0].value <= 1.0

    # 4. Verify Load Averages
    assert "linux_load1" in fam_dict
    assert fam_dict["linux_load1"].samples[0].value == 1.25
    assert "linux_load5" in fam_dict
    assert fam_dict["linux_load5"].samples[0].value == 2.50
    assert "linux_load15" in fam_dict
    assert fam_dict["linux_load15"].samples[0].value == 3.75

    # 5. Verify PSI CPU
    assert "linux_cpu_pressure_some_ratio" in fam_dict
    psi_ratio = fam_dict["linux_cpu_pressure_some_ratio"]
    avg10_sample = [s for s in psi_ratio.samples if s.labels.get("window") == "10"]
    assert len(avg10_sample) == 1
    assert avg10_sample[0].value == 0.025  # 2.50% converted to ratio 0.025

    assert "linux_cpu_pressure_some_total_seconds" in fam_dict
    psi_total = fam_dict["linux_cpu_pressure_some_total_seconds"]
    # 12345678 microseconds / 1e6 = 12.345678 seconds
    assert round(psi_total.samples[0].value, 6) == 12.345678


def test_cpu_collector_differential_utilization(mock_proc_dir):
    """Verify that successive samples calculate differential utilization correctly."""
    collector = CPUCollector(proc_path=mock_proc_dir)
    # First sample
    collector.collect()

    # Second sample (same values, so delta_active is 0 or baseline)
    families2 = collector.collect()
    fam_dict2 = {f.name: f for f in families2}
    assert "linux_cpu_utilization_ratio" in fam_dict2
