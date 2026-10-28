# Linux System Monitoring & Reliability Lab
### Production-Inspired Linux Observability and SRE Engineering Platform

[![Status: Phase 0](https://img.shields.io/badge/Status-Phase%200%3A%20Environment%20Assessment-blue.svg)](https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab)
[![Target OS](https://img.shields.io/badge/Target%20OS-Ubuntu%2024.04%20LTS-E95420.svg?logo=ubuntu)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

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

---

## 2. Problem Statement

Modern Linux environments require active observability and systematic reliability engineering. Off-the-shelf monitoring solutions are frequently deployed without understanding:
1. The kernel sources and calculation mechanics behind critical metrics (e.g., CPU saturation vs. utilization, anonymous vs. page cache memory, disk I/O latency).
2. The failure boundaries between host services and container runtimes.
3. How to construct alert thresholds that accurately reflect degradation without generating alert fatigue.
4. How to correlate metric anomalies with system log events during an incident.
5. How to quantitatively measure availability against an SLO error budget.

This project solves this by constructing the monitoring pipeline from the ground up on physical/virtual host hardware.

---

## 3. Core Capabilities

- **Host Telemetry**: Continuous sampling of CPU (per-core, user/sys/iowait), memory saturation, swap, disk filesystem/inode usage, disk I/O latency, network throughput/errors, and process states.
- **Custom Agent**: Independent Python 3 monitoring agent leveraging `psutil` exposing Prometheus-compatible metrics on `:9101/metrics`.
- **Bash Automation Suite**: 7 standalone POSIX-compliant Bash scripts (`set -Eeuo pipefail`) for targeted CLI health checks and diagnostics.
- **Metrics Pipeline**: Prometheus time-series database with tailored scrape configurations and retention policies.
- **Custom Dashboards**: 5 purpose-built Grafana operational dashboards crafted with native PromQL queries.
- **Alert Engineering**: Alertmanager pipeline supporting alert grouping, inhibition, deduplication, and external notifications.
- **Log Correlation**: `journald` and Loki-based log inspection correlated against Prometheus anomaly timestamps.
- **SRE Reliability Framework**: Defined SLIs, 99.9% SLO targets, error budget burn-rate tracking, and MTTD/MTTR telemetry.
- **Failure Engineering**: Controlled failure injection scenarios (`stress-ng`, bounded I/O, process termination) with automated remediation controllers.

---

## 4. Technology Stack

| Layer | Component | Description |
|---|---|---|
| **Host OS** | Ubuntu 24.04 LTS (Noble Numbat) | Monitored Linux host environment |
| **Automation** | Bash (`set -Eeuo pipefail`) | System check automation and remediation scripts |
| **Custom Agent** | Python 3.12 (`psutil`, `pyyaml`) | Host telemetry collector and HTTP metrics exporter |
| **Host Exporter** | Prometheus Node Exporter | Native hardware and kernel metrics exporter (`:9100`) |
| **Metrics Engine** | Prometheus Server | Time-series database, PromQL engine, scrape scheduler (`:9090`) |
| **Alert Routing** | Prometheus Alertmanager | Alert grouping, deduplication, routing, silencing (`:9093`) |
| **Visualization**| Grafana | Operational observability dashboards (`:3000`) |
| **Probing** | Blackbox Exporter | HTTP/TCP endpoint availability probing (`:9115`) |
| **Service Manager**| systemd | Host service lifecycle management and auto-restart policies |
| **Logging** | systemd-journald / Loki | Structured host and container log aggregation |
| **Container Runtime** | Docker & Docker Compose | Isolated deployment of monitoring platform components |
| **Testing** | `pytest`, `shellcheck`, `stress-ng` | Static analysis, agent unit testing, and load simulation |

---

## 5. High-Level Architecture

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
│     │  │   Prometheus (:9090)  │─────▶│ Alertmanager (:9093)  │  │     │
│     │  │   TSDB & PromQL       │      │ Alert Routing         │  │     │
│     │  └───────────┬───────────┘      └───────────┬───────────┘  │     │
│     │              │                              │              │     │
│     │              ▼                              ▼              │     │
│     │  ┌───────────────────────┐      ┌───────────────────────┐  │     │
│     │  │    Grafana (:3000)    │      │ External Notification │  │     │
│     │  │    Dashboards & SLIs  │      │ (Telegram / Webhook)  │  │     │
│     │  └───────────────────────┘      └───────────────────────┘  │     │
│     │              ▲                                             │     │
│     │              │ Query                                       │     │
│     │  ┌───────────┴───────────┐      ┌───────────────────────┐  │     │
│     │  │   Grafana Loki (:3100)│◀─────│ Blackbox Exp (:9115)  │  │     │
│     │  │   Log Aggregation     │      │ Endpoint Probing      │  │     │
│     │  └───────────────────────┘      └───────────────────────┘  │     │
│     └────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Development Roadmap

```
Phase 0: Environment Assessment & Project Initialization  ◀ [CURRENT STATUS]
Phase 1: Linux System Intelligence & Kernel Introspection
Phase 2: Custom Monitoring Automation (Bash & Python Agent)
Phase 3: Prometheus Infrastructure & Scrape Architecture
Phase 4: Grafana Observability Dashboards
Phase 5: Alerting & Incident Detection Pipeline
Phase 6: Linux Log Monitoring & Correlation
Phase 7: SRE Reliability Engineering (SLI / SLO / Error Budgets)
Phase 8: Failure Simulation & Automated Recovery Engineering
Phase 9: Production-Style Deployment, Hardening & Final Documentation
```

---

## 7. Project Status

- **Current Milestone**: `Phase 0 — Environment Assessment & Project Initialization`
- **Environment State**: Partially Ready (Host baseline cataloged, pending tool prerequisites and service port alignment).
- **Branch**: `main`
- **Next Milestone**: Phase 1 (Linux System Intelligence).
