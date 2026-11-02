# Milestone Report: Modular Bash Monitoring Toolkit Implementation

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Senior Linux Automation Engineer & SRE Observability Engineer  
**Milestone:** Phase 2.1 — Bash Monitoring & Operational Automation Suite  
**Date of Execution:** 2026-10-28  
**Repository Path:** `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`  
**Target Environment:** Ubuntu 24.04.5 LTS (Kernel `7.0.0-38-generic`, Intel Core i7-1355U, Samsung NVMe)  

---

## 1. Executive Summary

In this milestone, we engineered a modular, production-grade Linux monitoring toolkit implemented entirely in POSIX-compliant Bash (`set -Eeuo pipefail`).

The toolkit directly accesses Linux kernel pseudo-filesystems (`/proc`, `/sys`) and native system utilities (`df`, `findmnt`, `ss`, `ps`, `systemctl`) to provide deep host telemetry across compute, memory, storage, networking, processes, and service managers. All scripts adhere to strict SRE non-destructive safety invariants, supporting both ANSI-colored CLI diagnostic reports and schema-compliant JSON telemetry.

### Key Milestones Achieved:
1. **Modular Script Architecture**: Developed 7 independent, executable monitoring tools and 2 shared libraries.
2. **Double-Counting Kernel Accounting Correction**: Implemented CPU differential math that subtracts virtual guest execution ticks from raw user ticks, resolving the historical Linux kernel accounting overlap.
3. **Paging Rate Dynamics**: Implemented rate-of-change differential sampling on `/proc/vmstat` ($\Delta pswpin$, $\Delta pswpout$) to distinguish active swap thrashing from inert cold swap.
4. **Virtual Mount Filtering**: Filtered out ephemeral snap loop mounts (`squashfs`, `tmpfs`) from storage and diskstats by default, preventing CLI clutter.
5. **Deterministic Test Suite & Fixture Engine**: Created 7 test suites featuring 83 automated assertions executing against parameterized kernel mock fixtures (`PROC_ROOT`, `SYS_ROOT`).
6. **Zero ShellCheck Findings**: Validated all scripts with `shellcheck -x`, achieving zero errors and zero warnings.

---

## 2. System Architecture & Directory Organization

The toolkit enforces a decoupled architecture where modules can execute standalone or under a master CLI orchestrator:

```
scripts/
├── lib/
│   ├── common.sh              # Shared constants, exit codes, traps, logging, byte & JSON formatters
│   └── thresholds.sh          # Numeric comparison (awk), status aggregation, and colored badges
├── monitoring/
│   ├── cpu_monitor.sh         # CPU utilization, per-core load average, hardware info, PSI
│   ├── memory_monitor.sh      # Physical memory allocations, swap capacity, paging rates, PSI
│   ├── storage_monitor.sh     # Filesystem capacity, inode allocation, disk I/O stats, mount options
│   ├── network_monitor.sh     # Interface states, RX/TX throughput, error/drop rates, socket audit
│   ├── process_monitor.sh     # Task states (R/S/D/Z/T), thread count, top CPU/Mem, PID inspector
│   ├── systemd_monitor.sh     # Host system running state, failed units, service metadata
│   └── system_monitor.sh      # Unified orchestrator for subcommands and consolidated reports
└── tests/
    ├── test_runner.sh         # Lightweight TAP-like test runner and assertion framework
    ├── fixtures/              # Parameterized mock pseudo-filesystems (/proc, /sys)
    │   ├── proc/              # stat, loadavg, cpuinfo, meminfo, vmstat, pressure/*, diskstats, mounts, net/dev, 1/status
    │   └── sys/               # class/net/eth0/operstate, class/net/eth0/mtu
    ├── test_cpu.sh            # CPU utilization, topology, load, PSI, and threshold unit tests
    ├── test_memory.sh         # Memory allocations, swap math, paging rate delta, and PSI tests
    ├── test_storage.sh        # Filesystem capacity, inode parsing, diskstats rate, loop filter tests
    ├── test_network.sh        # Network interfaces, error counters, socket parsing, filter tests
    ├── test_process.sh        # Process states, zombie alerts, top lists, PID inspector tests
    ├── test_systemd.sh        # Service active states, failed unit parsing, degradation tests
    └── test_cli_and_errors.sh # Command dispatch, missing command (127), argument syntax (2) tests
```

---

## 3. Scripts Created & Responsibilities

| Script Name | Path | Execution Mode | Responsibilities |
|---|---|---|---|
| `common.sh` | `scripts/lib/common.sh` | Sourced | Defines exit codes (`0`, `1`, `2`, `3`, `4`, `127`), traps, timestamp generator, logging helpers, byte conversion, number checks, and JSON string escaping. |
| `thresholds.sh` | `scripts/lib/thresholds.sh` | Sourced | Numeric comparisons via `awk`, upper/lower threshold evaluation, severity aggregation (`CRIT` > `WARN` > `ERROR` > `OK`), and ANSI badges. |
| `cpu_monitor.sh` | `scripts/monitoring/cpu_monitor.sh` | Standalone / Orchestrated | Samples differential `/proc/stat` ticks (user, nice, sys, idle, iowait, irq, guest), `/proc/loadavg` (normalized per-core), `/proc/cpuinfo`, and CPU PSI. |
| `memory_monitor.sh` | `scripts/monitoring/memory_monitor.sh` | Standalone / Orchestrated | Computes true used RAM (`MemTotal - MemAvailable`), swap capacity, differential paging rates ($\Delta pswpin$, $\Delta pswpout$), and memory PSI. |
| `storage_monitor.sh` | `scripts/monitoring/storage_monitor.sh` | Standalone / Orchestrated | Inspects `df -PTk` blocks, `df -PTi` inodes, `/proc/mounts` options, and `/proc/diskstats` I/O rates excluding virtual snap loop devices. |
| `network_monitor.sh` | `scripts/monitoring/network_monitor.sh` | Standalone / Orchestrated | Inspects `/proc/net/dev` RX/TX bytes and error/drop rates, `/sys/class/net` operstate/mtu, and audits active listening ports via `ss -tulnH`. |
| `process_monitor.sh` | `scripts/monitoring/process_monitor.sh` | Standalone / Orchestrated | Evaluates process counts across scheduling states (`R`, `S`, `D`, `Z`, `T`), ranks top CPU and Memory consumers, and inspects single PIDs via `/proc/<pid>/status`. |
| `systemd_monitor.sh` | `scripts/monitoring/systemd_monitor.sh` | Standalone / Orchestrated | Queries `systemctl is-system-running`, parses failed units via `systemctl list-units --state=failed`, and extracts service properties via `systemctl show`. |
| `system_monitor.sh` | `scripts/monitoring/system_monitor.sh` | Master CLI | Subcommand router (`all`, `cpu`, `memory`, `storage`, `network`, `process`, `systemd`) and consolidated health dashboard generator. |
| `test_runner.sh` | `scripts/tests/test_runner.sh` | Harness | Discovers and runs all test suites, records assertion outcomes, formats TAP-like output, and returns aggregate pass/fail exit codes. |

---

## 4. Functions Implemented Inventory

### Shared Common Library (`scripts/lib/common.sh`):
- `timestamp_utc()`: Generates ISO 8601 UTC timestamps (`date -u +"%Y-%m-%dT%H:%M:%SZ"`).
- `log_info()`, `log_warn()`, `log_error()`, `log_debug()`: Standardized stderr log formatters with timestamp and ANSI prefixes.
- `is_integer()`, `is_uint()`, `is_number()`: Strict regex-based input validation functions.
- `require_command()`: Validates tool existence in `PATH`; exits with code `127` if missing.
- `check_readable()`: Verifies file existence and read permissions; exits with code `1` if inaccessible.
- `bytes_to_human()`: Formats raw byte counts into B, KiB, MiB, GiB, or TiB.
- `kb_to_human()`: Converts 1-KiB blocks from `/proc/meminfo` into human units.
- `json_escape()`: Sanitizes arbitrary strings by escaping `\`, `"`, `\n`, `\r`, and `\t`.
- `setup_traps()`: Registers `SIGINT` (130) and `SIGTERM` (143) traps for clean script termination.

### Threshold Evaluation Library (`scripts/lib/thresholds.sh`):
- `compare_num()`: Invokes `awk` to perform arbitrary-precision floating-point comparisons (`gt`, `ge`, `lt`, `le`, `eq`, `ne`).
- `eval_threshold()`: Evaluates a value against warning and critical thresholds in either "upper" or "lower" direction.
- `format_status_badge()`: Renders colored terminal badges (`[OK]`, `[WARN]`, `[CRIT]`).
- `status_to_string()`: Translates exit codes to JSON status strings (`OK`, `WARNING`, `CRITICAL`).
- `aggregate_status()`: Computes the maximum severity across two status codes.

### Subsystem Monitors:
- `cpu_monitor.sh`: `get_stat_cpu_line()`, `calculate_utilization()`, `collect_cpu_info()`, `collect_loadavg()`, `collect_psi()`.
- `memory_monitor.sh`: `collect_meminfo()`, `get_vmstat_counters()`, `collect_memory_psi()`.
- `storage_monitor.sh`: `get_mount_opts()`, `collect_filesystems()`, `get_diskstats_snapshot()`, `collect_disk_io()`.
- `network_monitor.sh`: `get_net_dev_snapshot()`, `get_iface_metadata()`, `collect_network_interfaces()`, `collect_listening_ports()`.
- `process_monitor.sh`: `collect_process_states()`, `collect_top_cpu()`, `collect_top_memory()`, `inspect_pid()`.
- `systemd_monitor.sh`: `collect_system_state()`, `collect_failed_units()`, `inspect_service()`.
- `system_monitor.sh`: `run_module_json()`, `run_full_report()`.

---

## 5. Live CLI Execution Evidence

### 5.1 Consolidated System Report (`system_monitor.sh all --summary`)

```
========================================================================================
Linux Reliability & Monitoring Lab — Consolidated System Health Report  [CRIT]
========================================================================================
Host Target: rubi | Timestamp: 2026-10-28T08:59:05Z | Toolkit Version: 1.0.0

--- Subsystem Health Summary ---
Subsystem          Status       Exit Code    Core Telemetry Highlights
----------------------------------------------------------------------------------------
CPU Compute        [OK]         0            Util: 83.25% | 1m Load: 7.58
Memory & Swap      [OK]         0            RAM Used: 71.50% | Swap Used: 75.08%
Storage & Inodes   [OK]         0            Root FS: 29% used
Network & Ports    [OK]         0            RX: 0.2 KiB/s | TX: 14.4 KiB/s
Process States     [OK]         0            Procs: 466 | Zombies: 0
systemd Services   [CRIT]       4            State: degraded | Failed Units: 2
----------------------------------------------------------------------------------------

Overall Diagnostic Result: [CRIT] (Exit Code: 4)
```

### 5.2 CPU Subsystem Report (`cpu_monitor.sh --text`)

```
=====================================================================
Linux CPU Subsystem Telemetry Report  [OK]
=====================================================================
Timestamp: 2026-10-28T08:51:12Z | Model: 13th Gen Intel(R) Core(TM) i7-1355U
Topology : 1 Socket(s) | 10 Physical Core(s) | 12 Logical Processor(s) (600.0 MHz)

--- Differential CPU Utilization (1s window) ---  [OK]
  Total Active Utilization : 54.97%
  ├─ Pure User Space       :  30.29%   ├─ Pure Idle Task :  44.95%
  ├─ Kernel System Space   :  10.18%   ├─ Disk I/O Wait  :   0.08%
  ├─ Virtual Guest (KVM)   :  14.34%   ├─ IRQ / SoftIRQ  :   0.16%
  └─ Nice Priority         :   0.00%   └─ Hypervisor Stl :   0.00%

--- System Load Average ---  [OK]
  1-Min Load: 9.11 (Normalized: 0.76/core) | 5-Min: 6.38 | 15-Min: 5.13
  Scheduling Entities: 15 runnable / 2327 total | Last PID: 1487542

--- Pressure Stall Information (CPU PSI) ---
  some avg10=6.01% avg60=6.13% avg300=4.26% | Total Stalled Time: 3074924476 us
---------------------------------------------------------------------
```

### 5.3 Storage Subsystem Report (`storage_monitor.sh --text`)

```
=====================================================================
Linux Storage Subsystem Telemetry Report  [OK]
=====================================================================
Timestamp: 2026-10-28T08:53:45Z

--- Active Filesystem Capacity & Inodes ---
Filesystem             Type          Size       Used      Avail   Use% Inodes% Mount Point      Status
------------------------------------------------------------------------------------------------------
/dev/nvme0n1p2         ext4    467.35 GiB 125.19 GiB 318.35 GiB  29.0%    5.0% /                [OK]
  └─ Options: rw,relatime
/dev/nvme0n1p1         vfat      1.05 GiB   6.14 MiB   1.04 GiB   1.0%    0.0% /boot/efi        [OK]
  └─ Options: rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro

--- Physical Block Device I/O Rates (1s window) ---
Device           Read r/s  Write w/s   Read KiB/s  Write KiB/s  In-Flight    %util
----------------------------------------------------------------------------------
nvme0n1               5.0       76.0         24.0        552.0          0     1.6%
nvme0n1p1             0.0        0.0          0.0          0.0          0     0.0%
nvme0n1p2             5.0       76.0         24.0        552.0          0     1.6%
---------------------------------------------------------------------
```

### 5.4 Process Subsystem Report (`process_monitor.sh --text`)

```
=====================================================================
Linux Process Subsystem Telemetry Report  [OK]
=====================================================================
Timestamp: 2026-10-28T08:56:16Z

--- Global Process Scheduling States ---
  Total Process Tasks: 462    | Total Kernel Threads: 2349
  ├─ Running (R)      : 3     ├─ Zombie Defunct (Z) : 0     [OK]
  ├─ Sleep Interrupt  : 344   ├─ Disk Sleep (D)     : 1     [OK]
  └─ Stopped / Traced : 0     └─ Kernel Idle (I)    : 114  

--- Top 5 CPU Consuming Processes ---
PID      PPID     USER           %CPU   %MEM STAT   COMMAND
---------------------------------------------------------------------
1271089  1270961  dineth          187   23.5 Sl     qemu-system-x86
1504734  1210680  dineth          101    0.3 Rsl    node
1216219  1216024  dineth         29.7    2.5 Sl     antigravity
1210953  1210680  dineth         28.5    1.1 Ssl    gnome-shell
1213187  1211980  dineth         21.8    3.2 Sl     brave

--- Top 5 Memory Consuming Processes (by RSS) ---
PID      PPID     USER                RSS   %MEM STAT   COMMAND
---------------------------------------------------------------------
1271089  1270961  dineth         3.61 GiB   23.5 Sl     qemu-system-x86
1212232  1211980  dineth         1.06 GiB    6.9 Sl     brave
1212720  1211980  dineth       558.81 MiB    3.5 Sl     brave
1213187  1211980  dineth       517.31 MiB    3.2 Sl     brave
1216185  1215975  dineth       497.27 MiB    3.1 Sl     language_server
---------------------------------------------------------------------
```

---

## 6. Test Suite & Verification Results

The test suite executes against parameterized mock fixtures in `scripts/tests/fixtures/`, decoupling tests from volatile workstation telemetry.

### 6.1 Test Suite Breakdown:
1. `test_cli_and_errors.sh`: Validates CLI command dispatch, `--help`, `--version`, missing command detection (`EXIT_NOCMD=127`), non-existent file checks, numeric comparisons, status severity aggregation, JSON escaping, and byte formatting.
2. `test_cpu.sh`: Validates CPU model extraction, core topology calculation, 1-minute load per-core normalization against fixture, PSI parsing, threshold breaches (`EXIT_WARN=3`, `EXIT_CRIT=4`), and syntax errors (`EXIT_USAGE=2`).
3. `test_memory.sh`: Validates `MemTotal`, `MemAvailable`, true used RAM math (`MemTotal - MemAvailable`), swap used percentage, cumulative `vmstat` counters, PSI parsing, and memory/swap threshold triggers.
4. `test_storage.sh`: Validates mount options extraction from `/proc/mounts`, diskstats exclusion of loop devices, targeted mount inspection (`--mount /`), threshold triggers, and non-existent mount failure.
5. `test_network.sh`: Validates interface enumeration, sysfs `operstate` and `mtu`, cumulative bytes and error counters, interface filtering (`-I eth0`), and `--ports-only` mode.
6. `test_process.sh`: Validates task state categorization (`R`, `S`, `D`, `Z`, `T`, `I`), top CPU/Memory consumer lists, PID 1 inspection from `/proc/1/status`, zombie threshold evaluation, and invalid PID handling.
7. `test_systemd.sh`: Validates host operational state (`degraded`), failed unit enumeration, service metadata inspection for `cron.service`, and threshold evaluation.

### 6.2 Test Execution Evidence:
```
$ bash scripts/tests/test_runner.sh

=== Test Suite: CLI Orchestrator, Error Handling & Safety Invariants ===
  • displays CLI help message on --help (exit code 0) ... PASS
  • displays version string on --version ... PASS
  • fails with exit code 2 on unknown command ... PASS
  • fails with exit code 2 when no command is provided ... PASS
  • verifies require_command exits with 127 when tool is missing ... PASS
  • verifies check_readable returns 1 on nonexistent file ... PASS
  • verifies numeric comparison helper handles floats and integers correctly ... PASS
  • verifies threshold status aggregator selects maximum severity ... PASS
  • verifies JSON string escaper safely escapes special characters ... PASS
  • verifies human byte formatting accurately converts magnitudes ... PASS

=== Test Suite: CPU Monitor: Deterministic Parsing & Threshold Verification ===
  • parses CPU model and core topology accurately from fixtures ... PASS
  • counts logical processors correctly from fixture (4 processors) ... PASS
  • reads and normalizes load average from fixture (0.75 / 4 = 0.19 per core) ... PASS
  • extracts Pressure Stall Information (PSI) correctly from fixture ... PASS
  • exits with code 0 [OK] when all metrics are within thresholds ... PASS
  • exits with code 3 [WARN] when warning load threshold is exceeded ... PASS
  • exits with code 4 [CRIT] when critical load threshold is exceeded ... PASS
  • validates that warn threshold cannot be greater than crit threshold (exit 2) ... PASS

=== Test Suite: Memory Monitor: Capacity, Swap Math & PSI Verification ===
  • calculates MemTotal correctly from fixture (16,000,000 kB) ... PASS
  • calculates Used Memory as MemTotal - MemAvailable (8,000,000 kB = 50.00%) ... PASS
  • calculates Swap Used and percentage (1,000,000 kB / 4,000,000 kB = 25.00%) ... PASS
  • reads cumulative vmstat counters from fixture ... PASS
  • reads Memory PSI metrics (some avg10=0.10, full avg10=0.00) ... PASS
  • exits with code 0 when within thresholds ... PASS
  • exits with code 3 [WARN] when RAM usage exceeds warn threshold (50% >= 40%) ... PASS
  • exits with code 4 [CRIT] when Swap usage exceeds critical threshold (25% >= 20%) ... PASS

=== Test Suite: Network Monitor: Interfaces, Error Counters & Socket Verification ===
  • parses interface names from /proc/net/dev fixture (eth0, lo) ... PASS
  • parses operstate and MTU from sysfs fixture (up, 1500) ... PASS
  • reads cumulative bytes and error/drop counters from fixture ... PASS
  • supports single interface filtering (--interface eth0) ... PASS
  • exits with code 0 when error rates are within thresholds ... PASS
  • fails with exit code 1 when target interface does not exist ... PASS
  • supports --ports-only mode and captures listening sockets ... PASS

=== Test Suite: Process Monitor: States, Top Resources & PID Inspection ===
  • counts and categorizes process states ... PASS
  • reports top CPU and top memory consumer arrays ... PASS
  • inspects PID 1 accurately from fixture /proc/1/status ... PASS
  • exits with code 0 when zombie threshold is not exceeded ... PASS
  • exits with code 1 when targeted PID does not exist ... PASS
  • exits with code 2 on invalid PID argument ... PASS

=== Test Suite: Storage Monitor: Filesystem, Inodes & Diskstats Verification ===
  • excludes virtual loop devices from diskstats by default ... PASS
  • verifies loop devices are not included in diskstats ... PASS
  • reads mount options from fixture /proc/mounts (rw,relatime) ... PASS
  • supports targeted mount inspection (--mount /) ... PASS
  • exits with code 0 when filesystem usage is below threshold ... PASS
  • exits with code 3 [WARN] when disk warning threshold is breached (e.g. >= 10%) ... PASS
  • exits with code 4 [CRIT] when disk critical threshold is breached (e.g. >= 10%) ... PASS
  • fails with exit code 1 when target mount does not exist ... PASS

=== Test Suite: systemd Monitor: Service State & Unit Failure Verification ===
  • collects overall system state and failed units count ... PASS
  • inspects service metadata for cron.service ... PASS
  • exits with code 0 when failed units count is below configured threshold ... PASS
  • exits with code 4 [CRIT] when failed units count meets or exceeds critical threshold (e.g. -c 1) ... PASS
  • exits with code 2 on invalid threshold input ... PASS

Execution completed in 7 seconds.

=====================================================================
Test Execution Summary
=====================================================================
Total Assertions : 83
Passed           : 83
Failed           : 0

All test suites passed successfully!
```

### 6.3 ShellCheck Audit Evidence:
```bash
$ /tmp/sc/shellcheck -x scripts/lib/*.sh scripts/monitoring/*.sh scripts/tests/*.sh
# Exit Code: 0 (No warnings or errors reported across any scripts)
```

---

## 7. Security, Safety & Operational Invariants Review

1. **Strict Read-Only Execution**:
   - Every metric extraction is executed against read-only interfaces: kernel `/proc`, `/sys`, or non-modifying CLI queries (`df`, `findmnt`, `ss`, `ps`, `systemctl is-active`, `systemctl show`).
   - The suite does not write to disks, allocate memory, modify iptables/nftables, terminate processes (`kill`), or reload systemd units.
2. **Zero Root Privilege Requirements**:
   - All modules operate fully without `sudo` or elevated capabilities. Missing permissions on restricted processes (e.g., viewing socket process owners or non-owned PIDs) are handled gracefully without aborting.
3. **No Unsafe Word Splitting or `eval`**:
   - Arrays and variable interpolations are strictly quoted (`"${VAR}"`, `"${ARRAY[@]}"`).
   - The unsafe `eval` builtin is completely avoided; dynamic arithmetic and comparisons are executed inside isolated `awk` environments.
4. **Environment Isolation**:
   - Scripts avoid assuming default locations for `/proc` and `/sys`, allowing deployment inside containers, chroot jails, or mock test harnesses.
5. **No Secrets or Identifiers**:
   - Host-specific IP addresses, MACs, or user paths are not hardcoded. Output can be safely piped to logs or external telemetry endpoints.

---

## 8. Limitations & Boundary Conditions

1. **Kernel PSI Dependency**: Pressure Stall Information requires Linux kernel config `CONFIG_PSI=y`. On older kernels (< 4.20) or distributions where PSI is disabled at boot (`psi=0`), PSI metrics will report `supported: false` and gracefully yield `0.00`.
2. **Socket Process Inspection**: When run as a standard non-root user, `ss -tulnp` cannot display process names or PIDs for sockets bound by other users (e.g., system services). The toolkit handles this by reporting socket IP/port bindings without failing.
3. **Transient Process Lifecycles**: Processes that terminate during sampling between `ps` invocation and `/proc/<pid>/status` read are safely caught and reported without crashing.
4. **Snap Loop Densities**: Systems with dozens of snap packages generate high volumes of loop devices. The storage monitor filters out loop devices by default, but operators can re-enable them via `--include-virtual`.

---

## 9. Integration Requirements for Next Milestones

1. **Phase 2 Custom Python Agent Integration (`agent/`)**:
   - The Python agent can execute the Bash monitoring scripts in `--json` mode or directly read the same kernel interfaces (`/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/net/dev`) to expose native Prometheus metrics on `:9101/metrics`.
2. **Prometheus Node Exporter Alignment**:
   - The metric naming conventions defined in this toolkit align directly with standard Prometheus metric names:
     - `node_cpu_seconds_total` $\leftrightarrow$ `cpu_monitor.sh`
     - `node_memory_MemTotal_bytes` $\leftrightarrow$ `memory_monitor.sh`
     - `node_filesystem_free_bytes` $\leftrightarrow$ `storage_monitor.sh`
     - `node_network_receive_bytes_total` $\leftrightarrow$ `network_monitor.sh`
     - `node_systemd_unit_state` $\leftrightarrow$ `systemd_monitor.sh`
3. **Automated Incident Remediation (Phase 8)**:
   - When the remediation daemon is implemented, it will utilize the exit codes and structured JSON output from this monitoring toolkit to detect degradation states and trigger bounded self-healing routines.
