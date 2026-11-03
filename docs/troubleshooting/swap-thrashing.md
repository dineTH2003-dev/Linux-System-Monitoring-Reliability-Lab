# Troubleshooting Runbook: Active Swap Thrashing & High Page Faults

## 1. Alert Overview
- **Associated Alert:** `HostSwapThrashingActive`
- **PromQL Trigger:** `rate(node_vmstat_pgmajfault[5m]) > 500 and rate(node_vmstat_pswpin[5m]) + rate(node_vmstat_pswpout[5m]) > 100`
- **Severity:** Critical
- **SLO Impact:** Kernel is continuously reading/writing pages from swap disk, leading to severe latency degradation and system unresponsiveness.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect Real-Time Swap Paging:**
   ```bash
   vmstat 1 10
   ```
2. **Check Swap Utilization:**
   ```bash
   free -h
   swapon --show
   bash scripts/monitoring/monitor_memory.sh --swap
   ```
3. **Identify Processes Consuming Swap:**
   ```bash
   for f in /proc/*/status; do awk '/VmSwap/{print $2, FILENAME}' "$f" 2>/dev/null; done | sort -nr | head -n 15
   ```

---

## 3. Resolution Procedures
1. **Terminate Leading Memory Hog:**
   ```bash
   kill -TERM <PID>
   ```
2. **Adjust Swappiness (if aggressive paging occurs under available RAM):**
   ```bash
   sysctl vm.swappiness
   sudo sysctl -w vm.swappiness=10
   ```

---

## 4. Recovery Verification
- Confirm `vmstat` shows `si` and `so` drops to 0.
