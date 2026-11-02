# Phase 1.1: CPU & Memory Performance Assessment Report

**Execution Timestamp:** 2026-10-28 11:50:00 IST (Audited: 12:00:00 IST)  
**Assessment Team:** Senior Linux Systems Engineer / Site Reliability Engineer  
**Host Target:** `rubi` (Ubuntu 24.04.5 LTS, Kernel `7.0.0-38-generic`, Intel Core i7-1355U)  
**Milestone:** Phase 1.1 — Linux CPU & Memory Intelligence (Technical Audit & Correction)  

---

## 1. Executive Summary

This report documents the audited empirical findings from direct kernel-level inspection of the CPU and memory subsystems on the local Linux host (`rubi`).

All metrics were captured using native Linux interfaces (`/proc/stat`, `/proc/loadavg`, `/proc/meminfo`, `/proc/pressure/*`, `/sys/devices/system/cpu/*`, `vmstat`, and `journalctl`).

### Key Audited Findings:
1. **CPU Health**:
   - The Intel Core i7-1355U (10 cores, 12 threads) maintains a steady baseline load average of $2.8 - 4.2$.
   - **Audited Differential CPU Utilization**: Active CPU utilization is **$23.67\%$**. A critical accounting correction was applied: raw `/proc/stat` records guest execution time inside the `user` counter; subtracting guest time yields **$10.02\%$ pure user**, **$9.29\%$ guest virtualization**, **$4.36\%$ kernel system**, **$75.77\%$ idle**, and **$0.57\%$ I/O wait**, summing to exactly $100.0\%$.
2. **Memory Saturation & Swap Behavior**:
   - Total RAM is 15.3 GiB with **3.8 - 4.1 GiB available**.
   - Swap utilization is active at **2.1 GiB of 4.0 GiB (52.6%)**.
   - Cumulative `/proc/vmstat` counters (`pswpin: 989,217`, `pswpout: 2,369,821`) reveal that $3.774\text{ GiB}$ ($4.052\text{ GB}$) of memory has been brought in from swap since boot, disproving the assumption that allocated swap represents purely inert cold pages.
3. **OOM Event Technical Review**:
   - Detailed review of kernel logs at 10:06:26 IST revealed that `antigravity-ide` invoked the OOM killer after swap was depleted to **240 kB free (99.99% full)** and page cache collapsed to 27 MiB.
   - The kernel terminated `brave` (PID 974678) which held $1.61\text{ GiB}$ of anonymous RSS and an `oom_score_adj` of 300.
   - The report strictly separates verifiable kernel facts from unproven causal hypotheses.

---

## 2. Empirical CPU Subsystem Telemetry

### 2.1 Hardware Architecture & Core Topology
- **Model**: Intel(R) Core(TM) i7-1355U (Raptor Lake, Family 6, Model 186, Stepping 2)
- **Sockets**: 1
- **Physical Cores**: 10
  - **P-cores (Hyper-threaded)**: 2 Physical Cores = 4 Logical CPUs (`cpu0`, `cpu1`, `cpu2`, `cpu3`)
  - **E-cores (Single-threaded)**: 8 Physical Cores = 8 Logical CPUs (`cpu4` through `cpu11`)
- **Total Logical Processors**: 12
- **Hardware Virtualization**: Intel VT-x (`vmx`) active.
- **Scaling Frequencies**: Minimum 400 MHz, Maximum 5,000 MHz (5.0 GHz Turbo).

### 2.2 Audited Differential `/proc/stat` Utilization Sample
Measured across a calibrated 1-second sample window:

```
Total Delta Clock Ticks: 1,238 jiffies
├── Pure User Space (user - guest): 124 ticks (10.02%)
├── Guest (QEMU / KVM):            115 ticks  (9.29%)
├── Kernel Space (system):          54 ticks  (4.36%)
├── I/O Wait (idle waiting on I/O):  7 ticks  (0.57%)
├── Hardware/Soft IRQ:               0 ticks  (0.00%)
└── Pure Idle Task:                938 ticks (75.77%)

Total Sum of Slices:             1,238 ticks (100.00%)
Active Compute Utilization:        293 ticks (23.67%)
```

> [!NOTE]
> **Audit Correction Note**: Previous calculations reported raw `user` (239 ticks / 19.31%) alongside `guest` (115 ticks / 9.29%), creating double-counting that summed to 109.3%. In the Linux kernel, guest ticks are accounted inside `user`. Subtracting `guest` from `user` provides the accurate non-overlapping user-space execution time.

---

## 3. Empirical Memory & Swap Telemetry

### 3.1 Memory Capacity & Allocation Breakdown
Sampled directly from `/proc/meminfo`:
- **`MemTotal`**: $16,068,168\text{ kB}$ ($15.32\text{ GiB}$)
- **`MemFree`**: $1,363,636\text{ kB}$ ($1.30\text{ GiB}$)
- **`MemAvailable`**: $4,028,776\text{ kB}$ ($3.84\text{ GiB}$)
- **`Buffers` + `Cached`**: $63,896\text{ kB} + 7,612,652\text{ kB} = 7.32\text{ GiB}$
- **`Shmem` (Shared Memory / tmpfs)**: $5,030,888\text{ kB}$ ($4.80\text{ GiB}$)
- **`SwapTotal`**: $4,194,300\text{ kB}$ ($4.00\text{ GiB}$)
- **`SwapFree`**: $2,078,712\text{ kB}$ ($1.98\text{ GiB}$)
- **`SwapUsed`**: $2,115,588\text{ kB}$ ($2.02\text{ GiB}$ or **$50.4\%$**)

### 3.2 Swap Analysis: Instantaneous vs. Cumulative Evidence
- **Instantaneous (10-second sample)**: `vmstat` showed `si=0, so=0`. While this confirmed that no pages moved to or from disk during that specific 10-second slice, it does not imply swap is permanently inert.
- **Cumulative Evidence (`/proc/vmstat`)**:
  - `pswpin = 989,217` ($\times 4096\text{ bytes} = 4,051,832,832\text{ bytes} = 3.774\text{ GiB}$ read back from swap since boot)
  - `pswpout = 2,369,821` ($\times 4096\text{ bytes} = 9,706,786,816\text{ bytes} = 9.040\text{ GiB}$ written to swap since boot)
  - `pgmajfault = 4,098,272` (cumulative major page faults since boot)
- **SRE Technical Interpretation**:
  - **Cumulative vs. Rate**: The large cumulative page counters reflect memory management activity across the host's 3.6-day uptime; they do not indicate that the system is currently thrashing. Instantaneous thrashing must be evaluated via rate-of-change metrics ($\Delta \text{pages} / \Delta t$).
  - **Scope of Major Faults**: The 4.09 million major page faults represent both swap-in events AND reading file-backed code, shared libraries, and `mmap` files from disk; they must not be misconstrued as swap I/O alone.
  - **Latent Latency Risk**: Over half of configured swap ($2.02\text{ GiB}$) remains allocated. When paged-out inactive processes or threads wake up, page faults to storage incur disk access latencies ($\approx 30\text{ }\mu\text{s}$ on NVMe) rather than nanosecond DRAM speeds.

---

## 4. OOM Incident Investigation: Evidence Separation

```
=== Verified Kernel Log Snippet ===
Oct 28 10:05:01 systemd-journald[380]: Under memory pressure, flushing caches.
... [Repeated 14 times] ...
Oct 28 10:06:26 kernel: antigravity-ide invoked oom-killer: gfp_mask=0x140cca, order=0, oom_score_adj=300
Oct 28 10:06:26 kernel: Mem-Info:
Oct 28 10:06:26 kernel: active_anon:1826920 inactive_anon:1824746 active_file:5688 inactive_file:1131
Oct 28 10:06:26 kernel: Free swap  = 240kB
Oct 28 10:06:26 kernel: Total swap = 4194300kB
Oct 28 10:06:26 kernel: Out of memory: Killed process 974678 (brave) total-vm:1520812752kB, anon-rss:1609556kB, file-rss:24kB, shmem-rss:4684kB, oom_score_adj:300
```

### 4.1 Directly Observed Kernel Evidence
1. **Pre-OOM Memory Starvation**: Between 10:05:01 and 10:06:26, `systemd-journald` flushed caches 14 times in response to kernel memory pressure notifications.
2. **Near-Total Swap Depletion**: At the moment the OOM killer was invoked, swap had only **240 kB free out of 4,194,300 kB** (99.99% full).
3. **Page Cache Collapse**: Active file cache was down to 5,688 pages and inactive file cache was 1,131 pages ($\approx 27.2\text{ MiB}$ total).
4. **Triggering Thread**: `antigravity-ide` (PID 1089019) attempted an allocation (`order=0`) that entered the slowpath and invoked `out_of_memory()`.
5. **Killed Target**: The kernel issued `SIGKILL` to PID 974678 (`brave`), whose state was $1,609,556\text{ kB}$ anonymous RSS, $403,566\text{ pages}$ total RSS, and `oom_score_adj: 300`.

### 4.2 Reasonable Technical Interpretation
1. The aggregate memory demand of multiple running desktop applications (web browser, development tools, system services, and background virtualization) drove anonymous memory beyond physical limits.
2. With swap space depleted to 240 kB free and file-backed page cache reduced to $\approx 27.2\text{ MiB}$, the kernel's memory allocation slowpath failed to satisfy the requested page allocation via direct page reclaim, leading to the invocation of `out_of_memory()`.
3. In `oom_badness()`, candidate processes are evaluated based on physical memory footprint plus swap usage, weighted by `oom_score_adj`. Process `974678` presented a high anonymous footprint ($1.61\text{ GiB}$) combined with a positive score adjustment ($+300$), making it the highest-scoring candidate among scanned tasks.

### 4.3 Unproven Hypotheses & Acknowledged Unknowns
1. **Docker Desktop Causation**: While Docker Desktop's VM process (`qemu-system-x86_64`) occupied 3.48 GiB of shared memory, the available evidence does **not** prove it caused the OOM event. Memory exhaustion is an aggregate saturation event across all running workloads.
2. **`oom_score_adj` as Sole Cause**: We cannot assume `oom_score_adj` alone caused `brave` to be selected. The kernel weights actual memory consumption alongside the adjustment factor.
3. **Application Leak vs. Workload**: We cannot determine from kernel logs whether `brave` experienced a memory leak or was handling a legitimate, highly demanding browser tab workload.
4. **Counterfactual Inevitability**: We cannot verify whether alternative kernel tunables (such as higher `min_free_kbytes` or adjusted `vm.swappiness`) would have altered memory reclaim dynamics or prevented invocation.

---

## 5. Continuous 10-Second Performance Observation

A non-destructive observation loop sampled the host every 2 seconds:

| Time | Load (1/5/15m) | CPU Usr% | CPU Sys% | CPU Idle% | MemAvailable | SwapUsed | Context Switches/sec |
|---|---|---|---|---|---|---|---|
| `11:49:00` | 2.81 3.57 3.55 | 23.08% | 4.15% | 61.64% | 3,905 MB | 2,155 MB | 23,852 |
| `11:49:02` | 2.81 3.57 3.55 | 26.41% | 4.25% | 62.70% | 4,165 MB | 2,155 MB | 24,756 |
| `11:49:04` | 2.98 3.60 3.56 | 25.51% | 4.68% | 62.05% | 4,183 MB | 2,155 MB | 28,736 |
| `11:49:06` | 2.98 3.60 3.56 | 26.61% | 3.96% | 65.22% | 4,111 MB | 2,155 MB | 26,360 |
| `11:49:08` | 2.98 3.60 3.56 | 27.03% | 4.85% | 59.08% | 4,089 MB | 2,155 MB | 25,660 |

---

## 6. SRE Recommendations for Future Phases

1. **Load Average Alerting Limitations**: Do not rely on fixed rules like `node_load1 > 12`. Interpret load average relative to active runnable threads (`r`), CPU PSI (`some`), and disk I/O latency to differentiate between compute saturation and disk wait.
2. **Memory Alerting Thresholds**: Do not rely on arbitrary static percentages. Combine low `MemAvailable` with sustained rates of direct reclaim (`rate(node_vmstat_pgsteal_direct[2m]) > 0`) and memory PSI stall duration calibrated against service-level latency targets.
3. **Safety Guardrails**: Never allocate more than 1.0 GiB in synthetic memory load tests, given that swap is already 50% utilized on this workstation.
