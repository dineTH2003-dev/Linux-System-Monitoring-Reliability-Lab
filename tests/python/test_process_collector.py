"""Unit tests for Process telemetry collector."""

from agent.collector.process import ProcessCollector
from agent.config import ProcessFilterConfig
from agent.models import MetricType


def test_process_collector_synthetic_proc(mock_proc_dir):
    """Test process states, counts, and resource usage using synthetic procfs entries."""
    filter_config = ProcessFilterConfig(
        max_processes=100,
        top_n_cpu=2,
        top_n_mem=2,
        sanitize_names=True,
    )
    collector = ProcessCollector(
        proc_path=mock_proc_dir,
        filter_config=filter_config,
        use_psutil=False,  # Force synthetic /proc parser
    )
    families = collector.collect()
    fam_dict = {f.name: f for f in families}

    assert "linux_process_count" in fam_dict
    count_fam = fam_dict["linux_process_count"]
    assert count_fam.type == MetricType.GAUGE

    # In mock_proc_dir:
    # PID 101: systemd -> 'sleeping'
    # PID 202: python3 -> 'running'
    # PID 303: defunct_proc -> 'zombie'
    state_map = {s.labels.get("state"): s.value for s in count_fam.samples}
    assert state_map.get("running") == 1
    assert state_map.get("sleeping") == 1
    assert state_map.get("zombie") == 1

    assert "linux_process_total" in fam_dict
    assert fam_dict["linux_process_total"].samples[0].value == 3

    assert "linux_process_memory_consumption_bytes" in fam_dict
    mem_fam = fam_dict["linux_process_memory_consumption_bytes"]
    names = [s.labels.get("name") for s in mem_fam.samples]
    # Sanitized names should be present
    assert "python3" in names or "systemd" in names


def test_process_collector_bounded_iteration(mock_proc_dir):
    """Verify that max_processes strictly limits directory iteration."""
    filter_config = ProcessFilterConfig(
        max_processes=1,  # Only process 1 PID
        top_n_cpu=1,
        top_n_mem=1,
    )
    collector = ProcessCollector(
        proc_path=mock_proc_dir,
        filter_config=filter_config,
        use_psutil=False,
    )
    families = collector.collect()
    fam_dict = {f.name: f for f in families}
    assert fam_dict["linux_process_total"].samples[0].value == 1


def test_process_name_sanitization():
    """Verify that process names with control characters, paths, and length are sanitized."""
    collector = ProcessCollector(use_psutil=False)
    assert collector._sanitize_name("/usr/bin/../../secret_app") == "secret_app"
    assert collector._sanitize_name("my_daemon; rm -rf /") == "my_daemon__rm_-rf"
    assert len(collector._sanitize_name("a" * 100)) == 32
