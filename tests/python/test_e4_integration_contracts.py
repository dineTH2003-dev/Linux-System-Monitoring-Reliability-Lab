"""Integration contract tests verifying Phase E.4 and E.4.1 source remediations.

Validates:
1. Grafana Alloy journal permissions (0:999 matching host systemd-journal GID) and least-privilege boundary.
2. Alloy journal collection configuration, read-only mounts, and Python agent journal coverage.
3. Alloy container health check (pure bash HTTP readiness probe without wget/curl).
4. Loki ruler configuration, tenant directory expectations (tenant 'fake'), and rule mounting.
5. Grafana dashboard telemetry integration for custom Python agent metrics and exact label contracts.
6. Blackbox DNS probe external dependency documentation.
"""

import json
import os
import re
import yaml
import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))


def test_alloy_config_least_privilege():
    """Verify Alloy config avoids unmounted socket/files and retains journal scraping."""
    config_path = os.path.join(REPO_ROOT, "alloy/config.alloy")
    assert os.path.isfile(config_path), f"Missing {config_path}"

    with open(config_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Must NOT attempt to connect to unmounted Docker socket
    assert "/var/run/docker.sock" not in content, "Alloy config still references /var/run/docker.sock"
    assert "discovery.docker" not in content, "Alloy config still contains discovery.docker block"
    assert "loki.source.docker" not in content, "Alloy config still contains loki.source.docker block"

    # Must NOT reference nonexistent flat-file path /var/log/agent
    assert "/var/log/agent" not in content, "Alloy config still references /var/log/agent"

    # Must retain systemd journal collection and sanitization
    assert 'loki.source.journal "systemd"' in content
    assert 'loki.relabel "journal_filter"' in content
    assert 'loki.process "journal_sanitization"' in content
    assert 'loki.write "default"' in content


def test_alloy_journal_permissions_and_user_mapping():
    """Verify Alloy user in Compose matches host systemd-journal GID (999)."""
    compose_path = os.path.join(REPO_ROOT, "docker-compose.yml")
    with open(compose_path, "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    alloy = compose["services"]["alloy"]
    # Host systemd-journal GID is 999. User must be 0:999 to permit DAC read on 0640 journal files
    assert alloy.get("user") == "0:999", (
        f"Alloy user setting '{alloy.get('user')}' does not match root:systemd-journal (0:999)"
    )


def test_alloy_journal_collection_mounts_and_agent_service():
    """Verify host journal is mounted read-only and agent logs are covered."""
    compose_path = os.path.join(REPO_ROOT, "docker-compose.yml")
    with open(compose_path, "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    alloy_volumes = compose["services"]["alloy"].get("volumes", [])

    # Read-only mounts
    assert any("/var/log/journal:/var/log/journal:ro" in str(v) for v in alloy_volumes)
    assert any("/run/log/journal:/run/log/journal:ro" in str(v) for v in alloy_volumes)
    assert any("/etc/machine-id:/etc/machine-id:ro" in str(v) for v in alloy_volumes)

    # Verify agent service logs to journal
    service_path = os.path.join(REPO_ROOT, "deployment/systemd/linux-monitoring-agent.service")
    with open(service_path, "r", encoding="utf-8") as f:
        svc_content = f.read()

    assert "StandardOutput=journal" in svc_content
    assert "SyslogIdentifier=linux-monitoring-agent" in svc_content


def test_docker_compose_alloy_hardening():
    """Verify Alloy service hardening in docker-compose.yml."""
    compose_path = os.path.join(REPO_ROOT, "docker-compose.yml")
    with open(compose_path, "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    alloy = compose["services"]["alloy"]

    # Container Security Hardening
    assert alloy.get("read_only") is True, "Alloy container must have read_only: true"
    assert "no-new-privileges:true" in alloy.get("security_opt", []), (
        "Alloy missing no-new-privileges security option"
    )
    cap_drop = alloy.get("cap_drop", [])
    assert "ALL" in cap_drop or "all" in cap_drop, "Alloy container must drop ALL capabilities"


def test_alloy_healthcheck_http_readiness():
    """Verify Alloy healthcheck uses pure bash HTTP readiness check (/dev/tcp /-/ready)."""
    compose_path = os.path.join(REPO_ROOT, "docker-compose.yml")
    with open(compose_path, "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    alloy = compose["services"]["alloy"]
    health_test = alloy.get("healthcheck", {}).get("test", [])
    health_str = " ".join(health_test)

    # Must NOT rely on wget or curl
    assert "wget" not in health_str, "Alloy healthcheck must not use wget"
    assert "curl" not in health_str, "Alloy healthcheck must not use curl"

    # Must verify HTTP status on /-/ready via bash /dev/tcp
    assert "/dev/tcp" in health_str, "Alloy healthcheck must use bash /dev/tcp"
    assert "/-/ready" in health_str, "Alloy healthcheck must target /-/ready endpoint"
    assert "200" in health_str, "Alloy healthcheck must validate HTTP 200 OK status"


def test_loki_ruler_tenant_and_mount_contract():
    """Verify Loki mounts local rules directory and tenant 'fake' directory structure matches."""
    compose_path = os.path.join(REPO_ROOT, "docker-compose.yml")
    with open(compose_path, "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    loki_volumes = compose["services"]["loki"].get("volumes", [])
    has_rules_mount = any(
        isinstance(v, str) and "./loki/rules:/loki/rules:ro" in v
        for v in loki_volumes
    )
    assert has_rules_mount, "docker-compose.yml does not mount ./loki/rules into Loki container"

    # Verify loki-config.yaml ruler configuration
    loki_cfg_path = os.path.join(REPO_ROOT, "loki/loki-config.yaml")
    with open(loki_cfg_path, "r", encoding="utf-8") as f:
        loki_cfg = yaml.safe_load(f)

    assert loki_cfg.get("auth_enabled") is False, "Loki auth_enabled should be false for lab"
    assert loki_cfg.get("ruler", {}).get("storage", {}).get("local", {}).get("directory") == "/loki/rules"

    # Single-tenant default tenant ID in Loki is 'fake'
    fake_tenant_dir = os.path.join(REPO_ROOT, "loki/rules/fake")
    assert os.path.isdir(fake_tenant_dir), f"Missing tenant rules directory: {fake_tenant_dir}"
    rule_files = os.listdir(fake_tenant_dir)
    assert "alert_rules.yaml" in rule_files
    assert "recording_rules.yaml" in rule_files


def test_prometheus_blackbox_dns_targets():
    """Verify Blackbox DNS probe targets reachable public resolvers, not 127.0.0.53."""
    prom_path = os.path.join(REPO_ROOT, "prometheus/prometheus.yml")
    with open(prom_path, "r", encoding="utf-8") as f:
        prom_cfg = yaml.safe_load(f)

    dns_job = next(
        (job for job in prom_cfg.get("scrape_configs", []) if job.get("job_name") == "blackbox-dns"),
        None,
    )
    assert dns_job is not None, "Missing blackbox-dns scrape job in prometheus.yml"

    targets = dns_job["static_configs"][0]["targets"]
    assert "127.0.0.53:53" not in targets, "Unreachable loopback 127.0.0.53:53 still in DNS targets"
    assert "1.1.1.1:53" in targets, "Missing Cloudflare DNS target 1.1.1.1:53"
    assert "8.8.8.8:53" in targets, "Missing Google DNS target 8.8.8.8:53"


def test_dns_probe_external_dependency_contract():
    """Verify that DNS probe documentation preserves distinction between external vs host-local DNS."""
    doc_path = os.path.join(REPO_ROOT, "docs/monitoring/alerting-and-incident-detection.md")
    with open(doc_path, "r", encoding="utf-8") as f:
        doc_content = f.read()

    assert "External" in doc_content and "1.1.1.1:53" in doc_content, (
        "Documentation missing external resolver qualification"
    )
    assert "systemd" in doc_content, "Documentation missing host-local systemd-resolved monitoring reference"


def test_blackbox_dns_module_remediation_contract():
    """Verify Blackbox dns_udp module targets example.com with NOERROR, not localhost."""
    blackbox_path = os.path.join(REPO_ROOT, "blackbox/blackbox.yml")
    with open(blackbox_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    dns_module = cfg.get("modules", {}).get("dns_udp", {})
    assert dns_module.get("prober") == "dns", "Missing dns prober in dns_udp module"
    dns_settings = dns_module.get("dns", {})
    assert dns_settings.get("query_name") == "example.com", (
        f"Expected query_name 'example.com', got '{dns_settings.get('query_name')}'"
    )
    assert "NOERROR" in dns_settings.get("valid_rcodes", []), "NOERROR must be an accepted rcode"


def test_alertmanager_configuration_contract():
    """Verify Alertmanager defines local mock webhook on port 5002 and required receivers."""
    am_path = os.path.join(REPO_ROOT, "alertmanager/alertmanager.yml")
    with open(am_path, "r", encoding="utf-8") as f:
        am_cfg = yaml.safe_load(f)

    receivers = {r["name"]: r for r in am_cfg.get("receivers", [])}
    assert "default-webhook" in receivers, "Missing default-webhook receiver"
    assert "blackbox-responder" in receivers, "Missing blackbox-responder receiver"

    default_urls = [w["url"] for w in receivers["default-webhook"].get("webhook_configs", [])]
    assert any("5002" in u for u in default_urls), (
        f"default-webhook must target mock sink on port 5002, got {default_urls}"
    )


def test_native_alloy_reproducibility_artifacts():
    """Verify native Alloy systemd override, defaults, and installer exist and are hardened."""
    override_path = os.path.join(REPO_ROOT, "deployment/systemd/alloy-override.conf")
    default_path = os.path.join(REPO_ROOT, "deployment/systemd/alloy.default")
    installer_path = os.path.join(REPO_ROOT, "deployment/systemd/install-alloy-service.sh")

    assert os.path.isfile(override_path), f"Missing {override_path}"
    assert os.path.isfile(default_path), f"Missing {default_path}"
    assert os.path.isfile(installer_path), f"Missing {installer_path}"

    with open(override_path, "r", encoding="utf-8") as f:
        override = f.read()
    assert "SupplementaryGroups=adm systemd-journal" in override
    assert "NoNewPrivileges=yes" in override
    assert "ProtectSystem=strict" in override
    assert "ReadOnlyPaths=/var/log/journal /run/log/journal" in override

    with open(default_path, "r", encoding="utf-8") as f:
        default = f.read()
    assert "--server.http.listen-addr=127.0.0.1:12346" in default


def test_deployment_tooling_alloy_port_consistency():
    """Verify port 12345 (Alloy) is tracked in deployment, healthcheck, and audit scripts."""
    # 1. deploy.sh LAB_PORTS
    deploy_path = os.path.join(REPO_ROOT, "deployment/deploy.sh")
    with open(deploy_path, "r", encoding="utf-8") as f:
        deploy_content = f.read()
    assert re.search(r"LAB_PORTS=.*12345", deploy_content), "deploy.sh LAB_PORTS missing port 12345"

    # 2. network_exposure_audit.sh LAB_PORTS
    audit_path = os.path.join(REPO_ROOT, "security/network_exposure_audit.sh")
    with open(audit_path, "r", encoding="utf-8") as f:
        audit_content = f.read()
    assert "12345:" in audit_content, "network_exposure_audit.sh LAB_PORTS missing port 12345"

    # 3. healthcheck.sh ENDPOINTS
    health_path = os.path.join(REPO_ROOT, "deployment/healthcheck.sh")
    with open(health_path, "r", encoding="utf-8") as f:
        health_content = f.read()
    assert "12345" in health_content, "healthcheck.sh ENDPOINTS missing Alloy on port 12345"

    # 4. .env.example
    env_example_path = os.path.join(REPO_ROOT, ".env.example")
    with open(env_example_path, "r", encoding="utf-8") as f:
        env_content = f.read()
    assert "ALLOY_HOST_PORT=12345" in env_content, ".env.example missing ALLOY_HOST_PORT=12345"


def test_grafana_custom_metrics_and_label_contracts():
    """Verify Grafana dashboards query exact verified custom metric names and labels."""
    # Dashboard 01: CPU and Memory
    d1_path = os.path.join(REPO_ROOT, "grafana/dashboards/01-linux-system-overview.json")
    with open(d1_path, "r", encoding="utf-8") as f:
        d1 = json.load(f)

    d1_exprs = [
        t.get("expr", "")
        for p in d1.get("panels", [])
        for t in p.get("targets", [])
    ]
    # Check exact label cpu="total" and $instance filter for custom CPU utilization
    assert any('linux_cpu_utilization_ratio{cpu="total",instance=~"$instance"}' in e for e in d1_exprs), (
        "Dashboard 01 missing exact custom CPU utilization with cpu='total' and $instance"
    )
    assert any('linux_memory_available_bytes{instance=~"$instance"}' in e for e in d1_exprs), (
        "Dashboard 01 missing custom memory available bytes with $instance"
    )

    # Dashboard 04: Processes
    d4_path = os.path.join(REPO_ROOT, "grafana/dashboards/04-network-and-processes.json")
    with open(d4_path, "r", encoding="utf-8") as f:
        d4 = json.load(f)

    d4_exprs = [
        t.get("expr", "")
        for p in d4.get("panels", [])
        for t in p.get("targets", [])
    ]
    assert any('linux_process_total{instance=~"$instance"}' in e for e in d4_exprs), (
        "Dashboard 04 missing linux_process_total with $instance"
    )
    assert any('linux_process_cpu_consumption_ratio{name=~"[a-zA-Z0-9_.-]+",instance=~"$instance"}' in e for e in d4_exprs), (
        "Dashboard 04 missing linux_process_cpu_consumption_ratio with $instance"
    )
    # Check exact label type="rss" and $instance for top process memory
    assert any('linux_process_memory_consumption_bytes{type="rss",name=~"[a-zA-Z0-9_.-]+",instance=~"$instance"}' in e for e in d4_exprs), (
        "Dashboard 04 missing exact custom process memory with type='rss' and $instance"
    )

    # Dashboard 05: SRE Reliability
    d5_path = os.path.join(REPO_ROOT, "grafana/dashboards/05-reliability-overview.json")
    with open(d5_path, "r", encoding="utf-8") as f:
        d5 = json.load(f)

    d5_exprs = [
        t.get("expr", "")
        for p in d5.get("panels", [])
        for t in p.get("targets", [])
    ]
    assert any('up{job="python-agent",instance=~"$instance"}' in e for e in d5_exprs), (
        "Dashboard 05 missing up{job='python-agent'} with $instance"
    )
    assert any('instance:custom_agent_collector_success:ratio1h{instance=~"$instance"}' in e for e in d5_exprs), (
        "Dashboard 05 missing custom_agent_collector_success with $instance"
    )
    assert any('instance:custom_agent_burn_rate:1h{instance=~"$instance"}' in e for e in d5_exprs), (
        "Dashboard 05 missing custom_agent_burn_rate with $instance"
    )


def test_grafana_no_unexpanded_empty_instance_filters():
    """Verify no dashboard queries contain unexpanded empty instance=~"" regex filters."""
    import glob
    dashboard_files = sorted(glob.glob(os.path.join(REPO_ROOT, "grafana/dashboards/*.json")))
    assert len(dashboard_files) == 5, f"Expected 5 dashboard files, found {len(dashboard_files)}"

    violations = []
    for d_path in dashboard_files:
        with open(d_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        for p in data.get("panels", []):
            p_title = p.get("title", "Untitled")
            for t in p.get("targets", []):
                expr = t.get("expr", "")
                if 'instance=~""' in expr or 'instance=~\\\"\\\"' in expr:
                    violations.append(f"{os.path.basename(d_path)} [{p_title}]: {expr}")

    assert not violations, f"Found unexpanded instance filters in dashboards: {violations}"


def test_grafana_custom_metrics_exist_in_python_collectors():
    """Verify all custom metrics queried in Grafana exist in Python collector definitions."""
    import glob
    python_metrics = set()
    for py_file in glob.glob(os.path.join(REPO_ROOT, "agent/collector/*.py")):
        with open(py_file, "r", encoding="utf-8") as f:
            content = f.read()
        for m in re.findall(r"name=[\"\x27]([a-zA-Z0-9_]+)[\"\x27]", content):
            python_metrics.add(m)

    required_in_dashboards = [
        "linux_cpu_utilization_ratio",
        "linux_memory_available_bytes",
        "linux_memory_total_bytes",
        "linux_process_total",
        "linux_process_cpu_consumption_ratio",
        "linux_process_memory_consumption_bytes",
    ]

    for req in required_in_dashboards:
        assert req in python_metrics, (
            f"Required dashboard metric '{req}' not found in any Python collector definition"
        )


def test_grafana_recording_rules_exist_in_prometheus_rules():
    """Verify all recording rules referenced in Grafana exist in Prometheus rule definitions."""
    import glob
    recording_rules = set()
    for r_file in glob.glob(os.path.join(REPO_ROOT, "prometheus/rules/*.yml")):
        with open(r_file, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        for grp in data.get("groups", []):
            for r in grp.get("rules", []):
                if "record" in r:
                    recording_rules.add(r["record"])

    required_rules = [
        "instance:custom_agent_collector_success:ratio1h",
        "instance:custom_agent_burn_rate:1h",
    ]

    for req in required_rules:
        assert req in recording_rules, (
            f"Required recording rule '{req}' not found in Prometheus rule files"
        )
