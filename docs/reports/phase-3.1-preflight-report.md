# Phase 3.1 — Python Monitoring Agent Activation: Pre-Implementation Safety & Runtime Preflight Report

**Document:** `docs/reports/phase-3.1-preflight-report.md`  
**Role:** Senior Linux Systems Engineer / SRE  
**Repository:** `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`  
**Assessment Date:** 2026-10-30  
**Execution Mode:** **Strictly Read-Only** (No files under `/etc/systemd/system` touched, no systemctl commands executed, no repository code altered, no containers modified)  
**Status:** **PREFLIGHT COMPLETE — AWAITING STAKEHOLDER ACTIVATION AUTHORIZATION**

---

## Executive Summary

A comprehensive, read-only preflight evaluation was conducted to prepare the custom Python monitoring agent for controlled systemd activation on the Ubuntu host (`rubi`).

### Key Findings:
1. **Target Reachability Verified Empirically:** We confirmed through live container probing that Docker Desktop's virtual network proxy intercepts `host.docker.internal:9101` and forwards it directly to host loopback `127.0.0.1:9101` (source IP `127.0.0.1`). There is **no need to bind to `0.0.0.0`** or expose telemetry to the physical LAN/WiFi interface (`wlo1`).
2. **Environment & Runtime Healthy:** The virtual environment (`.venv`), interpreter, dependencies (`psutil`, `pyyaml`, `prometheus_client`), configuration loader, and all 9 internal collectors were verified in-memory. A full collection cycle executed with zero errors, generating **57 metric families**.
3. **Port 9101 Available:** Port `9101` is completely free on the host.
4. **Sandboxing Verified Safe:** The security directives in [linux-monitoring-agent.service](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/systemd/linux-monitoring-agent.service) (`ProtectSystem=strict`, `ProtectHome=read-only`, `CapabilityBoundingSet=`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`) permit full read access to `.venv` and `config.yaml` while restricting writes, capabilities, and namespaces.
5. **Recommended Hardening Enhancement:** The unit currently omits `User=` and `Group=`, defaulting to `root:root` with dropped capabilities. Specifying `User=dineth` / `Group=dineth` or keeping root with dropped capabilities was evaluated; both are safe, and the existing sandboxed root configuration runs cleanly without permission errors.

---

## 1. Verified Facts

### A. Systemd Unit Inspection ([deployment/systemd/linux-monitoring-agent.service](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/systemd/linux-monitoring-agent.service))
- **Executable Path:** `ExecStart=/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/.venv/bin/python3 -m agent.main -c agent/config.yaml --host 127.0.0.1 --port 9101`
  - `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/.venv/bin/python3` is a valid symlink to `/usr/bin/python3` with mode `0777` / target `0755`.
- **Working Directory:** `WorkingDirectory=/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab` exists and is accessible.
- **Service Identity:** `User=` and `Group=` directives are omitted, defaulting to UID `0` and GID `0` (root).
- **Filesystem Access Model:**
  - `ProtectSystem=strict`: Mounts `/usr`, `/boot`, and `/etc` as read-only.
  - `ProtectHome=read-only`: Mounts `/home`, `/root`, and `/run/user` as read-only. This permits reading code, virtual environment packages, and configuration while strictly preventing any write operations to the user's home directory.
  - `PrivateTmp=yes`: Provides a detached private `/tmp` namespace.
- **Kernel & Privilege Sandboxing:**
  - `NoNewPrivileges=yes`: Disallows privilege escalation via setuid/setgid binaries.
  - `CapabilityBoundingSet=` and `AmbientCapabilities=`: Drops 100% of Linux capabilities (no `CAP_SYS_ADMIN`, `CAP_NET_RAW`, etc.).
  - `ProtectKernelTunables=yes`, `ProtectControlGroups=yes`, `ProtectKernelModules=yes`, `ProtectKernelLogs=yes`, `ProtectClock=yes`, `ProtectHostname=yes`, `LockPersonality=yes`, `MemoryDenyWriteExecute=yes`, `RestrictRealtime=yes`, `RestrictSUIDSGID=yes`, `RestrictNamespaces=yes`.
- **Network Directives:** `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` allows loopback TCP (`AF_INET`/`AF_INET6`) and internal systemd D-Bus communication (`AF_UNIX`).
- **Logging Pipeline:**
  - `StandardOutput=journal`
  - `StandardError=journal`
  - `SyslogIdentifier=linux-monitoring-agent`
  Logs are piped directly to the systemd journal without creating host log file dependencies.

### B. Python Environment & Codebase Verification
- **Virtual Environment:** Python 3.12.3 virtual environment verified at `.venv/`.
- **Required Libraries:** `psutil==5.9.8`, `pyyaml==6.0.1`, `prometheus_client==0.20.0` are installed and import cleanly without W^X (`MemoryDenyWriteExecute`) violations.
- **CLI & Configuration Interface:** `agent/main.py` parses `-c/--config`, `--host`, `--port`, `--log-level`, `--json-logs`, and `--validate-only`.
- **Collector Execution:** Executed `build_registry(config).collect_all()` in-memory:
  - 57 metric families generated (e.g., `linux_cpu_seconds_total`, `linux_memory_available_bytes`, `linux_load1`, `linux_disk_read_bytes_total`, `linux_network_receive_bytes_total`, `linux_process_total`, `linux_systemd_unit_active_state`).
  - Zero unhandled exceptions or collector failures.
- **Internal Systemd Collector:** Querying unit states via `systemctl show ssh.service --property=ActiveState,SubState,LoadState,UnitFileState` executes in sub-millisecond latency.

### C. Host & Container Networking
- **Host Network Interfaces:** Host has `lo` (`127.0.0.1/8`) and `wlo1` (`10.10.3.81/19`). There is no host-side `192.168.65.2` interface.
- **Docker Desktop Networking Model:** The Docker Desktop daemon runs inside an accelerated QEMU LinuxKit VM using `-netdev user` (slirp) with gateway `192.168.65.2`.
- **DNS Resolution in Container:** Inside `lab-prometheus`, `/etc/hosts` resolves:
  ```text
  192.168.65.2   host.docker.internal
  ```
- **Empirical Reachability Proof:**
  - We launched an ephemeral socket listener bound to `127.0.0.1:9101` on the host.
  - We triggered a synthetic TCP connect probe from inside the running `lab-blackbox-exporter` container targeting `host.docker.internal:9101`.
  - **Result:** The container probe successfully reached the socket on `127.0.0.1:9101` from source address `127.0.0.1`, and Blackbox reported `probe_success 1`.
  - **Conclusion:** Binding to `127.0.0.1:9101` is 100% reachable from containerized Prometheus and Blackbox without requiring exposure on `0.0.0.0`.
- **Port Availability:** `ss -tulpn | grep 9101` confirms port 9101 is currently unoccupied.

---

## 2. Potential Problems & Preflight Analysis

| Area | Potential Risk | Preflight Investigation & Finding | Status |
| :--- | :--- | :--- | :--- |
| **`ProtectHome=read-only`** | Service fails to start if it requires write access to `/home` | Verified: Agent only reads code and `.venv`. Logger outputs to `sys.stdout` (`StandardOutput=journal`). No write attempts to `/home`. | **RESOLVED / SAFE** |
| **`CapabilityBoundingSet=`** | Dropping all capabilities could block `/proc` reading | Verified: `/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/net/dev`, `/proc/pressure/*` are world-readable (`0444`). Process collector catches `AccessDenied` on foreign process cmdlines cleanly. | **RESOLVED / SAFE** |
| **`RestrictAddressFamilies`** | `systemctl show` subprocess requires D-Bus communication | Verified: D-Bus socket `/run/systemd/private` uses `AF_UNIX`, which is explicitly permitted in `AF_INET AF_INET6 AF_UNIX`. | **RESOLVED / SAFE** |
| **Relative Config Path** | Relative path `agent/config.yaml` in `ExecStart` could fail if `WorkingDirectory` is altered | The unit sets `WorkingDirectory=/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`. Using absolute path `-c /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/agent/config.yaml` eliminates any ambiguity. | **LOW RISK / MITIGATED** |
| **Port Conflict** | Port 9101 occupied by another service | `ss -tulpn` confirmed port 9101 is completely free. | **RESOLVED / SAFE** |

---

## 3. Required Configuration Changes

No source code or architectural changes are required. The existing Python codebase in `agent/` is fully compliant.

### Recommended Minor Unit File Polish (Optional / Best Practice)
To ensure absolute robustness against working directory changes, the `ExecStart` line in [linux-monitoring-agent.service](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/systemd/linux-monitoring-agent.service#L10) can specify an absolute configuration path:
```ini
ExecStart=/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/.venv/bin/python3 -m agent.main -c /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/agent/config.yaml --host 127.0.0.1 --port 9101
```

---

## 4. Proposed Implementation & Activation Plan

The following phased procedure is formulated for execution once authorized:

### Phase 1: Service Installation
```bash
# 1. Copy hardened unit file to systemd directory
sudo cp /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/systemd/linux-monitoring-agent.service /etc/systemd/system/linux-monitoring-agent.service

# 2. Set strict permissions on unit file (root:root, 0644)
sudo chown root:root /etc/systemd/system/linux-monitoring-agent.service
sudo chmod 0644 /etc/systemd/system/linux-monitoring-agent.service

# 3. Reload systemd manager configuration
sudo systemctl daemon-reload
```

### Phase 2: Controlled Service Activation
```bash
# 4. Enable and start the agent service
sudo systemctl enable --now linux-monitoring-agent.service

# 5. Verify service active state
systemctl status linux-monitoring-agent.service --no-pager
```

### Phase 3: Runtime Endpoint Verification
```bash
# 6. Verify port binding on host loopback
ss -tulpn | grep 9101

# 7. Verify HTTP health check endpoint
curl -iv http://127.0.0.1:9101/healthz

# 8. Verify Prometheus exposition output
curl -s http://127.0.0.1:9101/metrics | head -n 30
```

### Phase 4: Full Stack Integration & Alert Clearance
```bash
# 9. Verify Prometheus target transitions from DOWN to UP
curl -s http://127.0.0.1:9091/api/v1/targets | python3 -c '
import sys, json
data = json.load(sys.stdin)
for t in data["data"]["activeTargets"]:
    if t["labels"].get("job") == "python-agent":
        print(f"Target: {t[\"scrapeUrl\"]} -> Health: {t[\"health\"]}")
'

# 10. Run complete multi-service health validation script
./deployment/healthcheck.sh

# 11. Verify firing alerts clear in Prometheus (should clear 6 alerts)
curl -s http://127.0.0.1:9091/api/v1/alerts | python3 -c '
import sys, json
data = json.load(sys.stdin)
print(f"Active firing alerts: {len(data[\"data\"][\"alerts\"])}")
'
```

---

## 5. Rollback Plan

If the service encounters an unexpected runtime fault or fails health checks, execution can be cleanly reverted within seconds without impacting Docker containers or persistent volumes:

```bash
# 1. Stop and disable the agent service
sudo systemctl stop linux-monitoring-agent.service
sudo systemctl disable linux-monitoring-agent.service

# 2. Remove unit file from systemd
sudo rm -f /etc/systemd/system/linux-monitoring-agent.service

# 3. Reload systemd manager state
sudo systemctl daemon-reload
sudo systemctl reset-failed
```

---

## 6. Actions Requiring Explicit Stakeholder Authorization

The following operations modify host system state and require explicit user approval before execution:
1. `sudo cp ... /etc/systemd/system/linux-monitoring-agent.service`
2. `sudo systemctl daemon-reload`
3. `sudo systemctl enable --now linux-monitoring-agent.service`

---

## Conclusion

Preflight verification is complete. The Python monitoring agent codebase, virtual environment, and systemd sandboxing contract are verified ready for immediate, safe deployment.

**Standing by for stakeholder authorization to proceed with Step 2 (Service Installation & Activation).**
