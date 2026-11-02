# Linux CPU Subsystem & Performance Monitoring

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 1.1 — Linux CPU & Memory Intelligence (Audited)  
**Author:** Senior Linux Systems & Site Reliability Engineer  
**Target Environment:** Ubuntu 24.04 LTS (Intel Core i7-1355U, 12 Logical CPUs)  

---

## 1. CPU Architecture & Topology

### 1.1 Physical Cores vs. Logical Processors vs. Hybrid Microarchitecture
Modern multi-core processors introduce structural nuances that directly impact how the Linux kernel schedules threads and how SREs interpret CPU metrics.

On the monitored host, the CPU is an **Intel 13th Gen Core i7-1355U** (Raptor Lake), which features an asymmetric **hybrid architecture**:
- **Performance Cores (P-cores / Golden Cove architecture)**: Designed for high single-threaded IPC (Instructions Per Cycle). P-cores feature **Simultaneous Multithreading (SMT / Hyper-Threading)**.
  - Core 0: Logical CPUs `cpu0` and `cpu1` (`thread_siblings_list=0-1`)
  - Core 4: Logical CPUs `cpu2` and `cpu3` (`thread_siblings_list=2-3`)
  - Subtotal: **2 Physical P-cores = 4 Logical CPUs**
- **Efficient Cores (E-cores / Gracemont architecture)**: High-density, power-optimized execution units that do not support hyper-threading.
  - Cores 8, 9, 10, 11, 12, 13, 14, 15: Logical CPUs `cpu4` through `cpu11`
  - Subtotal: **8 Physical E-cores = 8 Logical CPUs**
- **Total Compute Capacity**: $2 + 8 = 10\text{ physical cores}$ providing **12 logical processors**.

```
┌────────────────────────────────────────────────────────────────────────┐
│                   Intel Core i7-1355U Topology (Host)                  │
├──────────────────────────────────┬─────────────────────────────────────┤
│      Performance Cores (P)       │         Efficiency Cores (E)        │
│    (2 Cores / 4 SMT Threads)     │       (8 Cores / 8 Threads)         │
├─────────────────┬────────────────┼──────┬──────┬──────┬──────┬────┬────┤
│ P-Core 0 (HT)   │ P-Core 1 (HT)  │ E-C0 │ E-C1 │ E-C2 │ E-C3 │... │E-C7│
│ [cpu0]   [cpu1] │ [cpu2]   [cpu3]│[cpu4]│[cpu5]│[cpu6]│[cpu7]│... │[11]│
└─────────────────┴────────────────┴──────┴──────┴──────┴──────┴────┴────┘
```

> [!IMPORTANT]
> **Asymmetric Capacity Consideration**: Logical CPUs do NOT possess identical compute capacity. SMT sibling threads (`cpu0`/`cpu1`) share execution execution ports, L1/L2 caches, and execution units. Running two compute-bound threads on `cpu0` and `cpu1` yields roughly $1.25\times - 1.35\times$ the throughput of a single thread—not $2.0\times$. Similarly, P-cores have wider instruction decode pipelines and higher boost frequencies than E-cores.

---

## 2. CPU Utilization & Time Slices

### 2.1 Anatomy of `/proc/stat` & The Double-Counting Trap
The Linux kernel tracks CPU activity in cumulative clock ticks (**jiffies**, typically 100 Hz on Linux x86_64, where 1 tick = 10 ms). The first line of `/proc/stat` aggregates all CPUs, followed by individual per-CPU rows:

```
cpu  3814494 281 1224239 18452391 14201 0 120412 0 312014 0
```

Field breakdown (columns 1 through 10 following the `cpu` prefix):
1. **`user`**: Time spent in user mode. **Crucial Note:** In the Linux kernel (`fs/proc/stat.c`), `user` **already includes** `guest`.
2. **`nice`**: Time spent in user mode with low priority. **Crucial Note:** `nice` **already includes** `guest_nice`.
3. **`system`**: Time executing in kernel space.
4. **`idle`**: Time spent in the idle task with no runnable threads.
5. **`iowait`**: Idle time where CPU had no runnable threads and at least one I/O request was in flight.
6. **`irq`**: Time servicing hardware interrupts.
7. **`softirq`**: Time servicing software interrupts.
8. **`steal`**: Involuntary wait time under a hypervisor.
9. **`guest`**: Time running a virtual CPU for guest operating systems (e.g., KVM / QEMU).
10. **`guest_nice`**: Time running a niced guest virtual CPU.

> [!WARNING]
> **The Double-Counting Pitfall**: Because `user` already contains `guest`, adding `guest` to the total CPU time double-counts those ticks in the denominator! Similarly, reporting raw `user` alongside `guest` results in category percentages that sum to greater than 100%.

### 2.2 Correct Differential CPU Utilization Formulas

To calculate true non-overlapping utilization across sample interval $\Delta T = T_2 - T_1$:

#### Step 1: True Total Ticks (Denominator)
$$\Delta \text{Total} = \Delta \text{user} + \Delta \text{nice} + \Delta \text{system} + \Delta \text{idle} + \Delta \text{iowait} + \Delta \text{irq} + \Delta \text{softirq} + \Delta \text{steal}$$

#### Step 2: Non-Overlapping User Ticks
$$\Delta \text{pure\_user} = \Delta \text{user} - \Delta \text{guest}$$
$$\Delta \text{pure\_nice} = \Delta \text{nice} - \Delta \text{guest\_nice}$$

#### Step 3: Idle vs. Active Classification
- **Idle Time**: $\Delta \text{Idle} = \Delta \text{idle} + \Delta \text{iowait}$
  *(Note on `iowait`: While tasks are blocked on I/O, the CPU core itself is in an idle state; it consumes zero compute cycles. SRE tooling treats `iowait` as a subtype of idle time indicating storage bottleneck rather than CPU load).*
- **Active Time**: $\Delta \text{Active} = \Delta \text{Total} - \Delta \text{Idle}$
- **Active Utilization %**:
  $$\text{Utilization \%} = \left( \frac{\Delta \text{Active}}{\Delta \text{Total}} \right) \times 100$$

#### Step 4: Component Breakdown (Sums to 100.0%)
$$\% \text{user} = \frac{\Delta \text{pure\_user}}{\Delta \text{Total}} \times 100, \quad \% \text{guest} = \frac{\Delta \text{guest}}{\Delta \text{Total}} \times 100, \quad \% \text{system} = \frac{\Delta \text{system}}{\Delta \text{Total}} \times 100$$
$$\% \text{idle} = \frac{\Delta \text{idle}}{\Delta \text{Total}} \times 100, \quad \% \text{iowait} = \frac{\Delta \text{iowait}}{\Delta \text{Total}} \times 100, \quad \% \text{irq} = \frac{\Delta \text{irq} + \Delta \text{softirq}}{\Delta \text{Total}} \times 100$$

#### Verified Python Reference Implementation:
```python
import time

def sample_proc_stat():
    with open('/proc/stat', 'r') as f:
        fields = [int(x) for x in f.readline().split()[1:11]]
    return fields # user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice

t1 = sample_proc_stat()
time.sleep(1.0)
t2 = sample_proc_stat()

d = [b - a for a, b in zip(t1, t2)]
# Correct total: do NOT add d[8] (guest) or d[9] (guest_nice)
total = sum(d[:8]) or 1

pure_user = d[0] - d[8]
pure_nice = d[1] - d[9]
system = d[2]
idle = d[3]
iowait = d[4]
irq = d[5] + d[6]
steal = d[7]
guest = d[8]
guest_nice = d[9]

active = total - (idle + iowait)

print(f"Total Ticks: {total}")
print(f"Pure User:  {pure_user/total*100:6.2f}%")
print(f"Guest:      {guest/total*100:6.2f}%")
print(f"System:     {system/total*100:6.2f}%")
print(f"Idle:       {idle/total*100:6.2f}%")
print(f"I/O Wait:   {iowait/total*100:6.2f}%")
print(f"Active CPU: {active/total*100:6.2f}%")
```

---

## 3. System Load Average & Saturation Analysis

### 3.1 Understanding What Load Average Measures
Load average represents the exponentially damped moving average of the sum of:
1. Threads in **`TASK_RUNNING` (`R`)**: Actively executing on a core or waiting in the CPU scheduler run-queue.
2. Threads in **`TASK_UNINTERRUPTIBLE` (`D`)**: Blocked in uninterruptible sleep, almost always waiting for disk I/O, device drivers, or kernel page-in operations.

### 3.2 Limitations of Load Average as a Saturation Indicator
It is common but technically flawed to assume that $12.0$ is an absolute saturation threshold simply because the machine has 12 logical processors:

1. **I/O Contamination**: A machine with 0% CPU utilization can have a load average of 25.0 if 25 processes are blocked on a stalled NVMe drive or unresponsive NFS share. Load average conflates CPU demand with storage latency.
2. **Asymmetric Processing Power**: Because 8 of the 12 cores are power-optimized E-cores and 4 are hyper-threaded P-core siblings, 12 runnable threads will experience unequal execution throughput depending on which cores the CFS assigns them to.
3. **Exponential Decay Time Lag**: Load average is calculated with an exponential decay factor across 1, 5, and 15-minute windows. Transient micro-bursts of CPU saturation can occur and resolve completely while the 1-minute load average barely registers the event.
4. **Thread State Variance**: High context switching and rapid fork/exec cycles can momentarily elevate load numbers without indicating persistent resource starvation.

### 3.3 Pressure Stall Information (PSI) for CPU Contention
To provide direct visibility into scheduling contention, modern Linux (4.20+) exposes **Pressure Stall Information (`/proc/pressure/cpu`)**:
```bash
cat /proc/pressure/cpu
# Output:
# some avg10=4.11 avg60=3.46 avg300=3.03 total=2766264439
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

#### What CPU PSI Measures:
- **`some`**: The percentage of wall-clock time within the rolling window (10s, 60s, 300s) during which **at least one non-idle task was runnable and delayed waiting for an available CPU core**. During this time, other tasks on other cores may still be executing productively.
- **`full`**: For the CPU subsystem, `full` is defined as 0.00 because CPU execution cannot be stalled across all tasks simultaneously while running none (unlike I/O or memory where every runnable thread can be blocked on a hardware event).
- **`total`**: The cumulative microseconds that tasks have spent waiting for CPU scheduling since boot.

#### SRE Contextual Interpretation:
PSI should not be treated as a standalone or universal saturation metric. Instead, it must be evaluated alongside:
1. **CPU Utilization**: High CPU utilization ($\approx 95\%$) with low CPU PSI stall ($\text{some} \approx 0.5\%$) indicates high, efficient system throughput with minimal scheduling delays. Conversely, moderate utilization with elevated PSI indicates uneven core affinity, lock contention, or frequent preemption.
2. **Runnable Queue Length**: Measured via `r` in `vmstat 1` or `procs_running` in `/proc/stat`. While queue length reports the instantaneous count of waiting threads, PSI quantifies the real temporal latency penalty (lost execution time) experienced by those threads.
3. **Application Latency & SLOs**: The operational significance of CPU stall depends strictly on workload type. A batch rendering or scientific computing cluster may intentionally run at high CPU stall ($\text{some} > 30\%$) to maximize hardware utilization without violating business goals. In contrast, an ultra-low-latency financial gateway or API service may breach its $p99$ response latency SLO when CPU stall exceeds even modest levels (e.g., illustrative threshold $\text{some} > 2\%$). Thresholds must be calibrated per service tier.

---

## 4. Practical CPU Troubleshooting Workflows

### Scenario 1: CPU Utilization is High
1. **Determine Core Distribution**:
   ```bash
   mpstat -P ALL 1 3
   ```
   *Observation Goal*: Identify if one core is pinned at 100% (single-threaded bottleneck) or if load is uniformly distributed.
2. **Identify Top Consuming Processes**:
   ```bash
   pidstat -u 1 3 | sort -k8 -rn | head -n 10
   ```
3. **Measure Actual Saturation & Latency Impact**:
   ```bash
   vmstat 1 3
   cat /proc/pressure/cpu
   ```
   *Evaluation*: Compare runnable tasks (`r`) against active cores and check whether `/proc/pressure/cpu` shows sustained scheduling stall that correlates with end-to-end application latency degradation.

### Scenario 2: Load Average is High with Low CPU Utilization
1. **Identify Tasks in Uninterruptible Sleep (`D` state)**:
   ```bash
   ps -eo state,pid,user,comm,wchan:20 | grep -E '^D'
   ```
2. **Inspect Blocked Process Count in `vmstat`**:
   Verify column `b` in `vmstat 1 3`.
3. **Correlate with Storage I/O Latency**:
   ```bash
   iostat -xz 1 3
   ```
   Look for disks where `%util > 90%` and `await` is abnormally elevated.
