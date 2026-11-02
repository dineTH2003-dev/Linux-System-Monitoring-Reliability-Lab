"""Deployment safety regression and contract tests for Phase E.5.1.

Validates:
1. Placeholder password rejection in deploy.sh preflight.
2. Missing .env rejection without silent copy.
3. Insecure .env permissions rejection (must be 0600 or 0400).
4. All Compose ports bound strictly to 127.0.0.1 (localhost).
5. No deployment or operational scripts tamper with native host services.
6. No deployment script deletes or prunes persistent Docker volumes.
7. Idempotent `deploy.sh up` does not invoke unnecessary teardown.
8. Preflight failure strictly aborts deployment in `deploy.sh up`.
9. Alloy user identity (0:999) and container hardening (read_only, cap_drop, no-new-privileges).
10. Accurate documentation of Alloy primary GID 999 and UID 0 volume ownership rationale.
"""

import os
import re
import stat
import subprocess
import tempfile
import pytest
import yaml

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
DEPLOY_SH = os.path.join(REPO_ROOT, "deployment/deploy.sh")
COMPOSE_FILE = os.path.join(REPO_ROOT, "docker-compose.yml")
SYS_ARCH_DOC = os.path.join(REPO_ROOT, "docs/architecture/system-architecture.md")


def test_placeholder_password_rejected():
    """Verify that deploy.sh preflight rejects the default placeholder password."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create a mock repo environment with .env containing placeholder
        env_file = os.path.join(tmpdir, ".env")
        placeholder = "CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS"
        with open(env_file, "w", encoding="utf-8") as f:
            f.write(f"GF_SECURITY_ADMIN_PASSWORD={placeholder}\n")
        os.chmod(env_file, 0o600)

        # Run preflight with this temp .env
        env = os.environ.copy()
        env["ENV_FILE"] = env_file
        # Provide a dummy compose file so compose config check isn't the failure point
        dummy_compose = os.path.join(tmpdir, "docker-compose.yml")
        with open(dummy_compose, "w", encoding="utf-8") as f:
            f.write("services:\n  dummy:\n    image: busybox:latest\n")
        env["COMPOSE_FILE"] = dummy_compose

        cmd = ["bash", DEPLOY_SH, "preflight"]
        result = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        assert result.returncode != 0, f"Preflight succeeded unexpectedly with placeholder password! Output: {result.stdout}\n{result.stderr}"
        combined_output = result.stdout + result.stderr
        assert "placeholder" in combined_output.lower() or "changeme" in combined_output.lower()
        # Verify secret itself is not leaked/printed in the failure message
        assert placeholder not in combined_output, "Preflight leaked the secret password value in output!"


def test_missing_env_rejected():
    """Verify that deploy.sh preflight rejects a missing .env file without copying .env.example."""
    with tempfile.TemporaryDirectory() as tmpdir:
        nonexistent_env = os.path.join(tmpdir, "nonexistent.env")
        example_env = os.path.join(tmpdir, ".env.example")
        with open(example_env, "w", encoding="utf-8") as f:
            f.write("TEST_VAR=123\n")

        env = os.environ.copy()
        env["ENV_FILE"] = nonexistent_env

        cmd = ["bash", DEPLOY_SH, "preflight"]
        result = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        assert result.returncode != 0, "Preflight succeeded despite missing .env file!"
        assert not os.path.exists(nonexistent_env), "Preflight auto-created or copied missing .env file unexpectedly!"


def test_insecure_env_permissions_rejected():
    """Verify that deploy.sh preflight requires exactly 0600 and rejects 0400, 0644, 0664, etc."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env_file = os.path.join(tmpdir, ".env")
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("GF_SECURITY_ADMIN_PASSWORD=a_valid_custom_secure_password_12345\n")

        env = os.environ.copy()
        env["ENV_FILE"] = env_file
        dummy_compose = os.path.join(tmpdir, "docker-compose.yml")
        with open(dummy_compose, "w", encoding="utf-8") as f:
            f.write("services:\n  dummy:\n    image: busybox:latest\n")
        env["COMPOSE_FILE"] = dummy_compose

        # Test rejected permissions: 0400, 0644, 0664
        for bad_mode, mode_octal in [("0400", 0o400), ("0644", 0o644), ("0664", 0o664)]:
            os.chmod(env_file, mode_octal)
            res = subprocess.run(["bash", DEPLOY_SH, "preflight"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            assert res.returncode != 0, f"Preflight unexpectedly accepted mode {bad_mode} on .env!"
            assert "exactly 0600" in (res.stdout + res.stderr) or "invalid permissions" in (res.stdout + res.stderr).lower()

        # Test required exact permission: 0600
        os.chmod(env_file, 0o600)
        res_sec = subprocess.run(["bash", "-c", f". {DEPLOY_SH}; cmd_preflight"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert "invalid permissions on .env" not in (res_sec.stdout + res_sec.stderr).lower()


def test_compose_ports_bind_localhost():
    """Verify that all published ports in Compose files bind explicitly to 127.0.0.1 or ${HOST_BIND_IP:-127.0.0.1}."""
    compose_files = [COMPOSE_FILE, os.path.join(REPO_ROOT, "loki/docker-compose.yml")]
    for path in compose_files:
        if not os.path.isfile(path):
            continue
        with open(path, "r", encoding="utf-8") as f:
            content = yaml.safe_load(f)

        services = content.get("services", {})
        for svc_name, svc_cfg in services.items():
            ports = svc_cfg.get("ports", [])
            for p in ports:
                port_str = str(p)
                assert port_str.startswith("127.0.0.1:") or port_str.startswith("${HOST_BIND_IP:-127.0.0.1}:"), (
                    f"Service '{svc_name}' in {path} publishes port '{port_str}' not bound to 127.0.0.1"
                )

    # Also verify .env.example defines HOST_BIND_IP as 127.0.0.1
    env_example = os.path.join(REPO_ROOT, ".env.example")
    with open(env_example, "r", encoding="utf-8") as f:
        env_example_content = f.read()
    assert "HOST_BIND_IP=127.0.0.1" in env_example_content, "HOST_BIND_IP not defaulting to 127.0.0.1 in .env.example"


def test_no_native_service_tampering():
    """Verify no scripts stop, disable, or mask native systemd services."""
    scripts_to_check = [
        os.path.join(REPO_ROOT, "deployment/deploy.sh"),
        os.path.join(REPO_ROOT, "deployment/stop.sh"),
        os.path.join(REPO_ROOT, "deployment/rollback.sh"),
        os.path.join(REPO_ROOT, "deployment/healthcheck.sh"),
        os.path.join(REPO_ROOT, "deployment/backup.sh"),
        os.path.join(REPO_ROOT, "deployment/restore.sh"),
    ]

    forbidden_patterns = [
        r"systemctl\s+(stop|disable|mask|restart)\s+(prometheus|grafana|node[-_]exporter)",
        r"service\s+(prometheus|grafana|node[-_]exporter)\s+stop",
    ]

    for script in scripts_to_check:
        if not os.path.isfile(script):
            continue
        with open(script, "r", encoding="utf-8") as f:
            content = f.read()
        for pat in forbidden_patterns:
            match = re.search(pat, content, re.IGNORECASE)
            assert not match, f"Script {script} contains forbidden host service command: {match.group(0)}"


def test_no_volume_deletion_in_deploy_script():
    """Verify that deployment/deploy.sh never deletes or prunes persistent Docker volumes."""
    with open(DEPLOY_SH, "r", encoding="utf-8") as f:
        content = f.read()

    assert "volume rm" not in content, "deploy.sh contains 'docker volume rm'"
    assert "down -v" not in content, "deploy.sh contains 'docker compose down -v'"
    assert "volume prune" not in content, "deploy.sh contains 'docker volume prune'"


def test_idempotent_up_no_unnecessary_teardown():
    """Verify that deploy.sh up is idempotent and does not execute teardown beforehand."""
    with open(DEPLOY_SH, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # Locate cmd_up function definition
    inside_cmd_up = False
    cmd_up_lines = []
    for line in lines:
        if line.strip().startswith("cmd_up()"):
            inside_cmd_up = True
            continue
        if inside_cmd_up:
            if line.strip().startswith("cmd_") or line.strip().startswith("main()"):
                break
            cmd_up_lines.append(line)

    cmd_up_text = "".join(cmd_up_lines)
    assert "cmd_down" not in cmd_up_text, "cmd_up invokes cmd_down, causing unnecessary service downtime!"
    assert "compose down" not in cmd_up_text, "cmd_up invokes compose down, causing unnecessary service downtime!"
    assert "up -d" in cmd_up_text, "cmd_up does not use idempotent detached up (-d)"


def test_preflight_failure_aborts_up():
    """Verify that cmd_up aborts immediately if cmd_preflight fails."""
    with open(DEPLOY_SH, "r", encoding="utf-8") as f:
        content = f.read()

    # Must contain explicit check in cmd_up
    assert re.search(r"cmd_up\(\)\s*\{.*?if\s+!\s+cmd_preflight;\s*then\s+.*?return\s+1", content, re.DOTALL), (
        "cmd_up does not guard against failed preflight with 'if ! cmd_preflight; then return 1; fi'"
    )


def test_restart_preflight_failure_prevents_teardown():
    """Verify that cmd_restart enforces preflight before teardown, preventing teardown on failure."""
    with open(DEPLOY_SH, "r", encoding="utf-8") as f:
        content = f.read()

    # Static assertion: cmd_restart must check preflight before calling cmd_down
    pattern = r"cmd_restart\(\)\s*\{.*?if\s+!\s+cmd_preflight;\s*then\s+.*?return\s+1.*?cmd_down"
    assert re.search(pattern, content, re.DOTALL), (
        "cmd_restart does not enforce preflight before cmd_down!"
    )

    # Dynamic assertion: invoke deploy.sh restart with invalid preflight conditions
    with tempfile.TemporaryDirectory() as tmpdir:
        # Mock docker command to trace invocations
        mock_bin = os.path.join(tmpdir, "bin")
        os.makedirs(mock_bin, exist_ok=True)
        docker_trace = os.path.join(tmpdir, "docker_trace.log")
        mock_docker = os.path.join(mock_bin, "docker")
        with open(mock_docker, "w", encoding="utf-8") as f:
            f.write(f'#!/bin/sh\necho "$@" >> "{docker_trace}"\nexit 0\n')
        os.chmod(mock_docker, 0o755)

        # Create invalid .env with placeholder password
        env_file = os.path.join(tmpdir, ".env")
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("GF_SECURITY_ADMIN_PASSWORD=CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS\n")
        os.chmod(env_file, 0o600)

        dummy_compose = os.path.join(tmpdir, "docker-compose.yml")
        with open(dummy_compose, "w", encoding="utf-8") as f:
            f.write("services:\n  dummy:\n    image: busybox:latest\n")

        env = os.environ.copy()
        env["PATH"] = f"{mock_bin}:{env['PATH']}"
        env["ENV_FILE"] = env_file
        env["COMPOSE_FILE"] = dummy_compose

        res = subprocess.run(["bash", DEPLOY_SH, "restart"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        assert res.returncode != 0, "deploy.sh restart succeeded despite failing preflight!"
        assert "preflight" in (res.stdout + res.stderr).lower()

        # Verify that docker compose down was NEVER called
        if os.path.exists(docker_trace):
            with open(docker_trace, "r", encoding="utf-8") as f:
                trace_content = f.read()
            assert "down" not in trace_content, f"Teardown command 'down' was executed despite preflight failure! Trace: {trace_content}"


def test_alloy_identity_and_hardening_contract():
    """Verify Alloy user identity is 0:999 and security hardening options are present."""
    with open(COMPOSE_FILE, "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    alloy = compose["services"]["alloy"]
    assert alloy.get("user") == "0:999", f"Alloy user setting '{alloy.get('user')}' is not '0:999'"
    assert alloy.get("read_only") is True, "Alloy read_only root filesystem is not enabled"
    assert alloy.get("cap_drop") == ["ALL"], "Alloy cap_drop is not ['ALL']"
    assert "no-new-privileges:true" in alloy.get("security_opt", []), (
        "Alloy missing 'no-new-privileges:true' in security_opt"
    )

    # Verify journal volume mount is read-only
    volumes = alloy.get("volumes", [])
    journal_mount = next((v for v in volumes if "/var/log/journal" in str(v)), None)
    assert journal_mount is not None, "Alloy missing /var/log/journal mount"
    assert str(journal_mount).endswith(":ro"), f"Journal mount '{journal_mount}' is not read-only (:ro)"


def test_alloy_documentation_accuracy():
    """Verify that documentation accurately explains GID 999 as primary GID and UID 0 volume ownership."""
    with open(COMPOSE_FILE, "r", encoding="utf-8") as f:
        compose_content = f.read()

    # In docker-compose.yml, comments should explain 0:999
    assert "primary GID" in compose_content or "primary group" in compose_content
    assert "lab_alloy_data" in compose_content

    with open(SYS_ARCH_DOC, "r", encoding="utf-8") as f:
        arch_content = f.read()

    assert "0:999" in arch_content
    assert "systemd-journal" in arch_content
    assert "lab_alloy_data" in arch_content
