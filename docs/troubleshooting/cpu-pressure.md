# Troubleshooting Runbook: CPU Pressure Stall Information (PSI) Contention

## 1. Alert Overview
- **Associated Alert:** `HostCpuPressureHigh`
- **PromQL Trigger:** `rate(node_pressure_cpu_waiting_seconds_total[5m]) > 0.25`
- **Severity:** Warning
- **SLO Impact:** Indicates runnable threads are stalled waiting for CPU scheduler time slices.

---

## 2. Immediate Triage & Diagnostics
1. **Check Real-Time Kernel PSI Metrics:**
   ```bash
   cat /proc/pressure/cpu
   ```
2. **Identify Top CPU Consuming Processes:**
   ```bash
   top -b -n 1 -o %CPU | head -n 20
   # Or using modular bash monitor:
   bash scripts/monitoring/monitor_processes.sh --top 10
   ```
3. **Inspect Thread Run-Queue and Context Switches:**
   ```bash
   vmstat 1 5
   ```

---

## 3. Resolution Procedures
1. **Identify Rogue or Contending Workloads:**
   - Check if stress testing or chaos experiments are running:
     ```bash
     pgrep -a stress-ng || pgrep -a dd
     ```
2. **Throttle or Deprioritize Runaway Processes:**
   ```bash
   # Renice rogue PID
   sudo renice +15 -p <PID>
   # Or terminate if unapproved:
   kill -TERM <PID>
   ```
3. **Check CPU Core Throttling / Frequency Governors:**
   ```bash
   cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort -u
   ```

---

## 4. Recovery Verification
- Monitor `/proc/pressure/cpu` until `some avg10` falls below 10.00.
