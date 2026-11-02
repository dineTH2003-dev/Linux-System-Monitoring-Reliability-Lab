# Linux systemd Service Architecture & Reliability Monitoring

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 1.3.3 — systemd Service Monitoring  
**Author:** Senior Linux Systems & Site Reliability Engineer  
**Target Environment:** Ubuntu 24.04 LTS (Kernel `7.0.0-38-generic`, systemd 255.4)  

---

## 1. systemd Architecture & Design Philosophy

`systemd` is the central system and service manager for modern Linux distributions. Executing as PID 1, it replaces traditional SysV init and Upstart, unifying service supervision, cgroups resource control, device events, mount orchestration, and logging.

```
┌────────────────────────────────────────────────────────────────────────┐
│                          systemd (PID 1)                               │
│        (Event Loop, D-Bus IPC, Socket Activation, Job Engine)          │
└──────┬──────────────┬──────────────┬──────────────┬──────────────┬─────┘
       │              │              │              │              │
       ▼              ▼              ▼              ▼              ▼
┌──────────────┐┌──────────────┐┌──────────────┐┌──────────────┐┌──────────────┐
│.service Units││.socket Units ││.target Units ││ .timer Units ││.mount Units  │
│(Daemons, Apps││(Lazy-start   ││(Sync barriers││(Cron replace-││(Filesystem   │
│ Workers)     ││ IPC sockets) ││ Multi-user)  ││ ments)       ││ mountpoints) │
└──────┬───────┘└──────────────┘└──────────────┘└──────────────┘└──────────────┘
       │
       ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   Unified cgroups v2 Hierarchy                         │
│   /sys/fs/cgroup/                                                      │
│   ├── system.slice/ (System services: sshd, jenkins, journald)        │
│   ├── user.slice/   (Interactive user sessions, desktop environments)  │
│   └── init.scope/   (PID 1 execution context)                          │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Core Components
- **Job Engine**: Evaluates transaction graphs when units are activated or stopped. Computes topological sorts, validates dependency satisfaction, and executes transitions concurrently.
- **Socket Activation**: Creates listening sockets before starting the daemon. When traffic arrives on the socket, systemd buffers the connection and launches the service on demand.
- **cgroups v2 Native Integration**: Automatically binds every service to an isolated control group subtree. Terminating a service terminates all child processes in the cgroup, preventing escaped daemon processes.

---

## 2. Unit Anatomy & Configuration Precedence

systemd configuration is defined through declarative unit files across a strict directory override hierarchy.

### 2.1 File Location Precedence (Highest to Lowest)
1. **`/etc/systemd/system/`**: Local administrator configurations and drop-in overrides. Takes absolute priority over all other locations.
2. **`/run/systemd/system/`**: Runtime ephemeral units and dynamically generated units created at boot by generators (e.g., SysV translation via `systemd-sysv-generator`).
3. **`/usr/lib/systemd/system/`** (or `/lib/systemd/system/`): Vendor-supplied default unit files installed by OS package managers (`apt`, `dpkg`). **Never edit files in this directory directly**; edits will be overwritten on package upgrade.

### 2.2 Drop-in Overrides vs. Full Replacement
- **Drop-in Configuration**: Rather than copying the entire unit file to `/etc/systemd/system/`, an SRE creates a drop-in file: `/etc/systemd/system/<unit>.service.d/override.conf`. Only the specific directives to be changed are placed here.
- **Inspecting Effective Definitions**:
  ```bash
  # View the merged active unit definition including all drop-ins
  systemctl cat jenkins.service
  ```

### 2.3 Anatomy of a Service Unit File

```ini
[Unit]
Description=Example Production Daemon
Documentation=man:daemon(8) https://example.com/docs
# Dependency Directives:
Requires=dbus.service
Wants=network-online.target
# Ordering Directives (Completely independent of dependencies):
After=network-online.target dbus.service

[Service]
Type=notify
User=appuser
Group=appgroup
WorkingDirectory=/opt/app
ExecStart=/opt/app/bin/server --config /etc/app.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Sandboxing & Security Directives
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true

# cgroups v2 Resource Constraints
CPUQuota=200%
MemoryMax=2G
MemoryHigh=1.8G
TasksMax=512

[Install]
WantedBy=multi-user.target
```

---

## 3. Service Lifecycle, Execution Types & State Engines

### 3.1 Service Execution Types (`Type=`)

| Service Type | Startup Readiness Signal | SRE Use Case & Mechanics |
| :--- | :--- | :--- |
| **`simple`** | Immediately after `fork()`. | Default when `ExecStart` is set and no type is specified. systemd does not wait for initialization; startup dependencies proceed immediately. |
| **`exec`** | Immediately after `execve()` executes successfully. | Ensures the binary exists and has correct permissions before systemd unblocks dependent units. |
| **`forking`** | Process calls traditional UNIX `fork()` and parent exits with status 0. | Legacy daemons. Requires `PIDFile=` so systemd tracks the child daemon's PID. |
| **`oneshot`** | Process executes and must terminate with exit code 0 before dependencies start. | Initialization scripts, crash dump handlers (`apport-autoreport.service`), setup scripts. |
| **`notify`** | Process explicitly sends `sd_notify("READY=1")` via a UNIX domain socket. | **Recommended Production Standard**. Guarantees application is fully initialized, listening on ports, and ready to serve before dependencies proceed. |
| **`dbus`** | Process acquires a configured name on the D-Bus system bus. | System services providing D-Bus APIs (e.g., `NetworkManager`, `polkit`). |

### 3.2 State Taxonomy: ActiveState vs. SubState

systemd separates high-level lifecycle state (`ActiveState`) from type-specific low-level state (`SubState`).

```
                    ┌───────────────────────────────┐
                    │      inactive (dead)          │
                    └──────────────┬────────────────┘
                                   │ systemctl start
                                   ▼
                    ┌───────────────────────────────┐
                    │     activating (start-pre)    │
                    └──────────────┬────────────────┘
                                   │ Readiness signal
                                   ▼
                    ┌───────────────────────────────┐
                    │       active (running)        │
                    └──────┬────────────────┬───────┘
                           │                │
            Normal exit /  │                │ Process crash /
            systemctl stop │                │ Unhandled exception
                           ▼                ▼
            ┌──────────────────────┐ ┌──────────────────────┐
            │deactivating (stop)   │ │    failed (failed)   │
            └──────────────┬───────┘ └──────────────────────┘
                           ▼
            ┌──────────────────────┐
            │   inactive (dead)    │
            └──────────────────────┘
```

- **`ActiveState`**: High-level abstract state: `active`, `reloading`, `inactive`, `failed`, `activating`, `deactivating`.
- **`SubState`**: Fine-grained execution substate: `running` (process active), `exited` (normal for oneshot), `dead` (not running), `auto-restart` (in restart backoff delay), `failed` (exited with error).

---

## 4. Dependencies vs. Ordering: The Critical SRE Distinction

One of the most widespread misconceptions in Linux systems operations is assuming that dependencies dictate startup order. **In systemd, dependencies and ordering are strictly orthogonal.**

```
┌────────────────────────────────────────────────────────┐
│            systemd Ordering Directives                 │
├───────────────────────────┬────────────────────────────┤
│ Before=foo.service        │ This unit must complete    │
│                           │ startup BEFORE foo starts. │
├───────────────────────────┼────────────────────────────┤
│ After=bar.service         │ This unit will delay start │
│                           │ until AFTER bar starts.    │
└───────────────────────────┴────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│            systemd Dependency Directives               │
├───────────────────────────┬────────────────────────────┤
│ Wants=baz.service         │ Activates baz when this    │
│                           │ unit starts (non-blocking).│
├───────────────────────────┼────────────────────────────┤
│ Requires=baz.service      │ Strict dependency: if baz  │
│                           │ fails, this unit fails.    │
├───────────────────────────┼────────────────────────────┤
│ BindsTo=baz.service       │ Lifecycle lock: if baz is  │
│                           │ stopped, this unit stops.  │
├───────────────────────────┼────────────────────────────┤
│ PartOf=baz.service        │ Propagates restart/reload  │
│                           │ signals from baz.          │
└───────────────────────────┴────────────────────────────┘
```

> [!WARNING]
> **The Concurrency Trap**: If you specify `Wants=database.service` in your application unit but **omit** `After=database.service`, systemd will launch **both units simultaneously in parallel**. The application will attempt to connect to the database before the database has opened its listening socket, causing an immediate connection refused error during boot. **Always pair `Requires=` or `Wants=` with `After=`.**

---

## 5. Failure Handling, Restart Policies & Crash Loops

When a managed process exits unexpectedly, systemd evaluates its configured restart directives.

### 5.1 Restart Directive Options (`Restart=`)
- **`no`**: Never restart the service (default).
- **`on-success`**: Restart only if the process exits cleanly with status 0.
- **`on-failure`**: Restart if the process exits with a non-zero exit code, is terminated by an uncaught signal (`SIGSEGV`, `SIGKILL`), times out, or fails a watchdog trigger.
- **`on-abort`**: Restart only if the process is terminated by an uncaught signal not considered a clean exit.
- **`always`**: Unconditionally restart the service regardless of exit code or clean shutdown.

### 5.2 Restart Rate Limiting & Crash Loop Prevention
To prevent broken daemons from thrashing the CPU in an infinite fork/crash loop, systemd applies burst rate limiting:

```ini
[Unit]
StartLimitIntervalSec=60s
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=5s
```

- **Mechanism**: If the service restarts more than `StartLimitBurst` (5 times) within `StartLimitIntervalSec` (60 seconds), systemd halts restart attempts and permanently places the unit into the **`failed`** state.
- **Resetting a Rate-Limited Unit**:
  ```bash
  # Clear the failure state and restart counters
  systemctl reset-failed <unit>.service
  systemctl restart <unit>.service
  ```

---

## 6. Host Case Study: Triage of Degraded System State

On the monitored host, executing `systemctl is-system-running` returned exit code 1 with status **`degraded`**. This section documents the empirical root-cause analysis.

### 6.1 Identifying the Failed Units
```bash
systemctl list-units --state=failed --no-pager
# Output:
#   UNIT                      LOAD   ACTIVE SUB    DESCRIPTION
# ● apport-autoreport.service loaded failed failed Process error reports when automatic reporting is enabled
# ● openipmi.service          loaded failed failed LSB: OpenIPMI Driver init script
```

### 6.2 Root Cause Analysis: `openipmi.service`
- **Unit Inspection**:
  ```bash
  systemctl cat openipmi.service
  # /run/systemd/generator.late/openipmi.service
  # Automatically generated by systemd-sysv-generator
  # SourcePath=/etc/init.d/openipmi
  ```
- **Journal Investigation**:
  ```bash
  journalctl -u openipmi.service -b --no-pager
  # Oct 24 20:34:36 rubi openipmi[1119]:    ...fail!
  # Oct 24 20:34:36 rubi systemd[1]: openipmi.service: Control process exited, code=exited, status=1/FAILURE
  ```
- **Technical SRE Finding**:
  - `openipmi` is an Intelligent Platform Management Interface (IPMI) driver designed for server motherboards with Baseboard Management Controllers (BMC).
  - The monitored host is a consumer laptop with an Intel Core i7-1355U. It possesses no physical IPMI hardware.
  - The legacy init script `/etc/init.d/openipmi` was automatically translated into a systemd unit by `systemd-sysv-generator` during boot. Upon invocation, the script probed for `/dev/ipmi0`, found no hardware, and exited with status 1.
  - **SRE Remediation**: Mask the service to prevent generator execution: `systemctl mask openipmi.service`.

### 6.3 Root Cause Analysis: `apport-autoreport.service`
- **Unit Inspection**:
  ```bash
  systemctl cat apport-autoreport.service
  # Type=oneshot
  # ExecStart=/usr/share/apport/whoopsie-upload-all --timeout 20
  ```
- **Journal Investigation**:
  ```bash
  journalctl -u apport-autoreport.service -b --no-pager
  # Oct 28 13:08:52 rubi whoopsie-upload-all[1392009]: INFO:root:  missing (remaining: 0 s): /var/crash/_opt_antigravity-2.0_antigravity.1000.uploaded
  # Oct 28 13:09:02 rubi systemd[1]: apport-autoreport.service: Main process exited, code=exited, status=2/INVALIDARGUMENT
  # Oct 28 13:09:02 rubi systemd[1]: Failed to start apport-autoreport.service
  ```
- **Technical SRE Finding**:
  - `apport-autoreport.service` is a oneshot crash collection script triggered when crash dumps exist in `/var/crash/`.
  - At 10:06:26 IST, the host experienced an OOM event where the kernel terminated memory-heavy processes, generating crash logs in `/var/crash/`.
  - When the upload daemon attempted to upload the dumps, the remote crash submission timed out after 20 seconds, and the script terminated with `status=2/INVALIDARGUMENT`.
  - Because the unit is `Type=oneshot` with no restart policy, systemd flagged the unit as permanently `failed`, causing the global system status to report `degraded`.

---

## 7. Resource Controls via systemd & cgroups v2

Modern systemd enforces kernel resource limits directly through the unified cgroups v2 tree (`/sys/fs/cgroup/`).

```bash
systemctl show systemd-journald.service -p MemoryCurrent,TasksCurrent,CPUAccounting,MemoryHigh,MemoryMax
# Output:
# MemoryCurrent=188227584 (179.5 MiB)
# TasksCurrent=1
# CPUAccounting=yes
# MemoryHigh=infinity
# MemoryMax=infinity
```

### 7.1 Key SRE Resource Directives

| systemd Directive | cgroups v2 Interface | Kernel Behavior & SRE Impact |
| :--- | :--- | :--- |
| **`MemoryMax=2G`** | `memory.max` | Hard memory ceiling. If the cgroup exceeds this limit, the kernel executes aggressive page reclaim. If insufficient memory is reclaimed, **the kernel OOM killer terminates a task inside the cgroup**. |
| **`MemoryHigh=1.8G`** | `memory.high` | Soft throttle threshold. When exceeded, the kernel throttles the processes and aggressively flushes page cache without invoking the OOM killer. |
| **`CPUQuota=150%`** | `cpu.max` | CFS bandwidth enforcement. `150%` limits the unit to $1.5$ logical CPU cores of execution time per scheduling period. |
| **`TasksMax=256`** | `pids.max` | Caps the total number of threads/processes inside the unit's cgroup. Prevents thread exhaustion and fork bombs. |
| **`IOWeight=500`** | `io.weight` | Proportional block I/O scheduling weight ($1 - 10000$) via BFQ scheduler. |

---

## 8. Service Observability: Logging & Boot Performance

### 8.1 Journald Diagnostic Workflows
`systemd-journald` captures structured logging from standard output, standard error, syslog, and kernel facilities.

```bash
# Filter logs for a specific unit within the current boot
journalctl -u jenkins.service -b --no-pager

# Filter errors and critical alerts across the entire system
journalctl -p 3 -xb --no-pager

# Export structured log entries in JSON format for SIEM ingestion
journalctl -u jenkins.service -n 1 -o json-pretty
```

### 8.2 Boot Performance & Critical Chain Analysis
systemd provides native profiling tools to analyze boot bottlenecks and identify blocking dependencies.

```bash
systemd-analyze
# Output:
# Startup finished in 12.800s (firmware) + 1.587s (loader) + 2.848s (kernel) + 7.811s (userspace) = 25.047s
# graphical.target reached after 7.796s in userspace.
```

```bash
systemd-analyze critical-chain
# Output:
# graphical.target @7.796s
# └─multi-user.target @7.796s
#   └─jenkins.service @3.447s +4.348s
#     └─network.target @3.436s
#       └─NetworkManager.service @2.628s +808ms
#         └─dbus.service @2.449s +118ms
```

### 8.3 Technical Interpretation of Boot Metrics
1. **The `critical-chain` Path**:
   - `graphical.target` required 7.796s of userspace execution.
   - The critical bottleneck was `jenkins.service`, which was started at `@3.447s` and took `+4.348s` to become ready.
   - Inspection of `jenkins.service` revealed `Type=notify`. Systemd blocked `multi-user.target` from completing until Jenkins initialized its JVM and signaled readiness via `sd_notify()`.
2. **The `blame` Caveat**:
   - Running `systemd-analyze blame` displayed `1d 3h 5min 58.002s snapd.service`.
   - **SRE Nuance**: `systemd-analyze blame` measures the time a unit took to complete or initialize. For persistent daemons that do not notify readiness, `blame` reports total elapsed active time, which does **not** imply that `snapd.service` delayed boot by 27 hours. SREs should always rely on `critical-chain` rather than raw `blame` to diagnose boot latency.

---

## 9. Diagnostic Toolkit & Practical Command Reference

| Tool | Purpose | Key Flags | Measurement Target | SRE Limitations |
| :--- | :--- | :--- | :--- | :--- |
| **`systemctl`** | Service control and state inspection | `status`, `list-units`, `is-active`, `is-system-running` | ActiveState, SubState, PID, memory, unit description | Does not display full unit file definitions without `cat`. |
| **`systemctl cat`** | View complete unit file definitions | `<unit>` | Merged unit files including all `/etc` drop-in overrides | Static definition; does not reflect live runtime property overrides. |
| **`systemctl show`** | Low-level property introspection | `-p PropertyName <unit>` | Exposes internal D-Bus properties (`MemoryCurrent`, `TasksCurrent`, `Restart`) | Verbose output; requires exact property names. |
| **`systemd-analyze`** | Boot performance and profiling | `time`, `blame`, `critical-chain`, `plot` | Firmware, kernel, and userspace startup latencies | `blame` can mislead without `critical-chain` correlation. |
| **`journalctl`** | Centralized binary journal inspection | `-u <unit>`, `-b`, `-p 3`, `-f`, `-o json` | Standard output, stderr, and syslog streams | Inactive or rotated logs may be truncated if storage limits are reached. |
