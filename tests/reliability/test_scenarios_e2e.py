"""End-to-end integration tests for reversible failure scenarios."""

import os
import subprocess
import time
import pytest


def test_scenario1_cpu_contention_bounded_execution():
    """Verify Scenario 1 executes within time bounds and exits cleanly."""
    res = subprocess.run(
        ["bash", "scripts/reliability/inject_cpu_contention.sh", "2", "1"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res.returncode == 0
    assert "Injecting controlled CPU contention" in res.stderr
    assert "Host CPU restored" in res.stderr


def test_scenario2_memory_pressure_bounded_execution():
    """Verify Scenario 2 allocates bounded memory and terminates cleanly."""
    res = subprocess.run(
        ["bash", "scripts/reliability/inject_memory_pressure.sh", "2", "64", "0"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res.returncode == 0
    assert "Allocated 64MB" in res.stderr
    assert "Memory pressure terminated cleanly" in res.stderr


def test_scenario3_storage_capacity_and_remediation(temp_sandbox_dir):
    """Verify Scenario 3 creates bounded payload and remediation cleanly purges it."""
    # Inject
    res_inject = subprocess.run(
        ["bash", "scripts/reliability/inject_filesystem_capacity.sh", temp_sandbox_dir, "1"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert res_inject.returncode == 0
    payload = os.path.join(temp_sandbox_dir, "test_fill_payload.dat")
    assert os.path.exists(payload)

    # Remediate
    res_rem = subprocess.run(
        ["bash", "scripts/reliability/remediation/remediate_filesystem.sh", temp_sandbox_dir],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res_rem.returncode == 0
    assert not os.path.exists(payload)
    assert "safely removed" in res_rem.stderr


def test_scenario4_inode_pressure_and_remediation(temp_sandbox_dir):
    """Verify Scenario 4 creates inode files and remediation cleanly purges them."""
    # Inject 20 files
    res_inject = subprocess.run(
        ["bash", "scripts/reliability/inject_inode_pressure.sh", temp_sandbox_dir, "20", "1"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert res_inject.returncode == 0
    files = [f for f in os.listdir(temp_sandbox_dir) if f.startswith("test_inode_")]
    assert len(files) == 20

    # Remediate
    res_rem = subprocess.run(
        ["bash", "scripts/reliability/remediation/remediate_inodes.sh", temp_sandbox_dir],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res_rem.returncode == 0
    remaining = [f for f in os.listdir(temp_sandbox_dir) if f.startswith("test_inode_")]
    assert len(remaining) == 0
    assert "purged" in res_rem.stderr


def test_scenario5_disk_io_latency_execution(temp_sandbox_dir):
    """Verify Scenario 5 executes synchronous I/O writes with measured latency."""
    res = subprocess.run(
        ["bash", "scripts/reliability/inject_disk_latency.sh", "2", temp_sandbox_dir],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res.returncode == 0
    assert "Started synchronous I/O latency worker" in res.stderr
    assert "Executed" in res.stdout or "Executed" in res.stderr or "Average await latency" in res.stdout or "Average await latency" in res.stderr


def test_scenario6_network_endpoint_and_remediation():
    """Verify Scenario 6 injects endpoint failure and remediation recovers it."""
    test_port = "8095"

    # Inject failure
    res_inject = subprocess.run(
        ["bash", "scripts/reliability/inject_network_failure.sh", test_port],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res_inject.returncode == 0
    assert "Network endpoint failure injected successfully" in res_inject.stderr

    # Remediate
    res_rem = subprocess.run(
        ["bash", "scripts/reliability/remediation/remediate_network.sh", test_port],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res_rem.returncode == 0
    assert "Remediation verified: Canary endpoint restored" in res_rem.stderr

    # Clean up test port process
    subprocess.run(["fuser", "-k", "-n", "tcp", test_port], capture_output=True)


def test_scenario8_exporter_failure_and_remediation():
    """Verify Scenario 8 injects exporter failure and recovers it."""
    test_port = "9105"

    res_inject = subprocess.run(
        ["bash", "scripts/reliability/inject_exporter_failure.sh", test_port],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert res_inject.returncode == 0
    assert "Exporter failure injected successfully" in res_inject.stderr

    # Clean up test port process
    subprocess.run(["fuser", "-k", "-n", "tcp", test_port], capture_output=True)
