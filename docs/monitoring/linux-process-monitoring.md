# Linux Process Subsystem & Resource Monitoring

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 1.3.2 — Linux Process Monitoring  
**Author:** Senior Linux Systems & Site Reliability Engineer  
**Target Environment:** Ubuntu 24.04 LTS (Kernel `7.0.0-38-generic`, Intel Core i7-1355U, 12 Logical CPUs)  

---

## 1. Process Architecture & The Kernel Task Model

In Linux, the kernel does not distinguish fundamentally between "processes" and "threads." Both are instantiated as instances of `struct task_struct` in kernel memory.

```
                      ┌──────────────────────────────┐
                      │    PID 0 (swapper/idle)      │
                      └──────────────┬───────────────┘
                                     │ kernel boot
                                     ▼
                      ┌──────────────────────────────┐
                      │    PID 1 (systemd init)      │
                      └──────┬────────────────┬──────┘
                             │                │
            ┌────────────────▼──────┐  ┌──────▼────────────────┐
            │   System Daemons      │  │ User Session Slice    │
            │ (sshd, journald, dbus)│  │ (Display Mgr, Shells) │
            └───────────────────────┘  └──────┬────────────────┘
                                              │ fork() / execve()
                                       ┌──────▼────────────────┐
                                       │ Application Tasks     │
                                       │ (Browsers, IDE, Java) │
                                       └───────────────────────┘
```

### 1.1 PID, TGID and Threading Architecture
When user space creates a thread via `pthread_create()`, the underlying library invokes the `clone()` system call with shared memory flags (`CLONE_VM`, `CLONE_FS`, `CLONE_FILES`, `CLONE_SIGHAND`).
- **`TGID` (Thread Group ID)**: Represents the identifier of the thread group leader. In POSIX user-space terminology, **the TGID is what applications report as the `PID`**.
- **`PID` (Kernel Task ID)**: Inside the kernel, each thread has its own unique `PID` (referred to as `TID` or LWP - Light Weight Process in user space).
- **`PPID` (Parent Process ID)**: The TGID of the process that spawned this task. If the parent terminates, orphaned children are automatically reparented to PID 1 (`systemd`) or an assigned subreaper.

```bash
# Verifying TGID vs PID inside /proc/1/status
cat /proc/1/status | grep -E "^(Name|State|Tgid|Pid|PPid|Threads)"
# Output:
# Name:    systemd
# State:   S (sleeping)
# Tgid:    1
# Pid:     1
# PPid:    0
# Threads: 1
```

---

## 2. Process Lifecycle & State Machine

Every task in Linux transitions through states governed by the Completely Fair Scheduler (CFS) and kernel synchronization primitives.

```
                  ┌───────────────┐
                  │    fork()     │
                  └───────┬───────┘
                          │ Task Struct Created
                          ▼
                  ┌───────────────┐
       ┌─────────►│  TASK_RUNNING │ (R) ◄── On CPU or in Run-Queue
       │          └───────┬───────┘
       │                  │ Schedule out / Block
       │       ┌──────────┴──────────┐
       │       │                     │
       │       ▼                     ▼
       │ ┌───────────────┐    ┌───────────────┐
       │ │TASK_INTERRUPT │(S) │TASK_UNINTERRUP│(D)
       │ │   (Sleeping)  │    │ (Disk / NFS)  │
       │ └───────┬───────┘    └───────┬───────┘
       │         │ Signal / Event     │ I/O Complete
       └─────────┴────────────────────┘
                          │ exit_group()
                          ▼
                  ┌───────────────┐
                  │  EXIT_ZOMBIE  │ (Z) ◄── Awaiting waitpid() from Parent
                  └───────┬───────┘
                          │ Parent reaps task
                          ▼
                  ┌───────────────┐
                  │   DEAD / GC   │
                  └───────────────┘
```

### 2.1 Process State Taxonomy

| State Code | Description | Kernel Constant | SRE Interpretation & Root Cause |
| :--- | :--- | :--- | :--- |
| **`R`** | Running or Runnable | `TASK_RUNNING` | The task is actively executing on a CPU core or waiting in the CPU run-queue. High counts relative to CPU core count indicate CPU saturation. |
| **`S`** | Interruptible Sleep | `TASK_INTERRUPTIBLE` | Task is waiting for an event, timer, or I/O. Will wake immediately if sent a POSIX signal. Normal state for idle daemons. |
| **`D`** | Uninterruptible Sleep | `TASK_UNINTERRUPTIBLE` | Task is blocked in kernel space waiting for a hardware condition (usually disk I/O, page faulting, or device driver lock). **Cannot be killed by `kill -9` (`SIGKILL`)**. Contributes directly to System Load Average. |
| **`T`** | Stopped | `TASK_STOPPED` | Task was halted by a job control signal (e.g., `SIGTSTP` via `Ctrl+Z`) or debug tracer (`TASK_TRACED` via `gdb`/`strace`). |
| **`Z`** | Zombie | `EXIT_ZOMBIE` | Task has completed execution (`exit_group()`) and freed its memory and file descriptors, but its exit status remains in the process table waiting for its parent to call `wait()` / `waitpid()`. |

---

## 3. Zombie & Orphan Processes

### 3.1 The Mechanics of Zombie Processes (`Z`)
A zombie process consumes **zero CPU and zero RAM**. Its virtual memory address space, stack, heap, and open file descriptors have already been deallocated by `do_exit()`.
- **What a Zombie Retains**: A 1.7 KiB kernel `task_struct`, thread stack structure, and an entry in the operating system's PID table.
- **Why `kill -9` Fails**: `SIGKILL` (signal 9) tells a process to execute its termination routine. Because a zombie is already dead, it cannot receive, handle, or execute any signals.
- **SRE Danger of Zombie Accumulation**: While individual zombies do not harm memory or CPU, an unmanaged leak of zombies will exhaust the available PID space defined by `/proc/sys/kernel/pid_max`. When PIDs are exhausted, the kernel returns `EAGAIN` / `ENOMEM`, and the entire host can no longer spawn new processes (SSH, cron, health checks fail).
- **Remediation**:
  1. Identify the parent: `ps -o ppid= -p <zombie_pid>`.
  2. Send `SIGCHLD` to the parent to force a reap: `kill -SIGCHLD <ppid>`.
  3. If the parent application is stuck, restart or terminate the parent. When the parent dies, the kernel reparents the zombie to PID 1 (`systemd`), which immediately invokes `waitpid()` and cleans the table.

### 3.2 Orphan Processes & Subreapers
When a parent process dies before its children, the children become **orphans**.
- Historically, the kernel unconditionally reparented orphaned children to PID 1.
- In modern Linux (kernel 3.4+), any process can designate itself as an explicit "subreaper" using `prctl(PR_SET_CHILD_SUBREAPER, 1)`. Container managers (Docker, containerd) and systemd user managers (`systemd --user`) use this flag to contain orphan reaping within their own subtrees.

---

## 4. Memory Profiling: VIRT vs. RES vs. SHR vs. PSS

Interpreting process memory requires understanding the difference between virtual allocations and physical memory residency.

```
Virtual Address Space (VIRT: e.g., 1,396 GiB)
┌─────────────────────────┬──────────────────────┬─────────────────────────┐
│ Unallocated / Reserved  │ Mapped Files / Code  │ Anonymous Heap / Stacks │
└─────────────────────────┴──────────┬───────────┴────────────┬────────────┘
                                     │                        │
Physical RAM Residency               ▼                        ▼
                              ┌──────────────┐         ┌──────────────┐
                              │ Shared (SHR) │         │ Private RSS  │
                              └──────┬───────┘         └──────┬───────┘
                                     └────────────┬───────────┘
                                                  ▼
                                     Resident Set Size (RES)
```

### 4.1 Memory Metrics Defined
1. **`VIRT` (Virtual Image Size - VSZ)**: Total address space reserved or mapped by the process. Includes shared libraries, memory-mapped files, uncommitted heap, thread stacks ($8\text{ MiB}$ each by default), and sparse address allocations.
   - *Host Observation*: The IDE process on the monitored host reports $1,396\text{ GiB}$ virtual memory. This is completely harmless; modern 64-bit V8/Chromium runtimes reserve large contiguous virtual address ranges for garbage collection and memory safety without committing physical RAM.
2. **`RES` (Resident Set Size - RSS)**: The exact quantity of physical RAM currently mapped into the process's page table.
   $$\text{RES} = \text{Anonymous RSS} + \text{File-backed RSS} + \text{Shared Memory RSS}$$
3. **`SHR` (Shared Memory)**: Physical memory mapped by this process that could be shared with other processes (e.g., standard `libc.so`, shared memory segments, memory-mapped shared files).
4. **`PSS` (Proportional Set Size)**: The most accurate metric for process memory accounting:
   $$\text{PSS} = \text{USS (Unique Set Size)} + \sum \left( \frac{\text{Shared Page Size}}{\text{Number of Processes Sharing Page}} \right)$$

### 4.2 Inspecting Process Memory via `/proc/[pid]/smaps_rollup`

```bash
# Accurate memory rollup for a process (e.g., PID 1)
cat /proc/1/smaps_rollup
# Output:
# Rss:               10820 kB
# Pss:               10115 kB
# Pss_Anon:           5168 kB
# Pss_File:           4947 kB
# Shared_Clean:       1416 kB
# Shared_Dirty:          0 kB
# Private_Clean:      4236 kB
# Private_Dirty:      5168 kB
# Referenced:        10820 kB
# Anonymous:          5168 kB
# LazyFree:              0 kB
# AnonHugePages:         0 kB
# ShmemPmdMapped:        0 kB
# FilePmdMapped:         0 kB
# Shared_Hugetlb:        0 kB
# Private_Hugetlb:       0 kB
# Swap:                  0 kB
# SwapPss:               0 kB
```

---

## 5. CPU Profiling & Context Switches

Process CPU utilization represents the fraction of CPU time slices allocated by the Completely Fair Scheduler (CFS).

### 5.1 Context Switching: Voluntary vs. Involuntary
Context switching occurs when the kernel suspends an active execution context on a CPU core and replaces it with another.

```bash
pidstat -w 1 1
# Host Sample:
# UID       PID   cswch/s nvcswch/s  Command
#   0        15    235.29      0.00  rcu_preempt
#   0        18     60.78      0.00  migration/0
# 1000  1210953    142.15     18.63  gnome-shell
```

- **Voluntary Context Switches (`cswch/s`)**: The task voluntarily relinquishes the CPU before its allocated time slice expires because it is blocked waiting for an external resource (e.g., file read, database network response, mutex lock, `sleep()`).
- **Involuntary / Non-Voluntary Context Switches (`nvcswch/s`)**: The task wanted to continue computing, but the CFS scheduler **preempted** it because its time slice elapsed or a higher-priority task became runnable.

> [!IMPORTANT]
> **SRE Saturation Alert**: A sharp spike in non-voluntary context switches (`nvcswch/s`) across application threads indicates severe **CPU scheduling contention**. The host has more runnable threads than physical execution cores can service simultaneously.

---

## 6. File Descriptors & System Capacity Limits

In UNIX philosophy, open files, network sockets, epoll instances, pipes, and eventfd primitives are all represented as file descriptors (FDs).

### 6.1 Capacity Limits & The Failure Modes

```
┌────────────────────────────────────────────────────────┐
│              Kernel Global File Table                  │
│       /proc/sys/fs/file-nr: 19,255 of 9.22 × 10^18     │
└───────────────────────────┬────────────────────────────┘
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
┌───────────────────────────┐ ┌───────────────────────────┐
│ Process A File Table      │ │ Process B File Table      │
│ ulimit -n: 1,048,576      │ │ ulimit -n: 1,024 (legacy) │
│ Open: 42 files            │ │ Open: 1,024 files (FULL)  │
└───────────────────────────┘ └─────────────┬─────────────┘
                                            │ Exceeded limit!
                                            ▼
                                  Returns: EMFILE
```

- **Process-Level Limit (`EMFILE`)**: When a process attempts `open()`, `socket()`, or `accept()` and its open FD count reaches its `RLIMIT_NOFILE` limit, the kernel rejects the call with error `EMFILE` (*"Too many open files"*).
- **System-Wide Limit (`ENFILE`)**: When the global kernel limit `/proc/sys/fs/file-max` is reached, the kernel returns `ENFILE` (*"Too many open files in system"*). On modern Linux kernels, `file-max` defaults to $2^{63}-1$ ($9.22 \times 10^{18}$), making system-wide exhaustion rare.

### 6.2 Empirical Host Capacity Limits
```bash
# System-wide allocations
cat /proc/sys/fs/file-nr
# Output: 19255    0    9223372036854775807
# Field 1: Currently allocated file handles (19,255)
# Field 2: Allocated unused file handles (0 in kernel 2.6+)
# Field 3: Maximum file handles limit (9,223,372,036,854,775,807)

# System-wide PID limit
cat /proc/sys/kernel/pid_max
# Output: 4194304 (4.19 Million PIDs)

# System-wide thread limit
cat /proc/sys/kernel/threads-max
# Output: 110775 (110.7k threads)
```

---

## 7. Process Monitoring Toolkit & Comparison

| Tool | Primary Purpose | Sampling Method | Strengths | SRE Limitations |
| :--- | :--- | :--- | :--- | :--- |
| **`ps`** | Snapshot of active processes | Traverses `/proc` once at invocation | Customizable columns (`-o pid,ppid,stat,%cpu,%mem`), scriptable, standard on all POSIX systems | Point-in-time snapshot; `%cpu` is lifetime average since process start, not instantaneous rate. |
| **`top`** | Interactive real-time dashboard | Differential polling of `/proc/stat` & `/proc/[pid]/stat` | Low overhead, displays system summary (load, tasks, CPU states, memory) | Default sorting by CPU can mask memory hogs; default process mode hides threads. |
| **`htop`** | Advanced interactive process viewer | Traverses `/proc` with ncurses UI | Visual per-core graphs, process tree view (`F5`), kill signals, search/filter | Interactive terminal tool; not suited for non-interactive automation or long-term metric storage. |
| **`pidstat`** | Granular thread/process metrics | Differential timer sampling (e.g., `pidstat 1 5`) | Separates user vs. system CPU, tracks `cswch/s`, page faults, disk I/O per process | Requires `sysstat` package; polling hundreds of processes at high frequency can incur measurable CPU overhead. |
| **`/proc/[pid]`** | Kernel source of truth | Direct virtual filesystem access | Zero abstraction; access to raw jiffies, file descriptors (`/fd`), limits, and environment | Requires custom parsing; non-atomic reads across multiple `/proc` files. |

---

## 8. SRE Golden Signals for Process Health

```
┌────────────────────────────────────────────────────────┐
│            SRE Golden Signals for Processes            │
├───────────────┬────────────────────────────────────────┤
│ Latency       │ Thread scheduling delay (run-queue     │
│               │ latency via Pressure Stall Info / eBPF)│
├───────────────┼────────────────────────────────────────┤
│ Traffic       │ Request rate (inferred via context     │
│               │ switches/sec and socket accept rates)  │
├───────────────┼────────────────────────────────────────┤
│ Errors        │ Non-zero exit codes, crash restarts,   │
│               │ EMFILE open errors, SIGSEGV faults     │
├───────────────┼────────────────────────────────────────┤
│ Saturation    │ RSS approaching cgroup MemoryMax,      │
│               │ open FDs approaching ulimit, CPU wait  │
└───────────────┴────────────────────────────────────────┘
```

1. **Avoid Polling `/proc` at Ultra-High Frequencies**:
   - Iterating over thousands of directories in `/proc` every second causes heavy dentry and inode cache churn in the kernel. In modern production environments, high-resolution process tracing should leverage **eBPF** (e.g., `bpftrace`, `sched` tracepoints) rather than brute-force `/proc` scraping.
2. **Never Rely on Lifetime CPU in `ps`**:
   - The `%CPU` metric in standard `ps aux` is calculated as $\text{Total CPU Time} / \text{Process Uptime}$. A process that spiked to 100% CPU for the last 10 minutes but has been running for 30 days will show less than $1\%$ CPU in `ps`. Use differential tools (`pidstat 1` or `top`) for live incident investigation.
3. **Monitor `voluntary` vs `nonvoluntary` Ratios**:
   - A healthy worker process that primarily handles network I/O should exhibit predominantly voluntary context switches. If `nonvoluntary_ctxt_switches` suddenly dominates, the application is CPU-saturated or competing with neighbor workloads for scheduler slices.
