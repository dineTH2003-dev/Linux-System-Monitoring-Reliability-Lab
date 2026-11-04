#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: security/network_exposure_audit.sh
# Purpose: Active network socket audit and interface exposure analysis
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "======================================================================"
echo "  LINUX MONITORING LAB — NETWORK EXPOSURE & SOCKET BINDING AUDIT"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "======================================================================"

python3 - << 'EOF'
import subprocess
import sys

# Monitored Lab Ports
LAB_PORTS = {
    9091: "Lab Prometheus (Container)",
    3001: "Lab Grafana (Container)",
    9093: "Lab Alertmanager (Container Default)",
    9094: "Lab Alertmanager (Container Alternate)",
    3100: "Lab Loki (Container)",
    9115: "Lab Blackbox Exporter (Container)",
    12345: "Lab Alloy Journal Shipper (Container)",
    9101: "Custom Python Monitoring Agent (Host)",
}

# Pre-Existing Native Host Services
NATIVE_PORTS = {
    9090: "Native Prometheus (systemd: prometheus.service)",
    9100: "Native Node Exporter (systemd: prometheus-node-exporter.service)",
    3000: "Native Grafana (systemd: grafana-server.service)",
    22: "Host SSH Server (systemd: ssh.service)",
    5432: "Local PostgreSQL DB",
    5433: "Docker PostgreSQL (taskmanager-postgres)",
    3306: "Local MySQL DB",
}

try:
    proc = subprocess.run(["ss", "-tuln"], capture_output=True, text=True, check=True)
    lines = proc.stdout.splitlines()
except Exception as e:
    print(f"Error running ss command: {e}", file=sys.stderr)
    sys.exit(1)

print("\n[1/3] Active Listening Sockets Analysis:")
print(f"{'Protocol':<8} {'Local Address':<25} {'Port':<8} {'Classification':<20} {'Service Description'}")
print("-" * 85)

violations = []
lab_active = []

for line in lines[1:]:
    parts = line.split()
    if len(parts) < 5:
        continue
    proto = parts[0]
    local_addr_str = parts[4]

    # Parse address and port
    if ":" not in local_addr_str:
        continue

    rcol = local_addr_str.rfind(":")
    addr = local_addr_str[:rcol].strip("[]%")
    port_str = local_addr_str[rcol + 1:]

    try:
        port = int(port_str)
    except ValueError:
        continue

    is_loopback = addr in ("127.0.0.1", "::1", "127.0.0.53", "127.0.0.54")
    is_wildcard = addr in ("0.0.0.0", "*", "::")

    if port in LAB_PORTS:
        desc = LAB_PORTS[port]
        lab_active.append(port)
        if is_loopback:
            cls = "LAB (SECURE)"
        else:
            cls = "LAB (EXPOSED!)"
            violations.append(f"Lab service {desc} on port {port} exposed to non-loopback: {addr}")
    elif port in NATIVE_PORTS:
        desc = NATIVE_PORTS[port]
        cls = "HOST NATIVE"
    else:
        continue

    print(f"{proto:<8} {addr:<25} {port:<8} {cls:<20} {desc}")

print("\n[2/3] Host Native Services Exposure Audit:")
print("  • Note: Host native services (Prometheus :9090, Node Exporter :9100, Grafana :3000)")
print("    are running natively and bind to wildcard 0.0.0.0. These are preserved and untouched")
print("    per user instruction.")

print("\n[3/3] Project Lab Services Security Verification:")
if violations:
    print("  [FAIL] Unsafe port exposure detected for lab services:")
    for v in violations:
        print(f"    - {v}")
    sys.exit(1)
else:
    print(f"  [PASS] All detected lab services adhere strictly to 127.0.0.1 loopback isolation.")
    if lab_active:
        print(f"         Active lab ports: {sorted(lab_active)}")
    else:
        print(f"         Note: Lab services are currently stopped or starting up.")

print("\n======================================================================")
print("  Network Exposure Audit Completed.")
print("======================================================================")
EOF
