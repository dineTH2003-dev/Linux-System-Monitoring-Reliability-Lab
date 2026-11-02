# PromQL Reference Manual & Query Mechanics Guide

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 3.2 — PromQL Telemetry & Query Engineering  
**Role:** Senior Prometheus Engineer & Site Reliability Engineer (Agent 5)  
**Host Target:** Ubuntu 24.04 LTS (`rubi`, Linux Kernel `7.0.0-38-generic`, Intel Core i7-1355U, NVMe SSD)  

---

## 1. Executive Summary & Design Principles

In production Site Reliability Engineering, PromQL queries must not be treated as opaque strings copied from internet templates. Misunderstanding the arithmetic behind kernel time-series counters results in false alerts, misdiagnosed incidents, and inaccurate SLO tracking.

This reference manual documents the mathematical formulas, underlying Linux kernel data sources, calculation mechanics, and operational interpretation for all core telemetry subsystems.

### Core Principles Followed:
1. **Rate Window Sizing ($[\Delta t]$)**:
   - Always choose a rate interval at least $4\times$ the scrape interval ($4 \times 15\text{s} = 60\text{s} = 1\text{m}$) to ensure at least two to four samples are enclosed, even across transient scrape drops.
   - For alert evaluation, use $5\text{m}$ to smooth out micro-bursts and avoid alert flapping.
2. **Double-Counting Elimination**:
   - In `/proc/stat`, the kernel accounts guest virtual CPU time inside `user`. PromQL queries must account for this relationship when breaking down execution modes.
3. **True Memory Availability**:
   - Never compute used memory as `MemTotal - MemFree`. In Linux, unused memory is utilized for buffer/cache. Always base memory saturation on `node_memory_MemAvailable_bytes`.
4. **Filesystem Mount Filtering**:
   - Exclude virtual and pseudo-filesystems (`squashfs`, `tmpfs`, `devtmpfs`, `overlay`) to eliminate noise from read-only Snap packages.

---

## 2. Compute Subsystem (CPU)

### 2.1 Overall Host CPU Utilization %
**PromQL Expression:**
```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```
- **Underlying Kernel Counter**: `/proc/stat` column 4 (`idle`).
- **Calculation Mechanics**:
  - `rate(node_cpu_seconds_total{mode="idle"}[5m])` computes the per-second rate of increase of the idle jiffies counter for each logical CPU core.
  - `avg by (instance) (...)` averages the per-core idle fractions across all 12 logical cores (yielding a value between $0.0$ and $1.0$).
  - Multiplying by $100$ produces the percentage of total compute capacity spent in the idle task.
  - Subtracting from $100$ yields the active compute utilization percentage across all non-idle modes (`user`, `system`, `nice`, `iowait`, `irq`, `softirq`, `steal`).
- **SRE Interpretation**:
  - Measures total compute capacity consumed. Sustained values $>85\%$ indicate compute saturation where CPU-bound threads may begin queueing.

---

### 2.2 Per-Core CPU Idle Time %
**PromQL Expression:**
```promql
rate(node_cpu_seconds_total{mode="idle"}[5m]) * 100
```
- **Underlying Kernel Counter**: `/proc/stat` per-CPU line, column 4.
- **Calculation Mechanics**: Evaluates the idle percentage independently for each logical core (`cpu="0"` through `cpu="11"`).
- **SRE Interpretation**:
  - Essential for identifying **single-threaded bottlenecks** on multi-core systems. If `cpu0` reports $0\%$ idle while overall system utilization is only $8.3\%$ ($1/12$), a single-threaded bottleneck is saturating one thread while the remainder of the system appears deceptively idle.

---

### 2.3 CPU Execution Breakdown by Mode
**PromQL Expression:**
```promql
sum by (mode) (rate(node_cpu_seconds_total[5m]))
/ ignoring(mode) group_left
sum(rate(node_cpu_seconds_total[5m])) * 100
```
- **Underlying Kernel Counter**: `/proc/stat` fields 1–8.
- **Calculation Mechanics**:
  - Sums the rate of ticks spent in each mode across all cores, divided by the sum of all ticks across all modes, scaled to 100%.
  - Modes evaluated: `user`, `system`, `nice`, `idle`, `iowait`, `irq`, `softirq`, `steal`.
- **SRE Interpretation**:
  - **High `user`**: User-space application logic (Python compute, databases, compilation).
  - **High `system`**: High system call rates, context switching, memory page zeroing, or kernel lock contention.
  - **High `iowait`**: CPU core is idle while tasks are blocked on storage/network I/O; points to storage bottlenecks, not compute starvation.
  - **High `irq` / `softirq`**: High network packet ingress (NIC softIRQ processing in NAPI loops).

---

### 2.4 Normalized System Load Average
**PromQL Expression:**
```promql
node_load1 / count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})
```
- **Underlying Kernel Counter**: `/proc/loadavg` (field 1: 1-minute exponential moving average of tasks in `TASK_RUNNING` and `TASK_UNINTERRUPTIBLE` states).
- **Calculation Mechanics**:
  - `node_load1` is divided by the total number of logical processors counted dynamically via `count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})` (12 on host `rubi`).
- **SRE Interpretation**:
  - Normalized load $< 1.0$: System has capacity to absorb threads immediately without queueing.
  - Normalized load $= 1.0$: Exactly 100% capacity utilized; every core has exactly one runnable task.
  - Normalized load $> 1.0$: Thread queueing is occurring; tasks must wait for CPU time slices.
  - *Distinction from CPU %*: Load average includes tasks blocked in disk I/O (`D` state). A high load with low CPU utilization indicates severe disk I/O latency, not CPU exhaustion.

---

### 2.5 CPU Pressure Stall Information (PSI)
**PromQL Expression:**
```promql
rate(node_pressure_cpu_waiting_seconds_total[1m]) * 100
```
- **Underlying Kernel Counter**: `/proc/pressure/cpu` line `some`, cumulative counter `total` (converted to seconds).
- **Calculation Mechanics**:
  - Measures the percentage of wall-clock time in which at least one non-idle task was stalled waiting for an available CPU core.
- **SRE Interpretation**:
  - Direct quantitative measurement of CPU scheduling contention. Unlike load averages (which blend runnable and I/O-blocked tasks), CPU PSI isolatedly captures compute starvation. Values $>25\%$ warrant operational investigation.

---

## 3. Memory Subsystem

### 3.1 True Available Memory (Bytes)
**PromQL Expression:**
```promql
node_memory_MemAvailable_bytes
```
- **Underlying Kernel Counter**: `/proc/meminfo` field `MemAvailable`.
- **Calculation Mechanics**:
  - Estimated by the Linux kernel memory manager taking into account `MemFree`, reclaimable page cache, reclaimable slab memory, and kernel low-watermark reservations (`min_free_kbytes`).
- **SRE Interpretation**:
  - The truthful gauge of remaining memory headroom. If this value approaches zero, the host is in acute danger of invoking the kernel Out-Of-Memory (OOM) killer.

---

### 3.2 Memory Saturation Ratio & Percentage
**PromQL Expression:**
```promql
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```
- **Underlying Kernel Counter**: `/proc/meminfo` fields `MemAvailable` and `MemTotal`.
- **Calculation Mechanics**:
  - Computes the proportion of physical RAM that cannot be immediately reclaimed without swapping or dropping actively referenced working sets.
- **SRE Interpretation**:
  - Provides a normalized percentage ($0\% - 100\%$). SRE alerts trigger warning states at $>85\%$ and critical states at $>95\%$.

---

### 3.3 Dynamic Swap Activity (Thrashing Throughput)
**PromQL Expression:**
```promql
(rate(node_vmstat_pswpin[1m]) + rate(node_vmstat_pswpout[1m])) * 4096
```
- **Underlying Kernel Counter**: `/proc/vmstat` fields `pswpin` and `pswpout`.
- **Calculation Mechanics**:
  - `pswpin` counts pages read back into physical RAM from swap storage.
  - `pswpout` counts pages written out of physical RAM to swap storage.
  - Multiplying by standard Linux page size ($4096\text{ bytes} = 4\text{ KiB}$) translates page rates into bytes per second (Bps).
- **SRE Interpretation**:
  - Crucial metric distinguishing **inert cold swap** from **active swap thrashing**. Static swap allocation (`node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes`) carries zero instantaneous performance impact. In contrast, non-zero swap I/O ($>10\text{ MB/s}$) indicates that active working sets are being evicted to disk, causing millisecond-scale memory access delays.

---

### 3.4 Memory Pressure Stall Information (PSI `some` and `full`)
**PromQL Expressions:**
```promql
# Some: at least one task stalled on memory
rate(node_pressure_memory_waiting_seconds_total[1m]) * 100

# Full: ALL non-idle tasks stalled on memory
rate(node_pressure_memory_stalled_seconds_total[1m]) * 100
```
- **Underlying Kernel Counter**: `/proc/pressure/memory` lines `some` and `full`.
- **Calculation Mechanics**:
  - `waiting_seconds_total` tracks cumulative microseconds where $\ge 1$ task stalled on page reclaim or swap-in.
  - `stalled_seconds_total` tracks cumulative microseconds where all productive compute halted while waiting for memory.
- **SRE Interpretation**:
  - `some > 10%`: Background or direct page reclaim is active, introducing micro-latencies.
  - `full > 0%`: Severe thrashing. The host is experiencing complete execution paralysis due to memory starvation.

---

## 4. Storage Subsystem (Filesystem & Block I/O)

### 4.1 Filesystem Utilization Ratio (Excluding Snap & Virtual Mounts)
**PromQL Expression:**
```promql
1 - (node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes{fstype=~"ext4|xfs"})
```
- **Underlying Kernel Counter**: `statvfs()` system call via `/proc/self/mountinfo`.
- **Calculation Mechanics**:
  - Evaluates available unprivileged blocks (`f_bavail * f_frsize`) over total blocks (`f_blocks * f_frsize`).
  - Label filter `{fstype=~"ext4|xfs"}` strictly isolates physical writeable filesystems, filtering out 41 read-only SquashFS Snap packages and memory-backed `tmpfs` mounts.
- **SRE Interpretation**:
  - Values range from $0.0$ to $1.0$. Reflects capacity available to unprivileged user applications (preserving the root reservation).

---

### 4.2 Inode Utilization Ratio
**PromQL Expression:**
```promql
1 - (node_filesystem_files_free{fstype=~"ext4|xfs"} / node_filesystem_files{fstype=~"ext4|xfs"})
```
- **Underlying Kernel Counter**: `statvfs()` system call (`f_ffree` over `f_files`).
- **Calculation Mechanics**:
  - Computes the percentage of allocated inode table entries consumed by directories and file handles.
  - Label filter `{fstype=~"ext4|xfs"}` ensures filesystems with zero-inode allocation models (such as FAT32 `/boot/efi`) are not evaluated, preventing division-by-zero errors.
- **SRE Interpretation**:
  - Filesystems can exhaust capacity in two independent ways: disk bytes or inode handles. A filesystem with $300\text{ GB}$ of free space will return `ENOSPC` on file creation if inodes reach $100\%$.

---

### 4.3 Filesystem Depletion Linear Prediction
**PromQL Expression:**
```promql
predict_linear(node_filesystem_avail_bytes{fstype=~"ext4|xfs"}[1h], 4 * 3600) < 0
```
- **Calculation Mechanics**:
  - Performs a linear regression across the preceding 1 hour of available byte telemetry and extrapolates the trajectory 4 hours into the future ($4 \times 3600\text{s} = 14400\text{s}$).
- **SRE Interpretation**:
  - Proactive predictive alerting. Fires before static capacity thresholds are breached when an aggressive log leak or rogue process is rapidly consuming disk capacity.

---

### 4.4 Disk Read and Write Throughput (Bps)
**PromQL Expressions:**
```promql
# Read Throughput
sum by (device) (rate(node_disk_read_bytes_total{device=~"nvme.*|sd.*|vd.*"}[1m]))

# Write Throughput
sum by (device) (rate(node_disk_written_bytes_total{device=~"nvme.*|sd.*|vd.*"}[1m]))
```
- **Underlying Kernel Counter**: `/proc/diskstats` fields 3 (sectors read) and 7 (sectors written) multiplied by 512 bytes per sector.
- **SRE Interpretation**:
  - Measures storage payload throughput in bytes per second. Essential for tracking backup cycles, database flushes, and bulk data movement.

---

### 4.5 Disk IOPS (Input/Output Operations Per Second)
**PromQL Expression:**
```promql
sum by (device) (
  rate(node_disk_reads_completed_total{device=~"nvme.*|sd.*|vd.*"}[1m]) +
  rate(node_disk_writes_completed_total{device=~"nvme.*|sd.*|vd.*"}[1m])
)
```
- **Underlying Kernel Counter**: `/proc/diskstats` fields 1 (reads completed) and 5 (writes completed).
- **SRE Interpretation**:
  - High IOPS with low byte throughput indicates random small-block access patterns (e.g., transactional databases or inode walks).

---

### 4.6 Average I/O Latency ($r\_await$ and $w\_await$)
**PromQL Expressions:**
```promql
# Read Latency (Seconds per read)
rate(node_disk_read_time_seconds_total{device=~"nvme.*"}[1m])
/ clamp_min(rate(node_disk_reads_completed_total{device=~"nvme.*"}[1m]), 0.001)

# Write Latency (Seconds per write)
rate(node_disk_write_time_seconds_total{device=~"nvme.*"}[1m])
/ clamp_min(rate(node_disk_writes_completed_total{device=~"nvme.*"}[1m]), 0.001)
```
- **Underlying Kernel Counter**: `/proc/diskstats` field 4 (ms spent reading) and field 8 (ms spent writing).
- **Calculation Mechanics**:
  - Total time spent servicing requests divided by total requests completed. `clamp_min(..., 0.001)` prevents division-by-zero during periods of zero I/O activity.
- **SRE Interpretation**:
  - True metric of storage responsiveness. Modern NVMe drives operate at read latencies $<100\text{ }\mu\text{s}$ ($0.0001\text{s}$). Values exceeding $10\text{ ms}$ indicate severe queue saturation or NAND controller garbage collection stalls.

---

## 5. Network Subsystem

### 5.1 Network Throughput (Bytes per Second)
**PromQL Expressions:**
```promql
# Ingress (RX) Throughput
sum by (device) (rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*"}[1m]))

# Egress (TX) Throughput
sum by (device) (rate(node_network_transmit_bytes_total{device!~"lo|docker.*|veth.*"}[1m]))
```
- **Underlying Kernel Counter**: `/proc/net/dev` columns 1 (RX bytes) and 9 (TX bytes).
- **Calculation Mechanics**:
  - `rate(...[1m])` computes per-second byte transfer rates.
  - Excludes virtual loopback (`lo`), Docker bridge networks (`docker0`), and container veth interfaces (`veth*`) to capture true physical adapter traffic (`wlo1`).

---

### 5.2 Network Packet Rates (Packets per Second)
**PromQL Expressions:**
```promql
# Ingress (RX) Packets
sum by (device) (rate(node_network_receive_packets_total{device!~"lo|docker.*|veth.*"}[1m]))

# Egress (TX) Packets
sum by (device) (rate(node_network_transmit_packets_total{device!~"lo|docker.*|veth.*"}[1m]))
```
- **Underlying Kernel Counter**: `/proc/net/dev` columns 2 (RX packets) and 10 (TX packets).
- **SRE Interpretation**:
  - Evaluates NIC interrupt workload. A flood of small packets (e.g., SYN flood or DNS amplification) can exhaust CPU softIRQ capacity even at low byte throughput.

---

### 5.3 Network Errors and Packet Drops
**PromQL Expressions:**
```promql
# Packet Drops (Ingress + Egress)
sum by (device) (
  rate(node_network_receive_drop_total[1m]) +
  rate(node_network_transmit_drop_total[1m])
)

# Packet Errors (Ingress + Egress)
sum by (device) (
  rate(node_network_receive_errs_total[1m]) +
  rate(node_network_transmit_errs_total[1m])
)
```
- **Underlying Kernel Counter**: `/proc/net/dev` columns 3/4 (RX errs/drop) and 11/12 (TX errs/drop).
- **SRE Interpretation**:
  - Drops indicate ring buffer exhaustion (`rx_dropped`) or kernel socket queue overflow. Errors reflect physical layer signal degradation or CRC checksum mismatches. In a healthy production environment, error rates should be exactly zero.

---

## 6. Service Health & Observability Core

### 6.1 Exporter Target Availability (`up`)
**PromQL Expression:**
```promql
up{job=~"node|python-agent|prometheus"}
```
- **Value**: Binary gauge ($1 = \text{reachable and scraped successfully}, 0 = \text{down}$).
- **SRE Interpretation**:
  - Fundamental availability indicator used for uptime calculation and alert routing.

---

### 6.2 Scrape Latency SLI (p95 Scrape Duration)
**PromQL Expression:**
```promql
quantile_over_time(0.95, scrape_duration_seconds{job="node"}[1h])
```
- **Calculation Mechanics**: Calculates the 95th percentile scrape duration over a 1-hour sliding window.
- **SRE Interpretation**:
  - Monitors exporter performance degradation. If scrape durations approach the scrape timeout ($10\text{s}$), scrapes will abort, causing telemetry blackouts.

---

### 6.3 Failed systemd Units Count
**PromQL Expression:**
```promql
sum(node_systemd_unit_state{state="failed"} == 1)
```
- **Underlying Kernel Counter**: systemd D-Bus interface via Node Exporter systemd collector.
- **SRE Interpretation**:
  - Provides instant detection of background service crashes, failed timer executions, or dead daemons.

---

### 6.4 Custom Python Agent Health
**PromQL Expression:**
```promql
linux_agent_collector_success == 0
```
- **Calculation Mechanics**: Evaluates collector health across all 9 custom collectors (`cpu`, `memory`, `swap`, `filesystem`, `inode`, `disk_io`, `network`, `process`, `systemd`).
- **SRE Interpretation**:
  - Pinpoints internal collector exceptions or missing kernel interfaces without crashing the agent process.
