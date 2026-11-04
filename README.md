# Linux System Monitoring & Reliability Lab

A lightweight Linux observability and reliability platform built with Prometheus, Grafana, Alertmanager, Loki, Alloy, and a custom Python host monitoring agent.

---

## What It Does & What It Monitors

The platform collects real-time system metrics and systemd journal logs from a Linux host, displays them on pre-built Grafana dashboards, evaluates symptom-based alerts, and includes automated self-healing scripts for common host failures.

It monitors:
- **CPU:** Mode utilization (user, system, iowait), load averages, and Pressure Stall Information (PSI).
- **Memory & Swap:** Available RAM, cache/buffers, swap thrashing, and memory stall pressure.
- **Disk & Storage:** Mount capacity, inode exhaustion, read/write throughput, and I/O latency.
- **Network & Services:** Interface traffic, packet drops, TCP sockets, and failed systemd units.

---

## Why I Built This

I built this project as a university IT student to understand Linux observability and Site Reliability Engineering (SRE) from first principles. Rather than relying on cloud SaaS agents, I wanted to learn how the Linux kernel exposes telemetry via `/proc`, build a custom exporter in Python, and practice defining SRE error budgets and safe self-healing runbooks.

---

## Technologies Used

- **Metrics & Alerting:** Prometheus, Alertmanager, Node Exporter, Blackbox Exporter
- **Visualization:** Grafana (5 provisioned dashboards)
- **Logging:** Grafana Loki, Grafana Alloy (systemd-journal log collector)
- **Host Agent & Scripts:** Python 3 (`psutil`), POSIX Bash
- **Deployment:** Docker Compose (hardened non-root containers), systemd

---

## Architecture Overview

All containers bind to `127.0.0.1` on custom ports to prevent conflicts with native host services:

```
┌──────────────────────────────────────────────────────────────────┐
│                        Linux Host                                │
│   Kernel Telemetry (/proc, /sys, systemd journals)               │
│            │                                       │             │
│   Node Exporter (:9100)                  Python Agent (:9101)    │
│            └───────────────────┬───────────────────┘             │
│                                ▼                                 │
│   Docker Containers (127.0.0.1 Loopback Network):                │
│   • Prometheus (:9091)   ──▶ Alertmanager (:9093)                │
│   • Grafana (:3001)      ──▶ 5 Dashboards                        │
│   • Loki (:3100)         ◀── Alloy (:12345) ◀── /var/log/journal │
│   • Blackbox (:9115)     ──▶ Synthetic HTTP/DNS/TCP/ICMP probes  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Quickstart

### Prerequisites
- Linux host (Ubuntu 22.04+ or Debian 12+; 2+ cores, 2–4 GB RAM)
- Docker with Docker Compose v2+
- Python 3.10+ with `venv`

### Installation & Startup
```bash
# 1. Clone repository
git clone https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab.git
cd Linux-System-Monitoring-Reliability-Lab

# 2. Configure environment (set a custom admin password >= 16 chars)
cp .env.example .env && chmod 600 .env
sed -i 's/CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS/YourStrongPassword123!/' .env

# 3. Set up Python virtual environment
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 4. Start the stack and verify health
./deployment/deploy.sh up
./deployment/healthcheck.sh
```

Stop the stack anytime with `./deployment/deploy.sh down`.

---

## Accessing Grafana

Open **`http://127.0.0.1:3001`** in your browser and log in with username `labadmin` and the password set in `.env`.

The 5 provisioned dashboards are:
1. `01 — Linux System Overview`
2. `02 — CPU and Memory`
3. `03 — Storage and Filesystem`
4. `04 — Network and Processes`
5. `05 — Reliability Overview`

---

## Documentation Index

- [System Architecture](docs/architecture/system-architecture.md) — Port mappings, data flow, and security boundaries.
- [Deployment & Operations Guide](docs/deployment/deployment-guide.md) — Requirements and step-by-step setup.
- [Multi-Host Monitoring](docs/deployment/multi-host-monitoring.md) — Monitoring multiple remote Linux nodes with File-SD.
- [Resource Optimization & Sizing](docs/deployment/resource-optimization-and-sizing.md) — Measured resource usage, tuning options, and capacity sizing.
- [Monitoring & Dashboard Guide](docs/monitoring/overview.md) — Metrics catalog, custom collectors, and panels.
- [Alerting & Incident Detection](docs/monitoring/alerting-and-incident-detection.md) — Alert rules, routing, and probes.
- [SLI/SLO Framework](docs/sre/sli-slo-framework.md) — Availability metrics and 99.9% SLO definition.
- [Error Budget Policy](docs/sre/error-budget-policy.md) — Multi-window burn rates and operational response.
- [Automated Remediation](docs/reliability/automated-remediation.md) — Guarded self-healing and circuit breakers.
- [Chaos Testing Guide](docs/reliability/chaos-testing.md) — Failure injection scenarios and post-mortem template.
- [Backup & Recovery Runbook](docs/deployment/backup-recovery-runbook.md) — Volume backups and restore procedures.
- [Container Security Profile](docs/security/container-security-profile.md) — CIS Docker Benchmark hardening matrix.
- [Troubleshooting Runbooks](docs/troubleshooting/) — 20 triage runbooks linked from Prometheus alerts.

---

## Known Limitations

- **Single-Node:** Built for a single Linux host, not a distributed cluster.
- **Local Storage:** Prometheus and Loki store data in local Docker volumes, not cloud object storage.
- **Journal Access:** Grafana Alloy journal ingestion requires read access to `/var/log/journal` with matching systemd group permissions.
- **On-Demand Remediation:** Self-healing scripts are run on demand during drills or triage rather than as a 24/7 autonomous daemon.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
