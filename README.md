# Linux System Monitoring & Reliability Lab
### Production-Inspired Linux Observability and SRE Engineering Platform

[![Status: Validated SRE Lab](https://img.shields.io/badge/Status-Validated%20SRE%20Lab%20(Phases%200--9%20Complete)-brightgreen.svg)](https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab)
[![Target OS](https://img.shields.io/badge/Target%20OS-Ubuntu%2024.04%20LTS-E95420.svg?logo=ubuntu)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests: Passing](https://img.shields.io/badge/Tests-100%25%20Passing-success.svg)](#8-testing--validation-suite)

---

## 1. Project Objectives

The **Linux System Monitoring & Reliability Lab** is an operational Site Reliability Engineering (SRE) project designed to implement, validate, and document a production-grade observability platform on an Ubuntu Linux system.

Rather than treating monitoring as a passive dashboard installation exercise, this project adopts an operational SRE lifecycle:
- Establishing host-level instrumentation across kernel interfaces (`/proc`, `/sys`) and systemd.
- Developing custom automation (Bash & Python) and exporting Prometheus metrics.
- Ingesting, storing, and querying time-series data using Prometheus and PromQL.
- Engineering focused Grafana dashboards from bare PromQL queries.
- Designing multi-stage alert rules, Alertmanager routing, and automated notification delivery.
- Analyzing system and kernel logs (`journald`, `syslog`, Grafana Loki).
- Defining measurable Service Level Indicators (SLIs), Service Level Objectives (SLOs), and Error Budgets.
- Conducting controlled failure injection experiments to measure Mean Time to Detect (MTTD) and Mean Time to Restore (MTTR).
- Automating service remediation with guardrails against cascading failures.
- Guaranteeing 100% zero-interference coexistence with pre-existing host services.

---

## 2. Problem Statement

Modern Linux environments require active observability and systematic reliability engineering. Off-the-shelf monitoring solutions are frequently deployed without understanding:
1. The kernel sources and calculation mechanics behind critical metrics (e.g., CPU saturation vs. utilization, anonymous vs. page cache memory, disk I/O latency).
2. The failure boundaries between host services and container runtimes.
3. How to construct alert thresholds that accurately reflect degradation without generating alert fatigue.
4. How to correlate metric anomalies with system log events during an incident.
5. How to quantitatively measure availability against an SLO error budget.
6. How to deploy containerized observability stacks alongside existing native monitoring systems without socket port collisions.

This project solves this by constructing the monitoring pipeline from the ground up on physical/virtual host hardware with strict dual-stack port isolation and zero-interference guarantees.

---

## 3. Core Capabilities

- **Host Telemetry**: Continuous sampling of CPU (per-core, user/sys/iowait), memory saturation, swap, disk filesystem/inode usage, disk I/O latency, network throughput/errors, and process states.
- **Custom Agent**: Independent Python 3 monitoring agent leveraging `psutil` exposing Prometheus-compatible metrics on `:9101/metrics`.
- **Bash Automation Suite**: 7 standalone POSIX-compliant Bash scripts (`set -Eeuo pipefail`) for targeted CLI health checks and diagnostics.
- **Metrics Pipeline**: Prometheus time-series database with tailored scrape configurations and retention policies (`:9091`).
- **Custom Dashboards**: 5 purpose-built Grafana operational dashboards crafted with native PromQL queries (`:3001`).
- **Alert Engineering**: Alertmanager pipeline supporting alert grouping, inhibition, deduplication, and webhook dispatch (`:9094`).
- **Mock Alert Receiver**: Local lightweight webhook sink for automated triage and alert verification (`:5002`).
- **Log Correlation**: `journald` and Loki-based log inspection correlated against Prometheus anomaly timestamps (`:3100`).
- **Synthetic Probing**: Multi-target Blackbox Exporter (`:9115`) probing HTTP and public DNS (`example.com`).
- **SRE Reliability Framework**: Defined SLIs, 99.9% SLO targets, multi-window multi-burn-rate tracking, and MTTD/MTTR telemetry.
- **Failure Engineering**: Controlled failure injection scenarios (`stress-ng`, bounded I/O, process termination) with automated remediation controllers.

---

## 4. Technology Stack & Port Allocation Matrix

The platform implements strict dual-stack isolation, preventing socket collisions with pre-existing host services:

| Component | Native Host Binding | Lab Project Binding | Container Internal | Description |
|---|---|---|---|---|
| **Prometheus** | `*:9090` | `127.0.0.1:9091` | `9090` | Time-series database & PromQL engine |
| **Grafana** | `*:3000` | `127.0.0.1:3001` | `3000` | Operational dashboards & SLI monitoring |
| **Node Exporter** | `*:9100` | *(Host Scraped)* | — | Bare-metal kernel & hardware telemetry |
| **Custom Agent** | — | `127.0.0.1:9101` | — | Native Python 3 host monitoring agent |
| **Alertmanager** | — | `127.0.0.1:9094` | `9093` | Alert routing, grouping, and deduplication |
| **Mock Alert Sink** | — | `127.0.0.1:5002` | — | Local alert webhook test sink |
| **Grafana Loki** | — | `127.0.0.1:3100` | `3100` | High-efficiency log aggregation engine |
| **Blackbox Exporter** | — | `127.0.0.1:9115` | `9115` | Synthetic HTTP/DNS availability prober |
| **Grafana Alloy** | `127.0.0.1:12346` | `127.0.0.1:12345` | `12345` | Next-gen telemetry collector & pipeline |
| **PostgreSQL** | `127.0.0.1:5432` | `0.0.0.0:5433` (Foreign) | `5432` | Isolated foreign application database |

---

## 5. System Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Kernel / Hardware (/proc, /sys, cgroups, network, block devices)     │
│                                 ▲                                      │
│                ┌────────────────┴───────────────┐                      │
│                │                                │                      │
│     ┌──────────┴─────────────┐      ┌───────────┴────────────┐         │
│     │ Node Exporter (:9100)  │      │ Custom Agent (:9101)   │         │
│     │ (Host systemd service) │      │ (Host Python service)  │         │
│     └──────────┬─────────────┘      └───────────┬────────────┘         │
│                │                                │                      │
│                │        Scrape HTTP Metrics     │                      │
│                └────────────────┬───────────────┘                      │
│                                 ▼                                      │
│     ┌────────────────────────────────────────────────────────────┐     │
│     │                 CONTAINERIZED OBSERVABILITY STACK          │     │
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
│     │              │ Query                        │ Alerts       │     │
│     │  ┌───────────┴───────────┐      ┌───────────┴───────────┐  │     │
│     │  │   Grafana Loki (:3100)│◀─────│ Blackbox Exp (:9115)  │  │     │
│     │  │   Log Aggregation     │      │ Synthetic DNS / HTTP  │  │     │
│     │  └───────────────────────┘      └───────────────────────┘  │     │
│     └────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Development Roadmap

```
[✓] Phase 0: Environment Assessment & Project Initialization
[✓] Phase 1: Linux System Intelligence & Kernel Introspection
[✓] Phase 2: Custom Monitoring Automation (Bash Suite & Python Agent)
[✓] Phase 3: Prometheus Infrastructure & Scrape Architecture
[✓] Phase 4: Grafana Observability Dashboards (5 Provisioned Dashboards)
[✓] Phase 5: Alerting & Incident Detection Pipeline (Alertmanager & Rules)
[✓] Phase 6: Linux Log Monitoring & Correlation (Journald & Loki)
[✓] Phase 7: SRE Reliability Engineering (SLI / SLO / Error Budgets)
[✓] Phase 8: Failure Simulation & Automated Recovery Engineering
[✓] Phase 9: Production-Style Deployment, Hardening & Final Documentation
```

---

## 7. Security & Hardening Profile

- **Container Hardening**: 42/42 project-defined container hardening checks passed (`security/container_audit.sh`), enforcing non-root users (`uid:gid`), dropped capabilities (`cap_drop: [ALL]`), `no-new-privileges: true`, and `read_only: true` filesystems.
- **Loopback Enforcement**: All container published ports are strictly bound to `127.0.0.1`, completely preventing exposure on external network interfaces.
- **Secret Scanning**: Zero hardcoded secrets, API tokens, or cleartext credentials detected across working tree and commit history via static regex scanning (`security/secret_scanner.sh`).

---

## 8. Testing & Validation Suite

The repository includes a comprehensive, multi-layer automated validation suite:

```bash
# 1. Python Unit & Contract Tests (Agent, SRE Math, Integration Contracts, Mock Sink)
./.venv/bin/pytest tests/python/ tests/reliability/ -v

# 2. Bash Monitoring & Safety Tests (POSIX compliance, CLI diagnostics, Procfs mock)
bash scripts/tests/test_runner.sh

# 3. Prometheus Rule Validation & Alert Unit Tests
promtool check config prometheus/prometheus.yml
promtool check rules prometheus/rules/*.yml prometheus/alerts/*.yml
promtool test rules prometheus/tests/*.yml

# 4. Security & Container Compliance Audits
bash security/secret_scanner.sh
bash security/container_audit.sh

# 5. Docker Compose Configuration Integrity
docker compose config --quiet
```

---

## 9. Operational Boundaries & Testing Scope

To maintain rigorous engineering honesty, this repository explicitly documents its operational boundaries and assumptions:
- **Workstation Lab Scope**: This platform is designed, tested, and validated as a single-workstation Linux SRE engineering lab (Ubuntu 24.04 LTS with Docker Desktop and native systemd). It is not an enterprise-certified multi-cluster cloud SaaS.
- **Loopback Ports vs. Foreign Services**: All published ports for the monitoring lab (`:9091`, `:3001`, `:9094`, `:3100`, `:9115`, `:12345`, `:9101`, `:5002`) are bound strictly to `127.0.0.1`. Unrelated foreign services listening on `0.0.0.0` (such as `taskmanager-postgres` on `:5433` and `resiliencelab-*` containers) are third-party stacks outside the scope and configuration boundary of this repository. No host firewall settings were modified.
- **Offline Node Exporter Behavior**: The native host `prometheus-node-exporter` service is optional. When stopped during host maintenance, the lab's primary system telemetry pipeline continues operating via the native Python agent on `:9101`. Prometheus accurately detects the missing host exporter (`up{job="node"} == 0`), evaluating multi-window error budget burn rate at exactly `200.0x` and demonstrating alert rule correctness under actual failure conditions.
- **Disaster Recovery Validation Status**: Automated backup creation (`deployment/backup.sh`), SHA-256 cryptographic verification, Schema 2.0.0 JSON metadata manifest validation, and `--dry-run` restore preflight safety checks (`deployment/restore.sh --dry-run`) have been empirically verified. Full live/isolated volume restore execution has not yet been demonstrated in this live environment to protect active persistent TSDB data.
- **Docker Desktop Staging Requirements**: When operating under Docker Desktop for Linux, the container engine runs in a virtual machine where `/tmp` is not shared. All backup staging operations must be directed to `$HOME`-based paths (`~/.local/share/lab-monitoring/tmp/`).
- **Port Allocation**: Host port allocations (`127.0.0.1:9094` for Alertmanager, `127.0.0.1:5002` for Mock Alert Receiver) ensure zero collisions with coexisting host services or foreign Docker stacks.

---

## 10. Operational Runbooks & Documentation Index

- [Host Service Coexistence](docs/deployment/host-service-coexistence.md)
- [Backup & Disaster Recovery Runbook](docs/deployment/runbooks/backup-recovery-runbook.md)
- [SLI / SLO Framework](docs/sre/sli-slo-framework.md)
- [Error Budget Policy](docs/sre/error-budget-policy.md)
- [Container Security Profile](docs/security/container-security-profile.md)
- [Least Privilege Guide](docs/security/linux-least-privilege-guide.md)
- [Automated Remediation Guardrails](docs/reliability/automated-remediation.md)
- [Incident Lifecycle & Runbooks](docs/reliability/incident-lifecycle.md)
