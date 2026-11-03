# Deployment & Operations Guide

This guide covers prerequisites, setup instructions, and routine maintenance commands for running the monitoring stack.

---

## 1. Architecture Overview

The lab runs as a set of Docker containers alongside host-level exporters:

```
┌────────────────────────────────────────────────────────────────────────┐
│                              LINUX HOST                                │
│                                                                        │
│   Native Host Services:                                                │
│   • Node Exporter (:9100)                                              │
│                                                                        │
│   Custom Agent (Systemd Service / Virtualenv):                         │
│   • linux-monitoring-agent.service (:9101)                             │
│                                                                        │
│   Containerized Monitoring Stack (docker-compose.yml):                 │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ • Prometheus Server ── 127.0.0.1:9091                        │     │
│   │ • Grafana Server    ── 127.0.0.1:3001                        │     │
│   │ • Alertmanager      ── 127.0.0.1:9093                        │     │
│   │ • Loki Log Store    ── 127.0.0.1:3100                        │     │
│   │ • Grafana Alloy     ── 127.0.0.1:12345                       │     │
│   │ • Blackbox Exporter ── 127.0.0.1:9115                        │     │
│   └──────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

The stack uses dedicated non-standard host ports (e.g., 9091 for Prometheus, 3001 for Grafana) so it will not conflict if you already have default monitoring services running on ports 9090 or 3000.

---

## 2. Prerequisites & System Requirements

### 2.1 Hardware Requirements
- **CPU**: 2 cores minimum (x86_64 or arm64).
- **RAM**: Minimum 2 GiB available system memory (4 GiB recommended).
- **Disk**: 10 GiB available storage for Prometheus TSDB blocks and Loki chunks.

### 2.2 Software Dependencies
| Component | Minimum Version | Notes |
|---|---|---|
| **Linux OS** | Ubuntu 22.04+ or Debian 12+ | Kernel >= 5.15 with PSI enabled |
| **Docker Engine** | `>= 24.0` | With compose plugin |
| **Python** | `>= 3.10` | For custom monitoring agent |
| **systemd** | `>= 245` | Standard on modern Linux distros |
| **curl / wget** | Any modern version | Used by health check scripts |

---

## 3. End-to-End Deployment Procedure

### Step 1: Pre-Flight Verification
Run the preflight check script to verify Docker, required permissions, and port availability:
```bash
./deployment/deploy.sh preflight
```
Expected output:
```
[INFO]  Docker Engine is operational.
[INFO]  Docker Compose is available.
[INFO]  Active .env configuration verified (mode 0600).
[INFO]  Filesystem capacity adequate.
[INFO]  Preflight checks completed successfully.
```

### Step 2: Environment Configuration
Initialize the active configuration file from the sanitized template:
```bash
cp .env.example .env
chmod 600 .env

# Set a strong, randomly generated Grafana administrator password:
ADMIN_PW=$(openssl rand -base64 24)
sed -i "s/CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS/${ADMIN_PW}/" .env
```

### Step 3: Python Agent Environment Initialization
Build and verify the Python virtual environment for the host telemetry agent:
```bash
python3 -m venv .venv
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r requirements.txt
./.venv/bin/pip install -e .

# Validate configuration syntax
./.venv/bin/python3 -m agent.main --validate-config-only
```

### Step 4: Launching the Monitoring Stack
Start all containerized services in detached mode with automated health validation:
```bash
./deployment/deploy.sh up
```
This command performs the following sequence:
1. Executes `deployment/deploy.sh preflight`.
2. Hardens file permissions via `security/harden_permissions.sh`.
3. Invokes `docker compose -f docker-compose.yml up -d`.
4. Waits 10 seconds for service daemonization.
5. Executes `deployment/healthcheck.sh` to assert multi-endpoint availability.

---

## 4. Operational Health Validation

Execute the multi-service health checker at any time to verify real-time status:
```bash
./deployment/healthcheck.sh
```

| Service Endpoint | URL | Expected Response | Role |
|---|---|---|---|
| **Lab Prometheus** | `http://127.0.0.1:9091/-/healthy` | HTTP 200 | Time-series core & rule evaluator |
| **Lab Grafana** | `http://127.0.0.1:3001/api/health` | HTTP 200 (`"database": "ok"`) | Dashboard UI |
| **Lab Alertmanager** | `http://127.0.0.1:9093/-/healthy` | HTTP 200 | Alert routing & deduplication |
| **Lab Loki** | `http://127.0.0.1:3100/ready` | HTTP 200 (`ready`) | Log aggregation |
| **Lab Blackbox** | `http://127.0.0.1:9115/-/healthy` | HTTP 200 | Endpoint availability probing |
| **Custom Agent** | `http://127.0.0.1:9101/healthz` | HTTP 200 (`"status": "healthy"`) | Custom psutil telemetry exporter |
| **Native Node Exporter** | `http://127.0.0.1:9100/metrics` | HTTP 200 | Host bare-metal kernel metrics |

---

## 5. Teardown & Lifecycle Commands

### Graceful Shutdown (Preserving Data)
```bash
./deployment/deploy.sh down
```
*Note*: Named Docker volumes (`lab_prometheus_data`, `lab_grafana_data`, `lab_alertmanager_data`, `lab_loki_data`) are preserved across restarts.

### Graceful Restart
```bash
./deployment/deploy.sh restart
```

### Live Status & Resource Utilization
```bash
./deployment/deploy.sh status
```

### Log Tailing
```bash
# Stream logs from all services
./deployment/deploy.sh logs

# Stream logs from a specific service (e.g. prometheus, grafana)
./deployment/deploy.sh logs prometheus
```

---

## 6. Disaster Recovery & Backup Procedures

### Executing an Automated Backup
```bash
./deployment/backup.sh
```
Creates a compressed, timestamped, SHA-256 verified archive under `backups/backup-YYYYMMDD-HHMMSS.tar.gz`.

### Restoring from an Archive
```bash
./deployment/deploy.sh down
./deployment/restore.sh backups/backup-YYYYMMDD-HHMMSS.tar.gz
./deployment/deploy.sh up
```
