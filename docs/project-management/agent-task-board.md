# Specialist Agent Task Board & Ownership Matrix

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Principal SRE Architect & Technical Integration Lead  
**Document Status:** Approved Engineering Task Board — Post-Remediation Baseline  
**Date:** October 2026  

---

## 1. Workstream Status Overview

| Agent Workstream | Specialist Role | Classification | Primary Deliverables | Blocked By / Dependencies |
|---|---|---|---|---|
| **Agent 1** | CPU & Memory Intelligence Specialist | **COMPLETED** | CPU/Memory Analysis, PSI Metrics, Assessment Reports | None |
| **Agent 2** | Storage & Filesystem Specialist | **COMPLETED** | Block/Filesystem Architecture, I/O Metrics, 5 Assessment Reports | None |
| **Agent 3** | Systems & Reliability Specialist | **COMPLETED** | Process Scheduling, Socket States, D-Bus Telemetry Reports | None |
| **Agent 4** | Automation & Custom Agent Engineer | **COMPLETED** | 7 Bash Monitoring Tools, Python Agent (`agent/`), 113 Assertions | None |
| **Agent 5** | Prometheus Observability Engineer | **READY_TO_IMPLEMENT** | Scrape Config, Rules (`recording_rules`, `sre_rules`, `alert_rules`), Promtool Tests | Ready for Phase B deployment |
| **Agent 6** | Grafana Visualization Engineer | **READY_TO_IMPLEMENT** | 5 Operational Dashboards, Datasource Provisioning | Awaiting Prometheus in Phase B |
| **Agent 7** | Incident Detection & Alerting Engineer | **READY_TO_IMPLEMENT** | Alertmanager Config, Inhibition Rules, Infrastructure Alert Catalog | Ready for Phase C deployment |
| **Agent 8** | Centralized Logging Engineer | **READY_TO_IMPLEMENT** | Loki TSDB v13 Config, Grafana Alloy Journald Pipeline | Ready for Phase C deployment |
| **Agent 9** | SRE Reliability & Governance Engineer | **READY_TO_IMPLEMENT** | SLI/SLO Framework, Multi-Window Burn-Rate Rules | Included in `prometheus.yml` |
| **Agent 10** | Failure Simulation & Recovery Engineer | **COMPLETED** | 9 Reversible Injectors, 6 Runbook Handlers, Reliability Test Suite | Ready for Phase E drills |
| **Agent 11** | Security & Deployment Engineer | **READY_TO_IMPLEMENT** | Hardened Compose, Deployment Scripts, Security Audits | Ready for Phase B/C deployment |

---

## 2. Granular Task Board by Specialist Workstream

### Agent 1: CPU & Memory Intelligence Specialist
- **Ownership:** Host hardware topology, CPU microarchitecture, Linux kernel memory accounting (`/proc/meminfo`), and Pressure Stall Information (PSI).
- **Status:** **COMPLETED**
- **Artifacts:**
  - `docs/reports/phase-1.1-cpu-memory-assessment.md`
  - `docs/monitoring/linux-cpu-monitoring.md`
  - `docs/monitoring/linux-memory-monitoring.md`
- **Remaining Responsibilities:**
  - Technical advisory on CPU/memory saturation thresholds for dashboard queries and alert calibrations.

### Agent 2: Storage & Filesystem Specialist
- **Ownership:** Storage subsystem architecture, block device layers, NVMe/SATA I/O queuing, filesystem structures (ext4, xfs, btrfs), inode allocation, and `diskstats`.
- **Status:** **COMPLETED**
- **Artifacts:**
  - 5 Assessment Reports: `docs/reports/phase-1.2.1-block-device-assessment.md` through `phase-1.2.5-storage-troubleshooting-assessment.md`
  - 5 Architecture Guides: `docs/monitoring/linux-*-storage*.md`
- **Remaining Responsibilities:**
  - Review disposable test filesystem mounts during reliability testing (Scenario 04 & 05).

### Agent 3: Systems & Reliability Specialist
- **Ownership:** Linux kernel process lifecycle, CFS scheduling, context switching, network socket states (`ss`/`tcp_diag`), and systemd D-Bus state transitions.
- **Status:** **COMPLETED**
- **Artifacts:**
  - `docs/reports/phase-1.3-linux-systems-assessment.md`
  - `docs/monitoring/linux-process-monitoring.md`
  - `docs/monitoring/linux-network-monitoring.md`
  - `docs/monitoring/linux-systemd-service-monitoring.md`
- **Remaining Responsibilities:**
  - Validate systemd unit dependencies during automated service recovery.

### Agent 4: Automation & Custom Agent Engineer
- **Ownership:** POSIX Bash CLI diagnostic tools and standalone Python 3 monitoring agent with HTTP Prometheus exporter on port `9101`.
- **Status:** **COMPLETED**
- **Artifacts:**
  - POSIX Bash Suite: `scripts/monitoring/cpu_monitor.sh`, `memory_monitor.sh`, `storage_monitor.sh`, `network_monitor.sh`, `process_monitor.sh`, `systemd_monitor.sh`, `system_monitor.sh`.
  - Python Agent: `agent/main.py`, `agent/server.py`, `agent/collector/*.py` (9 collectors).
  - Test Suite: 30 pytest unit tests (`tests/python/`), 83 Bash assertion tests (`scripts/tests/test_runner.sh`).
- **Remaining Responsibilities:**
  - Maintain socket reuse (`SO_REUSEADDR`) and graceful SIGTERM handling during reliability testing.

### Agent 5: Prometheus Observability Engineer
- **Ownership:** Prometheus server configuration, scrape pipeline, time-series storage retention, PromQL recording rules, and unit testing of rules.
- **Status:** **READY_TO_IMPLEMENT**
- **Completed Tasks:**
  1. [RESOLVED] Updated `prometheus/prometheus.yml` to include `rules/sre_rules.yml`. Promtool loads 5 rule files (80 rules).
  2. [RESOLVED] De-duplicated `prometheus/rules/alert_rules.yml`, retaining 5 non-overlapping supplementary alerts (`HostFilesystemReadonly`, `HostHighLoadAverage`, `HostOomKillDetected`, `TargetScrapeSlow`, `CustomAgentCollectorErrors`).
  3. [RESOLVED] Updated `prometheus/tests/rule_tests.yml` to test canonical alerts from `infrastructure_alerts.yml` (`promtool test rules` 100% SUCCESS).

### Agent 6: Grafana Visualization Engineer
- **Ownership:** Declarative dashboard definitions, datasource provisioning, panel queries, templated variables, and threshold color mappings.
- **Status:** **READY_TO_IMPLEMENT**
- **Completed Tasks:**
  1. [RESOLVED] Confirmed Datasource provisioning points to `http://prometheus:9090` and `http://loki:3100` on the unified `lab_monitoring_network`.
  2. [RESOLVED] Validated all 5 dashboard JSON models (`grafana/dashboards/*.json`) with zero syntax errors.

### Agent 7: Incident Detection & Alerting Engineer
- **Ownership:** Alertmanager routing trees, notification grouping, inhibition hierarchies, alert templating, Blackbox synthetic probe modules, and infrastructure alert rules.
- **Status:** **READY_TO_IMPLEMENT**
- **Completed Tasks:**
  1. [RESOLVED] Certified `prometheus/alerts/infrastructure_alerts.yml` as canonical for all infrastructure alerts.
  2. [RESOLVED] Validated all 7 Alertmanager inhibition rules against canonical alert names via `amtool check-config` (SUCCESS).
  3. [RESOLVED] Verified Blackbox service alias `blackbox-exporter` on `lab_monitoring_network`.

### Agent 8: Centralized Logging Engineer
- **Ownership:** Grafana Loki single-binary TSDB v13 deployment, chunk storage retention, Grafana Alloy log harvester configuration, and LogQL rule definitions.
- **Status:** **READY_TO_IMPLEMENT**
- **Completed Tasks:**
  1. [RESOLVED] Validated `loki/loki-config.yaml` using Loki v3.0.0 `-verify-config` (SUCCESS: "config is valid").
  2. [RESOLVED] Formatted and verified `alloy/config.alloy` via `alloy fmt` (SUCCESS).
  3. [RESOLVED] Connected Alloy to Loki push endpoint on `http://loki:3100/loki/api/v1/push`.

### Agent 9: SRE Reliability & Governance Engineer
- **Ownership:** Service Level Indicators (SLIs), Service Level Objectives (SLOs), Error Budget accounting policies, and multi-window multi-burn-rate alert rules.
- **Status:** **READY_TO_IMPLEMENT**
- **Completed Tasks:**
  1. [RESOLVED] Verified `prometheus/rules/sre_rules.yml` loading in `prometheus.yml` (21 SRE recording and burn-rate rules).
  2. [RESOLVED] Validated Promtool unit tests for SRE rules (`prometheus/tests/sre_rule_tests.yml`: SUCCESS).

### Agent 10: Failure Simulation & Recovery Engineer
- **Ownership:** Controlled, reversible failure injection framework, automated remediation runbooks, incident lifecycle tracking, and MTTR/MTTD quantification.
- **Status:** **COMPLETED**
- **Artifacts:**
  - Common Library: `scripts/reliability/common.sh`
  - Lifecycle Tracker: `scripts/reliability/lifecycle_tracker.py`
  - 9 Failure Injectors: `scripts/reliability/inject_*.sh`
  - 6 Remediation Runbooks: `scripts/reliability/remediation/remediate_*.sh`
  - Unified Scenario Runner: `scripts/reliability/run_scenario.sh`
  - Verification Suite: 25 passing unit/integration tests in `tests/reliability/`.
- **Remaining Responsibilities:**
  - Execute end-to-end chaos drills in Phase E following full platform deployment.

### Agent 11: Security & Deployment Engineer
- **Ownership:** Master hardened Docker Compose orchestration, systemd service units, backup/restore runbooks, container least-privilege enforcement, and security auditing.
- **Status:** **READY_TO_IMPLEMENT**
- **Completed Tasks:**
  1. [RESOLVED] Updated root `docker-compose.yml` mounting `./prometheus/alerts` and `./alertmanager/templates`.
  2. [RESOLVED] Added `blackbox-exporter` network alias and `cap_add: [NET_RAW]` to Blackbox service.
  3. [RESOLVED] Added `alloy` service container to root `docker-compose.yml` with host journal read mounts.
  4. [RESOLVED] Updated Loki service volume mount to reference `loki/loki-config.yaml`.
  5. [RESOLVED] Validated `docker compose config` with 6 hardened services and 5 named volumes.

---

## 3. Inter-Agent Handoff Matrix

```
Agent 1, 2, 3 (System & Kernel Intelligence)
       │
       ├──▶ Agent 4 (Telemetry Collectors & Diagnostics) [COMPLETED]
       │       │
       │       ▼
       ├──▶ Agent 5 (Prometheus TSDB & Scrape Engine) [READY_TO_IMPLEMENT] ◀── Agent 9 (SLI/SLO Rules) [READY]
       │       │
       │       ├─────────────────────────────────────────┐
       │       ▼                                         ▼
       ├──▶ Agent 6 (Grafana Dashboards) [READY]  Agent 7 (Alertmanager & Blackbox) [READY]
       │       ▲                                         ▲
       │       │                                         │
Agent 8 (Loki & Alloy) [READY] ──────────────────────────┘
       │
       ▼
Agent 11 (Master Deployment & Security Hardening) [READY_TO_IMPLEMENT]
       │
       ▼
Agent 10 (Reliability Verification & Automated Recovery Drills) [COMPLETED / READY FOR PHASE E]
```
