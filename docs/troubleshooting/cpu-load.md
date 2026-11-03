# Troubleshooting Runbook: Elevated System Load Average & Runqueue Pressure

## 1. Alert Overview
- **Associated Alert:** `HostHighLoadAverage`
- **PromQL Trigger:** `node_load15 / count without (cpu, mode) (node_cpu_seconds_total{mode="idle"}) > 2.0`
- **Severity:** Warning
- **SLO Impact:** High thread queuing, delayed background tasks, latency degradation.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect Load Average and Core Count:**
   ```bash
   uptime
   nproc
   bash scripts/monitoring/monitor_cpu.sh --load
   ```
2. **Check Process States (R vs D):**
   ```bash
   ps -eo stat | sort | uniq -c
   ```

---

## 3. Resolution Procedures
1. **If Dominated by R (Runnable) State:**
   - CPU-bound overload. Identify runaway processes via `top -b -n 1 -o %CPU`.
2. **If Dominated by D (Uninterruptible) State:**
   - I/O-bound overload. Identify NFS, NVMe, or filesystem stalls. (See `disk-latency.md`).

---

## 4. Recovery Verification
- Monitor `uptime` until 15-minute normalized load average drops below 1.5 per core.
