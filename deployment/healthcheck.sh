#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: deployment/healthcheck.sh
# Purpose: Comprehensive multi-service endpoint and API health validation
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "======================================================================"
echo "  LINUX MONITORING LAB — MULTI-SERVICE HEALTH VALIDATION"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "======================================================================"

python3 - << 'EOF'
import os
import urllib.request
import urllib.error
import time
import sys

# Load .env if present for dynamic port overrides
env_vars = {}
if os.path.exists(".env"):
    with open(".env", "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip().strip("'\"")

host_ip = os.getenv("HOST_BIND_IP", env_vars.get("HOST_BIND_IP", "127.0.0.1"))
prom_port = os.getenv("PROMETHEUS_HOST_PORT", env_vars.get("PROMETHEUS_HOST_PORT", "9091"))
grafana_port = os.getenv("GRAFANA_HOST_PORT", env_vars.get("GRAFANA_HOST_PORT", "3001"))
am_port = os.getenv("ALERTMANAGER_HOST_PORT", env_vars.get("ALERTMANAGER_HOST_PORT", "9093"))
loki_port = os.getenv("LOKI_HOST_PORT", env_vars.get("LOKI_HOST_PORT", "3100"))
blackbox_port = os.getenv("BLACKBOX_HOST_PORT", env_vars.get("BLACKBOX_HOST_PORT", "9115"))
alloy_port = os.getenv("ALLOY_HOST_PORT", env_vars.get("ALLOY_HOST_PORT", "12345"))
agent_port = os.getenv("AGENT_PORT", env_vars.get("AGENT_PORT", "9101"))

ENDPOINTS = [
    # Project Lab Services (Docker Stack)
    {"name": "Lab Prometheus", "url": f"http://{host_ip}:{prom_port}/-/healthy", "expected": 200, "critical": True},
    {"name": "Lab Grafana", "url": f"http://{host_ip}:{grafana_port}/api/health", "expected": 200, "critical": True},
    {"name": "Lab Alertmanager", "url": f"http://{host_ip}:{am_port}/-/healthy", "expected": 200, "critical": False},
    {"name": "Lab Loki", "url": f"http://{host_ip}:{loki_port}/ready", "expected": 200, "critical": False},
    {"name": "Lab Blackbox", "url": f"http://{host_ip}:{blackbox_port}/-/healthy", "expected": 200, "critical": False},
    {"name": "Lab Alloy", "url": f"http://{host_ip}:{alloy_port}/-/ready", "expected": 200, "critical": False},

    # Custom Agent
    {"name": "Custom Python Agent", "url": f"http://127.0.0.1:{agent_port}/healthz", "expected": 200, "critical": False},

    # Host Native Services (Optional coexistence targets; non-critical for lab portability)
    {"name": "Native Node Exporter", "url": "http://127.0.0.1:9100/metrics", "expected": 200, "critical": False},
    {"name": "Native Prometheus", "url": "http://127.0.0.1:9090/-/healthy", "expected": 200, "critical": False},
    {"name": "Native Grafana", "url": "http://127.0.0.1:3000/api/health", "expected": 200, "critical": False},
]

print(f"{'Service Name':<25} {'Target URL':<40} {'HTTP':<6} {'Latency':<10} {'Status'}")
print("-" * 92)

all_passed = True
critical_failed = False

for ep in ENDPOINTS:
    name = ep["name"]
    url = ep["url"]
    expected = ep["expected"]
    is_crit = ep["critical"]

    start = time.perf_counter()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Lab-Healthcheck/1.0"})
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            elapsed = (time.perf_counter() - start) * 1000.0
            status_code = resp.status
            if status_code == expected:
                status_str = "[PASS] HEALTHY"
            else:
                status_str = f"[WARN] HTTP {status_code}"
                if is_crit:
                    critical_failed = True
                all_passed = False
    except urllib.error.HTTPError as e:
        elapsed = (time.perf_counter() - start) * 1000.0
        status_code = e.code
        status_str = f"[FAIL] HTTP {status_code}"
        if is_crit:
            critical_failed = True
        all_passed = False
    except Exception as e:
        elapsed = (time.perf_counter() - start) * 1000.0
        status_code = 0
        status_str = f"[OFFLINE] {type(e).__name__}"
        if is_crit:
            critical_failed = True
        all_passed = False

    code_disp = str(status_code) if status_code != 0 else "N/A"
    lat_disp = f"{elapsed:.1f} ms"
    print(f"{name:<25} {url:<40} {code_disp:<6} {lat_disp:<10} {status_str}")

print("\n======================================================================")
if critical_failed:
    print("  Health Validation: CRITICAL SERVICE FAILURE")
    sys.exit(2)
elif not all_passed:
    print("  Health Validation: WARNING (Optional services offline or initializing)")
    sys.exit(0)
else:
    print("  Health Validation: ALL SERVICES HEALTHY (100% operational)")
    sys.exit(0)
EOF
