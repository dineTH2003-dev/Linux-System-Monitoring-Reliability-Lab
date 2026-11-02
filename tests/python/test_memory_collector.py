"""Unit tests for Memory telemetry collector."""

from agent.collector.memory import MemoryCollector
from agent.models import MetricType


def test_memory_collector_parsing(mock_proc_dir):
    """Test memory metrics collection and calculations against synthetic procfs."""
    collector = MemoryCollector(proc_path=mock_proc_dir)
    families = collector.collect()

    fam_dict = {f.name: f for f in families}

    # 1. Total bytes: 16068168 kB * 1024 = 16453804032 bytes
    assert "linux_memory_total_bytes" in fam_dict
    assert fam_dict["linux_memory_total_bytes"].type == MetricType.GAUGE
    assert fam_dict["linux_memory_total_bytes"].samples[0].value == 16068168 * 1024

    # 2. Available bytes: 4028776 kB * 1024 = 4125466624 bytes
    assert "linux_memory_available_bytes" in fam_dict
    assert fam_dict["linux_memory_available_bytes"].samples[0].value == 4028776 * 1024

    # 3. Free bytes: 1363636 kB * 1024 = 1396363264 bytes
    assert "linux_memory_free_bytes" in fam_dict
    assert fam_dict["linux_memory_free_bytes"].samples[0].value == 1363636 * 1024

    # 4. Used bytes: MemTotal - MemAvailable
    assert "linux_memory_used_bytes" in fam_dict
    expected_used = (16068168 - 4028776) * 1024
    assert fam_dict["linux_memory_used_bytes"].samples[0].value == expected_used

    # 5. Cached & Buffers
    assert "linux_memory_cached_bytes" in fam_dict
    assert fam_dict["linux_memory_cached_bytes"].samples[0].value == 7612652 * 1024
    assert "linux_memory_buffers_bytes" in fam_dict
    assert fam_dict["linux_memory_buffers_bytes"].samples[0].value == 63896 * 1024

    # 6. Custom memory saturation marker
    assert "linux_custom_memory_pressure" in fam_dict
    sat_sample = fam_dict["linux_custom_memory_pressure"].samples[0]
    assert sat_sample.labels.get("type") == "saturation"
    expected_ratio = (16068168 - 4028776) / 16068168
    assert round(sat_sample.value, 4) == round(expected_ratio, 4)

    # 7. Memory PSI
    assert "linux_memory_pressure_ratio" in fam_dict
    psi_ratio = fam_dict["linux_memory_pressure_ratio"]
    some_avg10 = [
        s for s in psi_ratio.samples
        if s.labels.get("type") == "some" and s.labels.get("window") == "10"
    ]
    assert len(some_avg10) == 1
    assert some_avg10[0].value == 0.005  # 0.50% / 100

    full_avg10 = [
        s for s in psi_ratio.samples
        if s.labels.get("type") == "full" and s.labels.get("window") == "10"
    ]
    assert len(full_avg10) == 1
    assert full_avg10[0].value == 0.001  # 0.10% / 100

    assert "linux_memory_pressure_total_seconds" in fam_dict
    psi_total = fam_dict["linux_memory_pressure_total_seconds"]
    some_tot = [s for s in psi_total.samples if s.labels.get("type") == "some"]
    assert round(some_tot[0].value, 4) == round(4567890 / 1e6, 4)
