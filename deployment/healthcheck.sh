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
import urllib.request
import urllib.error
import time
import sys

ENDPOINTS = [
    # Project Lab Services (Docker Stack)
    {"name": "Lab Prometheus", "url": "http://127.0.0.1:9091/-/healthy", "expected": 200, "critical": True},
    {"name": "Lab Grafana", "url": "http://127.0.0.1:3001/api/health", "expected": 200, "critical": True},
    {"name": "Lab Alertmanager", "url": "http://127.0.0.1:9093/-/healthy", "expected": 200, "critical": False},
    {"name": "Lab Loki", "url": "http://127.0.0.1:3100/ready", "expected": 200, "critical": False},
    {"name": "Lab Blackbox", "url": "http://127.0.0.1:9115/-/healthy", "expected": 200, "critical": False},
    {"name": "Lab Alloy", "url": "http://127.0.0.1:12345/-/ready", "expected": 200, "critical": False},

    # Custom Agent
    {"name": "Custom Python Agent", "url": "http://127.0.0.1:9101/healthz", "expected": 200, "critical": False},

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
