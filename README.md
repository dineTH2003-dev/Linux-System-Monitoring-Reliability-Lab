# Linux System Monitoring & Reliability Lab

A lightweight, disciplined Linux observability and Site Reliability Engineering (SRE) lab platform built with **Prometheus**, **Grafana**, **Alertmanager**, **Grafana Loki**, **Grafana Alloy**, and a custom **Python host monitoring agent**.

Designed from first principles, this lab demonstrates end-to-end telemetry ingestion (metrics, structured logs, synthetic probing), symptom-based alerting, multi-window SLI/SLO tracking, disaster recovery, and automated self-healing for single-node workstations and simulated multi-host environments.

---

## Table of Contents
1. [What It Does & What It Monitors](#what-it-does--what-it-monitors)
2. [Why I Built This](#why-i-built-this)
3. [Architecture Overview & Network Isolation](#architecture-overview--network-isolation)
4. [Technology Stack](#technology-stack)
5. [Quickstart & Setup](#quickstart--setup)
6. [Telemetry Ingestion Pipelines](#telemetry-ingestion-pipelines)
7. [Grafana Dashboards Catalog](#grafana-dashboards-catalog)
8. [Alerting Pipeline & Incident Detection](#alerting-pipeline--incident-detection)
9. [SRE Framework: SLIs, SLOs & Error Budgets](#sre-framework-slis-slos--error-budgets)
10. [Self-Healing & Automated Remediation](#self-healing--automated-remediation)
11. [Multi-Host Monitoring (Simulated vs Real)](#multi-host-monitoring-simulated-vs-real)
12. [Disaster Recovery: Backup & Restore](#disaster-recovery-backup--restore)
13. [Security Architecture & Hardening](#security-architecture--hardening)
14. [Measured Resource Footprint (Development Workstation Benchmark)](#measured-resource-footprint-development-workstation-benchmark)
15. [5-Minute Reviewer Demonstration Guide](#5-minute-reviewer-demonstration-guide)
16. [Known Limitations & Trade-offs](#known-limitations--trade-offs)
17. [Documentation Index](#documentation-index)
18. [License](#license)

---

## What It Does & What It Monitors

The platform collects real-time system metrics and systemd journal logs from Linux hosts, visualizes them across 5 pre-provisioned Grafana dashboards (90 panels), evaluates symptom-based alerts in Prometheus, and enforces automated self-healing runbooks:

- **CPU Saturation & Contention:** Core-normalized load averages, mode utilization (`user`, `system`, `iowait`, `softirq`), and kernel Pressure Stall Information (PSI `some` / `full`).
- **Memory & Swap Exhaustion:** True available RAM (`MemAvailable`), cache/buffer sizing, swap in/out thrashing rates, and memory pressure stalls.
- **Storage & Inode Depletion:** Mount space utilization, inode exhaustion trends, disk I/O throughput, read/write latency, and loop-device filtering.
- **Network & Socket Allocation:** Interface bandwidth, packet drop and error rates, TCP connection states (ESTABLISHED, TIME_WAIT, CLOSE_WAIT), and listening socket audits.
- **System Services & Runaway Processes:** Failed systemd units, top CPU/RAM consuming tasks, and zombie thread detection.
- **Synthetic Availability:** Blackbox HTTP, TCP, ICMP, and DNS probing of infrastructure dependencies.

---

## Why I Built This

I built this project as an IT student and aspiring Systems/Site Reliability Engineer to master Linux observability from first principles. Rather than relying on managed cloud SaaS agents (Datadog, New Relic) that abstract away system internals, I wanted to:
1. Understand how the Linux kernel exposes telemetry via `/proc`, `/sys`, and `systemd` journals.
2. Build a native, zero-dependency custom metrics exporter in Python using raw kernel pseudo-filesystems.
3. Architect a structured SRE observability stack adhering to Google SRE Golden Signals, multi-window error budgets, and strict CIS Docker Benchmark security profiles.
4. Practice writing idempotent disaster recovery tooling and guarded, automated self-healing scripts with circuit breakers.

---

## Architecture Overview & Network Isolation

All containerized monitoring components run on a dedicated Docker bridge network with ports **strictly bound to the loopback interface (`127.0.0.1`)** to prevent accidental network exposure and eliminate port conflicts with native host services:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                           LINUX HOST                                             │
│                                                                                                  │
│   ┌────────────────────────────────────────────────┐     ┌───────────────────────────────────┐   │
│   │               Kernel Telemetry                 │     │          Systemd Journals         │   │
│   │         (/proc, /sys, psutil, sockets)         │     │         (/var/log/journal)        │   │
│   └───────────────────────┬────────────────────────┘     └─────────────────┬─────────────────┘   │
│                           │                                                │                     │
│              ┌────────────┴────────────┐                                   │                     │
│              ▼                         ▼                                   ▼                     │
│   Native Node Exporter       Custom Python Agent               Native Grafana Alloy Shipper      │
│     (Port 9100 Host)         (Port 127.0.0.1:9101)                (Port 127.0.0.1:12346)         │
└──────────────┬─────────────────────────┬───────────────────────────────────┬─────────────────────┘
               │                         │                                   │ (HTTP Push)
               │ (Scrape via File-SD)    │ (Scrape via File-SD)              │
┌──────────────▼─────────────────────────▼───────────────────────────────────▼─────────────────────┐
│                       DOCKER COMPOSE STACK (127.0.0.1 Loopback Isolation)                        │
│                                                                                                  │
│   ┌────────────────────────────────────────────────┐     ┌───────────────────────────────────┐   │
│   │              Prometheus (:9091)                │────▶│        Alertmanager (:9094)       │   │
│   │ - 80 Rules (Alerts + SRE Recording Rules)      │     │ - Multi-tier Routing (Pager/Slack)│   │
│   │ - Dynamic File-Based Service Discovery (File-SD│     │ - Local Mock Receiver Sink (:5002)│   │
│   └──────┬───────────────────────────────────┬─────┘     └───────────────────────────────────┘   │
│          │                                   │                                                   │
│          ▼                                   ▼                                                   │
│   ┌─────────────────────────────┐     ┌─────────────────────────────┐     ┌──────────────────┐   │
│   │       Grafana (:3001)       │     │   Blackbox Exporter (:9115) │     │   Loki (:3100)   │   │
│   │ - 5 Provisioned Dashboards  │     │ - Synthetic Probing         │     │ - Journal Streams│   │
│   │ - 90 Total Verified Panels  │     │   (HTTP, TCP, ICMP, DNS)    │     │ - Token Masking  │   │
│   └─────────────────────────────┘     └─────────────────────────────┘     └──────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Port Allocation & Binding Matrix

| Service | Container Port | Host Port | Binding IP | Purpose |
|---------|----------------|-----------|------------|---------|
| **Prometheus** | `9090` | `9091` | `127.0.0.1` | Time-series metrics collection & rule evaluation |
| **Grafana** | `3000` | `3001` | `127.0.0.1` | Metrics visualization and dashboard UI |
| **Loki** | `3100` | `3100` | `127.0.0.1` | Centralized log stream indexing & querying |
| **Alertmanager** | `9093` | `9094` | `127.0.0.1` | Alert grouping, deduplication, and routing |
| **Blackbox Exporter** | `9115` | `9115` | `127.0.0.1` | Synthetic network & endpoint probing |
| **Grafana Alloy** (Container) | `12345` | `12345` | `127.0.0.1` | Container log collection & metrics shipping |
| **Grafana Alloy** (Native systemd)| N/A | `12346` | `127.0.0.1` | Native host journal shipping to Loki |
| **Node Exporter** (Native) | N/A | `9100` | Host / Wildcard | Host hardware and OS kernel metrics |
| **Python Agent** (Native) | N/A | `9101` | `127.0.0.1` | Custom granular process & PSI metrics |
| **Mock Alert Receiver** | N/A | `5002` | `127.0.0.1` | Safe local webhook receiver for E2E alert testing |

---

## Technology Stack

- **Metrics & Storage:** [Prometheus](https://prometheus.io/) v2.51, [PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/), TSDB.
- **Log Aggregation:** [Grafana Loki](https://grafana.com/oss/loki/) v2.9, [Grafana Alloy](https://grafana.com/oss/alloy/) v1.21.
- **Alert Management:** [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) v0.27.
- **Visualization:** [Grafana](https://grafana.com/) v10.4 (provisioned dashboards, alert rules, and datasources).
- **Synthetic Monitoring:** [Blackbox Exporter](https://github.com/prometheus/blackbox_exporter) v0.25.
- **Host Agents & Tooling:** Python 3 (`psutil`, `prometheus_client`), Bash (POSIX-compliant, ShellCheck-verified).
- **Orchestration & Security:** Docker Compose v2 (rootless, read-only rootfs, `cap_drop: [ALL]`), systemd.

---

## Quickstart & Setup

### Prerequisites
- Linux OS: Ubuntu 20.04+, Debian 11+, or any standard Linux distribution.
- Docker with Docker Compose v2+.
- Python 3.10+ with `venv`.
- System requirements: 2 CPU cores, 2–4 GB available RAM.

### 1. Clone & Configure
```bash
# Clone the repository
git clone https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab.git
cd Linux-System-Monitoring-Reliability-Lab

# Initialize environment configuration (enforce 0600 permissions)
cp .env.example .env && chmod 600 .env

# Set your own secure Grafana admin password (minimum 16 characters)
# Note: Choose a strong, unique password for your local environment
sed -i 's/CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS/<your-strong-password>/' .env
```

### 2. Python Environment Setup
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. Launch Stack & Verify Health
```bash
# Launch the monitoring stack in the background
./deployment/deploy.sh up

# Run the automated pre-flight and runtime health check
./deployment/healthcheck.sh
```

### 4. Access the Dashboards
Open **`http://127.0.0.1:3001`** in your browser.
- **Username:** `labadmin`
- **Password:** `<The password you set in .env>`

---

## Telemetry Ingestion Pipelines

### 1. Host Metrics Pipeline
- **Node Exporter (`:9100`):** Exposes standard Linux kernel metrics (`node_cpu_*`, `node_memory_*`, `node_filesystem_*`, `node_network_*`).
- **Custom Python Agent (`:9101`):** A custom daemon (`agent/main.py`) that collects PSI metrics (`node_pressure_*`), differential process resource allocations, and individual systemd unit statuses.
- **Prometheus File-SD (`prometheus/targets/`):** Scrapes both exporters every 15 seconds. Adding or modifying JSON targets dynamically registers new hosts without restarting Prometheus.

### 2. Systemd Journal Logging Pipeline
- **Grafana Alloy Shipper (`/etc/alloy/config.alloy`):** Runs as a native systemd service (`alloy.service`), reading `/var/log/journal`.
- **Parametric Host Identity:** Dynamically assigns `host="primary-node"` (or remote host IDs like `node-02`) so log streams correlate 1:1 with Prometheus `instance` metrics.
- **Log Sanitization:** A `loki.relabel` regex pipeline automatically masks sensitive tokens, bearer headers, and passwords into `[REDACTED]` before writing to Loki.

### 3. Synthetic Probing Pipeline
- **Blackbox Exporter (`:9115`):** Actively probes HTTP endpoints (`/healthz`), TCP sockets (`:22`, `:9100`, `:9101`), ICMP host ping, and DNS resolvers (`8.8.8.8:53`, `1.1.1.1:53`).

---

## Grafana Dashboards Catalog

The lab includes 5 pre-provisioned dashboards located in `grafana/dashboards/`:

| Dashboard | File | Panels | Key Metrics & Operational Focus |
|-----------|------|:------:|----------------------------------|
| **01 — Linux System Overview** | `01-linux-system-overview.json` | 19 | High-level host status, uptime, core gauges (CPU, RAM, Disk), active firing alerts, and systemd service failures. |
| **02 — CPU and Memory** | `02-cpu-and-memory.json` | 17 | Core utilization breakdown, load average vs core capacity, Pressure Stall Information (PSI), memory allocation, and swap thrashing. |
| **03 — Storage and Filesystem** | `03-storage-and-filesystem.json` | 17 | Filesystem capacity, inode consumption rates, predictive time-to-exhaustion, disk I/O throughput, IOPS, and read/write latency. |
| **04 — Network and Processes** | `04-network-and-processes.json` | 19 | Bandwidth by interface, packet errors/drops, TCP socket states, top 10 CPU/RAM consumer processes, and zombie thread counters. |
| **05 — Reliability Overview** | `05-reliability-overview.json` | 18 | SRE Golden Signals, 99.9% SLO compliance, error budget burn rates (1h & 6h), Blackbox probe latency, MTBF & MTTR. |

### Dashboard Verification Methodology:
- **Total Panels Across Dashboards:** 90 panels across all 5 JSON dashboard definitions.
- **Total PromQL Query Targets:** 111 query targets embedded within the panel definitions.
- **Programmatic Query Validation:** All 111 PromQL expressions were tested programmatically against the live Prometheus API (`http://127.0.0.1:9091/api/v1/query`) on the `primary-node` host:
  - **109 targets returned live metric data (>0 series)**.
  - **2 targets returned 0 series as expected** (`ALERTS{alertstate="firing"}` in Dashboard 01 and `ALERTS` in Dashboard 05), reflecting normal, healthy baseline operation with no active alerts.
  - **0 PromQL syntax or query execution errors**.
- **Visual UI Inspection:** Visual panel rendering, chart styles, and threshold colorizations can be viewed directly in the Grafana web interface at `http://127.0.0.1:3001`.

---

## Alerting Pipeline & Incident Detection

Alerting rules are organized in `prometheus/rules/` and `prometheus/alerts/` (80 total rules evaluated every 15 seconds):

### Routing Hierarchy (`alertmanager/alertmanager.yml`)
1. **Critical Outages (`severity: critical`):** Routed to `pager-critical` (PagerDuty placeholder) with immediate 10s wait and 1h repeat intervals.
2. **Warning Degradations (`severity: warning`):** Routed to `slack-warnings` (#alerts-warning channel placeholder) with 1m wait and 6h repeat intervals.
3. **Synthetic Failures (`subsystem: blackbox`):** Routed to `blackbox-responder` (`http://host.docker.internal:5002/api/blackbox-triage`) for automated triage.
4. **Heartbeat (`alertname: Watchdog`):** Continuous dead man's switch verifying the alert delivery pipeline.

### Inhibition Rules
- Total host unavailability inhibits all derived hardware and exporter alerts.
- Node Exporter downtime inhibits downstream memory/CPU/storage alerts on that instance.
- Critical filesystem exhaustion inhibits warning-level alerts on the same mountpoint.
- Endpoint total outage inhibits probe latency degradation alerts.

---

## SRE Framework: SLIs, SLOs & Error Budgets

Following Google SRE principles, the platform implements quantitative reliability tracking:

- **Service Level Indicator (SLI):** Host availability defined as successful probe responses and operational systemd units:
  $$\text{SLI} = \frac{\text{Successful Synthetic Probes}}{\text{Total Probes Executed}}$$
- **Service Level Objective (SLO):** **99.9% availability** over a 30-day rolling window (allowing at most 43.2 minutes of total downtime per month).
- **Multi-Window Multi-Burn-Rate Alerting:**
  - **1-Hour Burn Rate (14.4x):** Consumes 2% of the error budget in 1 hour $\rightarrow$ triggers **Critical Pager**.
  - **6-Hour Burn Rate (6x):** Consumes 5% of the error budget in 6 hours $\rightarrow$ triggers **Warning Slack Alert**.

---

## Self-Healing & Automated Remediation

Located in `scripts/reliability/`, automated runbooks resolve common host failures safely:

- **Idempotent Execution:** Checks precondition state before taking action.
- **Circuit Breakers:** Limits retry attempts (maximum 3 iterations) to prevent flapping or cascading failures.
- **Safety Invariants:** Strictly prohibits operations on the root filesystem (`/`) or system critical paths.
- **Audit Logging:** Every automated remediation step is appended to `/tmp/remediation_audit.log`.

---

## Multi-Host Monitoring (Simulated vs Real)

The lab provides multi-host telemetry discovery and isolation:

- **File-Based Service Discovery (File-SD):** Drop target files into `prometheus/targets/` (e.g. `node_node-02.json`). Prometheus automatically discovers the target within 30 seconds without reload.
- **Dynamic Helper Script:**
  ```bash
  ./scripts/monitoring/add_remote_host.sh <hostname> <ip_or_fqdn> [node_port] [agent_port]
  ```
- **Portable Per-Host Alloy Installer:**
  ```bash
  sudo ./deployment/systemd/install-alloy-service.sh --host-identity node-02 --loki-url http://<CENTRAL_IP>:3100/loki/api/v1/push
  ```

### Scope: Simulated vs. Physical Deployment:
- **Verified in Simulation:** Multi-host monitoring is actively demonstrated and tested using local containerized Node Exporter fixtures (`node-02` and `node-03` via `docker-compose.multihost.yml`). The 28 automated assertions in `tests/multihost/test_multihost_monitoring.sh` verify target discovery, metric isolation, and installer script mechanics locally.
- **Physical Remote Deployment Status:** The tooling and configuration templates to onboard external Linux machines are implemented; however, deployment across physical remote hardware over a LAN/WAN has not yet been demonstrated in this lab environment.
- **Network Boundary Requirement:** Central Loki binds to `127.0.0.1:3100` by default. Streaming logs from a physical external machine requires routing traffic through a secure private network, WireGuard VPN tunnel, or an authenticated reverse proxy.

---

## Disaster Recovery: Backup & Restore

### Disaster Recovery Backup Orchestrator (`deployment/backup.sh`)
- Enforces strict `umask 077` (directories `0700`, archives `0600`).
- **Filename-Pattern Secret Exclusion:** Automatically strips `.env`, `*.key`, `*.pem`, `id_rsa*`, and credentials before archiving.
- **Schema 2.0.0 Manifest:** Publishes cryptographic SHA-256 checksums, volume byte sizes, and metadata.
- **Snapshot Support:** Backs up all 5 Docker volumes (`prometheus_data`, `grafana_data`, `alertmanager_data`, `loki_data`, `alloy_data`).

### Safe Disaster Recovery Restore (`deployment/restore.sh`)
- **Offline Stack Safety Gate:** Refuses to restore volumes over active containers to prevent TSDB split-brain corruption.
- **Dry-Run Validation:**
  ```bash
  ./deployment/restore.sh --configs-only --dry-run <backup_set_dir>
  ```
- **Pre-Extraction Verification:** Verifies all checksums and nested archive structures before modifying a single file.

---

## Security Architecture & Hardening

The platform was hardened against the **CIS Docker Benchmark** and SRE least-privilege standards:

1. **Non-Root Execution:** All containers run as dedicated non-root UIDs (Prometheus `65534`, Grafana `472`, Loki `10001`, Alertmanager `65534`).
2. **Capability Dropping:** Containers drop all kernel capabilities (`cap_drop: [ALL]`).
3. **Read-Only Root Filesystems:** All containers enforce `read_only: true` with ephemeral mounts in `tmpfs`.
4. **Privilege Escalation Prevention:** `no-new-privileges: true` enforced on all services.
5. **Loopback Isolation:** All listening ports bind exclusively to `127.0.0.1`.
6. **Zero Hardcoded Secrets:** Audited using static secret scanners (`security/secret_scanner.sh`).

---

## Measured Resource Footprint (Development Workstation Benchmark)

> [!NOTE]
> These figures represent point-in-time measurements captured on the author's local Ubuntu development workstation (Intel/AMD x86_64, Linux 6.8 kernel, Docker Desktop) under idle-to-moderate baseline lab conditions. Memory and CPU usage on other machines will vary depending on host hardware, Linux distribution, container runtime, scrape interval, and log volume.

| Component | Architecture | CPU Usage | Memory (RSS) | Limit |
|-----------|--------------|:---------:|:------------:|:-----:|
| `lab-prometheus` | Container | ~0.42% | ~111 MiB | 1.0 GiB |
| `lab-grafana` | Container | ~0.06% | ~82 MiB | 512 MiB |
| `lab-loki` | Container | ~2.37% | ~156 MiB | 512 MiB |
| `lab-alertmanager`| Container | ~0.19% | ~26 MiB | 256 MiB |
| `lab-blackbox` | Container | ~0.00% | ~22 MiB | 128 MiB |
| `lab-alloy` | Container | ~1.00% | ~48 MiB | 384 MiB |
| **Combined Stack**| **6 Containers** | **~4.04%** | **~445 MiB** | **2.8 GiB** |
| *Python Agent* | *Host Native* | *~0.30%* | *~26 MiB* | *N/A* |
| *Node Exporter* | *Host Native* | *~0.00%* | *~17 MiB* | *N/A* |

---

## 5-Minute Reviewer Demonstration Guide

For technical reviewers and interviewers who want to test the platform in minutes, see the complete step-by-step walkthrough in:

👉 **[docs/demonstration-guide.md](docs/demonstration-guide.md)**

Quick summary of tests you can execute immediately:
1. **Container Health:** `docker ps --filter "name=lab-"`
2. **Grafana Dashboards:** Open `http://127.0.0.1:3001` (user `labadmin`).
3. **Log Streaming & Token Masking:** Query Loki via `curl -s "http://127.0.0.1:3100/loki/api/v1/query"`.
4. **Multi-Host Test:** `bash tests/multihost/test_multihost_monitoring.sh` (28 assertions).
5. **Security Scan:** `bash security/container_audit.sh` (42 CIS checks).
6. **Full Test Suite:** `.venv/bin/pytest tests/python/ tests/reliability/` (88 tests).

---

## Known Limitations & Trade-offs

- **Workstation-Optimized / Educational Lab Scope:** Built for single workstations or small edge node clusters; not intended as a replacement for petabyte-scale distributed object storage (Cortex / Mimir / Thanos).
- **Local TSDB Storage:** Prometheus and Loki store blocks in local Docker named volumes rather than cloud object storage (AWS S3 / Google Cloud Storage).
- **Physical Remote Hardware Not Demonstrated:** Multi-host capabilities are demonstrated using local containerized fixtures; physical remote Linux deployment across WAN/LAN has not been tested on dedicated remote machines.
- **Docker Desktop Journal Isolation:** When Docker Desktop runs inside a virtualized VM on Linux, containerized Alloy cannot read native host journals directly from the host filesystem; the included native systemd Alloy service (`alloy.service`) ships host journals directly.
- **Loki Network Boundary:** Loki is loopback-bound to `127.0.0.1` by default for security. Forwarding logs from remote physical hosts requires establishing a WireGuard VPN or secure reverse proxy.
- **On-Demand Remediation:** Self-healing scripts are run on demand during drills or triage rather than as a 24/7 autonomous daemon.

---

## Documentation Index

- [Reviewer Demonstration Guide](docs/demonstration-guide.md) — 5-minute technical tour for reviewers.
- [System Architecture](docs/architecture/system-architecture.md) — Architectural diagrams, data flow, and port tables.
- [Deployment & Operations Guide](docs/deployment/deployment-guide.md) — Step-by-step deployment and operational procedures.
- [Multi-Host Monitoring](docs/deployment/multi-host-monitoring.md) — Monitoring remote Linux hosts with File-SD and per-host Alloy configs.
- [Resource Optimization & Sizing](docs/deployment/resource-optimization-and-sizing.md) — Measured performance data and capacity planning.
- [Monitoring & Dashboard Guide](docs/monitoring/overview.md) — Metrics catalog, PromQL queries, and panel documentation.
- [Alerting & Incident Detection](docs/monitoring/alerting-and-incident-detection.md) — Alert rules, routing hierarchy, and inhibition rules.
- [SLI/SLO Framework](docs/sre/sli-slo-framework.md) — Availability formulas and 99.9% SLO definition.
- [Error Budget Policy](docs/sre/error-budget-policy.md) — Multi-window burn rates and operational escalation policies.
- [Automated Remediation](docs/reliability/automated-remediation.md) — Guarded self-healing runbooks and safety invariants.
- [Chaos Testing Guide](docs/reliability/chaos-testing.md) — Controlled failure injection drills and post-mortem template.
- [Backup & Recovery Runbook](docs/deployment/backup-recovery-runbook.md) — Disaster recovery backup and restore procedures.
- [Container Security Profile](docs/security/container-security-profile.md) — CIS Docker Benchmark hardening matrix.
- [Troubleshooting Runbooks](docs/troubleshooting/) — 20 triage runbooks linked directly from Prometheus alerts.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
