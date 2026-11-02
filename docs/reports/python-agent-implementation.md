# Python Monitoring Agent Implementation & Telemetry Verification Report

**Project:** Linux System Monitoring & Reliability Lab  
**Component:** Custom Python Monitoring Agent (`agent/`)  
**Phase:** Phase 2 — Custom Monitoring Automation  
**Author:** Senior Python Backend Engineer, Linux Observability Engineer & SRE  
**Execution Date:** 2026-10-28  
**Target Environment:** Ubuntu 24.04 LTS (Kernel `7.0.0-38-generic`, Python 3.12.3)  

---

## 1. Executive Summary

This report documents the end-to-end design, implementation, verification, and performance characteristics of the modular Python 3.12 Linux Monitoring Agent.

The agent collects high-resolution system telemetry across 9 isolated collectors, exposes Prometheus-compatible metrics on port `9101`, validates configuration dynamically, and enforces strict security and resource bounds.

---

## 2. Architecture Overview

The agent is organized into clean, decoupled layers:

1. **Configuration Layer (`agent/config.py`, `agent/config.yaml`)**:
   Dataclass-based schema with strict type validation, boundary enforcement, and CLI parameter overrides.
2. **Collector Layer (`agent/collector/`)**:
   9 specialized collectors subclassing `BaseCollector`, each isolating access to specific kernel interfaces (`/proc`, `/sys`, `statvfs`, `systemd`).
3. **Registry & Fault Containment Layer (`agent/registry.py`)**:
   Executes collectors within exception containment boundaries, logs diagnostics, tracks per-collector health/latency, and serializes metrics into Prometheus 0.0.4 text format.
4. **HTTP Server & Lifecycle Layer (`agent/server.py`, `agent/main.py`)**:
   `ThreadingHTTPServer` bound to `127.0.0.1:9101`, exposing `/metrics` and `/healthz`, with clean signal handling for `SIGINT` and `SIGTERM`.

---

## 3. Collectors Implemented

| Collector | Module | Primary Subsystems / Interfaces | Key Responsibility |
|---|---|---|---|
| **CPU** | `agent.collector.cpu` | `/proc/stat`, `/proc/loadavg`, `/proc/pressure/cpu` | CPU time by mode, differential utilization, 1/5/15m load average, CPU PSI |
| **Memory** | `agent.collector.memory` | `/proc/meminfo`, `/proc/pressure/memory` | Physical RAM totals, true `MemAvailable`, buffers, cache, saturation, memory PSI |
| **Swap** | `agent.collector.swap` | `/proc/meminfo`, `/proc/vmstat` | Total/used/free swap, cumulative `pswpin` and `pswpout` page counters |
| **Filesystem** | `agent.collector.filesystem` | `/proc/mounts`, `os.statvfs` | Filesystem capacity, unprivileged available bytes, read-only flag, virtual fs filtering |
| **Inode** | `agent.collector.inode` | `os.statvfs` | Total, free, and used inodes; graceful zero-inode handling for FAT32 filesystems |
| **Disk I/O** | `agent.collector.disk_io` | `/proc/diskstats` | Reads/writes completed, throughput bytes (512-byte sectors), queue depth, I/O latency |
| **Network** | `agent.collector.network` | `/proc/net/dev` | Ingress/egress throughput bytes, packet counters, physical CRC errors, drops |
| **Process** | `agent.collector.process` | `psutil`, `/proc/[pid]/stat` | Bounded process enumeration, state grouping (R, S, D, Z, T, I), top CPU/mem consumers |
| **Systemd** | `agent.collector.systemd` | `systemctl show` | Monitored service availability, active state, substate, subprocess timeout guard |

---

## 4. Comprehensive Metrics Catalog

All exposed metrics adhere to standard Prometheus naming guidelines:

```
┌──────────────────────────────────────────────┬─────────┬────────────────────────────────────────────────────────┐
│ Metric Name                                  │ Type    │ Description / Labels                                   │
├──────────────────────────────────────────────┼─────────┼────────────────────────────────────────────────────────┤
│ linux_cpu_seconds_total                      │ Counter │ CPU time in seconds by cpu="total|0..11", mode="..."   │
│ linux_cpu_utilization_ratio                  │ Gauge   │ Active utilization (0.0 to 1.0) by cpu="total|0..11"   │
│ linux_load1, linux_load5, linux_load15       │ Gauge   │ 1, 5, 15-minute exponentially damped load average      │
│ linux_cpu_pressure_some_ratio                │ Gauge   │ CPU PSI stall ratio by window="10|60|300"              │
│ linux_cpu_pressure_some_total_seconds        │ Counter │ Cumulative microseconds stalled on CPU scheduling      │
│ linux_memory_total_bytes                     │ Gauge   │ Total physical RAM capacity in bytes                   │
│ linux_memory_available_bytes                 │ Gauge   │ Usable physical RAM without swapping in bytes          │
│ linux_memory_used_bytes                      │ Gauge   │ Consumed memory (MemTotal - MemAvailable) in bytes     │
│ linux_memory_free_bytes                      │ Gauge   │ Low-level unallocated memory in bytes                  │
│ linux_memory_cached_bytes                    │ Gauge   │ In-memory file page cache in bytes                     │
│ linux_memory_buffers_bytes                   │ Gauge   │ Block device buffer cache in bytes                     │
│ linux_memory_shmem_bytes                     │ Gauge   │ Shared memory (tmpfs, IPC) in bytes                    │
│ linux_memory_sreclaimable_bytes              │ Gauge   │ In-kernel reclaimable SLAB cache in bytes              │
│ linux_custom_memory_pressure                 │ Gauge   │ Memory saturation ratio: (Used / Total)                │
│ linux_memory_pressure_ratio                  │ Gauge   │ Memory PSI stall ratio by type="some|full", window     │
│ linux_memory_pressure_total_seconds          │ Counter │ Cumulative memory stall time in seconds                │
│ linux_swap_total_bytes                       │ Gauge   │ Total configured swap space in bytes                   │
│ linux_swap_free_bytes                        │ Gauge   │ Unallocated swap space in bytes                        │
│ linux_swap_used_bytes                        │ Gauge   │ Consumed swap space in bytes                           │
│ linux_swap_in_pages_total                    │ Counter │ Monotonic count of swap-in pages (pswpin)              │
│ linux_swap_out_pages_total                   │ Counter │ Monotonic count of swap-out pages (pswpout)            │
│ linux_filesystem_size_bytes                  │ Gauge   │ Filesystem capacity by device, mountpoint, fstype      │
│ linux_filesystem_avail_bytes                 │ Gauge   │ Unprivileged available bytes by mountpoint             │
│ linux_filesystem_free_bytes                  │ Gauge   │ Total unallocated bytes (including root reserve)       │
│ linux_filesystem_used_bytes                  │ Gauge   │ Occupied bytes by mountpoint                           │
│ linux_filesystem_readonly                    │ Gauge   │ Boolean indicator (1 = read-only, 0 = read-write)      │
│ linux_inode_total                            │ Gauge   │ Total inode capacity by device, mountpoint, fstype     │
│ linux_inode_free                             │ Gauge   │ Inodes available for file allocation                   │
│ linux_inode_used                             │ Gauge   │ Inodes currently allocated                             │
│ linux_disk_reads_completed_total             │ Counter │ Completed read operations by device                    │
│ linux_disk_writes_completed_total            │ Counter │ Completed write operations by device                   │
│ linux_disk_read_bytes_total                  │ Counter │ Cumulative bytes read (sectors * 512) by device        │
│ linux_disk_written_bytes_total               │ Counter │ Cumulative bytes written (sectors * 512) by device     │
│ linux_disk_io_time_seconds_total             │ Counter │ Milliseconds in I/O converted to seconds by device     │
│ linux_disk_io_time_weighted_seconds_total    │ Counter │ Weighted I/O time in seconds by device                 │
│ linux_disk_io_in_progress                    │ Gauge   │ Instantaneous I/O requests in flight by device         │
│ linux_network_receive_bytes_total            │ Counter │ Cumulative RX throughput bytes by device               │
│ linux_network_transmit_bytes_total           │ Counter │ Cumulative TX throughput bytes by device               │
│ linux_network_receive_packets_total          │ Counter │ Ingress packet count by device                         │
│ linux_network_transmit_packets_total         │ Counter │ Egress packet count by device                          │
│ linux_network_receive_errors_total           │ Counter │ Ingress physical/framing errors by device              │
│ linux_network_transmit_errors_total          │ Counter │ Egress transmission errors by device                   │
│ linux_network_receive_drops_total            │ Counter │ Ingress ring buffer/queue drops by device              │
│ linux_network_transmit_drops_total           │ Counter │ Egress queue overflow drops by device                  │
│ linux_process_count                          │ Gauge   │ Process count by state="running|sleeping|zombie..."    │
│ linux_process_total                          │ Gauge   │ Total process count on host                            │
│ linux_process_cpu_consumption_ratio          │ Gauge   │ CPU consumption ratio (0.0-1.0) by pid, name (top N)   │
│ linux_process_memory_consumption_bytes       │ Gauge   │ Memory footprint (rss/vms) by pid, name (top N)        │
│ linux_systemd_unit_active                    │ Gauge   │ Service availability (1 = active, 0 = inactive/failed) │
│ linux_systemd_unit_state                     │ Gauge   │ State matrix by unit, state="active|failed|inactive"   │
│ linux_systemd_service_collector_errors_total │ Counter │ Total systemctl execution errors                       │
│ linux_agent_collector_success                │ Gauge   │ Scrape success (1.0 = success, 0.0 = fail) by collector│
│ linux_agent_collector_duration_seconds       │ Gauge   │ Scrape latency in seconds by collector                 │
│ linux_agent_collector_errors_total           │ Counter │ Cumulative exception count by collector                │
│ linux_agent_build_info                       │ Gauge   │ Metadata by version="1.0.0", python_version, system    │
└──────────────────────────────────────────────┴─────────┴────────────────────────────────────────────────────────┘
```

---

## 5. Configuration Architecture

The agent loads its configuration from `agent/config.yaml` or a user-specified path (`--config`):

```yaml
server:
  host: "127.0.0.1"        # Strict loopback binding
  port: 9101               # Contract port
  timeout: 30.0

collectors:
  cpu: true
  memory: true
  swap: true
  filesystem: true
  inode: true
  disk_io: true
  network: true
  process: true
  systemd: true

filesystem_filter:
  exclude_fstypes:
    - autofs
    - squashfs
    - tmpfs
    - devtmpfs
    - overlay
    - proc
    - sysfs
  exclude_mountpoints:
    - "^/(dev|proc|sys|run|snap)($|/)"

disk_filter:
  exclude_devices:
    - "^loop[0-9]+"
    - "^ram[0-9]+"

process_filter:
  max_processes: 500       # Denial of service safeguard
  top_n_cpu: 5
  top_n_mem: 5
  sanitize_names: true

systemd:
  monitored_units:
    - "ssh.service"
    - "systemd-journald.service"
    - "cron.service"
    - "prometheus.service"
    - "prometheus-node-exporter.service"
  timeout_seconds: 2.0

logging:
  level: "INFO"
  json_format: false
```

---

## 6. Dependencies & Virtual Environment

All dependencies are pinned in `requirements.txt` and `requirements-dev.txt`:

```text
pyyaml==6.0.2
psutil==6.1.0
prometheus-client==0.21.0
pytest==8.3.3
pytest-cov==5.0.0
flake8==7.1.1
```

Setup command:
```bash
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt -r requirements-dev.txt
.venv/bin/pip install -e .
```

---

## 7. HTTP API Examples & Responses

### 7.1 Health Check (`GET /healthz`)
```bash
$ curl -s http://127.0.0.1:9101/healthz
{
  "status": "healthy",
  "version": "1.0.0",
  "uptime_seconds": 24.5
}
```

### 7.2 Metrics Scrape (`GET /metrics`)
```bash
$ curl -s http://127.0.0.1:9101/metrics | head -n 30
# HELP linux_cpu_seconds_total Total CPU time spent in each mode in seconds.
# TYPE linux_cpu_seconds_total counter
linux_cpu_seconds_total{cpu="total",mode="user"} 245102.34
linux_cpu_seconds_total{cpu="total",mode="nice"} 43.11
linux_cpu_seconds_total{cpu="total",mode="system"} 61680.12
linux_cpu_seconds_total{cpu="total",mode="idle"} 1020490.87
linux_cpu_seconds_total{cpu="total",mode="iowait"} 1499.82
linux_cpu_seconds_total{cpu="total",mode="irq"} 0.0
linux_cpu_seconds_total{cpu="total",mode="softirq"} 1400.12
linux_cpu_seconds_total{cpu="total",mode="steal"} 0.0
linux_cpu_seconds_total{cpu="total",mode="guest"} 71540.2
linux_cpu_seconds_total{cpu="total",mode="guest_nice"} 0.0
# HELP linux_cpu_utilization_ratio Instantaneous or differential active CPU utilization (0.0 to 1.0).
# TYPE linux_cpu_utilization_ratio gauge
linux_cpu_utilization_ratio{cpu="total"} 0.0824
# HELP linux_load1 1-minute exponentially damped moving system load average.
# TYPE linux_load1 gauge
linux_load1 2.38
# HELP linux_load5 5-minute exponentially damped moving system load average.
# TYPE linux_load5 gauge
linux_load5 3.01
# HELP linux_load15 15-minute exponentially damped moving system load average.
# TYPE linux_load15 gauge
linux_load15 2.76
```

### 7.3 Method Not Allowed (`POST /metrics`)
```bash
$ curl -s -i -X POST http://127.0.0.1:9101/metrics
HTTP/1.0 405 Method Not Allowed
Content-Type: text/plain; charset=utf-8
Content-Length: 23

405 Method Not Allowed
```

---

## 8. Test Execution & Coverage Results

Unit tests were executed using `pytest` with synthetic fixtures and mocks, isolating tests from live host resource states:

```bash
$ .venv/bin/pytest tests/python/ -v --cov=agent --cov-report=term-missing
============================= test session starts ==============================
platform linux -- Python 3.12.3, pytest-8.3.3, pluggy-1.7.0
rootdir: /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab
configfile: pyproject.toml
plugins: cov-5.0.0
collected 30 items

tests/python/test_config.py::test_default_config_validity PASSED         [  3%]
tests/python/test_config.py::test_invalid_port_out_of_range PASSED       [  6%]
tests/python/test_config.py::test_invalid_host PASSED                    [ 10%]
tests/python/test_config.py::test_invalid_logging_level PASSED           [ 13%]
tests/python/test_config.py::test_invalid_process_filter PASSED          [ 16%]
tests/python/test_config.py::test_load_config_from_yaml PASSED           [ 20%]
tests/python/test_config.py::test_load_config_invalid_yaml PASSED        [ 23%]
tests/python/test_cpu_collector.py::test_cpu_collector_parsing PASSED    [ 26%]
tests/python/test_cpu_collector.py::test_cpu_collector_differential_utilization PASSED [ 30%]
tests/python/test_disk_io_collector.py::test_disk_io_collector_parsing_and_filtering PASSED [ 33%]
tests/python/test_error_handling.py::test_registry_fault_isolation PASSED [ 36%]
tests/python/test_error_handling.py::test_collectors_missing_proc_files PASSED [ 40%]
tests/python/test_filesystem_collector.py::test_filesystem_collector_filtering_and_parsing PASSED [ 43%]
tests/python/test_inode_collector.py::test_inode_collector_parsing_and_fat32_handling PASSED [ 46%]
tests/python/test_main.py::test_parse_args_defaults PASSED               [ 50%]
tests/python/test_main.py::test_parse_args_custom PASSED                 [ 53%]
tests/python/test_main.py::test_build_registry_toggles PASSED            [ 56%]
tests/python/test_memory_collector.py::test_memory_collector_parsing PASSED [ 60%]
tests/python/test_network_collector.py::test_network_collector_parsing PASSED [ 63%]
tests/python/test_process_collector.py::test_process_collector_synthetic_proc PASSED [ 66%]
tests/python/test_process_collector.py::test_process_collector_bounded_iteration PASSED [ 70%]
tests/python/test_process_collector.py::test_process_name_sanitization PASSED [ 73%]
tests/python/test_server.py::test_metrics_endpoint PASSED                [ 76%]
tests/python/test_server.py::test_healthz_endpoint PASSED                [ 80%]
tests/python/test_server.py::test_root_endpoint PASSED                   [ 83%]
tests/python/test_server.py::test_not_found_endpoint PASSED              [ 86%]
tests/python/test_server.py::test_method_not_allowed PASSED              [ 90%]
tests/python/test_swap_collector.py::test_swap_collector_parsing PASSED  [ 93%]
tests/python/test_systemd_collector.py::test_systemd_collector_active_and_inactive PASSED [ 96%]
tests/python/test_systemd_collector.py::test_systemd_collector_timeout_and_missing_binary PASSED [100%]

---------- coverage: platform linux, python 3.12.3 -----------
Name                            Stmts   Miss  Cover   Missing
-------------------------------------------------------------
agent/__init__.py                   1      0   100%
agent/collector/__init__.py        11      0   100%
agent/collector/base.py            45      5    89%   21, 46, 53, 65-66
agent/collector/cpu.py             88      6    93%   62-63, 80, 142-143, 162
agent/collector/disk_io.py         57      3    95%   82, 96-97
agent/collector/filesystem.py      59      5    92%   37, 75, 80, 88-89
agent/collector/inode.py           52      5    90%   36, 64, 68, 76-77
agent/collector/memory.py          75      4    95%   23, 30-31, 141
agent/collector/network.py         49      3    94%   68, 80-81
agent/collector/process.py        111     39    65%   64-65, 73, 79, 85, 96-97, 110-151, 178-181, 197-198
agent/collector/swap.py            61      5    92%   24, 30-31, 80-81
agent/collector/systemd.py         50      0   100%
agent/config.py                   133     21    84%   28, 48, 69, 71, 85, 99, 101, 119, 121, 134, 161-163, 195-196, 202-203, 208-209, 217-218
agent/logger.py                    26      8    69%   14-32, 47
agent/main.py                      79     40    49%   82, 94, 101-152, 156
agent/models.py                    21      0   100%
agent/registry.py                  62      2    97%   104, 125
agent/server.py                    78      7    91%   41, 44, 61-63, 132-133
-------------------------------------------------------------
TOTAL                            1058    153    86%

============================== 30 passed in 4.10s ==============================
```

Code style and PEP 8 conformance:
```bash
$ .venv/bin/flake8 agent/ tests/python/ --max-line-length=120
# (Exit code 0, clean)
```

---

## 9. Security Assessment

1. **Privilege Demarcation**:
   The agent requires no root or `sudo` capabilities. Telemetry counters (`/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/net/dev`, `os.statvfs`) are universally world-readable in Linux.
2. **Network Exposure Guardrail**:
   Default listen address is explicitly locked to `127.0.0.1`. The agent does not bind to public interfaces (`0.0.0.0`) or expose internal topology to external subnets.
3. **Command Injection Prevention**:
   Systemd status queries execute via direct parameter array invocations (`subprocess.run(["systemctl", "show", ...], shell=False)`), completely avoiding shell evaluation and preventing command injection.
4. **Credential Protection**:
   Process telemetry strictly excludes process command-line arguments (`cmdline`), environment variables (`environ`), and working directories. Only sanitized binary basenames are exposed.
5. **Denial of Service Resilience**:
   Process iteration is capped at a strict upper limit (`max_processes = 500`), preventing CPU or memory exhaustion during fork bombs or high process concurrency.
6. **No Secret Ingestion**:
   Configuration parsing does not log file contents or expose tokens.

---

## 10. Known Limitations & Operating Boundaries

1. **Systemd In Containerized Environments**:
   When executed inside Docker or Podman containers where `systemd` is not PID 1, `systemctl show` will fail. The agent gracefully detects this condition, records `linux_systemd_service_collector_errors_total`, and sets `linux_systemd_unit_active = 0` without crashing.
2. **Wi-Fi Transient Packet Drops**:
   On wireless physical interfaces (e.g. `wlo1`), Layer 2 frame drops are expected due to RF interference. Prometheus alert expressions should rate-limit drop alerts to server Ethernet links (e.g., `device=~"eth.*|en.*"`).
3. **Unprivileged Process Visibility**:
   When run as an unprivileged user, `/proc/[pid]/` for processes owned by other users provides limited memory statistics under hardened kernels (`hidepid=2`). This is a deliberate kernel security feature and does not affect aggregate host metrics.

---

## 11. Prometheus Integration Instructions

Add the following scrape configuration to Prometheus (`prometheus.yml`):

```yaml
scrape_configs:
  - job_name: "custom_python_agent"
    scrape_interval: 15s
    scrape_timeout: 10s
    static_configs:
      - targets: ["127.0.0.1:9101"]
        labels:
          role: "custom_agent"
          host: "rubi"
```

To run the agent as a systemd service (`/etc/systemd/system/linux-monitoring-agent.service`):

```ini
[Unit]
Description=Linux System Monitoring Custom Agent
After=network.target

[Service]
Type=simple
User=dineth
WorkingDirectory=/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab
ExecStart=/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/.venv/bin/python -m agent.main --config /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/agent/config.yaml
Restart=on-failure
RestartSec=5s
KillSignal=SIGTERM
TimeoutStopSec=10s

[Install]
WantedBy=multi-user.target
```
