"""Tests for SRE reliability safety boundaries and invariant guards."""

import subprocess
import pytest


def run_bash_func(func_call: str) -> subprocess.CompletedProcess:
    """Helper to run a function from scripts/reliability/common.sh."""
    cmd = f"source scripts/reliability/common.sh && {func_call}"
    return subprocess.run(
        ["bash", "-c", cmd],
        capture_output=True,
        text=True,
    )


def test_assert_not_root_mount_rejects_root():
    """Verify that targeting the root filesystem is unconditionally blocked."""
    res = run_bash_func('assert_not_root_mount "/"')
    assert res.returncode != 0
    assert "SAFETY VIOLATION" in res.stderr
    assert "Refusing to target root filesystem" in res.stderr


def test_assert_not_root_mount_rejects_system_dirs():
    """Verify that targeting critical system directories (/boot, /etc, /usr) is blocked."""
    for sys_dir in ["/boot", "/etc", "/usr", "/var/lib"]:
        res = run_bash_func(f'assert_not_root_mount "{sys_dir}"')
        assert res.returncode != 0
        assert "SAFETY VIOLATION" in res.stderr


def test_assert_not_root_mount_allows_safe_temp():
    """Verify that valid temporary lab directories are permitted."""
    res = run_bash_func('assert_not_root_mount "/tmp/lab_test_mount"')
    assert res.returncode == 0


def test_assert_safe_timeout_validates_bounds():
    """Verify that timeouts outside safe range (1-300s) or non-integers fail."""
    # Negative
    assert run_bash_func('assert_safe_timeout -5 60').returncode != 0
    # Zero
    assert run_bash_func('assert_safe_timeout 0 60').returncode != 0
    # Exceeding max
    assert run_bash_func('assert_safe_timeout 100 60').returncode != 0
    # String
    assert run_bash_func('assert_safe_timeout "abc" 60').returncode != 0
    # Valid
    assert run_bash_func('assert_safe_timeout 30 60').returncode == 0


def test_assert_whitelisted_enforces_membership():
    """Verify whitelist validation blocks unauthorized targets."""
    whitelist = 'items=("agent" "systemd_canary" "test_fs")'
    # Authorized
    res = run_bash_func(f'{whitelist} && assert_whitelisted "agent" "${{items[@]}}"')
    assert res.returncode == 0

    # Unauthorized
    res = run_bash_func(f'{whitelist} && assert_whitelisted "production_db" "${{items[@]}}"')
    assert res.returncode != 0
    assert "SAFETY VIOLATION" in res.stderr


def test_cpu_contention_rejects_excessive_cores():
    """Verify inject_cpu_contention.sh rejects >4 cores to preserve host stability."""
    res = subprocess.run(
        ["bash", "scripts/reliability/inject_cpu_contention.sh", "10", "8"],
        capture_output=True,
        text=True,
    )
    assert res.returncode != 0
    assert "SAFETY VIOLATION" in res.stderr
    assert "must be between 1 and 4" in res.stderr


def test_memory_pressure_rejects_unbounded_ram():
    """Verify inject_memory_pressure.sh rejects RAM allocation >1024MB."""
    res = subprocess.run(
        ["bash", "scripts/reliability/inject_memory_pressure.sh", "10", "4096"],
        capture_output=True,
        text=True,
    )
    assert res.returncode != 0
    assert "SAFETY VIOLATION" in res.stderr
    assert "must be bounded" in res.stderr


def test_filesystem_capacity_rejects_root():
    """Verify inject_filesystem_capacity.sh refuses to target root."""
    res = subprocess.run(
        ["bash", "scripts/reliability/inject_filesystem_capacity.sh", "/"],
        capture_output=True,
        text=True,
    )
    assert res.returncode != 0
    assert "SAFETY VIOLATION" in res.stderr
