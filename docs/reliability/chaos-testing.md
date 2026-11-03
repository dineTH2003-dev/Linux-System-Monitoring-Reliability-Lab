# Chaos Testing & Failure Simulation Guide

**Project:** Linux System Monitoring & Reliability Lab  
**Scope:** Chaos Engineering Architecture, Failure Injectors (01–09), Blast Radius Controls & Safety Invariants  

---

## 1. Architectural Overview

The **Reliability Testing Framework** couples controlled failure injection with automated incident response and quantitative lifecycle telemetry. Rather than treating chaos testing as unconstrained fault injection, this platform executes scenarios with rigorous blast-radius boundaries to protect the host operating system:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Native Services (Preserved & Untouched):                             │
│   • Node Exporter (:9100)       • Prometheus (:9090)                   │
│   • Grafana (:3000)             • Docker Engine                        │
│                                 ▲                                      │
│                                 │ Pull Metrics                         │
│     ┌───────────────────────────┴────────────────────────────────┐     │
│     │                 RELIABILITY TEST HARNESS                   │     │
│     │                                                            │     │
│     │  ┌────────────────────────┐      ┌──────────────────────┐  │     │
│     │  │  Fault Injectors       │      │  Lifecycle Recorder  │  │     │
│     │  │  (scripts/reliability) │─────▶│  (lifecycle_tracker) │  │     │
│     │  └───────────┬────────────┘      └───────────┬──────────┘  │     │
│     │              │                               │             │     │
│     │              ▼                               ▼             │     │
│     │  ┌────────────────────────┐      ┌──────────────────────┐  │     │
│     │  │  Isolated Test Targets │      │  Prometheus Engine   │  │     │
│     │  │  • Loopback ext4 (50MB)│      │  (:9091 TSDB)        │  │     │
│     │  │  • User systemd unit   │      │  • Scrapes Targets   │  │     │
│     │  │  • Port 8088 Canary    │      │  • Evaluates Alerts  │  │     │
│     │  │  • Python Agent :9101  │      └───────────┬──────────┘  │     │
│     │  └───────────┬────────────┘                  │             │     │
│     │              │                               ▼             │     │
│     │              ▼                   ┌──────────────────────┐  │     │
│     │  ┌────────────────────────┐      │  Incident Telemetry  │  │     │
│     │  │  Safe Remediation      │◀─────│  (MTTD, MTTR, MTBF,  │  │     │
│     │  │  Controller & Runbooks │      │   Audit Logs)        │  │     │
│     │  └────────────────────────┘      └──────────────────────┘  │     │
│     └────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Blast Radius Matrix & Boundary Guarantees

All tests execute on an active Linux development host. Under no circumstances may a test scenario compromise host responsiveness, invoke the kernel Out-Of-Memory (OOM) killer on user processes, exhaust root filesystem storage, alter network routing tables, or disrupt host systemd units.

| Subsystem | Failure Simulation | Blast Radius Guarantee | Enforcement Mechanism |
|---|---|---|---|
| **Storage Capacity** | Space exhaustion simulation | Bounded to a dedicated 50MB loopback image or `/tmp` sandbox. Root filesystem (`/`) and physical partitions are untouched. | `assert_not_root_mount()` in `common.sh`; rejects `/`, `/boot`, `/etc`, `/usr`, `/var/lib`. |
| **Storage Inodes** | Inode exhaustion simulation | Operates in disposable sandbox directory (`/tmp/lab_test_inode_mount`). Root filesystem inodes are untouched. | Pre-allocated count ($\le 1000$ files); automated cleanup of `test_inode_*.dat`. |
| **Compute / CPU** | Thread run-queue saturation | Pinned to maximum 2–4 logical cores at lowest CPU priority (`nice +19`). Remaining host cores remain completely free. | Kernel scheduler priority `nice -n 19`; hard timeout timer via `timeout` or Python watchdog. |
| **Memory / Swap** | Memory pressure simulation | Allocation capped strictly at 128MB–256MB (max allowed 1024MB). Host OOM killer cannot be invoked. | Bound parameter check; container cgroup `--memory=256m` or in-process bytearray with exit trap. |
| **Disk I/O Latency** | High await latency | Synchronous I/O loop (`O_SYNC` + `fdatasync`) in a temporary directory throttled to 10–20 writes/sec. Zero impact on host NVMe throughput. | Process sleeping between sync writes; watchdog termination after $\le 60\text{s}$. |
| **Networking** | Endpoint failure | Fault targets exclusively a canary server on port `8088`. Host physical NICs, loopback (`lo`), DNS, and default routes are untouched. | Target validation; no `ip link set down` or global iptables rules. |
| **Observability Agent** | Agent stoppage | Fault targets the custom Python agent process (`agent.main`, `:9101`). Host Node Exporter (`:9100`) and Prometheus (`:9090`) are preserved. | Targeted PID matching via `/tmp/lab_agent.pid`; `SIGTERM` signal dispatch. |
| **Metrics Exporter** | Exporter down | Targets a dedicated synthetic exporter on port `9102`. Host exporters remain active. | Dedicated test port binding; PID cleanup on exit. |
| **System Services** | Unit failure | Targets a dedicated user-space unit `lab-canary-user.service`. System services (`systemd-journald`, `sshd`) are never touched. | Whitelist assertion `assert_whitelisted()`; user-level unit execution (`systemctl --user`). |

---

## 3. Failure Injection Scenarios (01–09)

The lab provides nine dedicated scenario scripts located in `scripts/reliability/`:

### Scenario 01: CPU Contention & Pressure Stall (`scenario_01_cpu_contention.sh`)
- **Fault Mechanism**: Spawns bounded CPU worker threads running arithmetic loops at `nice +19`.
- **Target Metrics**: PromQL `node_load1`, `rate(node_cpu_seconds_total{mode="user"}[1m])`, and custom `linux_agent_cpu_pressure_pct`.
- **Triggered Alert**: `HostHighCpuUtilizationWarning` / `HostCpuPressureContentionCritical`.
- **Remediation**: `runbook_remediate_cpu_contention.sh` identifies top offending PID and dispatches bounded `SIGTERM`.

### Scenario 02: Memory Starvation & PSI Spike (`scenario_02_memory_pressure.sh`)
- **Fault Mechanism**: Allocates a fixed 256MB anonymous memory buffer using Python or POSIX `/dev/shm`.
- **Target Metrics**: `node_memory_MemAvailable_bytes`, `linux_agent_memory_pressure_pct`.
- **Triggered Alert**: `HostLowMemoryAvailableWarning` / `HostMemoryPressureContentionCritical`.
- **Remediation**: `runbook_remediate_memory_leak.sh` drops cached allocations and terminates leaking test processes.

### Scenario 03: Filesystem Space Exhaustion (`scenario_03_storage_exhaustion.sh`)
- **Fault Mechanism**: Writes binary chunks into an isolated 50MB loopback ext4 image until utilization exceeds 85%.
- **Target Metrics**: `node_filesystem_free_bytes`, `node_filesystem_avail_bytes`.
- **Triggered Alert**: `HostFilesystemSpaceWarning` / `HostFilesystemSpaceCritical`.
- **Remediation**: `runbook_remediate_disk_space.sh` truncates old log files and deletes temporary test payloads.

### Scenario 04: Inode Capacity Exhaustion (`scenario_04_inode_exhaustion.sh`)
- **Fault Mechanism**: Generates hundreds of small zero-byte files inside an isolated loopback mount with restricted inode count.
- **Target Metrics**: `node_filesystem_files_free`, `linux_agent_inode_utilization_pct`.
- **Triggered Alert**: `HostInodeExhaustionWarning` / `HostInodeExhaustionCritical`.
- **Remediation**: `runbook_remediate_inodes.sh` identifies high-count directory and unlinks orphaned test entries.

### Scenario 05: Disk I/O Saturation & Await Latency (`scenario_05_disk_io_latency.sh`)
- **Fault Mechanism**: Dispatches sequential synchronous writes with `fdatasync` to an isolated test mount.
- **Target Metrics**: `node_disk_read_time_seconds_total`, `node_disk_write_time_seconds_total`, `linux_agent_disk_await_ms`.
- **Triggered Alert**: `HostDiskReadLatencyHigh` / `HostDiskWriteLatencyHigh`.
- **Remediation**: Terminated automatically by execution timeout watchdog ($\le 30\text{s}$).

### Scenario 06: Network Endpoint Outage (`scenario_06_network_endpoint.sh`)
- **Fault Mechanism**: Stops canary HTTP listener on `127.0.0.1:8088`.
- **Target Metrics**: `probe_success{job="blackbox-http"}` drops from `1` to `0`.
- **Triggered Alert**: `BlackboxEndpointDown`.
- **Remediation**: `runbook_remediate_network_endpoint.sh` restarts canary server and asserts HTTP 200 healthiness.

### Scenario 07: Custom Monitoring Agent Failure (`scenario_07_agent_down.sh`)
- **Fault Mechanism**: Dispatches `SIGTERM` to the custom Python monitoring agent (`:9101`).
- **Target Metrics**: `up{job="python-agent"} == 0`.
- **Triggered Alert**: `CustomAgentUnavailable`.
- **Remediation**: `runbook_remediate_agent_failure.sh` restarts agent daemon in virtual environment and asserts `:9101/metrics`.

### Scenario 08: Synthetic Exporter Failure (`scenario_08_exporter_failure.sh`)
- **Fault Mechanism**: Simulates scrape target failure on port 9102.
- **Target Metrics**: `up{job="node"} == 0` or synthetic `up == 0`.
- **Triggered Alert**: `TargetDown` / `NodeExporterUnavailable`.
- **Remediation**: Rebinds test listener and restores Prometheus scrape target status.

### Scenario 09: Systemd Service Failure (`scenario_09_systemd_unit.sh`)
- **Fault Mechanism**: Fails a dedicated user-level systemd unit `lab-canary-user.service`.
- **Target Metrics**: `node_systemd_unit_state{name="lab-canary-user.service", state="failed"} == 1`.
- **Triggered Alert**: `HostSystemdUnitFailed`.
- **Remediation**: `runbook_remediate_systemd_service.sh` runs `systemctl --user restart lab-canary-user.service`.

---

## 4. Signal Traps & Safe Cleanup Guarantees

Every scenario script implements strict POSIX cleanup traps:
```bash
cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  # Terminate background workload workers
  if [[ -n "${WORKER_PIDS:-}" ]]; then
    kill -TERM ${WORKER_PIDS} 2>/dev/null || true
    wait ${WORKER_PIDS} 2>/dev/null || true
  fi
  # Unmount isolated test image if mounted
  if mountpoint -q "${TEST_MOUNT_DIR:-/nonexistent}"; then
    umount -l "${TEST_MOUNT_DIR}" 2>/dev/null || true
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM
```
