# Troubleshooting Runbook: Kernel Out-Of-Memory (OOM) Kill Detected

## 1. Alert Overview
- **Associated Alert:** `HostOomKillDetected`
- **PromQL Trigger:** `increase(node_vmstat_oom_kill[5m]) > 0`
- **Severity:** Critical
- **SLO Impact:** Unexpected process termination and service availability downtime.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect Kernel OOM Log Messages:**
   ```bash
   sudo dmesg -T | grep -iE "(killed process|oom_reaper|out of memory)" | tail -n 20
   journalctl -k --grep="Out of memory" -n 20 --no-pager
   ```
2. **Identify Which Process Was Killed:**
   - Note the killed PID, process name, and total virtual memory consumption at time of kill.

---

## 3. Resolution Procedures
1. **Verify if Killed Process Was a Core Lab Service:**
   ```bash
   docker ps -a
   systemctl --failed
   ```
2. **Restart Killed Service (if not auto-restarted):**
   ```bash
   docker compose up -d <service_name>
   ```
3. **Tune Memory Limits / Heap Allocation:**
   - If Prometheus was killed, reduce retention or adjust `--storage.tsdb.retention.size`.

---

## 4. Recovery Verification
- Confirm service is healthy, and `increase(node_vmstat_oom_kill[15m]) == 0`.
