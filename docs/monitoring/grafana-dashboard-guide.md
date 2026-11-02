# Grafana Dashboard & Operational Observability Guide

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Senior Observability Engineer & Site Reliability Engineer  
**Target Environment:** Ubuntu 24.04 LTS (`rubi`, Linux 7.0.0-38-generic)  
**Grafana Target:** Grafana v10+ / v13+  

---

## 1. Observability Visualization Philosophy & Architecture

In production Site Reliability Engineering (SRE), monitoring dashboards are not decorative wall displays; they are **interactive investigation consoles engineered to accelerate incident triage and minimize Mean Time to Detect (MTTD) and Mean Time to Restore (MTTR)**.

### 1.1 Core Visualization Principles
1. **High Signal-to-Noise Ratio**: Operational dashboards avoid visual clutter and redundant data streams. Every panel must answer a specific hypothesis during system degradation.
2. **Grounding in Linux Kernel Reality**: Metric calculations strictly mirror the underlying kernel accounting mechanics (`/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/pressure/*`). We never invent metrics or present synthetic approximations when kernel ground truth is available.
3. **Consistent Units & Standardization**:
   - Storage and Memory: IEC binary units (`bytes`, `KiB`, `MiB`, `GiB`).
   - Throughput & Bandwidth: Byte rates (`Bps` - bytes/sec) or packet rates (`pps`).
   - IOPS: Input/output operations per second (`iops`).
   - Latency: Base SI seconds (`s`) with Grafana auto-scaling down to milliseconds and microseconds.
   - Percentages: Standard 0–100% scale (`percent`) with consistent green/yellow/red thresholding.
4. **Reproducible Dashboard-as-Code**: Dashboards are version-controlled JSON objects provisioned automatically through declarative Grafana providers. No production dashboard relies on ad-hoc manual UI configuration.

---

## 2. Dashboard Suite Architecture & Navigation

The platform provides five specialized operational dashboards structured in an investigation hierarchy:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   DASHBOARD INVESTIGATION HIERARCHY                    │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  [Alert Fired / Triage Triggered]                                      │
│                │                                                       │
│                ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────┐      │
│  │ Dashboard 1: Linux System Overview                           │      │
│  │ (30-Second Situational Awareness: Host, CPU, RAM, Disk, Net) │      │
│  └──────────────────────────────┬───────────────────────────────┘      │
│                                 │                                      │
│         ┌───────────────────────┼────────────────────────┐             │
│         ▼                       ▼                        ▼             │
│  ┌──────────────┐       ┌──────────────┐         ┌──────────────┐      │
│  │ Dashboard 2: │       │ Dashboard 3: │         │ Dashboard 4: │      │
│  │ CPU & Memory │       │ Storage & FS │         │ Network &    │      │
│  │ Subsystem    │       │ Subsystem    │         │ Processes    │      │
│  └──────────────┘       └──────────────┘         └──────────────┘      │
│                                 ▲                                      │
│                                 │                                      │
│  ┌──────────────────────────────┴──────────────────────────────┐      │
│  │ Dashboard 5: Reliability Overview                           │      │
│  │ (SLI Availability, 99.9% SLO Compliance, Error Budgets,     │      │
│  │  Burn Rates & Kernel Degradation Indicators)                │      │
│  └─────────────────────────────────────────────────────────────┘      │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Provisioning & Template Variables

### 3.1 Provisioning Configuration (`dashboards.yaml`)
Dashboards are provisioned via `grafana/provisioning/dashboards/dashboards.yaml`. When Grafana launches, it registers the file provider and loads all JSON models from the configured path:

```yaml
apiVersion: 1

providers:
  - name: 'Linux System Monitoring & Reliability Lab'
    orgId: 1
    folder: 'Linux System Monitoring'
    type: file
    disableDeletion: false
    editable: true
    updateIntervalSeconds: 15
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

### 3.2 Templating Variables Strategy
To ensure 100% portability across environments (workstation, containerized Compose, multi-node lab), dashboards define dynamic variables:

| Variable | Type | Query / Definition | Operational Purpose |
|---|---|---|---|
| `$datasource` | Datasource | `prometheus` (type: prometheus) | Allows seamless switching between local and containerized Prometheus endpoints without hardcoding internal UIDs. |
| `$instance` | Query | `label_values(node_uname_info, instance)` | Multi-host instance filter supporting `$__all` aggregation. |
| `$device` | Query | `label_values(node_disk_read_bytes_total, device)` | Filters physical and virtual block storage devices with regex `/^(nvme.*\|sd.*\|vd.*)$/`. |
| `$mountpoint` | Query | `label_values(node_filesystem_size_bytes{fstype=~"ext4\|xfs"}, mountpoint)` | Filesystem volume filter isolating persistent storage partitions. |
| `$interface` | Query | `label_values(node_network_up{device!~"lo\|docker.*\|veth.*"}, device)` | Physical and wireless network interface selector excluding loopback and virtual bridges. |

---

## 4. Dashboard 1 — Linux System Overview

**UID:** `linux-system-overview`  
**Purpose:** Provides a rapid, single-pane operational health check of the monitored Linux system.

### 4.1 Panel Inventory & Technical Specifications

| Panel Title | Visual Type | PromQL Query | Unit | Description |
|---|---|---|---|---|
| **Host Availability** | Stat (Background) | `up{job="node",instance=~"$instance"}` | `percentunit` | Boolean probe health ($1 = \text{UP}, 0 = \text{DOWN}$). Turns red immediately if the exporter fails to respond. |
| **System Uptime** | Stat (Value) | `time() - node_boot_time_seconds{job="node",instance=~"$instance"}` | `dthms` | Elapsed time since last kernel boot. Detects unannounced reboots. |
| **CPU Utilization** | Gauge | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle",job="node",instance=~"$instance"}[$__rate_interval])) * 100)` | `percent` | Total compute utilization aggregated across all 12 logical processors. |
| **Memory Utilization** | Gauge | `(1 - (node_memory_MemAvailable_bytes{job="node",instance=~"$instance"} / node_memory_MemTotal_bytes{job="node",instance=~"$instance"})) * 100` | `percent` | Utilization based on `MemAvailable` rather than naive free memory. |
| **Available Memory** | Stat (Area sparkline) | `node_memory_MemAvailable_bytes{job="node",instance=~"$instance"}` | `bytes` | Headroom available for starting new applications without swapping. |
| **Active Firing Alerts** | Stat (Background) | `count(ALERTS{alertstate="firing"}) or vector(0)` | `short` | Count of active firing Prometheus alert rules. Green if 0, Red if $\ge 1$. |
| **CPU Utilization by Mode** | Timeseries (Stacked) | `sum by (mode) (rate(node_cpu_seconds_total{mode!="idle",job="node",instance=~"$instance"}[$__rate_interval])) / ignoring(mode) group_left count without (cpu, mode) (node_cpu_seconds_total{mode="idle",job="node",instance=~"$instance"}) * 100` | `percent` | Continuous breakdown across user, system, iowait, nice, steal, irq modes. |
| **Memory Utilization & Available Bytes** | Timeseries (Multi-line) | `MemTotal - MemAvailable`, `MemAvailable`, `Cached`, `Buffers` | `bytes` | Tracks memory consumption trends against kernel disk cache allocations. |
| **Filesystem Capacity Utilization** | Bar Gauge | `(1 - (node_filesystem_avail_bytes{fstype=~"ext4\|xfs",...} / node_filesystem_size_bytes{...})) * 100` | `percent` | Storage space consumption across root and data mountpoints. |
| **Filesystem Inode Utilization** | Bar Gauge | `(1 - (node_filesystem_files_free{fstype=~"ext4\|xfs",...} / node_filesystem_files{...})) * 100` | `percent` | Metadata index node allocation across persistent volumes. |
| **Disk I/O Throughput** | Timeseries | `sum by (device) (rate(node_disk_read_bytes_total{...}[$__rate_interval]))` and written bytes | `Bps` | Combined read and write storage throughput. |
| **Network Interface Throughput** | Timeseries | `rate(node_network_receive_bytes_total{...}[$__rate_interval])` and transmit bytes | `Bps` | Inbound (RX) and outbound (TX) bandwidth on active interfaces. |
| **Swap Activity (Pages In / Out)** | Timeseries | `rate(node_vmstat_pswpin{...}[$__rate_interval]) * 4096` and `pswpout` | `Bps` | Instantaneous swap transfer rates indicating active page thrashing. |
| **Active Firing Alerts** | Table | `ALERTS{alertstate="firing"}` | Table | Detailed listing of alert names, severities, and labels. |

---

## 5. Dashboard 2 — CPU and Memory

**UID:** `cpu-and-memory`  
**Purpose:** Kernel-level compute, scheduling contention, memory anatomy, and memory pressure analysis.

### 5.1 Panel Inventory & Technical Specifications

| Panel Title | Visual Type | PromQL Query | Unit | Description |
|---|---|---|---|---|
| **Active CPU Utilization** | Gauge | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle",...}[$__rate_interval])) * 100)` | `percent` | Instantaneous total active compute load across all cores. |
| **System Load (1m)** | Stat | `node_load1{job="node",...}` | `short` | 1-minute exponentially damped system load average. |
| **CPU Pressure (PSI Some)** | Stat | `rate(node_pressure_cpu_waiting_seconds_total{...}[$__rate_interval]) * 100` | `percent` | Percentage of time tasks were runnable but delayed waiting for CPU scheduling. |
| **Memory Utilization** | Gauge | `(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100` | `percent` | Proportion of physical RAM currently committed. |
| **Swap Space Used %** | Stat | `(1 - (node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes)) * 100` | `percent` | Proportion of swap backing file allocated. |
| **Memory Pressure (PSI Some)** | Stat | `rate(node_pressure_memory_waiting_seconds_total{...}[$__rate_interval]) * 100` | `percent` | Percentage of time tasks were stalled waiting for memory reclaim or swap-in. |
| **CPU Utilization by Mode** | Timeseries (Stacked) | `sum by (mode) (rate(node_cpu_seconds_total{mode!="idle",...}[$__rate_interval])) / ignoring(mode) group_left count without (cpu, mode) (node_cpu_seconds_total{mode="idle",...}) * 100` | `percent` | High-fidelity stacked view separating user compute, kernel syscall overhead, and I/O wait. |
| **System Load Average vs. Core Capacity** | Timeseries | `node_load1`, `node_load5`, `node_load15` vs `count(node_cpu_seconds_total{mode="idle"})` | `short` | Compares multi-window load against the physical core capacity threshold (12 on `rubi`). |
| **Memory Allocation Breakdown** | Timeseries | Used (`MemTotal - MemAvailable`), Page Cache (`Cached`), Buffers, Free (`MemFree`) | `bytes` | Full decomposition of kernel physical memory allocations. |
| **Reclaimable Slab & Anonymous Memory** | Timeseries | `Active_anon`, `Inactive_anon`, `SReclaimable`, `SUnreclaim` | `bytes` | Distinguishes application anonymous pages from reclaimable dentry/inode caches. |
| **Swap Space Usage & Allocation** | Timeseries | Swap Total, Swap Used, Swap Free | `bytes` | Capacity tracking of swap backing storage. |
| **Swap Paging Rates (Thrashing Activity)** | Timeseries | `rate(node_vmstat_pswpin[...]) * 4096` and `pswpout` | `Bps` | Dynamic paging speed. Distinguishes inert cold swap pages from active thrashing. |
| **Compute & Memory Pressure (PSI Stalls)** | Timeseries | CPU Some, Memory Some, Memory Full | `percent` | Correlates CPU scheduling contention with memory reclaim stalls. |

### 5.2 Key SRE Metric Interpretations
- **I/O Wait (`iowait`)**: While tasks are blocked waiting for disk I/O, the CPU core is in an **idle state**; it is not consuming compute cycles. High iowait indicates storage subsystem bottleneck, not CPU starvation.
- **Pressure Stall Information (PSI)**:
  - `some`: At least one runnable thread was stalled waiting for a resource.
  - `full`: **All** runnable threads were stalled simultaneously (zero productive work happening across the system).

---

## 6. Dashboard 3 — Storage and Filesystem

**UID:** `storage-and-filesystem`  
**Purpose:** Block device throughput, IOPS, read/write wait latency, VFS filesystem capacity, and I/O saturation.

### 6.1 Panel Inventory & Technical Specifications

| Panel Title | Visual Type | PromQL Query | Unit | Description |
|---|---|---|---|---|
| **Root Filesystem Utilization** | Gauge | `(1 - (node_filesystem_avail_bytes{mountpoint="/"...} / node_filesystem_size_bytes{mountpoint="/"...})) * 100` | `percent` | Available user capacity on the primary root volume. |
| **Root Available Space** | Stat | `node_filesystem_avail_bytes{mountpoint="/"...}` | `bytes` | Free bytes available to unprivileged user processes. |
| **Root Inode Utilization** | Gauge | `(1 - (node_filesystem_files_free{mountpoint="/"...} / node_filesystem_files{mountpoint="/"...})) * 100` | `percent` | Percentage of allocated ext4 inodes consumed on root. |
| **Total Disk Read Bandwidth** | Stat | `sum(rate(node_disk_read_bytes_total{device=~"$device"...}[$__rate_interval]))` | `Bps` | Aggregate block device read bandwidth. |
| **Total Disk Write Bandwidth** | Stat | `sum(rate(node_disk_written_bytes_total{device=~"$device"...}[$__rate_interval]))` | `Bps` | Aggregate block device write bandwidth. |
| **I/O Pressure (PSI Some)** | Stat | `rate(node_pressure_io_waiting_seconds_total{...}[$__rate_interval]) * 100` | `percent` | Percentage of time tasks were stalled waiting for storage I/O completion. |
| **Filesystem Capacity & Mount Inventory** | Table | `node_filesystem_size_bytes` and `node_filesystem_avail_bytes` | Table | Complete table of persistent partitions, sizes, available space, and filesystem types. |
| **Inode Utilization by Filesystem** | Bar Gauge | `(1 - node_filesystem_files_free / node_filesystem_files) * 100` | `percent` | Inode consumption per filesystem. Excludes `vfat` (which lacks Unix inodes). |
| **Disk Read and Write Throughput** | Timeseries | `rate(node_disk_read_bytes_total{device=~"$device"...})` and write bytes | `Bps` | Read and write data transfer rates for the selected `$device`. |
| **Disk Read and Write IOPS** | Timeseries | `rate(node_disk_reads_completed_total{device=~"$device"...})` and write ops | `iops` | Completed read and write requests per second handled by the controller. |
| **Disk Average I/O Latency (r_await & w_await)** | Timeseries | Read Latency: `rate(node_disk_read_time_seconds_total) / rate(node_disk_reads_completed_total)` | `s` | Average response latency per I/O operation (queue time + device transfer time). |
| **Device Saturation (%util)** | Timeseries | `rate(node_disk_io_time_seconds_total{device=~"$device"...}[$__rate_interval]) * 100` | `percent` | Proportion of time the storage controller had requests in flight. |
| **Storage I/O Pressure Stall Information (PSI)** | Timeseries | I/O Some (Waiting) and I/O Full (Stalled) | `percent` | Quantifies real system execution loss caused by slow storage devices. |

---

## 7. Dashboard 4 — Network and Processes

**UID:** `network-and-processes`  
**Purpose:** Network interface bandwidth, packet transfer rates, frame drops/errors, process execution states, and systemd service health.

### 7.1 Panel Inventory & Technical Specifications

| Panel Title | Visual Type | PromQL Query | Unit | Description |
|---|---|---|---|---|
| **Network Inbound (RX)** | Stat | `sum(rate(node_network_receive_bytes_total{device=~"$interface"...}[$__rate_interval]))` | `Bps` | Current incoming traffic rate on selected interfaces. |
| **Network Outbound (TX)** | Stat | `sum(rate(node_network_transmit_bytes_total{device=~"$interface"...}[$__rate_interval]))` | `Bps` | Current outgoing traffic rate on selected interfaces. |
| **Packet Drop Rate** | Stat | Sum of receive and transmit drops/s | `pps` | Total packets discarded by kernel buffers. |
| **Processes Running** | Stat | `node_procs_running{job="node"...}` | `short` | Count of threads actively running or waiting in scheduler run-queues (`TASK_RUNNING`). |
| **Processes Blocked (I/O Wait)** | Stat | `node_procs_blocked{job="node"...}` | `short` | Count of threads blocked in uninterruptible sleep (`TASK_UNINTERRUPTIBLE` / `D-state`). |
| **Failed systemd Services** | Stat | `count(node_systemd_unit_state{state="failed"...} == 1) or vector(0)` | `short` | Total systemd services in failed state. |
| **Network Throughput (RX / TX Bytes)** | Timeseries | `rate(node_network_receive_bytes_total)` and transmit bytes | `Bps` | Continuous ingress and egress bandwidth. |
| **Network Packet Rates (PPS)** | Timeseries | `rate(node_network_receive_packets_total)` and transmit packets | `pps` | Inbound and outbound packet processing frequency. |
| **Network Packet Drops (RX / TX)** | Timeseries | `rate(node_network_receive_drop_total)` and transmit drops | `pps` | Drops caused by socket buffer exhaustion or NIC ring overflows. |
| **Network Hardware Errors (RX / TX)** | Timeseries | `rate(node_network_receive_errs_total)` and transmit errors | `pps` | Physical layer errors, framing errors, or FIFO overruns. |
| **Process Execution States & Fork Rate** | Timeseries | `node_procs_running`, `node_procs_blocked`, and `rate(node_forks_total)` | `short` | Identifies process scheduling bottlenecks and rapid process creation storms. |
| **Monitored Daemon CPU Consumption** | Timeseries | `rate(process_cpu_seconds_total[$__rate_interval]) * 100` | `percent` | CPU utilization consumed by monitoring daemons (`prometheus`, `node_exporter`). |
| **Monitored Daemon Memory Footprint** | Timeseries | `process_resident_memory_bytes` and `process_virtual_memory_bytes` | `bytes` | Physical RAM (RSS) and address space (VSZ) allocated to monitoring daemons. |
| **Failed systemd Services Inventory** | Table | `node_systemd_unit_state{state="failed"...} == 1` | Table | Names and types of failed system services requiring remediation. |

---

## 8. Dashboard 5 — Reliability Overview

**UID:** `reliability-overview`  
**Purpose:** Quantitative Site Reliability Engineering (SRE) management: availability SLIs, 99.9% SLO compliance tracking, error budget burn rates, and kernel failure indicators.

### 8.1 SRE Definitions & Mathematical Formulations
- **Availability SLI**: The ratio of successful scrape probes over total expected probes across the selected time window:
  $$\text{SLI}_{\text{avail}} = \text{avg\_over\_time}(\text{up}\{\text{job}="node"\}[T]) \times 100$$
- **Target SLO**: **99.9% availability** ($0.999$) across a 30-day sliding window.
- **Allowed Failure Margin**: $1 - 0.999 = 0.001$ ($0.1\%$).
- **Consumed Error Budget %**:
  $$\text{Consumed Budget \%} = \frac{1 - \text{avg\_over\_time}(\text{up}[T])}{0.001} \times 100$$
- **Remaining Error Budget %**:
  $$\text{Remaining Budget \%} = \max\left(0, 100 - \text{Consumed Budget \%}\right)$$
- **Error Budget Burn Rate**:
  $$\text{Burn Rate} = \frac{1 - \text{avg\_over\_time}(\text{up}[1\text{h}])}{0.001}$$
  - $\text{Burn Rate} = 1.0$: Consumes exactly 100% of the budget over the 30-day window.
  - $\text{Burn Rate} = 14.4$: Consumes 2% of the error budget in 1 hour (rapid page alert threshold).

### 8.2 Panel Inventory & Technical Specifications

| Panel Title | Visual Type | PromQL Query | Unit | Description |
|---|---|---|---|---|
| **Host Telemetry Availability SLI** | Gauge | `avg_over_time(up{job="node",...}[$__range]) * 100` | `percent` | Rolling availability percentage over the active dashboard time range. |
| **SLO Compliance Status** | Stat (Background) | `(avg_over_time(up{job="node",...}[$__range]) * 100) >= bool 99.9` | `short` | Boolean compliance indicator ($1 = \text{COMPLIANT}$, $0 = \text{BREACHED}$). |
| **Remaining Error Budget %** | Gauge | `clamp_min((1 - ((1 - avg_over_time(up{...}[$__range])) / 0.001)) * 100, 0)` | `percent` | Headroom remaining before the 99.9% reliability commitment is exhausted. |
| **1-Hour Error Budget Burn Rate** | Stat | `(1 - avg_over_time(up{job="node",...}[1h])) / 0.001` | `short` | Speed of budget consumption. Values $>1.0$ indicate unsustainable failure rates. |
| **OOM Killer Invocations** | Stat | `increase(node_vmstat_oom_kill{...}[$__range])` | `short` | Count of processes killed by the kernel Out-of-Memory killer during the window. |
| **Degraded Service Units** | Stat | `count(node_systemd_unit_state{state="failed"...} == 1) or vector(0)` | `short` | Count of degraded host services impacting host reliability. |
| **Service Availability SLI Trend** | Timeseries | `avg_over_time(up{job="node"...}[5m]) * 100` and `up{job="prometheus"...}` | `percent` | Availability timeline with an explicit 99.9% SLO threshold line. |
| **Scrape Latency SLI (p95 & Mean)** | Timeseries | `quantile_over_time(0.95, scrape_duration_seconds{...}[5m])` | `s` | 95th percentile and mean duration of metric collection queries. |
| **Cumulative Error Budget Consumption %** | Timeseries | `clamp_min((1 - avg_over_time(up[...])) / 0.001 * 100, 0)` | `percent` | Depletion trajectory of the error budget over time. |
| **Multi-Window Error Budget Burn Rate** | Timeseries | 1-hour and 6-hour burn rates compared to $1.0\times$ and $14.4\times$ thresholds | `short` | Multi-window burn-rate tracking matching Google SRE alerting standards. |
| **Kernel OOM Invocations & Memory Stalls** | Timeseries | `increase(node_vmstat_oom_kill[5m])` and Memory Full PSI % | `short` | Correlates fatal process terminations with extreme memory pressure. |
| **systemd System Running State** | Timeseries | `node_systemd_system_running` and failed units count | `short` | Tracking host systemd overall health state transitions over time. |
| **Alertmanager Active & Pending Alerts** | Table | `ALERTS` | Table | Complete audit log of firing and pending alert rules. |

---

## 9. Incident Triage Playbooks Using the Dashboards

### 9.1 Playbook: Investigating High CPU Contention
1. **Open Dashboard 1 (Linux System Overview)**:
   - Check the **CPU Utilization** gauge. If $>85\%$, proceed to detailed analysis.
2. **Navigate to Dashboard 2 (CPU and Memory)**:
   - Inspect **CPU Utilization by Mode**:
     - If `user` is dominant: Compute-bound user application.
     - If `system` is dominant: Excessive syscalls, context switching, or lock contention.
     - If `iowait` is dominant: The CPU is idle waiting for storage. Switch to Dashboard 3.
   - Inspect **CPU Pressure (PSI Some)**:
     - If CPU Utilization is 95% but PSI Some is $<1\%$: Efficient batch execution; no starvation.
     - If PSI Some is $>10\%$: Severe thread queue contention; tasks are experiencing significant scheduling delays.
   - Inspect **System Load vs Core Capacity**:
     - Compare 1m, 5m, and 15m load against the 12-core threshold line.

### 9.2 Playbook: Investigating Memory Starvation & OOM Incidents
1. **Open Dashboard 5 (Reliability Overview)**:
   - Check **OOM Killer Invocations**. If $\ge 1$, an Out-Of-Memory incident occurred.
2. **Navigate to Dashboard 2 (CPU and Memory)**:
   - Inspect **Available Memory**: Check how low `MemAvailable` dropped prior to the event.
   - Inspect **Swap Paging Rates**: Check if swap throughput (`pswpin`/`pswpout`) spiked immediately before the kill, proving active memory thrashing.
   - Inspect **Memory Pressure (PSI Full)**: Verify whether `full` PSI spiked, indicating the entire system stalled on memory allocation.
3. **Navigate to Dashboard 4 (Network and Processes)**:
   - Check **Monitored Daemon Memory Footprint** to verify whether observability processes experienced runaway memory leaks.

### 9.3 Playbook: Investigating Storage Exhaustion or I/O Stalls
1. **Open Dashboard 3 (Storage and Filesystem)**:
   - Inspect **Root Filesystem Utilization** and **Root Inode Utilization**:
     - If byte utilization is $100\%$: Filesystem capacity exhaustion.
     - If byte utilization is $20\%$ but Inode utilization is $100\%$: **Inode exhaustion outage** (millions of small files blocking writes with `ENOSPC`).
   - Inspect **Disk Average I/O Latency ($r\_await$ / $w\_await$)**:
     - Normal NVMe latency: $<1\text{ ms}$ ($0.001\text{ s}$).
     - Latency $>20\text{ ms}$: Storage controller bottleneck or NAND write saturation.
   - Inspect **Device Saturation (%util)**:
     - If $\%util > 90\%$ sustained, the storage device is at queue capacity.
   - Inspect **Storage I/O Pressure (PSI Some & Full)** to measure application stall impact.
