#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: security/container_audit.sh
# Purpose: Container security posture audit against CIS Docker Benchmark principles
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "======================================================================"
echo "  LINUX MONITORING LAB — CONTAINER SECURITY POSTURE AUDIT"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "  Benchmark: CIS Docker Benchmark & SRE Least Privilege Rules"
echo "======================================================================"

python3 - << 'EOF'
import subprocess
import yaml
import sys

try:
    proc = subprocess.run(["docker", "compose", "config"], capture_output=True, text=True, check=True)
    compose_data = yaml.safe_load(proc.stdout)
except Exception as e:
    print(f"Error parsing docker compose configuration: {e}", file=sys.stderr)
    sys.exit(1)

services = compose_data.get("services", {})
if not services:
    print("No services defined in docker compose configuration.", file=sys.stderr)
    sys.exit(1)

total_checks = 0
passed_checks = 0
violations = []

print(f"\nDiscovered {len(services)} services in composition: {', '.join(services.keys())}\n")

for name, srv in services.items():
    print(f"--- Service: {name} ---")

    # 1. Non-root user execution
    total_checks += 1
    user = str(srv.get("user", "")).strip()
    if user and user not in ("0", "root", "0:0"):
        print(f"  [PASS] Non-root execution: user is '{user}'")
        passed_checks += 1
    else:
        msg = f"{name}: runs as root or undefined user (user: '{user}')"
        print(f"  [FAIL] {msg}")
        violations.append(msg)

    # 2. Dropped Linux Capabilities
    total_checks += 1
    cap_drop = srv.get("cap_drop", [])
    if "ALL" in cap_drop or "all" in cap_drop:
        print(f"  [PASS] Linux capabilities: dropped ALL")
        passed_checks += 1
    else:
        msg = f"{name}: fails to drop all capabilities (cap_drop: {cap_drop})"
        print(f"  [FAIL] {msg}")
        violations.append(msg)

    # 3. No New Privileges
    total_checks += 1
    sec_opts = srv.get("security_opt", [])
    if any("no-new-privileges:true" in opt for opt in sec_opts):
        print(f"  [PASS] Security option: no-new-privileges enforced")
        passed_checks += 1
    else:
        msg = f"{name}: missing 'no-new-privileges:true' security_opt"
        print(f"  [FAIL] {msg}")
        violations.append(msg)

    # 4. Read-Only Root Filesystem
    total_checks += 1
    read_only = srv.get("read_only", False)
    if read_only:
        print(f"  [PASS] Filesystem: read_only root filesystem active")
        passed_checks += 1
    else:
        msg = f"{name}: root filesystem is writable (read_only: false)"
        print(f"  [FAIL] {msg}")
        violations.append(msg)

    # 5. Loopback Port Binding (No wildcard 0.0.0.0 exposure)
    total_checks += 1
    ports = srv.get("ports", [])
    wildcard_ports = []
    for p in ports:
        if isinstance(p, dict):
            host_ip = p.get("host_ip", "")
            if host_ip not in ("127.0.0.1", "::1"):
                wildcard_ports.append(f"{host_ip}:{p.get('published')}")
        elif isinstance(p, str):
            if not p.startswith("127.0.0.1:"):
                wildcard_ports.append(p)
    if not wildcard_ports:
        print(f"  [PASS] Network Exposure: all ports strictly bound to 127.0.0.1")
        passed_checks += 1
    else:
        msg = f"{name}: port exposed outside loopback: {wildcard_ports}"
        print(f"  [FAIL] {msg}")
        violations.append(msg)

    # 6. Resource Limits
    total_checks += 1
    deploy_limits = srv.get("deploy", {}).get("resources", {}).get("limits", {})
    cpu_limit = deploy_limits.get("cpus")
    mem_limit = deploy_limits.get("memory")
    if cpu_limit and mem_limit:
        print(f"  [PASS] Resource bounds: limits cpus={cpu_limit}, memory={mem_limit}")
        passed_checks += 1
    else:
        msg = f"{name}: missing resource limits (cpus={cpu_limit}, memory={mem_limit})"
        print(f"  [FAIL] {msg}")
        violations.append(msg)

    # 7. Health Check
    total_checks += 1
    health = srv.get("healthcheck", {})
    if health.get("test"):
        print(f"  [PASS] Healthcheck configured: interval={health.get('interval')}, timeout={health.get('timeout')}")
        passed_checks += 1
    else:
        msg = f"{name}: missing container healthcheck"
        print(f"  [FAIL] {msg}")
        violations.append(msg)

print("\n======================================================================")
print(f"  Container Audit Summary: {passed_checks}/{total_checks} checks passed")
if violations:
    print(f"  Status: FAILED ({len(violations)} violations)")
    for v in violations:
        print(f"    - {v}")
    sys.exit(1)
else:
    print(f"  Status: PASSED ({passed_checks}/{total_checks} project-defined container hardening checks passed)")
    sys.exit(0)
EOF
