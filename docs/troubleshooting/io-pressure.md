# Troubleshooting Runbook: Storage I/O Pressure Stall Information (PSI)

## 1. Alert Overview
- **Associated Alerts:** `HostIoPressureWaitingHigh`, `HostIoPressureStalledCritical`
- **PromQL Triggers:**
  - `rate(node_pressure_io_waiting_seconds_total[5m]) > 0.20` (Warning: 20% waiting for 5m)
  - `rate(node_pressure_io_stalled_seconds_total[5m]) > 0.10` (Critical: 10% fully stalled for 2m)
- **Severity:** Warning / Critical
- **SLO Impact:** Indicates processes are completely blocked on storage access, stalling system execution.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect I/O PSI Counters:**
   ```bash
   cat /proc/pressure/io
   ```
2. **Inspect Kernel Device Queues & In-Flight Requests:**
   ```bash
   iostat -xz 1 5
   ```
3. **Identify Processes in Uninterruptible Sleep (D State):**
   ```bash
   ps -eo pid,stat,cmd | grep " D"
   ```

---

## 3. Resolution Procedures
1. **Check In-Progress Large Backups or Synchronous Flush Operations:**
   ```bash
   ps aux | grep -E "(backup|tar|dd|rsync)"
   ```
2. **Ensure Lab Staging Directories Use Appropriate Storage:**
   - Confirm backups target local SSD storage rather than virtual network mounts.

---

## 4. Recovery Verification
- Verify `/proc/pressure/io` shows `some avg10` and `full avg10` return to 0.00.
