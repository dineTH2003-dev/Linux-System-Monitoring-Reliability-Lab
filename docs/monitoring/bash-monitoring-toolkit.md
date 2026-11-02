# Bash-Based Modular Linux Monitoring & Diagnostics Toolkit

**Project:** Linux System Monitoring & Reliability Lab  
**Role:** Senior Linux Automation & SRE Observability Engineer  
**Milestone:** Phase 2.1 — Bash Monitoring & Operational Automation  
**Target Environment:** Ubuntu 24.04 LTS (x86_64, Linux 6.x / 7.x Kernel, systemd 255)  

---

## 1. Architectural Overview & Design Philosophy

The **Modular Bash-Based Monitoring Toolkit** provides an operator-grade, non-destructive diagnostic suite designed to sample, inspect, and evaluate bare-metal Linux host telemetry.

While time-series daemons (e.g., Prometheus Node Exporter, custom Python daemons) scrape metrics at fixed intervals for long-term trending, operators during active incident triage and automated health checks require instantaneous, deterministic, low-overhead CLI tools that execute with minimal runtime dependencies.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        UNIFIED CLI ORCHESTRATOR (system_monitor.sh)                    │
│                        Subcommands: all | cpu | memory | storage | network | process   │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
            ┌───────────────────────────────┼───────────────────────────────┐
            ▼                               ▼                               ▼
 ┌──────────────────────┐        ┌──────────────────────┐        ┌──────────────────────┐
 │    cpu_monitor.sh    │        │  memory_monitor.sh   │        │  storage_monitor.sh  │
 ├──────────────────────┤        ├──────────────────────┤        ├──────────────────────┤
 │ • /proc/stat diff    │        │ • /proc/meminfo      │        │ • df -PTk / df -PTi  │
 │ • /proc/loadavg      │        │ • /proc/vmstat diff  │        │ • /proc/diskstats    │
 │ • /proc/cpuinfo      │        │ • /proc/pressure/mem │        │ • /proc/mounts       │
 │ • /proc/pressure/cpu │        │ • Paging rates       │        │ • Device I/O rates   │
 └──────────────────────┘        └──────────────────────┘        └──────────────────────┘
            │                               │                               │
            └───────────────────────────────┼───────────────────────────────┘
                                            │
            ┌───────────────────────────────┼───────────────────────────────┐
            ▼                               ▼                               ▼
 ┌──────────────────────┐        ┌──────────────────────┐        ┌──────────────────────┐
 │  network_monitor.sh  │        │  process_monitor.sh  │        │  systemd_monitor.sh  │
 ├──────────────────────┤        ├──────────────────────┤        ├──────────────────────┤
 │ • /proc/net/dev diff │        │ • Process task count │        │ • is-system-running  │
 │ • /sys/class/net/*   │        │ • States: R,S,D,Z,T  │        │ • list-units failed  │
 │ • ss -tulnH sockets  │        │ • Top CPU / Memory   │        │ • systemctl show     │
 │ • Interface rates    │        │ • /proc/[pid]/status │        │ • Unit restart count │
 └──────────────────────┘        └──────────────────────┘        └──────────────────────┘
                                            │
                ┌───────────────────────────┴───────────────────────────┐
                ▼                                                       ▼
 ┌───────────────────────────────┐                       ┌───────────────────────────────┐
 │       scripts/lib/common.sh   │                       │   scripts/lib/thresholds.sh   │
 ├───────────────────────────────┤                       ├───────────────────────────────┤
 │ • set -Eeuo pipefail / traps  │                       │ • Numeric comparison (awk)    │
 │ • Exit code constants         │                       │ • Upper & lower directions    │
 │ • Non-destructive read paths  │                       │ • Severity aggregation        │
 │ • JSON string escaping        │                       │ • Colored terminal badges     │
 └───────────────────────────────┘                       └───────────────────────────────┘
```

### Core Engineering Invariants:
1. **Zero Destructive Actions**: The scripts perform only read-only inspections. They never invoke `kill`, `rm`, `systemctl restart`, `ip link set down`, or mount alterations.
2. **Deterministic Testability**: Kernel interface paths (`/proc`, `/sys`, `/dev`) are parameterized via `PROC_ROOT`, `SYS_ROOT`, and `DEV_ROOT` variables, allowing complete, fixture-driven testing in isolated environments without depending on live host state.
3. **Locale Neutrality**: All scripts enforce `export LC_ALL=C` to guarantee consistent decimal formatting (`.` vs `,`), date parsing, and column ordering regardless of user locale.
4. **ShellCheck Compliance**: 100% of shell scripts pass `shellcheck -x` with 0 errors and 0 unsuppressed warnings.
5. **Machine & Human Readability**: Every tool supports dual output modes: formatted, human-readable terminal output (`--text`) with ANSI status badges, and strict JSON (`--json`) for automation pipelines and jq consumption.

---

## 2. Directory & Component Inventory

| File Path | Role | Description |
|---|---|---|
| `scripts/lib/common.sh` | Library | Core constants, exit codes, trap handlers, number validation, byte formatters, JSON string escaping |
| `scripts/lib/thresholds.sh` | Library | Upper/lower threshold comparison, severity aggregation (`CRIT` > `WARN` > `OK`), status badges |
| `scripts/monitoring/cpu_monitor.sh` | Module | Differential CPU utilization (with guest time subtraction), load average, CPU info, and PSI |
| `scripts/monitoring/memory_monitor.sh`| Module | RAM allocations, swap capacity, differential swap in/out rates, major faults, and memory PSI |
| `scripts/monitoring/storage_monitor.sh`| Module | Filesystem capacity, inode allocation, disk I/O throughput/IOPS rates, and mount options |
| `scripts/monitoring/network_monitor.sh`| Module | Interface operational state, RX/TX throughput, error/drop rates, and listening socket audit |
| `scripts/monitoring/process_monitor.sh`| Module | Global scheduling states (R/S/D/Z/T), total threads, top CPU/Memory consumers, PID inspection |
| `scripts/monitoring/systemd_monitor.sh`| Module | System-level status, failed unit enumeration, and detailed service metadata query |
| `scripts/monitoring/system_monitor.sh` | CLI | Master CLI entrypoint providing unified subcommands and full system health reports |
| `scripts/tests/test_runner.sh` | Test Harness | Standalone, zero-dependency TAP-like test runner and assertion framework |
| `scripts/tests/test_*.sh` | Test Suites | 7 deterministic unit test suites with 83 automated assertions covering all modules and edge cases |
| `scripts/tests/fixtures/` | Test Data | Deterministic mock `/proc` and `/sys` hierarchies for CPU, memory, disks, networking, and PIDs |

---

## 3. Exit Code Convention

All monitoring scripts adhere to standardized exit codes to enable automated alerting and exit code evaluation:

| Code | Status | Meaning |
|---|---|---|
| `0` | **OK / SUCCESS** | Execution succeeded; all monitored metrics are healthy and within thresholds. |
| `1` | **ERROR** | Runtime error (e.g., target file/directory unreadable, command failed, PID not found). |
| `2` | **USAGE** | Invalid command-line arguments, bad threshold syntax, or conflicting flags. |
| `3` | **WARN** | Warning threshold breached in one or more evaluated metrics. |
| `4` | **CRIT** | Critical threshold breached in one or more evaluated metrics. |
| `127`| **MISSING_CMD**| A required Linux CLI command (`df`, `ps`, `ss`, `systemctl`) is missing from `PATH`. |

When multiple conditions occur, the toolkit aggregates status using strict severity ranking:  
$$\text{CRITICAL (4)} > \text{WARNING (3)} > \text{ERROR (1)} > \text{OK (0)}$$

---

## 4. Module Specifications & Command Reference

### 4.1 Master CLI Orchestrator (`system_monitor.sh`)

The entrypoint forwards commands to individual modules or aggregates all subsystems into a single executive dashboard.

```bash
# Display full consolidated health report
bash scripts/monitoring/system_monitor.sh all

# Display high-level summary table only
bash scripts/monitoring/system_monitor.sh all --summary

# Display consolidated report in structured JSON format
bash scripts/monitoring/system_monitor.sh all --json

# Run individual subsystems with forwarded options
bash scripts/monitoring/system_monitor.sh cpu --interval 2
bash scripts/monitoring/system_monitor.sh memory --warn-mem 80
bash scripts/monitoring/system_monitor.sh storage --mount /
bash scripts/monitoring/system_monitor.sh network --interface wlo1
bash scripts/monitoring/system_monitor.sh process --top 10
bash scripts/monitoring/system_monitor.sh systemd --service cron.service
```

---

### 4.2 CPU Subsystem Monitor (`cpu_monitor.sh`)

#### Kernel Sources:
- `/proc/stat`: Sampled twice over a calibrated window (default 1s) to calculate differential ticks.
  - **Accounting Correction**: Linux accounts virtual guest cycles inside both `user` and `guest`. To prevent double-counting ($>100\%$), the pure user space is computed as $\Delta \text{user} - \Delta \text{guest}$.
  - Total Active Ticks: $\Delta \text{user}_{\text{pure}} + \Delta \text{nice}_{\text{pure}} + \Delta \text{system} + \Delta \text{irq} + \Delta \text{softirq} + \Delta \text{steal} + \Delta \text{guest}$.
- `/proc/loadavg`: 1-minute, 5-minute, and 15-minute load averages, scheduling entity counts (runnable / total), and per-core normalized load ($L_{\text{norm}} = L_{1m} / N_{\text{cores}}$).
- `/proc/cpuinfo`: Hardware model name, socket count, physical core count, logical processors, and frequency.
- `/proc/pressure/cpu`: Pressure Stall Information (PSI) reporting `some` avg10, avg60, avg300, and cumulative stalled microseconds.

#### CLI Flags:
- `-i, --interval SEC`: Differential sampling window in seconds (default: 1).
- `-w, --warn-util PCT`: Warning threshold for CPU utilization percentage.
- `-c, --crit-util PCT`: Critical threshold for CPU utilization percentage.
- `-W, --warn-load NUM`: Warning threshold for 1-minute per-core normalized load.
- `-C, --crit-load NUM`: Critical threshold for 1-minute per-core normalized load.
- `-j, --json`: Output structured JSON.
- `-t, --text`: Formatted human-readable output (default).

---

### 4.3 Memory & Swap Subsystem Monitor (`memory_monitor.sh`)

#### Kernel Sources:
- `/proc/meminfo`:
  - `MemTotal`, `MemFree`, `MemAvailable`, `Buffers`, `Cached`, `Shmem`, `SReclaimable`, `Dirty`.
  - True Used RAM: $\text{MemTotal} - \text{MemAvailable}$ (matching modern `free`).
  - Swap Capacity: $\text{SwapTotal}$, $\text{SwapFree}$, $\text{SwapUsed} = \text{SwapTotal} - \text{SwapFree}$.
- `/proc/vmstat`:
  - Differential sampling over interval $t$ to measure instantaneous paging activity:
    $$\Delta pswpin / \Delta t \quad (\text{pages in/sec}) \times 4\text{ KiB} = \text{KiB/s read from swap}$$
    $$\Delta pswpout / \Delta t \quad (\text{pages out/sec}) \times 4\text{ KiB} = \text{KiB/s written to swap}$$
    $$\Delta pgmajfault / \Delta t \quad (\text{major faults/sec read from disk})$$
- `/proc/pressure/memory`: PSI tracking both `some` and `full` stall metrics.

#### CLI Flags:
- `-i, --interval SEC`: Sampling interval for paging rate (default: 1).
- `-w, --warn-mem PCT`: Warning threshold for physical RAM utilization percentage.
- `-c, --crit-mem PCT`: Critical threshold for physical RAM utilization percentage.
- `-W, --warn-swap PCT`: Warning threshold for Swap allocation percentage.
- `-C, --crit-swap PCT`: Critical threshold for Swap allocation percentage.

---

### 4.4 Storage & Block Device Monitor (`storage_monitor.sh`)

#### Sources:
- `df -PTk` & `df -PTi`:
  - POSIX portable mode reporting 1-KiB blocks and inode allocation.
  - Automatically filters out virtual loop mounts (`squashfs`, `tmpfs`, `devtmpfs`) unless `--include-virtual` is passed.
- `/proc/mounts`:
  - Direct VFS mount table inspection extracting options (`rw`/`ro`, `relatime`, `errors=remount-ro`, etc.).
- `/proc/diskstats`:
  - Differential block I/O statistics excluding virtual loop/ram devices:
    - Read IOPS ($r/s$) and Write IOPS ($w/s$).
    - Read throughput (KiB/s) and Write throughput (KiB/s).
    - In-flight I/O requests.
    - Device utilization percentage ($\%util$).

#### CLI Flags:
- `-m, --mount PATH`: Restrict capacity analysis to a specific mount point (e.g. `/`).
- `-i, --interval SEC`: Sampling interval for disk I/O rates (default: 1).
- `-w, --warn-disk PCT`: Warning threshold for filesystem capacity percentage.
- `-c, --crit-disk PCT`: Critical threshold for filesystem capacity percentage.
- `-W, --warn-inode PCT`: Warning threshold for inode allocation percentage.
- `-C, --crit-inode PCT`: Critical threshold for inode allocation percentage.
- `-v, --include-virtual`: Include virtual loop and tmpfs filesystems.

---

### 4.5 Network Subsystem Monitor (`network_monitor.sh`)

#### Sources:
- `/proc/net/dev`:
  - Interface RX/TX cumulative bytes, packets, errors, and drops.
  - Differential rates: RX KiB/s, TX KiB/s, RX packets/s (pps), TX packets/s (pps), and error/drop rates.
- `/sys/class/net/<iface>/`:
  - `operstate`: Operational status (`up`, `down`, `unknown`).
  - `mtu`: Maximum Transmission Unit.
- `ss -tulnH`:
  - Socket Statistics inspection auditing active listening TCP/UDP sockets without header noise or DNS resolution delays.

#### CLI Flags:
- `-I, --interface IFACE`: Restrict metrics to a single interface (e.g. `wlo1`).
- `-i, --interval SEC`: Sampling interval for throughput calculation (default: 1).
- `-w, --warn-errors NUM`: Warning threshold for error + drop rate per second.
- `-c, --crit-errors NUM`: Critical threshold for error + drop rate per second.
- `-p, --ports-only`: Output only listening ports audit.
- `-s, --stats-only`: Output only interface statistics, skipping listening sockets.

---

### 4.6 Process Subsystem Monitor (`process_monitor.sh`)

#### Sources:
- `ps -eo stat --no-headers`:
  - Categorizes all running tasks into kernel scheduling states:
    - `R`: Running / Runnable on CPU runqueue.
    - `S`: Interruptible sleep (waiting for event).
    - `D`: Uninterruptible disk sleep (waiting for hardware I/O).
    - `Z`: Zombie / Defunct (terminated, parent has not reaped).
    - `T` / `t`: Stopped by job control or traced by debugger.
    - `I`: Idle kernel thread.
- `ps -eLf`: Total thread count across all processes.
- Top Lists:
  - Top CPU consumers sorted by `%cpu`.
  - Top Memory consumers sorted by resident set size (`rss`).
- `/proc/<PID>/status` & `/proc/<PID>/cmdline`:
  - Deep single-PID inspection mode: PPID, threads, VmRSS, VmSize, and complete command line.

#### CLI Flags:
- `-n, --top NUM`: Number of top processes to report (default: 5).
- `-p, --pid PID`: Inspect detailed telemetry for a single process ID.
- `-z, --warn-zombies NUM`: Warning threshold for zombie count.
- `-Z, --crit-zombies NUM`: Critical threshold for zombie count.
- `-d, --warn-dstate NUM`: Warning threshold for uninterruptible disk sleep count.
- `-D, --crit-dstate NUM`: Critical threshold for uninterruptible disk sleep count.

---

### 4.7 systemd Service Monitor (`systemd_monitor.sh`)

#### Sources:
- `systemctl is-system-running`: Host system operational state (`running`, `degraded`, `maintenance`, `stopping`).
- `systemctl list-units --state=failed --plain --no-legend`:
  - Uncovers failed units across services, sockets, targets, and timers.
- `systemctl show <unit>`:
  - Machine-readable property inspection: `Id`, `ActiveState`, `SubState`, `UnitFileState`, `MainPID`, `ExecMainStatus`, `NRestarts`, `Description`.

#### CLI Flags:
- `-s, --service UNIT`: Inspect metadata and state for a target unit.
- `-f, --failed-only`: Show only failed units, omitting system status.
- `-w, --warn-failed NUM`: Warning threshold for failed unit count.
- `-c, --crit-failed NUM`: Critical threshold for failed unit count (default: 1).

---

## 5. JSON Telemetry Schema

When invoked with `--json`, each script outputs deterministic, schema-compliant JSON.

### Sample Consolidated Health Output (`system_monitor.sh all --json`):
```json
{
  "timestamp": "2026-10-28T09:00:00Z",
  "hostname": "rubi",
  "version": "1.0.0",
  "status": "OK",
  "exit_code": 0,
  "subsystems": {
    "cpu": {
      "timestamp": "2026-10-28T09:00:00Z",
      "module": "cpu",
      "status": "OK",
      "exit_code": 0,
      "hardware": {
        "model": "13th Gen Intel(R) Core(TM) i7-1355U",
        "sockets": 1,
        "physical_cores": 10,
        "logical_processors": 12,
        "frequency_mhz": 600.0
      },
      "utilization": {
        "total_pct": 24.50,
        "user_pct": 14.20,
        "nice_pct": 0.00,
        "system_pct": 5.10,
        "idle_pct": 75.30,
        "iowait_pct": 0.10,
        "irq_pct": 0.20,
        "steal_pct": 0.00,
        "guest_pct": 4.90,
        "status": "OK"
      },
      "load_average": {
        "load_1m": 2.15,
        "load_5m": 2.80,
        "load_15m": 3.10,
        "load_1m_per_core": 0.18,
        "runnable_entities": 4,
        "total_entities": 2340,
        "status": "OK"
      },
      "pressure": {
        "supported": true,
        "some_avg10": 1.20,
        "some_avg60": 1.80,
        "some_avg300": 2.10,
        "total_stalled_us": 3075000000
      }
    },
    "memory": { ... },
    "storage": { ... },
    "network": { ... },
    "process": { ... },
    "systemd": { ... }
  }
}
```

---

## 6. SRE Operational Runbook & Alert Response Guide

When incorporating these scripts into alerting scripts, cron jobs, or incident response procedures, follow these diagnosis steps:

| Alert Status | Potential Root Cause | Verification Command | Remediation Guidance |
|---|---|---|---|
| **CPU: `[CRIT]`** (Util > 90% or Load/core > 2.0) | Runaway compute threads, process storm, or crypto mining. | `bash scripts/monitoring/process_monitor.sh -n 10` | Identify PID, inspect parent PID, profile thread count, verify application runqueue. |
| **Memory: `[CRIT]`** (RAM > 90% and Swap > 80%) | Memory leak, aggressive cache growth, or near-OOM exhaustion. | `bash scripts/monitoring/memory_monitor.sh -i 2` | Check `Swap In/Out Rate` and PSI `full avg10`. High PSI indicates active kernel memory thrashing. |
| **Storage: `[CRIT]`** (Disk > 90% or Inodes > 90%) | Log file growth, core dump accumulation, or uncollected session files. | `bash scripts/monitoring/storage_monitor.sh --mount /` | Check specific filesystem. Audit `/var/log`, `/tmp`, and `/var/tmp`. Inode exhaustion prevents new file creation even with free disk blocks. |
| **Storage: High I/O Stalls** (`%util > 80%` or high D-state procs) | NVMe queue saturation, synchronous write bottlenecks, or failing storage. | `bash scripts/monitoring/storage_monitor.sh -i 2`<br/>`bash scripts/monitoring/process_monitor.sh` | Check `In-Flight` requests and processes in state `D`. Check `dmesg -T` for I/O timeouts. |
| **Network: `[CRIT]`** (Error/drop rate > threshold) | Interface buffer overflow, wireless interference, or MTU mismatch. | `bash scripts/monitoring/network_monitor.sh -I wlo1` | Inspect `rx_dropped` vs `rx_errors`. High drop rate with 0 errors indicates OS socket buffer saturation. |
| **systemd: `[CRIT]`** (Failed units > 0) | Daemon crash, unhandled exception, or failed dependency chain. | `bash scripts/monitoring/systemd_monitor.sh -f` | Identify failed service. Run `journalctl -u <unit> -e -n 50` to inspect error logs. |

---

## 7. Testing & Static Analysis

The entire suite includes automated verification:

```bash
# Execute full unit test suite (83 assertions)
bash scripts/tests/test_runner.sh

# Run ShellCheck static analysis across all scripts
shellcheck -x scripts/lib/*.sh scripts/monitoring/*.sh scripts/tests/*.sh
```
