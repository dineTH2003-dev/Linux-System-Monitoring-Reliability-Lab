# Agent Interface Contract & System Standards

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Principal SRE Architect & Technical Integration Lead  
**Document Status:** Approved Engineering Contract  
**Date:** October 2026  

---

## 1. Purpose & Authority

This contract establishes the definitive, binding technical specifications for all components, scripts, collectors, alerts, and containerized services in the **Linux System Monitoring & Reliability Lab**. All eleven specialist workstreams and future contributors MUST strictly adhere to these interfaces to guarantee non-conflicting integration and flawless data interoperability.

---

## 2. Port Allocation & Binding Contract

To prevent network collisions with native host services (Prometheus on `:9090` and Grafana on `:3000`) and to prevent unauthorized exposure over physical network interfaces (LAN/WLAN/WAN), all services MUST follow this exact allocation and binding matrix:

| Component | Architecture Role | Host Port | Container Port | Interface Binding | Protocol | Enforcement Rule |
|---|---|---|---|---|---|---|
| **Node Exporter** | Host Telemetry | `9100` | N/A | `127.0.0.1` | HTTP (TCP) | Native host systemd daemon |
| **Python Monitoring Agent** | Custom Telemetry | `9101` | N/A | `127.0.0.1` | HTTP (TCP) | Standalone Python process |
| **Lab Prometheus** | Metrics TSDB | `9091` | `9090` | `127.0.0.1` | HTTP (TCP) | Docker loopback port mapping |
| **Lab Grafana** | Visualization | `3001` | `3000` | `127.0.0.1` | HTTP (TCP) | Docker loopback port mapping |
| **Lab Alertmanager** | Incident Router | `9093` | `9093` | `127.0.0.1` | HTTP (TCP) | Docker loopback port mapping |
| **Lab Blackbox Exporter** | Synthetic Probes | `9115` | `9115` | `127.0.0.1` | HTTP (TCP) | Docker loopback port mapping |
| **Lab Loki** | Log TSDB Engine | `3100` | `3100` | `127.0.0.1` | HTTP (TCP) | Docker loopback port mapping |
| **Lab Alloy** | Journal Shipper | `12345` | `12345` | `12345` | HTTP (TCP) | Docker loopback port mapping |

> [!CRITICAL]
> Under no circumstances may any container or script bind to `0.0.0.0` or expose ports on public interfaces. All Docker Compose port declarations MUST explicitly prefix `${HOST_BIND_IP:-127.0.0.1}:<host_port>:<container_port>`.

---

## 3. Metric Naming & Labeling Standards

### 3.1 Metric Naming Conventions

All metrics produced by the platform MUST conform to standard Prometheus naming taxonomy:
- **Format:** `<namespace>_<subsystem>_<metric_name>_<unit>`
- **Prefixes:**
  - `node_*`: Reserved exclusively for the official Linux Node Exporter (e.g., `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`).
  - `linux_agent_*`: Reserved exclusively for the Custom Python Monitoring Agent (e.g., `linux_agent_cpu_pressure_pct`, `linux_agent_disk_read_bytes_total`).
  - `probe_*`: Reserved for Blackbox Exporter synthetic metrics (e.g., `probe_success`, `probe_duration_seconds`).
  - `instance:*`: Reserved for recording rules and calculated SLI ratios (e.g., `instance:node_exporter_availability:ratio5m`).

### 3.2 Canonical Label Taxonomy

Every metric time-series ingested into Prometheus or Loki MUST incorporate the following canonical labels to ensure multi-dimensional correlation:

| Label Key | Permitted Values | Definition / Usage |
|---|---|---|
| `environment` | `lab` | Distinguishes lab telemetry from any host or corporate monitoring. |
| `instance` | `rubi` (or target hostname/IP) | Identifies the physical host or target endpoint. |
| `collector_type` | `node_exporter`, `python_agent`, `prometheus_internal`, `blackbox` | Identifies the origin telemetry engine. |
| `role` | `host_telemetry`, `custom_telemetry`, `monitoring_core`, `synthetics` | High-level architectural role of the metric stream. |
| `subsystem` | `cpu`, `memory`, `storage`, `disk_io`, `network`, `process`, `systemd`, `sre_sli` | Logical hardware or OS subsystem being observed. |
| `severity` | `critical`, `warning`, `info` | Applied to alerts and synthetic failures to govern routing. |

---

## 4. Alert Definition & Inhibition Standards

### 4.1 Alert Naming & Tiering Rules

All alert rules defined in `prometheus/alerts/` and `prometheus/rules/` MUST follow strict tiered naming to allow Alertmanager inhibition to function reliably:
1. **Tiered Suffix Convention:**
   - Warning tier: `<Resource><Condition>Warning` (e.g., `HostHighCpuUtilizationWarning`, `HostFilesystemSpaceWarning`, `HostInodeExhaustionWarning`).
   - Critical tier: `<Resource><Condition>Critical` (e.g., `HostHighCpuUtilizationCritical`, `HostFilesystemSpaceCritical`, `HostInodeExhaustionCritical`).
2. **Never create untiered root alerts** (e.g., `HostHighCpuUtilization` without suffix) if a tiered warning/critical pair exists. Untiered alerts bypass inhibition rules and generate notification duplicates.
3. **Target Availability Naming:**
   - Root host outage: `HostUnavailable`
   - Node Exporter scrape failure: `NodeExporterUnavailable`
   - Python Agent scrape failure: `PythonAgentUnavailable`
   - Dead-man heartbeat: `Watchdog`

### 4.2 Mandatory Alert Annotations

Every alert rule definition MUST supply the following structured annotations:
- `summary`: Concise one-line description including `$labels.instance` and primary metric value.
- `description`: Detailed explanation of the condition, threshold, and operational impact.
- `runbook_url`: Relative path within `docs/` pointing to the troubleshooting guide (e.g., `docs/troubleshooting/cpu-saturation.md`).
- `diagnostic_command`: Exact, non-destructive CLI command an operator can copy and run immediately on the host to diagnose the issue (e.g., `top -b -n 1 -o %CPU | head -n 20`).

### 4.3 Alertmanager Inhibition Rules

The canonical inhibition tree enforced in `alertmanager/alertmanager.yml` is defined as follows:

```yaml
inhibit_rules:
  # 1. Total Host failure inhibits all downstream exporter and metric alerts
  - source_matchers: [alertname = HostUnavailable]
    target_matchers: [severity =~ "critical|warning"]
    equal: ['instance']

  # 2. Node Exporter failure inhibits all derived hardware metric alerts
  - source_matchers: [alertname = NodeExporterUnavailable]
    target_matchers: [subsystem =~ "cpu|memory|storage|disk_io|network|swap"]
    equal: ['instance']

  # 3. Critical CPU saturation inhibits warning CPU alert
  - source_matchers: [alertname = HostHighCpuUtilizationCritical]
    target_matchers: [alertname = HostHighCpuUtilizationWarning]
    equal: ['instance']

  # 4. Critical storage exhaustion inhibits warning storage alert on same mount
  - source_matchers: [alertname = HostFilesystemSpaceCritical]
    target_matchers: [alertname = HostFilesystemSpaceWarning]
    equal: ['instance', 'mountpoint']

  # 5. Critical inode exhaustion inhibits warning inode alert on same mount
  - source_matchers: [alertname = HostInodeExhaustionCritical]
    target_matchers: [alertname = HostInodeExhaustionWarning]
    equal: ['instance', 'mountpoint']

  # 6. Critical memory exhaustion inhibits warning memory alert
  - source_matchers: [alertname = HostCriticalMemoryAvailable]
    target_matchers: [alertname = HostLowMemoryAvailable]
    equal: ['instance']

  # 7. Endpoint total outage inhibits endpoint latency degradation alerts
  - source_matchers: [alertname = BlackboxEndpointDown]
    target_matchers: [alertname =~ "BlackboxProbeLatencyHigh|BlackboxProbeSlowCritical|BlackboxHttpProbeFailed"]
    equal: ['instance']
```


---

## 5. Directory Structure & File Path Schema

To maintain repository cleanliness and ensure Docker volume mounts map cleanly without broken symlinks, all files MUST reside in their canonical locations:

```
Linux-System-Monitoring-Reliability-Lab/
├── agent/                           # Python Monitoring Agent Codebase
│   ├── collector/                   # 9 kernel/process collectors
│   ├── config.py                    # Schema validation
│   ├── main.py                      # CLI entrypoint
│   └── server.py                    # HTTP server (:9101) with SO_REUSEADDR
├── alertmanager/                    # Incident Detection & Alertmanager
│   ├── alertmanager.yml             # Canonical routing & inhibition
│   ├── docker-compose.yml           # Subsystem Compose (for unit testing)
│   └── templates/alerts.tmpl        # Alert notification templates
├── alloy/                           # Grafana Alloy Log Harvester
│   └── config.alloy                 # Journald scraping pipeline
├── blackbox/                        # Synthetic Probing Stack
│   ├── blackbox.yml                 # HTTP, TCP, DNS, ICMP probe modules
│   └── docker-compose.yml           # Subsystem Compose (for unit testing)
├── deployment/                      # Deployment & Lifecycle Automation
│   ├── backup.sh                    # TSDB volume backup script
│   ├── deploy.sh                    # Master deployment orchestration
│   ├── healthcheck.sh               # Post-deployment health verification
│   ├── restore.sh                   # TSDB volume restore script
│   └── systemd/                     # Host systemd service definitions
├── docs/                            # Comprehensive Technical Documentation
│   ├── architecture/                # System architecture & interface contract
│   ├── monitoring/                  # 18 subsystem monitoring guides
│   ├── project-management/          # Audit, roadmap, and task board
│   ├── reliability/                 # Testing framework & incident lifecycle
│   ├── reports/                     # 16 specialist assessment reports
│   ├── security/                    # Hardening guides and threat model
│   ├── sre/                         # SLI/SLO framework & error budget policy
│   └── troubleshooting/             # Operational runbooks (linked by alerts)
├── grafana/                         # Visualization & Dashboards
│   ├── dashboards/                  # 01 to 05 declarative JSON dashboards
│   └── provisioning/                # Auto-provisioning configs for datasources & dashboards
├── loki/                            # Centralized Log Aggregation
│   ├── docker-compose.yml           # Subsystem Compose (for unit testing)
│   └── loki-config.yaml             # Canonical TSDB v13 Loki 3.0 configuration
├── prometheus/                      # Metrics TSDB & Rules
│   ├── alerts/                      # Operational alert rules (infrastructure, blackbox)
│   ├── docker-compose.yml           # Subsystem Compose (for unit testing)
│   ├── prometheus.yml               # Canonical scrape configs & rule includes
│   ├── rules/                       # Recording rules & SRE SLI rules
│   └── tests/                       # Promtool rule test suites
├── scripts/                         # Operator Scripts & Diagnostics
│   ├── monitoring/                  # 7 standalone POSIX Bash tools
│   ├── reliability/                 # 9 injectors, 6 runbooks, lifecycle tracker
│   └── tests/                       # Bash test runner (83 assertions)
├── security/                        # Security Auditing & Scanners
│   ├── audit_permissions.sh         # Least privilege file permission auditor
│   ├── container_audit.sh           # Docker container hardening auditor
│   └── secret_scanner.sh            # Git repo credential scanner
├── tests/                           # Python Test Suites
│   ├── python/                      # 30 unit tests for Python Agent
│   └── reliability/                 # 25 unit/integration tests for Reliability Framework
└── docker-compose.yml               # Master Hardened Orchestration (Production Source of Truth)
```

---

## 6. Inter-Process & API Boundaries

### 6.1 Prometheus HTTP API
- **Scrape Path:** `GET /metrics` on targets. Responds with plain text Prometheus exposition format (`Content-Type: text/plain; version=0.0.4`).
- **Healthcheck Path:** `GET /-/healthy` returns `200 OK`.
- **Configuration Reload:** `POST /-/reload` triggers atomic configuration reload without process restart (enabled via `--web.enable-lifecycle`).

### 6.2 Loki HTTP API
- **Ingestion Path:** `POST /loki/api/v1/push` accepts snappy-compressed Protocol Buffer or JSON payloads from Alloy.
- **Query Path:** `GET /loki/api/v1/query` and `GET /loki/api/v1/query_range` accept LogQL expressions.
- **Readiness Path:** `GET /ready` returns `200 OK` (used by Docker healthchecks).

### 6.3 Alertmanager Webhook API
- **Alert Ingestion:** `POST /api/v2/alerts` receives firing/resolved alerts from Prometheus.
- **Healthcheck Path:** `GET /-/healthy` returns `200 OK`.

### 6.4 Custom Python Monitoring Agent API
- **Metrics Path:** `GET /metrics` returns host CPU, memory, storage, process, and systemd metrics collected via `psutil`.
- **Health Path:** `GET /health` returns JSON object `{"status": "healthy", "collectors": 9}`.
- **Socket Options:** Server MUST enable `SO_REUSEADDR` to permit immediate restart without `EADDRINUSE` port lockup.
