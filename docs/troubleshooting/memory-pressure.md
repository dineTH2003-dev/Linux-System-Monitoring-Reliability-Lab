# Troubleshooting Runbook: Memory Pressure Stall Information (PSI)

## 1. Alert Overview
- **Associated Alerts:** `HostMemoryPressureWaiting`, `HostMemoryPressureStalled`
- **PromQL Triggers:**
  - `rate(node_pressure_memory_waiting_seconds_total[5m]) > 0.20` (Warning: 20% for 5m)
  - `rate(node_pressure_memory_stalled_seconds_total[5m]) > 0.10` (Critical: 10% for 2m)
- **Severity:** Warning / Critical
- **SLO Impact:** Memory reclaim, direct allocation stalls, and swap paging are degrading application throughput.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect Memory PSI:**
   ```bash
   cat /proc/pressure/memory
   ```
2. **Check Paging & Swap Activity in vmstat:**
   ```bash
   vmstat 1 5
   ```

---

## 3. Resolution Procedures
1. **Free Reclaimable Slab / Pagecache:**
   ```bash
   sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
   ```
2. **Investigate Heavy Allocators:**
   ```bash
   ps -eo pid,user,%mem,rss,cmd --sort=-rss | head -n 10
   ```

---

## 4. Recovery Verification
- Confirm `/proc/pressure/memory` returns to normal levels (< 5%).
