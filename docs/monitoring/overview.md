# Linux Telemetry, Custom Agent & Dashboard Guide

## 1. Overview of Telemetry Architecture

The monitoring platform collects metrics from the Linux host through two complementary agents:
1. **Node Exporter (`:9100`)**: Standard Prometheus host collector gathering low-level hardware, memory, disk, and network counters.
2. **Custom Python Monitoring Agent (`:9101`)**: A lightweight, modular daemon written in Python 3 using `psutil` and direct `/proc` parsing to demonstrate custom metric instrumentation.
3. **Bash Monitoring Suite (`scripts/monitoring/`)**: 7 standalone CLI diagnostic scripts using POSIX utilities (`vmstat`, `iostat`, `mpstat`, `df`, `ip`, `systemctl`) for manual triage.

Metrics are scraped by **Prometheus (`:9091`)** every 15 seconds, evaluated against recording and alert rules, and visualized in **5 provisioned Grafana dashboards (`:3001`)**.

---

## 2. Kernel Telemetry Sources & Custom Collector Implementation

The custom Python agent (`agent/`) implements an isolated registry (`agent/registry.py`) where each collector inherits from `agent/collector/base.py`. If one collector encounters an unexpected error, other collectors continue executing without disruption.

The agent gathers data directly from Linux virtual filesystems:

| Kernel Interface | What It Provides | Parsed Metric in Agent | Prometheus Metric Name |
|---|---|---|---|
| `/proc/stat` | Cumulative CPU ticks spent in each mode (user, system, idle, iowait, etc.) | CPU mode utilization and core count | `custom_cpu_usage_ratio`, `custom_cpu_cores_total` |
| `/proc/pressure/cpu` | Pressure Stall Information (PSI): percentage of time tasks are stalled on CPU | 10s, 60s, 300s CPU stall percentages | `custom_cpu_pressure_some_ratio` |
| `/proc/meminfo` | Real-time memory breakdown (`MemTotal`, `MemFree`, `MemAvailable`, `Buffers`, `Cached`, `SwapTotal`, `SwapFree`) | Available RAM %, Swap %, and absolute byte counters | `custom_memory_available_bytes`, `custom_swap_used_ratio` |
| `/proc/pressure/memory` | PSI memory stall metrics (some / full) | Memory pressure stall ratios | `custom_memory_pressure_some_ratio` |
| `/proc/diskstats` | Sectors read/written, I/O in progress, time spent doing I/O | Read/write throughput and I/O latency | `custom_disk_io_read_bytes_total`, `custom_disk_io_write_bytes_total` |
| `/proc/mounts` & `statvfs` | Active mountpoints, filesystem types, block sizes, free blocks, and inodes | Disk capacity and inode saturation | `custom_filesystem_usage_ratio`, `custom_inode_usage_ratio` |
| `/proc/net/dev` | Network interface rx/tx bytes, packets, drops, and errors | Throughput and interface error rates | `custom_network_receive_bytes_total`, `custom_network_errors_total` |
| `systemctl` / D-Bus | State of critical host systemd units | Failed unit count and service status | `custom_systemd_units_failed_total` |

---

## 3. Prometheus Scrape Configuration (`prometheus/prometheus.yml`)

Prometheus operates in a hardened container listening on loopback `127.0.0.1:9091`. It is configured with targeted scrape jobs:

- **`job="node"`**: Scrapes the host Node Exporter (`:9100`).
- **`job="custom-agent"`**: Scrapes the Python monitoring daemon (`127.0.0.1:9101/metrics`).
- **`job="prometheus"`**: Scrapes Prometheus internal runtime metrics (`localhost:9090`).
- **`job="blackbox-http"`**: Probes local HTTP endpoints (`/healthz`, `/api/health`).
- **`job="blackbox-dns"`**: Probes public DNS resolvers (`1.1.1.1:53`, `8.8.8.8:53`).
- **`job="alloy"`**: Scrapes Grafana Alloy telemetry pipeline (`:12345`).

Scrape interval is set to **15s** with a **10s** timeout, and TSDB data retention is configured for **15 days** (`--storage.tsdb.retention.time=15d`).

---

## 4. Provisioned Grafana Dashboards

The lab automatically provisions 5 operational dashboards from declarative JSON files in `grafana/dashboards/`:

### 1. `01 — Linux System Overview`
- **Purpose:** High-level operational health of the host.
- **Key Panels:**
  - Active CPU Utilization (`100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval])) * 100)`)
  - CPU Utilization by Mode (Stacked user, system, iowait, softirq, steal)
  - Normalized System Load Average (1m, 5m, 15m load divided by logical core count)
  - Memory Utilization Breakdown (Used, Cached, Buffers, Free)
  - Storage Mount Capacity (% used per mount)
  - Network Interface Bandwidth (Receive vs. Transmit bytes/sec)

### 2. `02 — CPU and Memory`
- **Purpose:** Deep-dive kernel compute and memory diagnostics.
- **Key Panels:**
  - Per-Core CPU Utilization heatmap
  - Pressure Stall Information: CPU waiting time vs. Memory stalled time
  - Major and Minor Page Fault Rates (`rate(node_vmstat_pgmajfault[$__rate_interval])`)
  - Swap Activity & Thrashing Detection (`pswpin` / `pswpout`)

### 3. `03 — Storage and Filesystem`
- **Purpose:** Physical storage performance and capacity forecasting.
- **Key Panels:**
  - Disk Read/Write Throughput (`rate(node_disk_read_bytes_total)`)
  - Disk Read/Write Latency (`await` time calculation)
  - Filesystem Fill-Rate Prediction (`predict_linear(...)` extrapolating disk full in < 48h)
  - Inode Utilization (%)

### 4. `04 — Network and systemd`
- **Purpose:** Network interface health and host service reliability.
- **Key Panels:**
  - Network Traffic & Packet Rates
  - Interface Drop and Error Rates (`node_network_receive_drop_total`)
  - Sockets in Use (TCP established, time-wait, close-wait)
  - systemd Service Active States and Failed Unit Alerts

### 5. `05 — Python Agent & SRE Overview`
- **Purpose:** Custom Python agent introspection and SRE availability tracking.
- **Key Panels:**
  - Agent Collector Execution Duration (`custom_agent_collector_duration_seconds`)
  - Collector Error Rates (`custom_agent_collector_errors_total`)
  - 99.9% SLO Error Budget Remaining (%)
  - Multi-Window Error Budget Burn Rates (14.4x fast burn, 6x medium burn, 1x slow burn)

---

## 5. Centralized Logging (Loki & Grafana Alloy)

Log collection is decoupled from metrics to prevent log storms from degrading time-series ingestion:
1. **Grafana Alloy (`:12345`)**: Runs in a hardened container mapped to read `/var/log/journal` via group GID `999` (`systemd-journal`).
2. **Label Extraction**: Alloy extracts unit names, priority levels, and syslog identifiers from journal entries.
3. **Grafana Loki (`:3100`)**: Stores chunked log streams on persistent volume `lab_loki_data`.
4. **LogQL Exploration**: Operators can query logs directly in Grafana using LogQL:
   ```logql
   {unit="docker.service"} |= "error"
   {unit="linux-monitoring-agent.service"}
   ```
