# Production Deployment & Operations Guide

**Project:** Linux System Monitoring & Reliability Lab  
**Document Ref:** DEP-01 — Deployment Architecture & Operations Manual  
**Author:** Agent 11 (Infrastructure Security & Deployment Engineer)  
**Target Environment:** Local Ubuntu 24.04 LTS (`rubi`, Linux Kernel `7.0.0-38-generic`, Intel Core i7-1355U)  

---

## 1. Architecture Overview & Principles

The **Linux System Monitoring & Reliability Lab** deployment architecture is engineered for 100% reproducibility, non-destructive coexistence with native host services, and rapid automated disaster recovery.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Native Host Services (Untouched & Preserved):                        │
│   • prometheus.service (:9090) ── Active                               │
│   • prometheus-node-exporter.service (:9100) ── Active                 │
│   • grafana-server.service (:3000) ── Active                           │
│                                                                        │
│   Custom Agent (Systemd User Service / Venv):                          │
│   • linux-monitoring-agent.service (:9101)                             │
│                                                                        │
│   Docker Desktop LinuxKit VM Boundary (Bridge: lab-monitoring-net)    │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ Project Lab Monitoring Stack (docker-compose.yml):           │     │
│   │ • Prometheus Server ── Bound to 127.0.0.1:9091               │     │
│   │ • Grafana Server    ── Bound to 127.0.0.1:3001               │     │
│   │ • Alertmanager      ── Bound to 127.0.0.1:9093               │     │
│   │ • Loki Log Store    ── Bound to 127.0.0.1:3100               │     │
│   │ • Blackbox Exporter ── Bound to 127.0.0.1:9115               │     │
│   └──────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Prerequisites & System Requirements

### 2.1 Hardware Requirements
- **CPU**: 64-bit x86_64 processor with minimum 4 cores (Host: 10 cores / 12 threads).
- **RAM**: Minimum 4 GiB available system memory (Host: 15 GiB physical RAM, 7.0 GiB unallocated).
- **Disk**: Minimum 10 GiB available storage on root partition (Host: 316 GiB available on `/`).

### 2.2 Software Dependencies
| Component | Minimum Version | Verified Host Version | Status |
|---|---|---|---|
| **Linux Kernel** | `>= 5.15` | `7.0.0-38-generic` | Operational |
| **Docker Engine** | `>= 24.0` | `29.9.1` (Docker Desktop) | Operational |
| **Docker Compose** | `>= 2.20` | `v5.1.4` (compose plugin) | Operational |
| **Python** | `>= 3.12` | `3.12.3` | Operational |
| **systemd** | `>= 245` | systemd 255 | Operational |
| **curl / wget** | Standard | curl 8.5.0, wget 1.21.4 | Operational |

---

## 3. End-to-End Deployment Procedure

### Step 1: Pre-Flight Verification
Run the automated preflight checker to validate Docker status, permissions, disk capacity, and port availability:
```bash
cd /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab
./deployment/deploy.sh preflight
```
*Expected Output:*
```
[INFO]  Docker Engine is operational.
[INFO]  Docker Compose is available (5.1.4).
[INFO]  Active .env configuration verified (mode 0600).
[INFO]  Filesystem capacity adequate: 316 GiB available.
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
