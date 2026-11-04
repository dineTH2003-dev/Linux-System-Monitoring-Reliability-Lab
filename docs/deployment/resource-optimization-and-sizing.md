# Resource Optimization & Capacity Sizing Guide

This guide documents the measured resource footprint of the Linux System Monitoring & Reliability Lab platform, sizing guidelines for single-host and multi-host installations, tuning options, and operational boundaries.

All data in this document is derived from direct empirical measurements on a native Linux system running Docker Engine v27.x.

---

## 1. Measured Resource Consumption

Measurements were captured under steady-state operating conditions with active telemetry collection across three monitored Linux instances (primary host + 2 simulated remote hosts: `node-02`, `node-03`), 5 Grafana dashboards, continuous systemd journal log ingestion via Grafana Alloy into Loki, and Alertmanager routing.

### A. Central Server Containers

| Service | Container Name | Measured Memory (Idle / Baseline) | Memory Limit (Compose) | Measured CPU % (Idle) | CPU Limit (Compose) | Block I/O (Read / Write) |
|---|---|---|---|---|---|---|
| **Prometheus** | `lab-prometheus` | ~92 MiB | 1024 MiB | 1.1% | 1.0 core | 406 kB / 10.5 MB |
| **Grafana** | `lab-grafana` | ~73 MiB | 512 MiB | 0.2% | 1.0 core | 664 kB / 303 kB |
| **Loki** | `lab-loki` | ~118 MiB | 512 MiB | 1.2% | 0.5 core | 188 kB / 9.8 MB |
| **Alertmanager** | `lab-alertmanager` | ~21 MiB | 256 MiB | 0.3% | 0.5 core | 115 kB / 0 B |
| **Blackbox Exporter**| `lab-blackbox-exporter` | ~22 MiB | 128 MiB | 0.8% | 0.25 core | 0 B / 0 B |
| **Grafana Alloy** | `lab-alloy` | ~45 MiB | 384 MiB | 1.6% | 0.5 core | 795 kB / 389 kB |
| **Total Central Server** | — | **~371 MiB** | **2,816 MiB** | **~5.2%** | **3.75 cores** | — |

*Note: Total RAM for all 6 core monitoring services is approximately **371 MiB**, well within the capacity of modest 2 GB RAM virtual machines.*

### B. Per-Host Telemetry Agents

| Component | Process / Service | Memory (RSS / RAM) | CPU % (Steady-State) | Network Telemetry Rate |
|---|---|---|---|---|
| **Node Exporter** | `prometheus-node-exporter` | ~18.4 MiB | <0.1% | ~25 kB/min per scrape target |
| **Custom Python Agent** | `agent.main` (Python 3.12) | ~26.4 MiB | ~0.4% | ~12 kB/min per scrape target |
| **Simulated Mock Node** | `lab-mock-node-02/03` | ~11.5 MiB | <0.05% | ~25 kB/min |

### C. Persistent Storage & Growth Rates

| Component | Storage Path / Volume | Current Disk Size | Retention Policy | Projected Growth (3 Hosts) |
|---|---|---|---|---|
| **Prometheus TSDB** | `lab_prometheus_data` (`/prometheus`) | ~113 MiB | 15 days (`10GB` max) | ~15–25 MB / day |
| **Loki Log Chunks** | `lab_loki_data` (`/loki`) | ~54 MiB | 7 days (168 hours) | ~8–15 MB / day |
| **Grafana DB** | `lab_grafana_data` (`/var/lib/grafana`) | ~1.5 MiB | Permanent | Static (~100 kB / month) |
| **Alloy Buffer** | `lab_alloy_data` (`/data-alloy`) | ~4.2 MiB | Transient WAL | Bounded (<50 MB) |

### D. Time-Series Cardinality & Ingestion

- **Total Active Time-Series in Prometheus TSDB:** ~7,200 series (across 3 monitored instances).
  - Primary host (`primary-node`): ~1,920 series.
  - Remote host 2 (`node-02`): ~1,570 series.
  - Remote host 3 (`node-03`): ~1,560 series.
  - Internal Prometheus & synthetic probes: ~830 series.
- **Top Metrics by Cardinality:**
  - `node_systemd_unit_state`: ~990 series (filtered down to active units only; inactive/deactivating states dropped at ingestion).
  - `node_cpu_seconds_total`: 384 series (12 logical cores x 8 CPU modes x 3 hosts).
  - Zero-value kernel counters (`node_nfs_*`, `node_nfsd_*`, `node_cpu_guest_*`) are excluded via metric relabeling, preventing over 500 unnecessary series from entering memory.
- **Loki Log Ingestion:**
  - Raw uncompressed log throughput: ~7 MB across 24 hours.
  - All log streams indexed by low-cardinality labels: `job`, `host`, `unit`, `level`, `transport`. Dynamic process IDs (`__journal__pid`) and desktop scopes are dropped at ingestion to prevent cardinality explosion.

### E. Dashboard Query Latency

PromQL query execution times measured against the live Prometheus server (`:9091`):

| Query Type | Typical Expression | Measured Latency |
|---|---|---|
| **CPU Utilization Ratio** | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` | 2.38 ms |
| **Available RAM %** | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100` | 2.25 ms |
| **Disk Throughput** | `rate(node_disk_read_bytes_total[5m]) + rate(node_disk_written_bytes_total[5m])` | 2.41 ms |
| **Network Traffic** | `rate(node_network_receive_bytes_total{device!~"lo\|veth.*\|docker.*"}[5m])` | 4.18 ms |
| **Per-Core CPU Rate** | `rate(node_cpu_seconds_total[5m])` | 4.71 ms |
| **Instance Core Count** | `count by (instance) (node_cpu_seconds_total{mode="idle"})` | 2.10 ms |
| **Grafana Health API** | `GET /api/health` | 1.56 ms |

All core queries evaluate in under 5 milliseconds, ensuring fluid dashboard rendering with minimal query overhead.

---

## 2. Capacity Sizing Guidelines

| Fleet Size | Minimum Central Server Specs | Recommended Specs | Storage Allocation | Agent Footprint per Host |
|---|---|---|---|---|
| **Small Lab (1–3 hosts)** | 2 vCPUs, 2 GB RAM | 2 vCPUs, 4 GB RAM | 20 GB SSD | ~45 MB RAM, <1% CPU |
| **Department Fleet (4–10 hosts)** | 2 vCPUs, 4 GB RAM | 4 vCPUs, 8 GB RAM | 50 GB SSD | ~45 MB RAM, <1% CPU |
| **Scale Fleet (11–25 hosts)** | 4 vCPUs, 8 GB RAM | 4 vCPUs, 16 GB RAM | 120 GB SSD | ~45 MB RAM, <1% CPU |

---

## 3. Tuning Options

### A. Tuning Prometheus Scrape Cadence
The default scrape interval is **15s** for host metrics and **30s** for synthetic blackbox probes:
- In environments with severe network or CPU constraints, scrape intervals can be increased to **30s** or **60s** in `prometheus/prometheus.yml`:
  ```yaml
  global:
    scrape_interval: 30s
    evaluation_interval: 30s
  ```
- *Trade-off:* 30s scrape interval halves TSDB storage growth, but increases metric detection latency and doubles the time required to detect brief CPU/I/O spikes.

### B. Tuning TSDB Retention
Configured via `.env` or flags in `docker-compose.yml`:
- `PROMETHEUS_RETENTION_TIME=15d` (adjust to `7d` for constrained disks, or `30d` for longer historical analysis).
- `PROMETHEUS_RETENTION_SIZE=10GB` (enforces hard storage cap; oldest blocks pruned automatically when size is exceeded).

### C. Tuning Loki Log Retention
Configured in `loki/loki-config.yaml`:
- `retention_period: 168h` (7 days).
- Compactor active deletion is enabled (`retention_enabled: true`). To reduce disk usage on constrained systems, lower to `72h` (3 days).

### D. Tuning Custom Python Agent Process Limits
Configured in `agent/config.yaml`:
- `max_processes: 500`: Bounds process table scanning to prevent excessive `/proc` iteration during process storms.
- `top_n_cpu: 5` and `top_n_mem: 5`: Exposes only the top 5 consumers, strictly bounding metric cardinality.

---

## 4. Supported Deployment Environments & Limitations

### Supported Environments
1. **Ubuntu 24.04 LTS / 22.04 LTS (x86_64, aarch64)** with native Docker Engine (v24.x+ or v27.x+) and Docker Compose v2.x.
2. **Debian 12 (Bookworm)** with native Docker Engine.
3. **Enterprise Linux (RHEL 9 / Rocky Linux 9)** with container-selinux and Docker CE or rootless Podman.

### Verified Deployment Modes
- **Single-Host Native Monitoring:** Central server running in Docker, monitoring the native host via loopback bindings.
- **Centralized Multi-Host Monitoring:** Central server monitoring multiple remote hosts via Prometheus File-SD target discovery (`prometheus/targets/node_*.json`) and remote log shipping.

### Known Limitations
1. **Host Telemetry in Containerized Node Exporter:**
   - Running Node Exporter inside a container requires `--pid=host`, `--net=host`, and mounting `/proc` and `/sys` from the host. In strict multi-tenant environments where rootless containers are mandated, native systemd installation (`apt install prometheus-node-exporter`) is required for full hardware counter fidelity.
2. **Synthetic Probing Across Firewalled Networks:**
   - Blackbox ICMP and TCP probes require direct IP route reachability. If remote hosts are behind NAT or strict cloud security groups without a VPN/tunnel, Blackbox probes will report `probe_success == 0`.
3. **Physical Multi-Host Testing:**
   - In this repository's automated test fixture, secondary and tertiary nodes (`node-02`, `node-03`) are simulated using isolated Node Exporter containers on the Docker bridge network. Validation across physically distinct bare-metal machines or separate cloud VMs requires network routing and firewall configuration as described in `multi-host-monitoring.md`.
