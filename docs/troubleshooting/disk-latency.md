# Troubleshooting Runbook: High Disk Read / Write I/O Latency

## 1. Alert Overview
- **Associated Alerts:** `HostDiskReadLatencyHigh`, `HostDiskWriteLatencyHigh`
- **PromQL Triggers:**
  - `rate(node_disk_read_time_seconds_total[5m]) / rate(node_disk_reads_completed_total[5m]) > 0.050` (50ms for 5m)
  - `rate(node_disk_write_time_seconds_total[5m]) / rate(node_disk_writes_completed_total[5m]) > 0.050` (50ms for 5m)
- **Severity:** Warning
- **SLO Impact:** Degrades database commit latency (Prometheus TSDB), logging flush times (Loki), and application I/O responsiveness.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect Disk I/O Utilization & Wait Time:**
   ```bash
   iostat -xz 1 5
   bash scripts/monitoring/monitor_storage.sh --io
   ```
2. **Identify Top I/O Processes (iotop / pidstat):**
   ```bash
   sudo pidstat -d 1 5
   ```
3. **Check Kernel Diskstats:**
   ```bash
   cat /proc/diskstats | grep -E "(nvme|sd)"
   ```

---

## 3. Resolution Procedures
1. **Identify Heavy Concurrent Disk Writers:**
   - Check if heavy backup operations or unthrottled log dumping is occurring:
     ```bash
     ps -eo pid,cmd,wchan:20 | grep -E "(tar|gzip|rsync|dd|backup)"
     ```
2. **Throttle Heavy Tasks using ionice:**
   ```bash
   sudo ionice -c 3 -p <PID>   # Idle priority
   ```
3. **Tune Dirty Page Writeback Parameters (if write stalls observed):**
   ```bash
   sysctl vm.dirty_background_ratio vm.dirty_ratio
   ```

---

## 4. Recovery Verification
- Confirm average read/write latency drops below 20ms in `iostat -xz 1 3`.
