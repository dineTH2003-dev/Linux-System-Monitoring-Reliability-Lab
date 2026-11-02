# Linux Memory Subsystem & Reliability Engineering

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 1.1 — Linux CPU & Memory Intelligence (Audited)  
**Author:** Senior Linux Systems & Site Reliability Engineer  
**Target Environment:** Ubuntu 24.04 LTS (15 GiB Physical RAM, 4 GiB Swap)  

---

## 1. Physical Memory Subsystem & Architecture

### 1.1 Anatomy of `/proc/meminfo`
In Linux, the memory manager utilizes physical RAM aggressively. Memory is rarely left completely "free" because unused RAM is wasted RAM; instead, the kernel caches files from disk to accelerate subsequent reads.

```bash
# Read live core memory metrics
egrep '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Active|Inactive|Shmem|SReclaimable):' /proc/meminfo
```

Field breakdown on the monitored host:
| Field | Value (Observed) | Architectural Meaning |
|---|---|---|
| **`MemTotal`** | 16,068,168 kB (~15.3 GiB) | Total usable physical RAM (excluding kernel binary reserved space) |
| **`MemFree`** | 1,363,636 kB (~1.3 GiB) | Low-level unallocated memory currently holding no data or cache |
| **`MemAvailable`**| 4,028,776 kB (~3.8 GiB) | **Estimated memory available for starting new applications without swapping** |
| **`Buffers`** | 63,896 kB (~62 MiB) | In-memory block device cache (raw filesystem metadata) |
| **`Cached`** | 7,612,652 kB (~7.2 GiB) | Page cache for file read operations |
| **`Shmem`** | 5,030,888 kB (~4.8 GiB) | Shared memory (POSIX shared memory, `tmpfs`, desktop shared buffers) |
| **`SReclaimable`**| 450,364 kB (~440 MiB) | In-kernel SLAB cache allocations that can be reclaimed under pressure |

### 1.2 Why `MemAvailable` Trumps Simple `MemTotal - MemUsed`
A frequent beginner mistake in monitoring is calculating memory utilization as:
$$\text{Used \% (Flawed)} = \frac{\text{MemTotal} - \text{MemFree}}{\text{MemTotal}} \times 100$$
This formula almost always reports $90\%+$ utilization on a healthy, long-running Linux system because the kernel deliberately uses unallocated pages for page cache (`Cached`).

**`MemAvailable`** (kernel 3.14+) was specifically engineered by kernel developers to provide a truthful estimation of available capacity:
$$\text{MemAvailable} \approx \text{MemFree} + \text{Reclaimable Page Cache} + \text{Reclaimable Slab} - \text{Low-Watermark Reservation}$$

Not all page cache can be reclaimed immediately; dirty pages must be written back to disk first, and minimum watermarks (`min_free_kbytes`) must remain untouched for atomic kernel interrupt handlers.

---

## 2. Swap Subsystem Mechanics & Limitations of Short-Window Sampling

### 2.1 Static Allocation vs. Dynamic Thrashing
Swap is a disk backing store (partition or file, e.g. `/swap.img`) used to page out anonymous memory.

In SRE observability, engineers must differentiate between:
1. **Static Swap Allocation**: Pages written to swap and remaining unreferenced on disk.
2. **Dynamic Swap Activity (Thrashing)**: Rapid, continuous swap-in (`si`) and swap-out (`so`) operations.

```bash
# Sample swap rate via vmstat
vmstat 1 5
# Column 'si': Memory paged in from swap per second (kB/s)
# Column 'so': Memory paged out to swap per second (kB/s)
```

### 2.2 SRE Caution: Why Zero Swap I/O in a Short Window Can Be Deceptive
> [!CAUTION]
> It is an engineering error to conclude that used swap (e.g., 2.1 GiB) is "harmless cold memory" based solely on a short (10-second) sampling window with `si=0, so=0`.

#### Technical Justification & Metric Distinctions:
1. **Cumulative Counters vs. Instantaneous Rates**:
   - `/proc/vmstat` records monotonic cumulative counters since system boot:
     - `pswpin`: $989,217\text{ pages}$ ($\times 4096\text{ bytes} = 4,051,832,832\text{ bytes} = 3.774\text{ GiB}$) paged in from swap since boot.
     - `pswpout`: $2,369,821\text{ pages}$ ($\times 4096\text{ bytes} = 9,706,786,816\text{ bytes} = 9.040\text{ GiB}$) paged out to swap since boot.
   - **Crucial SRE Distinction**: High cumulative `pswpin`/`pswpout` values reflect historical memory activity across the entire system uptime (over 3.6 days), **not** active memory thrashing at the moment of inspection. Instantaneous thrashing must be evaluated using rate-of-change metrics ($\Delta \text{pages} / \Delta t$), such as `vmstat` columns `si`/`so` (kB/s) or Prometheus rates (`rate(node_vmstat_pswpin[1m])`).
2. **Major Page Faults (`pgmajfault`) Involve File I/O and Swap**:
   - `/proc/vmstat` records `pgmajfault = 4,098,272`.
   - A major page fault occurs whenever requested memory is not present in physical RAM and must be fetched from backing storage.
   - Crucially, `pgmajfault` encompasses **both** anonymous memory paged back in from swap **and** file-backed I/O (such as reading executable binaries from disk on launch, loading shared libraries, or reading `mmap` files). It must never be interpreted as swap traffic alone.
3. **Latent Latency Penalty of Swapped Memory**:
   - Even when instantaneous swap throughput is zero, having 2.1 GiB of anonymous memory on disk introduces latency risk. When an inactive process or background thread with paged-out memory wakes up and references its working set, execution halts while pages are retrieved from storage at NVMe latency ($\approx 30\text{ }\mu\text{s}$) rather than DRAM speed ($\approx 50\text{ ns}$).

---

## 3. Memory Pressure & Kernel Reclaim Mechanics

### 3.1 Direct Reclaim vs. Background Reclaim (`kswapd`)
When free memory drops below zone watermarks:
1. **Background Reclaim (`kswapd`)**: The kernel daemon wakes up asynchronously and scans page lists, freeing clean pages and queuing dirty pages. User applications experience zero allocation pause.
2. **Direct Reclaim**: If memory allocation demand outstrips `kswapd` throughput, the kernel forces the allocating user process into direct reclaim (`pgsteal_direct` in `/proc/vmstat`). The application thread halts execution synchronously while scanning and freeing pages.

### 3.2 Pressure Stall Information (PSI) for Memory Contention
Memory contention is reported via `/proc/pressure/memory`:
```bash
cat /proc/pressure/memory
# Output on host:
# some avg10=0.00 avg60=0.00 avg300=0.00 total=322516615
# full avg10=0.00 avg60=0.00 avg300=0.00 total=269292914
```

#### Understanding `some` vs. `full`:
- **`some`**: The percentage of wall-clock time within the rolling window during which **at least one non-idle task was stalled waiting for memory** (such as direct page reclaim, swap-in, or page cache read). Other non-stalled tasks may continue executing on available cores.
- **`full`**: The percentage of wall-clock time during which **all non-idle tasks were simultaneously stalled on memory**. While in `full`, no productive user/application compute is taking place across the system—the entire system is blocked on memory allocation or swap I/O.
- **`total`**: Cumulative microseconds spent in stall states since boot.

#### Workload & SLO Contextualization:
Universal thresholds (such as "alert if some > 5%") should not be applied blindly:
- **Workload Dependency**: A memory-intensive scientific computation or batch data processor may tolerate moderate memory pressure (`some` avg10 around 10–15%) as an acceptable trade-off for maximizing memory density. Conversely, an interactive web service or low-latency trading engine may consider any persistent `some > 1%` an operational incident causing $p99$ response SLA violations.
- **Distinguishing Pressure from Warning Conditions**: A non-zero `total` counter indicates that memory stalls occurred at some point in the host's uptime. Active operational alerts must be evaluated based on the rate of stall increase over a sustained evaluation window (e.g. 2–5 minutes), correlated directly with application transaction latencies and error budget burn rates.

---

## 4. Technical Audit of the Real Host OOM Incident

During our system audit, an Out-Of-Memory (OOM) killer event was identified in the host kernel log (`journalctl -k`):

```
Oct 28 10:05:01 systemd-journald[380]: Under memory pressure, flushing caches.
... [Repeated 14 times over 85 seconds] ...
Oct 28 10:06:26 kernel: antigravity-ide invoked oom-killer: gfp_mask=0x140cca, order=0, oom_score_adj=300
Oct 28 10:06:26 kernel: Mem-Info:
Oct 28 10:06:26 kernel: active_anon:1826920 inactive_anon:1824746 active_file:5688 inactive_file:1131
Oct 28 10:06:26 kernel: Free swap  = 240kB
Oct 28 10:06:26 kernel: Total swap = 4194300kB
Oct 28 10:06:26 kernel: Out of memory: Killed process 974678 (brave) total-vm:1520812752kB, anon-rss:1609556kB, file-rss:24kB, shmem-rss:4684kB, oom_score_adj:300
```

### 4.1 Directly Observed Kernel Evidence
1. **Pre-Incident Memory Starvation**: Between 10:05:01 and 10:06:26, `systemd-journald` logged `Under memory pressure, flushing caches` 14 times in response to kernel memory pressure notifications.
2. **Near-Total Swap Depletion**: At the moment of invocation, free swap was **240 kB out of 4,194,300 kB** (**99.99% swap utilization**).
3. **Page Cache Evaporated**: File-backed cache had shrunk to only 6,819 pages ($5688\text{ active} + 1131\text{ inactive} \approx 27.2\text{ MiB}$), leaving virtually no clean file pages to reclaim.
4. **Triggering Entity**: `antigravity-ide` (PID 1089019) attempted an allocation (`order=0`) that entered the slowpath and invoked `out_of_memory()`.
5. **Terminated Process**: Process 974678 (`brave`) was killed via `SIGKILL`. Its state at termination was $1,609,556\text{ kB}$ anonymous RSS, $403,566\text{ pages}$ total RSS, and an `oom_score_adj` of `300`.

### 4.2 Reasonable Technical Interpretation
1. System-wide aggregate memory consumption from multiple concurrent desktop applications (browser processes, development environments, and background virtualization) drove anonymous memory beyond physical RAM capacity.
2. With swap space depleted to 240 kB free and file-backed page cache reduced to $\approx 27.2\text{ MiB}$, the kernel's memory allocation path (`__alloc_pages_slowpath`) failed to satisfy the requested page allocation via direct page reclaim, triggering `out_of_memory()`.
3. In `oom_badness()`, candidate processes are evaluated based on physical memory footprint plus swap usage, weighted by `oom_score_adj`. Process `974678` presented a high anonymous footprint ($1.61\text{ GiB}$) combined with a positive score adjustment ($+300$), making it the highest-scoring candidate among scanned tasks.

### 4.3 Unproven Hypotheses & Acknowledged Unknowns
1. **Docker Desktop Causation**: While Docker Desktop's VM process (`qemu-system-x86_64`) occupied 3.48 GiB of shared memory, the available evidence does **not** prove it caused the OOM event. Memory exhaustion is an aggregate saturation event across all running workloads.
2. **`oom_score_adj` As Sole Selection Reason**: We cannot assume `oom_score_adj` alone caused `brave` to be selected. The kernel weights actual memory consumption alongside the adjustment factor.
3. **Application Leak vs. Expected Workload**: We cannot determine from kernel logs whether `brave` experienced a memory leak or was simply rendering legitimate heavy web content.
4. **Counterfactual Inevitability**: We cannot verify whether alternative kernel tunables (such as higher `min_free_kbytes` or adjusted `vm.swappiness`) would have altered memory reclaim dynamics or prevented invocation.

---

## 5. Practical Memory Troubleshooting Workflows

### Scenario 3: Available Memory is Decreasing System-Wide
1. **Check Memory Breakdown & Buffer Health**:
   ```bash
   free -h
   egrep '^(MemAvailable|Active\(anon\)|Inactive\(anon\)|Active\(file\)|Inactive\(file\)|Dirty):' /proc/meminfo
   ```
2. **Inspect Cumulative Swap & Page-In Metrics**:
   ```bash
   egrep '^(pswpin|pswpout|pgmajfault|pgsteal_direct)' /proc/vmstat
   ```
3. **Verify Memory PSI Stalls**:
   ```bash
   cat /proc/pressure/memory
   ```

### Scenario 4: Single Process Memory Leak Detection
1. **Identify High RSS Consumers**:
   ```bash
   ps -eo pid,user,%mem,rss,vsz,comm --sort=-rss | head -n 10
   ```
2. **Inspect Proportional Set Size (PSS) and Private Dirty Pages**:
   ```bash
   cat /proc/<PID>/smaps_rollup 2>/dev/null | grep -E '^(Rss|Pss|Private_Dirty|Swap):'
   ```
3. **Evaluate Monotonic Growth Over Time**:
   ```bash
   for i in $(seq 1 5); do ps -p <PID> -o %cpu,%mem,rss,vsz,comm --no-headers; sleep 5; done
   ```
