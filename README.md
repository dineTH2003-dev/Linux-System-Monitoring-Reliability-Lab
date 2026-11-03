# Linux System Monitoring & Reliability Lab
### Hands-On Linux Observability, SRE Engineering & Automated Reliability Platform

[![Status: Validated SRE Lab](https://img.shields.io/badge/Status-Validated%20SRE%20Lab%20(100%25%20Verified)-brightgreen.svg)](https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab)
[![Target OS](https://img.shields.io/badge/Target%20OS-Ubuntu%2024.04%20LTS-E95420.svg?logo=ubuntu)](https://ubuntu.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests: Passing](https://img.shields.io/badge/Tests-100%25%20Passing%20(170%2B%20Assertions)-success.svg)](#7-automated-validation--test-suite)
[![Security: Hardened](https://img.shields.io/badge/Security-CIS%20Hardened%20(42%2F42%20Pass)-blueviolet.svg)](security/container_audit.sh)

---

## 1. Executive Summary & SRE Objectives

The **Linux System Monitoring & Reliability Lab** is an operational Site Reliability Engineering (SRE) project designed to implement, validate, and document a production-grade observability and automated reliability platform on an Ubuntu Linux system.

Rather than treating monitoring as a passive dashboard installation exercise, this platform implements the complete SRE operational lifecycle:
- **Bare-Metal Linux Instrumentation:** Direct introspection of kernel subsystems (`/proc`, `/sys`, cgroups v2, Pressure Stall Information).
- **Custom Telemetry Agents:** Modular Python 3 daemon (`:9101`) and POSIX Bash toolkit (`scripts/monitoring/`) exporting Prometheus metrics.
- **Time-Series Ingestion & Querying:** Hardened Prometheus TSDB (`:9091`) with tailored retention and recording rules.
- **Production Dashboards:** 5 purpose-built Grafana operational dashboards (`:3001`) engineered with bare PromQL queries.
- **Alert Engineering & Webhook Delivery:** Multi-stage Alertmanager pipeline (`:9094`) with grouping, deduplication, inhibition, and webhook dispatch to an automated triage sink (`:5002`).
- **Log Correlation & Stream Aggregation:** High-efficiency log ingestion via Grafana Loki (`:3100`) and journald shipping via Grafana Alloy (`:12345`).
- **SRE Reliability Framework:** Quantitative Service Level Indicators (SLIs), 99.9% Service Level Objectives (SLOs), and multi-window, multi-burn-rate error budgets.
- **Chaos Engineering & Automated Remediation:** Controlled failure simulations (CPU contention, memory leaks, disk fill-rate) paired with idempotent self-healing controllers.
- **Disaster Recovery:** Automated volume backup engine with SHA-256 integrity verification and preflight restore validation.
- **100% Loopback Dual-Stack Coexistence:** Strict port binding to `127.0.0.1`, guaranteeing zero socket collisions with pre-existing host services.

---

## 2. System Architecture & Component Interactions

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Kernel Telemetry (/proc, /sys, PSI, cgroups v2, systemd-journald)    │
│                                 ▲                                      │
│                ┌────────────────┴───────────────┐                      │
│                │                                │                      │
│     ┌──────────┴─────────────┐      ┌───────────┴────────────┐         │
│     │ Node Exporter (:9100)  │      │ Custom Agent (:9101)   │         │
│     │ (Host systemd daemon)  │      │ (Host Python 3 daemon) │         │
│     └──────────┬─────────────┘      └───────────┬────────────┘         │
│                │                                │                      │
│                │        Scrape HTTP Metrics     │                      │
│                └────────────────┬───────────────┘                      │
│                                 ▼                                      │
│     ┌────────────────────────────────────────────────────────────┐     │
│     │             CONTAINERIZED OBSERVABILITY STACK              │     │
│     │                                                            │     │
│     │  ┌───────────────────────┐      ┌───────────────────────┐  │     │
│     │  │   Prometheus (:9091)  │─────▶│ Alertmanager (:9094)  │  │     │
│     │  │   TSDB & PromQL       │      │ Alert Routing         │  │     │
│     │  └───────────┬───────────┘      └───────────┬───────────┘  │     │
│     │              │                              │              │     │
│     │              ▼                              ▼              │     │
│     │  ┌───────────────────────┐      ┌───────────────────────┐  │     │
│     │  │    Grafana (:3001)    │      │ Mock Alert Sink(:5002)│  │     │
│     │  │    Dashboards & SLIs  │      │ Automated Triage Sink │  │     │
│     │  └───────────────────────┘      └───────────────────────┘  │     │
│     │              ▲                              ▲              │     │
│     │              │ LogQL Query                  │ Alerts       │     │
│     │  ┌───────────┴───────────┐      ┌───────────┴────────────┐ │     │
│     │  │   Grafana Loki (:3100)│◀─────│  Grafana Alloy (:12345)│ │     │
│     │  │   Log Aggregation     │ Logs │  Journald Log Shipping │ │     │
│     │  └───────────────────────┘      └────────────────────────┘ │     │
│     │              ▲                              ▲              │     │
│     │              │                              │ Synthetic    │     │
│     │              └──────────────────────────────┴──────────────┘     │
│     │                                 ▲                                │
│     │                   ┌─────────────┴─────────────┐                  │
│     │                   │   Blackbox Prober (:9115) │                  │
│     │                   │   Synthetic HTTP & DNS    │                  │
│     │                   └───────────────────────────┘                  │
│     └────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Technology Stack & Port Allocation Matrix

The platform implements strict dual-stack isolation, preventing socket collisions with pre-existing host services:

| Component | Host Port | Internal Port | Protocol | Execution Boundary | Purpose |
|---|---|---|---|---|---|
| **Prometheus** | `127.0.0.1:9091` | `9090` | HTTP | Container (`nobody`) | Time-series metrics engine & PromQL evaluation |
| **Grafana** | `127.0.0.1:3001` | `3000` | HTTP | Container (`grafana`) | 5 operational dashboards & SLI tracking |
| **Alertmanager** | `127.0.0.1:9094` | `9093` | HTTP | Container (`nobody`) | Alert deduplication, grouping & webhook routing |
| **Grafana Loki** | `127.0.0.1:3100` | `3100` | HTTP | Container (`loki`) | Chunked log stream storage & LogQL queries |
| **Blackbox Exporter** | `127.0.0.1:9115` | `9115` | HTTP | Container (`nobody`) | Synthetic HTTP endpoint & DNS availability prober |
| **Grafana Alloy** | `127.0.0.1:12345` | `12345` | HTTP | Container (`0:999`) | Host `systemd-journald` log collector & shipper |
| **Custom Agent** | `127.0.0.1:9101` | — | HTTP | Native Python 3 | Host procfs/sysfs telemetry & healthz API |
| **Mock Alert Sink** | `127.0.0.1:5002` | — | HTTP | Native Python 3 | Webhook endpoint capturing firing/resolved alerts |
| **Node Exporter** | `*:9100` | — | HTTP | Native systemd | Bare-metal host hardware & kernel metrics |

---

## 4. Quickstart Guide

### Prerequisites
- Ubuntu 24.04 LTS (or compatible Linux host)
- Docker Desktop or Docker Engine with Docker Compose v2+
- Python 3.12+ with `venv`
- Standard Linux utilities: `procps`, `sysstat`, `curl`, `jq`, `promtool`

### 1. Clone & Set Up Python Environment
```bash
git clone https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab.git
cd Linux-System-Monitoring-Reliability-Lab

# Initialize Python virtual environment
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure Environment Security
Create the local, untracked `.env` file with restrictive permissions (`0600`):
```bash
cat << 'EOF' > .env
GF_SECURITY_ADMIN_PASSWORD=LabAdminSecurePassword2026!
EOF
chmod 600 .env
```

### 3. Launch the Observability Stack
```bash
# Preflight validate and start container composition
docker compose up -d

# Start the native Python monitoring agent (in background)
nohup ./.venv/bin/python3 agent/main.py --host 127.0.0.1 --port 9101 > ~/.local/share/lab-monitoring/logs/agent.log 2>&1 &

# Start the mock alert receiver (in background)
nohup ./.venv/bin/python3 scripts/reliability/mock_alert_receiver.py --host 127.0.0.1 --port 5002 --output-file docs/reports/final-live-demonstration/webhook_events.jsonl > /dev/null 2>&1 &
```

### 4. Verify Component Health
```bash
# Verify all 6 Docker containers are healthy
docker compose ps

# Verify Prometheus target status (expect 14/14 UP)
curl -s http://127.0.0.1:9091/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Verify Custom Python Agent health endpoint
curl -s http://127.0.0.1:9101/healthz | jq .

# Verify Grafana HTTP API
curl -s http://127.0.0.1:3001/api/health | jq .
```

### 5. Access Dashboards & Web Interfaces
| Interface | URL | Default Credentials | Description |
|---|---|---|---|
| **Grafana** | `http://localhost:3001` | `admin` / `.env password` | Operational dashboards & SLI monitoring |
| **Prometheus** | `http://localhost:9091` | None (Localhost only) | Time-series explorer & active alert status |
| **Alertmanager** | `http://localhost:9094` | None (Localhost only) | Alert routing tree & silencing controls |
| **Grafana Alloy** | `http://localhost:12345` | None (Localhost only) | Telemetry pipeline & log component graph |
| **Agent Metrics** | `http://localhost:9101/metrics`| None (Localhost only) | Raw Prometheus metrics from custom agent |
| **Mock Webhook Sink**| `http://localhost:5002/healthz`| None (Localhost only) | Alert verification and incident triage sink |

---

## 5. Provisioned Grafana Dashboards

The lab provisions 5 production dashboards from declarative JSON definitions in `grafana/dashboards/`:

1. **`01 — Linux System Overview`**: High-level host summary, CPU mode stacking, system load per core, memory allocation breakdown, disk capacity, and network interface throughput.
2. **`02 — CPU and Memory`**: In-depth kernel compute telemetry, per-core CPU utilization, Pressure Stall Information (PSI) for CPU and memory, major/minor page faults, and swap thrashing diagnostics.
3. **`03 — Storage and Filesystem`**: Physical block device throughput, read/write I/O latency, queue saturation, filesystem fill-rate prediction, and inode density.
4. **`04 — Network and systemd`**: Network interface bandwidth, transmit/receive error rates, socket state distribution, systemd service states, and failed unit counters.
5. **`05 — Python Agent & SRE Overview`**: Custom Python agent telemetry, collector execution duration, SLI performance tracking, 99.9% SLO error budget burn rates, and MTTD/MTTR metrics.

---

## 6. SRE Reliability Engineering & Chaos Framework

### Service Level Objectives (SLOs)
The platform tracks 4 core Service Level Indicators (SLIs) against a **99.9% availability target** over a rolling 30-day window:
- **Host Infrastructure Telemetry Availability:** `up{job="node"} == 1`
- **Custom Agent Availability:** `up{job="custom-agent"} == 1`
- **Synthetic HTTP Endpoint Availability:** `probe_success{job="blackbox-http"} == 1`
- **Telemetry Ingestion Health:** `rate(custom_agent_collector_errors_total[5m]) == 0`

### Multi-Window Error Budget Alerting
Configured in `prometheus/rules/sre_rules.yml` following Google SRE best practices:
- **Critical (Fast Burn):** 14.4x burn rate (2% error budget consumed in 1 hour).
- **High (Medium Burn):** 6.0x burn rate (5% error budget consumed in 6 hours).
- **Warning (Slow Burn):** 1.0x burn rate (10% error budget consumed in 3 days).

### Controlled Failure Simulation & Automated Self-Healing
Located in `scripts/reliability/` and `scripts/remediation/`:
- **CPU Contention:** Inject bounded multi-core compute pressure (`stress-ng`) and trigger CPU throttling remediation.
- **Memory Starvation:** Safe anonymous memory allocation and automatic cache drop remediation.
- **Storage Fill-Rate:** Controlled synthetic data generation in `/tmp` and automated inode/disk log rotation.
- **Service Termination:** Graceful kill simulation with automated circuit-breaker restarts.

---

## 7. Automated Validation & Test Suite

The repository includes a comprehensive, multi-layer automated validation suite (over 170 assertions):

```bash
# 1. Python Unit, Contract, and Deployment Safety Tests (87 tests)
./.venv/bin/pytest tests/python/ tests/reliability/ -v

# 2. POSIX Bash Monitoring & Safety Tests (83 assertions)
bash scripts/tests/test_runner.sh

# 3. Prometheus Configuration Syntax & Promtool Alert Unit Tests
promtool check config prometheus/prometheus.yml
promtool check rules prometheus/rules/*.yml prometheus/alerts/*.yml
promtool test rules prometheus/tests/*.yml

# 4. Security & CIS Docker Benchmark Compliance Audits
bash security/secret_scanner.sh
bash security/container_audit.sh

# 5. Docker Compose Configuration Integrity
docker compose config --quiet
```

---

## 8. Documentation Index

### Core Architecture & Platform Engineering
- [System Architecture](docs/architecture/system-architecture.md) — Architectural blueprint, container isolation, port allocations, and data flows.
- [Monitoring & Observability Overview](docs/monitoring/overview.md) — Linux kernel `/proc` parsing mechanics, Python collector implementations, Prometheus scrape jobs, and Grafana dashboard guide.
- [Alerting Architecture & Incident Detection](docs/monitoring/alerting-and-incident-detection.md) — Multi-tier alert routing, inhibition hierarchies, symptom-based alerting rules, and Blackbox synthetic probes.

### SRE & Reliability Engineering
- [SLI & SLO Specification Framework](docs/sre/sli-slo-framework.md) — Multi-window mathematical models, availability ratios, and objective targets.
- [Error Budget Governance & Escalation Policy](docs/sre/error-budget-policy.md) — Multi-window burn-rate alerting ($14.4\times, 6\times$), consequence thresholds, and escalation workflows.
- [Automated Self-Healing & Remediation Architecture](docs/reliability/automated-remediation.md) — Guarded remediation controller, circuit breakers, idempotency controls, and incident lifecycle telemetry (MTTD/MTTR/MTBF).
- [Chaos Testing & Failure Simulation Guide](docs/reliability/chaos-testing.md) — Chaos engineering scenarios (01–09), blast radius guarantees, and signal traps.
- [Standard Root-Cause Analysis (RCA) Post-Mortem Template](docs/reliability/rca-standard-template.md) — Blameless post-mortem framework and incident timeline template.

### Deployment, Operations & Security
- [Deployment & Operations Guide](docs/deployment/deployment-guide.md) — Step-by-step setup, preflight verification, and container lifecycle commands.
- [Backup & Disaster Recovery Runbook](docs/deployment/backup-recovery-runbook.md) — Cryptographic manifest verification, offline stack restore gates, and volume recovery procedures.
- [Container Security Profile & Hardening Matrix](docs/security/container-security-profile.md) — CIS Docker Benchmark controls, non-root UID pinning, dropped capabilities, and read-only filesystems.

### Live Demonstration & Verification Evidence
- [End-to-End Live Demonstration Report](docs/reports/live-demonstration.md) — Empirical scorecard, PromQL telemetry extracts, webhook delivery traces, and automated recovery evidence.
  - Raw Telemetry Data: [`telemetry_snapshot.json`](docs/reports/final-live-demonstration/telemetry_snapshot.json)
  - Webhook Delivery Stream: [`webhook_events.jsonl`](docs/reports/final-live-demonstration/webhook_events.jsonl)
  - Mock Receiver Logs: [`mock_alert_receiver.log`](docs/reports/final-live-demonstration/mock_alert_receiver.log)

### Alertmanager Troubleshooting Runbooks (`docs/troubleshooting/`)
- [Host CPU Saturation](docs/troubleshooting/cpu-saturation.md)
- [CPU Pressure Contention (PSI)](docs/troubleshooting/cpu-pressure.md)
- [Elevated System Load Average](docs/troubleshooting/cpu-load.md)
- [Memory Starvation & Low Available RAM](docs/troubleshooting/memory-starvation.md)
- [Memory Pressure Contention (PSI)](docs/troubleshooting/memory-pressure.md)
- [Active Swap Thrashing](docs/troubleshooting/swap-thrashing.md)
- [Kernel Out-Of-Memory (OOM) Kill](docs/troubleshooting/oom-incident.md)
- [Filesystem Space Utilization & Fill Rate](docs/troubleshooting/disk-capacity.md)
- [Filesystem Inode Exhaustion](docs/troubleshooting/disk-inodes.md)
- [Filesystem Remounted Read-Only](docs/troubleshooting/disk-readonly.md)
- [High Disk I/O Read / Write Latency](docs/troubleshooting/disk-latency.md)
- [Storage I/O Pressure Contention (PSI)](docs/troubleshooting/io-pressure.md)
- [Network Packet Drops & Errors](docs/troubleshooting/network-errors.md)
- [Host systemd Unit Failure](docs/troubleshooting/systemd-unit.md)
- [Host Unreachable Scrape Failure](docs/troubleshooting/host-unavailable.md)
- [Scrape Target Down](docs/troubleshooting/target-down.md)
- [Custom Python Agent Failure](docs/troubleshooting/custom-agent.md)
- [Prometheus Scrape Duration Slow](docs/troubleshooting/slow-scrape.md)
- [Blackbox Synthetic Probe Failure](docs/troubleshooting/blackbox-probe.md)
- [SSL / TLS Certificate Expiry](docs/troubleshooting/ssl-certificate.md)

---

## 9. Governance & Open-Source Compliance

- **License:** Distributed under the terms of the [MIT License](LICENSE).
- **Contributing:** Guidelines, standards, and commit conventions are documented in [CONTRIBUTING.md](CONTRIBUTING.md).
- **Security Policy:** Vulnerability reporting procedures and isolation invariants are documented in [SECURITY.md](SECURITY.md).
- **Changelog:** Project release history and component milestones are maintained in [CHANGELOG.md](CHANGELOG.md).
