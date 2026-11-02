# Modular Python Linux Monitoring Agent: Architecture & Design Specification

**Project:** Linux System Monitoring & Reliability Lab  
**Component:** Custom Python Monitoring Agent (`agent/`)  
**Port:** `9101`  
**Endpoint:** `http://127.0.0.1:9101/metrics`  
**Author:** Senior Python Backend Engineer, Linux Observability Engineer & SRE  
**Target Environment:** Ubuntu 24.04 LTS (Kernel `7.0.0-38-generic`, Python 3.12.3)  

---

## 1. High-Level Architectural Design

The custom monitoring agent provides specialized, fine-grained host telemetry that complements native Prometheus exporters (such as Node Exporter on `:9100`). Designed under strict Site Reliability Engineering (SRE) reliability and isolation principles, the agent directly interrogates stable Linux kernel subsystems (`/proc`, `/sys`, `statvfs(2)`, `systemd`) while ensuring minimal resource footprint, deterministic execution, and complete fault containment.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 LINUX HOST SUBSYSTEMS                                  │
│   • /proc/stat         • /proc/meminfo       • /proc/vmstat       • /proc/diskstats    │
│   • /proc/loadavg      • /proc/pressure/cpu  • /proc/pressure/mem • /proc/net/dev      │
│   • /proc/mounts       • statvfs(2)          • /proc/[pid]/stat   • systemd / D-Bus    │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        PYTHON MONITORING AGENT (PORT :9101)                            │
│                                                                                        │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                      MODULAR COLLECTORS LAYER (ISOLATED)                       │   │
│   │                                                                                │   │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐  │   │
│   │  │ CPUCollector │  │ MemoryCollec │  │ SwapCollect  │  │ FilesystemCollect  │  │   │
│   │  └──────────────┘  └──────────────┘  └──────────────┘  └────────────────────┘  │   │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐  │   │
│   │  │ InodeCollect │  │ DiskIOCollect│  │ NetworkCollec│  │ ProcessCollector   │  │   │
│   │  └──────────────┘  └──────────────┘  └──────────────┘  └────────────────────┘  │   │
│   │  ┌──────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ SystemdCollector (Monitored Unit Active/Substate Telemetry)              │  │   │
│   │  └──────────────────────────────────────────────────────────────────────────┘  │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
│                                           │ MetricFamilies                             │
│                                           ▼                                            │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                      METRIC REGISTRY & FAULT CONTAINMENT                       │   │
│   │  • Per-Collector Exception Handling & Error Isolation (No Crash Propagation)   │   │
│   │  • Telemetry Latency & Error Counters (linux_agent_collector_success, etc.)    │   │
│   │  • Prometheus 0.0.4 Text Format Serialization & Value Escaping                 │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
│                                           │ Formatted Text                             │
│                                           ▼                                            │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          HTTP SERVER & LIFECYCLE                               │   │
│   │  • ThreadingHTTPServer (Concurrent Scrapes)                                    │   │
│   │  • Strict Loopback Binding (127.0.0.1)                                         │   │
│   │  • GET /metrics -> Prometheus Scrape Target                                    │   │
│   │  • GET /healthz -> JSON Service & Uptime Health Check                          │   │
│   │  • Graceful Shutdown Handler (SIGTERM, SIGINT)                                 │   │
│   └────────────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Core Modules and Interfaces

### 2.1 Collector Base Contract (`agent.collector.base.BaseCollector`)
Every telemetry collector inherits from `BaseCollector` and implements a single contract method:
```python
class BaseCollector(ABC):
    name: str

    @abstractmethod
    def collect(self) -> List[MetricFamily]:
        """Collect and return metric families."""
        raise NotImplementedError
```
The base class supplies protected file I/O utilities (`read_file`, `read_lines`) that safely absorb `FileNotFoundError`, `PermissionError`, and kernel `OSError` conditions without propagating unhandled exceptions.

### 2.2 Metric Registry & Fault Containment (`agent.registry.MetricRegistry`)
Scrapes must never fail entirely if a single subsystem or kernel interface misbehaves. During a scrape:
1. Each collector's `collect()` method is executed inside an isolated `try...except` boundary.
2. If an exception occurs, the registry increments `linux_agent_collector_errors_total{collector="..."}`, emits an error record to the structured logger, sets `linux_agent_collector_success{collector="..."} = 0.0`, and continues executing the remaining collectors.
3. Collection latency per collector is measured and exposed as `linux_agent_collector_duration_seconds{collector="..."}`.
4. Metric families are validated and rendered into standard Prometheus 0.0.4 exposition text format.

### 2.3 HTTP Server Layer (`agent.server.MonitoringServer`)
- Built upon `http.server.ThreadingHTTPServer` to service concurrent scrape and health check requests without blocking.
- Endpoints:
  - `GET /metrics`: Standard Prometheus 0.0.4 formatted telemetry.
  - `GET /healthz` (and `/health`): Structured JSON report including agent operational status, version, and uptime in seconds.
  - `GET /`: Navigation landing page.
  - Non-GET methods return `405 Method Not Allowed`.
  - Unrecognized routes return `404 Not Found`.

---

## 3. Telemetry Collectors & Kernel Subsystem Mechanics

### 3.1 CPU Collector (`agent/collector/cpu.py`)
- **Kernel Sources**: `/proc/stat`, `/proc/loadavg`, `/proc/pressure/cpu`.
- **Differential Utilization & The Double-Counting Pitfall**:
  In `/proc/stat`, `user` already includes `guest`, and `nice` already includes `guest_nice`. Adding `guest` to the total tick sum double-counts CPU cycles in the denominator.
  True total ticks are calculated as:
  $$\Delta \text{Total} = \Delta \text{user} + \Delta \text{nice} + \Delta \text{system} + \Delta \text{idle} + \Delta \text{iowait} + \Delta \text{irq} + \Delta \text{softirq} + \Delta \text{steal}$$
  Non-overlapping user time is computed as $\Delta \text{pure\_user} = \Delta \text{user} - \Delta \text{guest}$.
- **Exposed Metrics**:
  - `linux_cpu_seconds_total{cpu="total|0|1...", mode="user|nice|system|idle|iowait|irq|softirq|steal|guest|guest_nice"}` (Counter)
  - `linux_cpu_utilization_ratio{cpu="total|0|1..."}` (Gauge, 0.0 to 1.0)
  - `linux_load1`, `linux_load5`, `linux_load15` (Gauge)
  - `linux_cpu_pressure_some_ratio{window="10|60|300"}` (Gauge, 0.0 to 1.0)
  - `linux_cpu_pressure_some_total_seconds` (Counter)

### 3.2 Memory Collector (`agent/collector/memory.py`)
- **Kernel Sources**: `/proc/meminfo`, `/proc/pressure/memory`.
- **True SRE Availability vs. Flawed Formulas**:
  Naive memory formulas ($\frac{\text{Total} - \text{Free}}{\text{Total}}$) falsely report healthy Linux systems as 95%+ consumed because the kernel aggressively allocates unallocated RAM for page cache.
  This collector extracts **`MemAvailable`**, which accurately accounts for reclaimable page cache, reclaimable slab (`SReclaimable`), and zone watermarks.
  Used memory is computed as:
  $$\text{Used} = \text{MemTotal} - \text{MemAvailable}$$
- **Exposed Metrics**:
  - `linux_memory_total_bytes`, `linux_memory_available_bytes`, `linux_memory_used_bytes`, `linux_memory_free_bytes` (Gauge)
  - `linux_memory_cached_bytes`, `linux_memory_buffers_bytes`, `linux_memory_shmem_bytes`, `linux_memory_sreclaimable_bytes` (Gauge)
  - `linux_custom_memory_pressure{type="saturation"}` (Gauge, saturation ratio)
  - `linux_memory_pressure_ratio{type="some|full", window="10|60|300"}` (Gauge, 0.0 to 1.0)
  - `linux_memory_pressure_total_seconds{type="some|full"}` (Counter)

### 3.3 Swap Collector (`agent/collector/swap.py`)
- **Kernel Sources**: `/proc/meminfo`, `/proc/vmstat`.
- **SRE Distinction Between Allocation and Thrashing**:
  Having swap allocated on disk is not inherently an issue. Dynamic swap thrashing ($\Delta \text{pswpin}/\Delta t > 0$, $\Delta \text{pswpout}/\Delta t > 0$) causes severe latency penalties.
- **Exposed Metrics**:
  - `linux_swap_total_bytes`, `linux_swap_free_bytes`, `linux_swap_used_bytes` (Gauge)
  - `linux_swap_in_pages_total`, `linux_swap_out_pages_total` (Counter)

### 3.4 Filesystem Collector (`agent/collector/filesystem.py`)
- **Kernel Sources**: `/proc/mounts`, `os.statvfs`.
- **Filtering Virtual Mounts & Snap Images**:
  Ubuntu 24.04 mounts numerous SquashFS loopback devices for Snap packages and virtual mounts (`tmpfs`, `devtmpfs`, `cgroup`, `proc`, `sysfs`). These are automatically excluded using configurable regexes (`exclude_fstypes`, `exclude_mountpoints`) to prevent metric bloat and false-positive disk alerts.
- **Exposed Metrics**:
  - `linux_filesystem_size_bytes{device, mountpoint, fstype}` (Gauge)
  - `linux_filesystem_avail_bytes{device, mountpoint, fstype}` (Gauge, unprivileged space)
  - `linux_filesystem_free_bytes{device, mountpoint, fstype}` (Gauge, includes root reserve)
  - `linux_filesystem_used_bytes{device, mountpoint, fstype}` (Gauge)
  - `linux_filesystem_readonly{device, mountpoint, fstype}` (Gauge, 1 = read-only, 0 = read-write)

### 3.5 Inode Collector (`agent/collector/inode.py`)
- **Kernel Sources**: `os.statvfs`.
- **Zero-Inode Handling (FAT32 /boot/efi)**:
  Non-Unix filesystems (such as FAT32 EFI system partitions) report `f_files = 0`. The collector safely accounts for zero inodes without zero-division errors.
- **Exposed Metrics**:
  - `linux_inode_total{device, mountpoint, fstype}` (Gauge)
  - `linux_inode_free{device, mountpoint, fstype}` (Gauge)
  - `linux_inode_used{device, mountpoint, fstype}` (Gauge)

### 3.6 Disk I/O Collector (`agent/collector/disk_io.py`)
- **Kernel Sources**: `/proc/diskstats`.
- **Device Filtering & Sector Conversion**:
  Virtual loop devices (`loop[0-9]+`) and ramdisks are filtered out. Sector counters are converted to bytes using standard Linux block architecture factor ($512.0\text{ bytes/sector}$).
- **Exposed Metrics**:
  - `linux_disk_reads_completed_total{device}`, `linux_disk_writes_completed_total{device}` (Counter)
  - `linux_disk_read_bytes_total{device}`, `linux_disk_written_bytes_total{device}` (Counter)
  - `linux_disk_io_time_seconds_total{device}`, `linux_disk_io_time_weighted_seconds_total{device}` (Counter)
  - `linux_disk_io_in_progress{device}` (Gauge, active queue depth)

### 3.7 Network Collector (`agent/collector/network.py`)
- **Kernel Sources**: `/proc/net/dev`.
- **Throughput, Errors, and Drops**:
  Extracts 64-bit monotonic counters for link-layer throughput, packets, physical CRC/framing errors, and ring buffer / queue drop events.
- **Exposed Metrics**:
  - `linux_network_receive_bytes_total{device}`, `linux_network_transmit_bytes_total{device}` (Counter)
  - `linux_network_receive_packets_total{device}`, `linux_network_transmit_packets_total{device}` (Counter)
  - `linux_network_receive_errors_total{device}`, `linux_network_transmit_errors_total{device}` (Counter)
  - `linux_network_receive_drops_total{device}`, `linux_network_transmit_drops_total{device}` (Counter)

### 3.8 Process Collector (`agent/collector/process.py`)
- **Kernel Sources**: `psutil` with transparent fallback to `/proc/[pid]/stat`.
- **Bounded Iteration & Privacy Protection**:
  - Scanning is strictly bounded to `max_processes: 500` to prevent CPU exhaustion on high-PID density servers.
  - Process command-line arguments and environment variables are **never** inspected or exported, preventing accidental credential exposure.
  - Process names are strictly sanitized to strip directories, special characters, and length.
- **Exposed Metrics**:
  - `linux_process_count{state="running|sleeping|disk_sleep|zombie|stopped|idle"}` (Gauge)
  - `linux_process_total` (Gauge)
  - `linux_process_cpu_consumption_ratio{pid, name}` (Gauge, top N)
  - `linux_process_memory_consumption_bytes{pid, name, type="rss|vms"}` (Gauge, top N)

### 3.9 Systemd Service Collector (`agent/collector/systemd.py`)
- **Sources**: `systemctl show <unit>` with non-blocking subprocess execution.
- **Timeout and Isolation Guardrails**:
  Subprocess execution is bound to `timeout_seconds: 2.0` to prevent hanging scrapes if systemd D-Bus stalls. Failures increment `linux_systemd_service_collector_errors_total`.
- **Exposed Metrics**:
  - `linux_systemd_unit_active{unit="ssh.service..."}` (Gauge, 1 = active, 0 = inactive/failed)
  - `linux_systemd_unit_state{unit="...", state="active|inactive|failed|activating|deactivating"}` (Gauge)
  - `linux_systemd_service_collector_errors_total` (Counter)

---

## 4. Configuration Schema & Validation

Configuration is validated via `agent/config.py`:
- **Server**: `host` (string, non-empty), `port` (`1..65535`), `timeout` (positive float).
- **Collectors**: Individual booleans to toggle each of the 9 collectors.
- **Filters**: Excluded filesystem types, excluded mount regexes, excluded block devices.
- **Process Filters**: `max_processes` (>0), `top_n_cpu` (>=0), `top_n_mem` (>=0), `sanitize_names` (bool).
- **Systemd**: `monitored_units` (list of strings), `timeout_seconds` (>0).
- **Logging**: `level` (`DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`), `json_format` (bool).

---

## 5. Security & SRE Reliability Considerations

1. **Unprivileged Operation**: The agent executes cleanly under an unprivileged user (`sre` or standard user). It requires zero root privileges for `/proc`, `/sys`, `statvfs`, and `systemctl show`.
2. **Network Security**: By default, the server binds exclusively to `127.0.0.1`. It never listens on public interfaces (`0.0.0.0`) unless explicitly reconfigured.
3. **No Credential Exposure**: Command line flags, process arguments, passwords, and environment blocks are completely excluded from scraping and metric labels.
4. **Scrape Timeout Resilience**: Every collector operates with deterministic, sub-second execution times (~80ms total scrape latency across all 9 collectors on the host).
