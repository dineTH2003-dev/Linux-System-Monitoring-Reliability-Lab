# Prometheus Monitoring Architecture & Server Configuration

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 3.1 — Prometheus Infrastructure & Scrape Architecture  
**Role:** Senior Prometheus Engineer & Site Reliability Engineer (Agent 5)  
**Target Environment:** Local Ubuntu 24.04 LTS (`rubi`, Linux Kernel `7.0.0-38-generic`)  
**Deployment Model:** Containerized Isolated Stack (Docker Compose) on Host Port `9091`  

---

## 1. High-Level Architecture & Isolation Model

The Linux System Monitoring & Reliability Lab couples bare-metal Linux kernel observability with an isolated, reproducible containerized Prometheus monitoring platform.

### 1.1 Coexistence & Port Conflict Resolution
The physical Ubuntu workstation already runs native monitoring services managed by host systemd:
- Native Prometheus: listening on `0.0.0.0:9090`
- Native Node Exporter: listening on `0.0.0.0:9100`
- Native Grafana: listening on `0.0.0.0:3000`

In strict adherence to SRE safety and non-interference requirements, **none of the native services are stopped, disabled, overwritten, or reconfigured**. Instead, the project-owned Prometheus monitoring stack operates inside an isolated Docker container with strict host port mapping:
- **Project Prometheus Port**: `127.0.0.1:9091 -> container 9090`
- **Native Host Prometheus**: remains untouched on `9090`
- **Native Host Node Exporter**: leveraged directly on `9100` as the authoritative source of physical kernel and hardware metrics
- **Custom Python Agent**: leveraged on `9101` for high-resolution process and systemd telemetry

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Native Services (Preserved & Untouched):                             │
│   • Native Prometheus (:9090) ── [HOST SYSTEMD - PRESERVED]            │
│   • Native Grafana (:3000)    ── [HOST SYSTEMD - PRESERVED]            │
│   • Native Node Exporter (:9100) ── [Direct Kernel Instrumentation]   │
│   • Custom Python Agent (:9101)  ── [psutil /proc /sys Exporter]      │
│                                 ▲                                      │
│                                 │ HTTP Scrapes via                     │
│                                 │ host.docker.internal                 │
│     ┌───────────────────────────┴────────────────────────────────┐     │
│     │          PROJECT-OWNED PROMETHEUS STACK (COMPOSE)          │     │
│     │                                                            │     │
│     │  ┌──────────────────────────────────────────────────────┐  │     │
│     │  │  Prometheus Server Container (prom/prometheus:v2.51) │  │     │
│     │  │  • Container Internal Port: 9090                     │  │     │
│     │  │  • Host Mapping: 127.0.0.1:9091:9090 (Loopback only) │  │     │
│     │  │  • Scrape Jobs:                                      │  │     │
│     │  │    - node (host.docker.internal:9100)                │  │     │
│     │  │    - python-agent (host.docker.internal:9101)        │  │     │
│     │  │    - prometheus (localhost:9090)                     │  │     │
│     │  │  • Rules:                                            │  │     │
│     │  │    - rules/recording_rules.yml (25 rules)            │  │     │
│     │  │    - rules/alert_rules.yml (18 rules)                │  │     │
│     │  │  • TSDB Storage: lab_prometheus_data volume          │  │     │
│     │  └──────────────────────────────────────────────────────┘  │     │
│     └────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Container-to-Host Network Routing

Because the local Docker daemon is provided by **Docker Desktop for Linux** (operating via an accelerated QEMU LinuxKit virtual machine), containerized processes do not share the host's loopback namespace (`127.0.0.1` inside a container refers to the container itself).

### 2.1 Empirical Routing Validation
Container-to-host connectivity was empirically tested prior to finalizing configuration:
1. **Host-Gateway DNS Resolution**: `host.docker.internal` is mapped via Compose `extra_hosts: ["host.docker.internal:host-gateway"]`, resolving to `192.168.65.2` (the QEMU host proxy).
2. **Wildcard Bind (`0.0.0.0:9100`)**: The host Node Exporter bound to `0.0.0.0:9100` answered HTTP probes from inside test containers with `HTTP/1.1 200 OK` (Node Exporter v1.7.0).
3. **Loopback Bind (`127.0.0.1`)**: Tested by launching a temporary HTTP server bound exclusively to `127.0.0.1:9199`. An isolated container querying `http://host.docker.internal:9199` received `HTTP/1.1 200 OK`, proving that Docker Desktop's host proxy routes requests to loopback-bound host services.

---

## 3. Prometheus Server Configuration (`prometheus.yml`)

The primary configuration resides at `prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  external_labels:
    environment: 'lab'
    monitor: 'linux-system-monitoring-lab'
    host: 'rubi'

rule_files:
  - 'rules/recording_rules.yml'
  - 'rules/alert_rules.yml'

scrape_configs:
  # 1. Native Node Exporter running on physical Ubuntu host
  - job_name: 'node'
    scrape_interval: 15s
    scrape_timeout: 10s
    metrics_path: '/metrics'
    static_configs:
      - targets: ['host.docker.internal:9100']
        labels:
          instance: 'rubi'
          collector_type: 'node_exporter'
          role: 'host_telemetry'

  # 2. Custom Python Monitoring Agent running on Ubuntu host
  - job_name: 'python-agent'
    scrape_interval: 15s
    scrape_timeout: 10s
    metrics_path: '/metrics'
    static_configs:
      - targets: ['host.docker.internal:9101']
        labels:
          instance: 'rubi'
          collector_type: 'python_agent'
          role: 'custom_telemetry'

  # 3. Prometheus Server Self-Monitoring
  - job_name: 'prometheus'
    scrape_interval: 15s
    scrape_timeout: 10s
    static_configs:
      - targets: ['localhost:9090']
        labels:
          instance: 'lab-prometheus'
          collector_type: 'prometheus_internal'
          role: 'monitoring_core'
```

### 3.1 Scrape Cadence & Timeout Justification
- **`scrape_interval: 15s`**: Aligned with SRE best practices for system metrics. Provides high-resolution visibility into transient CPU and memory spikes without incurring excessive TSDB storage churn.
- **`evaluation_interval: 15s`**: Synchronized with the scrape interval so that recording rules and alert evaluations operate on freshly scraped sample points without artificial phase delays.
- **`scrape_timeout: 10s`**: Enforces a strict upper bound. Scrapes exceeding 10 seconds are aborted, leaving a 5-second buffer before the next scrape window and preventing scrape queue piling.

---

## 4. Scrape Jobs & Target Roles

| Job Name | Target URI | Protocol | Role | Key Telemetry Harvested |
|---|---|---|---|---|
| **`node`** | `host.docker.internal:9100` | HTTP/GET | Physical Host Telemetry | Kernel CPU modes, memory watermarks, diskstats, ext4 block/inode stats, network interface counters, systemd unit states. |
| **`python-agent`** | `host.docker.internal:9101` | HTTP/GET | Custom Agent Telemetry | Process state counts, top-N CPU/memory consumers, systemd unit states, custom memory saturation markers. |
| **`prometheus`** | `localhost:9090` | HTTP/GET | Monitoring Core Health | TSDB compaction time, scrape duration, series count, query engine latency, rule evaluation performance. |

### 4.2 Uniform Metric Labeling Schema
To ensure consistent PromQL querying across dashboards and alert engines, all targets are annotated with standard target labels:
- `instance`: Static host identifier (`rubi` for host collectors, `lab-prometheus` for TSDB).
- `collector_type`: Distinguishes exporter origin (`node_exporter`, `python_agent`, `prometheus_internal`).
- `role`: Functional classification (`host_telemetry`, `custom_telemetry`, `monitoring_core`).
- `environment`: `lab` (injected via `external_labels`).
- `monitor`: `linux-system-monitoring-lab` (injected via `external_labels`).

---

## 5. Target Health & Observability Metrics

Prometheus generates synthetic telemetry for every scrape target automatically:

1. **`up{job="..."}` (Gauge)**:
   - Value `1`: Target scrape succeeded and returned valid Prometheus exposition format within `scrape_timeout`.
   - Value `0`: Target unreachable, timed out, DNS failure, or HTTP error response.
2. **`scrape_duration_seconds{job="..."}` (Gauge)**:
   - Measures network round-trip time plus target metric generation latency.
   - Used for SLI/SLO measurement and slow-scrape alerting.
3. **`scrape_samples_scraped{job="..."}` (Gauge)**:
   - Number of distinct time-series samples returned in the scrape payload.
4. **`scrape_series_added{job="..."}` (Gauge)**:
   - Number of new time series introduced in the scrape pool.

---

## 6. Docker Compose Deployment Specification

The isolated container stack is defined in `prometheus/docker-compose.yml`:

```yaml
services:
  prometheus:
    image: prom/prometheus:v2.51.0
    container_name: lab-prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:9091:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --storage.tsdb.retention.size=10GB
      - --web.enable-lifecycle
      - --web.listen-address=0.0.0.0:9090
    extra_hosts:
      - "host.docker.internal:host-gateway"
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:9090/-/healthy || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s

volumes:
  prometheus_data:
    name: lab_prometheus_data
```

### 6.1 Security & Reliability Controls
1. **Loopback Port Binding (`127.0.0.1:9091`)**: Prevents Prometheus from being exposed on the workstation's physical wireless interface (`wlo1`) or local area network.
2. **Read-Only Volume Mounts (`:ro`)**: `prometheus.yml` and `rules/` are mounted read-only, preventing runtime modification by the container process.
3. **Storage Retention Constraints**: Enforces dual retention limits (`15d` time retention and `10GB` size cap) to prevent TSDB growth from exhausting the host's root NVMe partition.
4. **Lifecycle API (`--web.enable-lifecycle`)**: Enables runtime configuration reload via HTTP POST to `/-/reload` without container restarts or service interruptions.

---

## 7. Operational Management Procedures

### 7.1 Starting the Stack
```bash
cd /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/prometheus
docker compose up -d
```

### 7.2 Stopping the Stack
```bash
cd /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/prometheus
docker compose down
```

### 7.3 Validating Configuration & Rules with Promtool
```bash
# Validate server configuration
cd /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/prometheus
promtool check config prometheus.yml

# Validate individual rule files
promtool check rules rules/recording_rules.yml
promtool check rules rules/alert_rules.yml

# Execute automated unit test suite
cd /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/prometheus/tests
promtool test rules rule_tests.yml
```

### 7.4 Reloading Configuration at Runtime
```bash
curl -X POST http://127.0.0.1:9091/-/reload
```

### 7.5 Inspecting Target Health via CLI
```bash
curl -s http://127.0.0.1:9091/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, instance: .labels.instance, health: .health, lastError: .lastError}'
```
