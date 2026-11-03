"""Unit tests for Systemd service collector."""

import subprocess
from agent.collector.systemd import SystemdCollector
from agent.config import SystemdConfig
from agent.models import MetricType


def test_systemd_collector_active_and_inactive():
    """Verify active and inactive state parsing for monitored systemd units."""
    def mock_runner(cmd, **kwargs):
        unit = cmd[2]
        if unit == "ssh.service":
            return subprocess.CompletedProcess(
                args=cmd,
                returncode=0,
                stdout="ActiveState=active\nSubState=running\nLoadState=loaded\n",
            )
        elif unit == "cron.service":
            return subprocess.CompletedProcess(
                args=cmd,
                returncode=0,
                stdout="ActiveState=inactive\nSubState=dead\nLoadState=loaded\n",
            )
        return subprocess.CompletedProcess(args=cmd, returncode=1, stdout="")

    config = SystemdConfig(monitored_units=["ssh.service", "cron.service", "missing.service"])
    collector = SystemdCollector(config=config, runner_func=mock_runner)
    families = collector.collect()
    fam_dict = {f.name: f for f in families}

    assert "linux_systemd_unit_active" in fam_dict
    active_fam = fam_dict["linux_systemd_unit_active"]
    assert active_fam.type == MetricType.GAUGE

    ssh_sample = [s for s in active_fam.samples if s.labels.get("unit") == "ssh.service"][0]
    assert ssh_sample.value == 1.0

    cron_sample = [s for s in active_fam.samples if s.labels.get("unit") == "cron.service"][0]
    assert cron_sample.value == 0.0

    missing_sample = [s for s in active_fam.samples if s.labels.get("unit") == "missing.service"][0]
    assert missing_sample.value == 0.0

    assert "linux_systemd_service_collector_errors_total" in fam_dict
    err_fam = fam_dict["linux_systemd_service_collector_errors_total"]
    assert err_fam.samples[0].value == 1.0  # missing.service failed returncode


def test_systemd_collector_timeout_and_missing_binary():
    """Verify timeout and missing binary do not crash the collector."""
    def timeout_runner(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=1.0)

    config = SystemdConfig(monitored_units=["ssh.service"])
    collector = SystemdCollector(config=config, runner_func=timeout_runner)
    families = collector.collect()
    fam_dict = {f.name: f for f in families}

    assert fam_dict["linux_systemd_unit_active"].samples[0].value == 0.0
    assert fam_dict["linux_systemd_service_collector_errors_total"].samples[0].value == 1.0


def test_systemd_collector_query_batch():
    """Verify batch systemctl show output parsing across multiple units."""
    batch_stdout = (
        "Id=ssh.service\n"
        "LoadState=loaded\n"
        "ActiveState=active\n"
        "SubState=running\n\n"
        "Id=cron.service\n"
        "LoadState=loaded\n"
        "ActiveState=inactive\n"
        "SubState=dead\n"
    )

    def batch_runner(cmd, **kwargs):
        return subprocess.CompletedProcess(args=cmd, returncode=0, stdout=batch_stdout)

    config = SystemdConfig(monitored_units=["ssh.service", "cron.service"])
    collector = SystemdCollector(config=config, runner_func=batch_runner)
    batch_res = collector._query_batch()

    assert "ssh.service" in batch_res
    assert batch_res["ssh.service"]["ActiveState"] == "active"
    assert "cron.service" in batch_res
    assert batch_res["cron.service"]["ActiveState"] == "inactive"

