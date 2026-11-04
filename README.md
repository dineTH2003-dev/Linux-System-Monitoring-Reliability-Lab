# Linux System Monitoring & Reliability Lab

A Linux observability and Site Reliability Engineering (SRE) lab platform built with Prometheus, Grafana, Alertmanager, Grafana Loki, Grafana Alloy, and a custom Python host monitoring agent.

The platform provides end-to-end host telemetry collection (metrics, kernel Pressure Stall Information, systemd journal logs, synthetic probing), symptom-based alerting, multi-window SLI/SLO error budget tracking, disaster recovery, and automated self-healing.

---

## Key Features

- **Host & Kernel Telemetry:** Ingests CPU, memory, storage, network, and systemd unit metrics from `/proc`, `/sys`, and D-Bus alongside Linux Pressure Stall Information (PSI).
- **Custom Python Agent:** Lightweight host daemon (`:9101`) featuring modular collectors, differential process accounting, and an isolated metric registry.
- **Structured Journal Logging:** Ships host `systemd-journald` logs via Grafana Alloy to Loki with token masking and per-host identity labels.
- **Curated Dashboards:** 5 pre-provisioned Grafana dashboards covering host overview, compute/memory, storage/IO, network/processes, and SRE reliability.
- **Symptom-Based Alerting:** 80 Prometheus rules with tiered routing (Critical Pager, Warning Slack, Webhook triage) and alert inhibition trees.
- **SRE Error Budget Framework:** Quantitative 99.9% availability SLO tracking with multi-window multi-burn-rate alerting (1h and 6h windows).
- **Self-Healing & Chaos Drills:** Automated remediation runbooks with circuit breakers and 9 controlled failure injection drills.
- **Disaster Recovery:** Idempotent volume backup and offline restore tooling with SHA-256 manifest validation.
- **Least-Privilege Security:** Non-root containers, read-only root filesystems, dropped capabilities (`cap_drop: [ALL]`), and loopback-only bindings (`127.0.0.1`).

---

## Architecture Overview

The lab runs containerized observability services alongside host-level telemetry agents. All containers communicate over an internal Docker bridge network (`lab-monitoring-net`), and exposed service ports are strictly bound to the loopback interface (`127.0.0.1`) to avoid port conflicts with native host services.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                   LINUX HOST                                    │
│                                                                                 │
│   Kernel Telemetry (/proc, /sys)               Systemd Journal                  │
│               │                                       │                         │
│       ┌───────┴───────┐                               │                         │
│       ▼               ▼                               ▼                         │
│  Node Exporter   Python Agent                Grafana Alloy (systemd)            │
│    (:9100)       (127.0.0.1:9101)               (127.0.0.1:12346)               │
└───────┬───────────────┬───────────────────────────────┬─────────────────────────┘
        │ Scraped via   │ Scraped via                   │ Push (HTTP)
        │ host-gateway  │ host-gateway                  │
┌───────▼───────────────▼───────────────────────────────▼─────────────────────────┐
│               DOCKER COMPOSE STACK (127.0.0.1 Loopback Bound)                   │
│                                                                                 │
│   ┌───────────────────────────────┐     ┌───────────────────────────────────┐   │
│   │      Prometheus (:9091)       │────▶│       Alertmanager (:9094)        │   │
│   │  • File-SD target discovery   │     │  • Alert routing & deduplication  │   │
│   │  • 80 Alert & SRE rules       │     │  • Webhook triage (:5002)         │   │
│   └───────┬───────────────┬───────┘     └───────────────────────────────────┘   │
│           │               │                                                     │
│           ▼               ▼                                                     │
│   ┌───────────────┐ ┌───────────────────┐   ┌───────────────────────────────┐   │
│   │Grafana (:3001)│ │Blackbox (:9115)   │   │         Loki (:3100)          │   │
│   │• 5 Dashboards │ │• Synthetic probes │   │  • Log stream storage         │   │
│   └───────────────┘ └───────────────────┘   └───────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Port Allocation

- **Prometheus:** `127.0.0.1:9091` (internal `9090`)
- **Grafana:** `127.0.0.1:3001` (internal `3000`)
- **Alertmanager:** `127.0.0.1:9094` or `9093` (internal `9093`)
- **Grafana Loki:** `127.0.0.1:3100`
- **Blackbox Exporter:** `127.0.0.1:9115`
- **Grafana Alloy:** `127.0.0.1:12345` (container) / `127.0.0.1:12346` (native systemd)
- **Custom Python Agent:** `127.0.0.1:9101`
- **Node Exporter:** `9100`

---

## Technology Stack

- **Metrics & Alerting:** Prometheus v2.51, Alertmanager v0.27, Blackbox Exporter v0.25, PromQL
- **Log Aggregation:** Grafana Loki v3.0, Grafana Alloy v1.21 / v1.0, LogQL
- **Visualization:** Grafana v10.4
- **Host Agents & Scripts:** Python 3.12 (`psutil`, `prometheus_client`, `PyYAML`), POSIX Bash
- **Container Runtime & Security:** Docker Compose v2, systemd, CIS Docker Benchmark hardening profiles

---

## Getting Started

### Prerequisites

- Linux host (Ubuntu 22.04+, Debian 12+, or equivalent).
- Docker Engine with Docker Compose v2.
- Python 3.10+ with `venv`.
- Available resources: 2 CPU cores, 2–4 GB RAM.

### 1. Clone & Configure

```bash
git clone https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab.git
cd Linux-System-Monitoring-Reliability-Lab

# Initialize local configuration template (enforce 0600 permissions)
cp .env.example .env && chmod 600 .env

# Set a strong Grafana administrator password
sed -i 's/CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS/<your-secure-password>/' .env
```

### 2. Python Environment Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. Start the Stack & Verify Health

```bash
# Launch the monitoring stack
./deployment/deploy.sh up

# Run automated pre-flight and runtime health checks
./deployment/healthcheck.sh
```

### 4. Access the Dashboards

Open **`http://127.0.0.1:3001`** in your browser.
- **Username:** `labadmin`
- **Password:** The password configured in your `.env` file.

### 5. Stop the Stack

```bash
./deployment/deploy.sh down
```

---

## Monitoring Dashboards

The lab includes 5 pre-provisioned dashboards located in `grafana/dashboards/`:

- **01 — Linux System Overview:** High-level operational health, host uptime, core resource gauges (CPU, memory, disk), active alert state, and failed systemd units.
- **02 — CPU and Memory:** Per-core CPU utilization breakdown, load average vs. capacity, kernel Pressure Stall Information (PSI), memory allocation, page faults, and swap thrashing.
- **03 — Storage and Filesystem:** Mount space utilization, inode consumption, disk I/O throughput, IOPS, and read/write latency.
- **04 — Network and Processes:** Interface bandwidth, packet drop and error rates, TCP socket allocation states, top CPU/RAM consuming processes, and zombie thread counts.
- **05 — Reliability Overview:** SRE Golden Signals, 99.9% SLO compliance tracking, multi-window error budget burn rates, Blackbox probe availability, MTBF, and MTTR.

For detailed metric definitions and PromQL queries, see [docs/monitoring/overview.md](docs/monitoring/overview.md).

---

## Project Structure

```
.
├── agent/                  # Custom Python host monitoring agent (:9101)
├── alertmanager/           # Alertmanager configuration and routing templates
├── alloy/                  # Grafana Alloy logging configuration
├── blackbox/               # Blackbox Exporter synthetic probe configuration
├── deployment/             # Deployment, backup, restore, and systemd service scripts
├── docs/                   # Technical documentation and operational runbooks
│   ├── architecture/       # System architecture and network isolation
│   ├── deployment/         # Deployment guide, multi-host, and sizing
│   ├── monitoring/         # Telemetry catalog and alert routing
│   ├── reliability/        # Chaos engineering and automated remediation
│   ├── security/           # Container security profiles and hardening
│   ├── sre/                # SLI/SLO framework and error budget policies
│   └── troubleshooting/    # 20 operational runbooks linked to Prometheus alerts
├── grafana/                # Provisioning configs and 5 dashboard JSON definitions
├── loki/                   # Loki log aggregation configuration
├── prometheus/             # Prometheus configuration, rules, alerts, and tests
├── scripts/
│   ├── monitoring/         # Bash host diagnostic scripts
│   ├── reliability/        # Chaos fault injectors and remediation runbooks
│   └── tests/              # Subsystem assertion test scripts
├── security/               # Security scanners and permission hardening scripts
├── tests/                  # Integration, safety, multihost, and reliability tests
├── docker-compose.yml      # Core monitoring stack definition
└── README.md
```

---

## Known Limitations

- **Workstation & Lab Scope:** Engineered for single-node development workstations or edge environments; does not implement distributed multi-tenant storage (Cortex, Mimir, Thanos).
- **Local TSDB Storage:** Prometheus metrics and Loki log chunks persist to local Docker named volumes rather than remote cloud object storage.
- **Simulated Multi-Host Testing:** Multi-host target discovery and metric isolation are demonstrated using local containerized fixtures; physical remote deployment over a LAN/WAN requires external routing and firewall setup as described in [docs/deployment/multi-host-monitoring.md](docs/deployment/multi-host-monitoring.md).
- **Loki Network Boundary:** Central Loki binds to `127.0.0.1` by default. Forwarding logs from remote physical hosts requires establishing a WireGuard VPN tunnel or authenticated reverse proxy.
- **On-Demand Remediation:** Self-healing scripts are designed for guarded execution during drills or triage rather than running as an unattended 24/7 background daemon.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
