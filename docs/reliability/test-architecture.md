# Reliability Test Architecture & Simulation Platform

**Project:** Linux System Monitoring & Reliability Lab  
**Module:** Reliability Testing & Recovery Framework (Phase 8)  
**Author:** Senior SRE / Failure Simulation & Recovery Engineer (Agent 10)  
**Target Environment:** Local Ubuntu 24.04 LTS (`rubi`, Linux Kernel `7.0.0-38-generic`, Intel Core i7-1355U)  
**Status:** Operational & Grounded in Empirical Telemetry  

---

## 1. Architectural Overview

The **Reliability Testing Framework** couples production-grade failure simulation with automated incident response and quantitative lifecycle telemetry. Rather than treating chaos testing as ad-hoc fault injection, this platform models an operational SRE incident lifecycle:

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

## 2. Core Architectural Principles

1. **Host Preservation & Zero Blast Radius**:
   - The test harness runs directly on the operator's primary workstation. Destructive actions on primary storage mounts (`/`), physical block devices (`nvme0n1`), default networking (`wlo1`), or critical host daemons (`systemd-journald`, `sshd`, `dockerd`) are categorically prohibited through programmatic assertions.
2. **Reversibility by Design**:
   - Every failure injection scenario contains an atomic, unbypassable recovery path. If an injector is interrupted via `SIGINT`, `SIGTERM`, or an uncaught exception, a POSIX signal trap cleans up child processes and unmounts temporary test storage.
3. **Strict Cgroup & Process Isolation**:
   - Workload stress is bounded to a fraction of system capacity (e.g. max 2 CPU cores, max 256MB RAM) and executes at `nice +19` to guarantee that interactive desktop performance is never compromised.
4. **Empirical Telemetry**:
   - Timestamps ($T_{\text{inject}}$, $T_{\text{detect}}$, $T_{\text{alert}}$, $T_{\text{investigate}}$, $T_{\text{recover\_start}}$, $T_{\text{restored}}$) are captured directly from Linux kernel clocks and HTTP endpoint assertions with millisecond resolution (`date +%s.%3N`).

---

## 3. Component Architecture

### 3.1 Fault Injection Engine (`scripts/reliability/`)
The injection suite provides 9 modular, parameter-validated scenario scripts:

| Script | Failure Domain | Mechanism | Safety Invariant |
|---|---|---|---|
| `inject_cpu_contention.sh` | Compute | Bounded Python math loop (2 threads, `nice +19`) | $\le 4$ cores, hard watchdog timeout ($\le 60\text{s}$) |
| `inject_memory_pressure.sh` | Memory | Bounded allocation (128–256MB) | Strictly $\le 1024\text{MB}$; cannot invoke host OOM |
| `inject_filesystem_capacity.sh`| Storage | 45MB payload on dedicated 50MB loopback mount | Rejects `/`, `/boot`, `/etc`, `/usr`, `/var/lib` |
| `inject_inode_pressure.sh` | Storage | Bounded file creation in disposable test directory | Target must be non-root sandbox mount |
| `inject_disk_latency.sh` | Block I/O | Synchronous write loop with `O_SYNC` and `fdatasync` | Bounded duration ($\le 60\text{s}$), isolated test dir |
| `inject_network_failure.sh` | Network | Process stoppage / port closure on port 8088 | Never touches `wlo1`, `lo`, or routing tables |
| `inject_agent_failure.sh` | Telemetry | Graceful `SIGTERM` of Python agent (`:9101`) | Targeted PID only; native Node Exporter preserved |
| `inject_exporter_failure.sh` | Telemetry | Stoppage of synthetic Prometheus exporter (`:9102`) | Dedicated canary port; native `:9100` untouched |
| `inject_systemd_failure.sh` | Init / Service | `SIGKILL` to disposable `lab-canary-user.service` | Whitelisted unit only; system units protected |

### 3.2 Automated Remediation Controller (`scripts/reliability/remediation/`)
The remediation subsystem implements automated self-healing governed by strict safety controllers:
- **`controller.py`**: A Python-based state machine enforcing:
  - Whitelisting of approved targets.
  - Precondition checks prior to execution.
  - Idempotent execution (returns `ALREADY_HEALTHY` if target is verified healthy).
  - Exponential backoff and maximum 3 retry attempts.
  - Circuit breaker tripping after 3 consecutive failures within 10 minutes.
  - Rollback handler execution upon retry exhaustion.
  - Human approval gates for high-risk operations.
  - Immutable audit logging to `/tmp/reliability-remediation-audit.log`.

---

## 4. Scrape Architecture & Incident Telemetry Flow

```
[Fault Injector]
       │ (T_inject)
       ▼
[Target Degradation] ──▶ [Prometheus Scrape / Probe]
                               │ (T_detect)
                               ▼
                        [Rule Evaluation Engine]
                               │ (T_alert)
                               ▼
                        [Alertmanager / API: FIRING]
                               │ (T_investigate)
                               ▼
                        [Remediation Controller]
                               │ (T_recover_start)
                               ▼
                        [Target Restored]
                               │ (T_restored)
                               ▼
                        [Verification Check Passed]
```

### Telemetry Formulations:
- **Mean Time to Detect (MTTD)**:
  $$\text{MTTD} = T_{\text{detect}} - T_{\text{inject}}$$
- **Alert Evaluation Latency**:
  $$\text{Latency}_{\text{alert}} = T_{\text{alert}} - T_{\text{detect}}$$
- **Mean Time to Restore (MTTR)**:
  $$\text{MTTR} = T_{\text{restored}} - T_{\text{recover\_start}}$$
- **Total Incident Duration**:
  $$\text{Duration}_{\text{total}} = T_{\text{restored}} - T_{\text{inject}}$$
