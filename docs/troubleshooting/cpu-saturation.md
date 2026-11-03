# Troubleshooting Runbook: Host CPU Saturation & High Utilization

## 1. Alert Overview
- **Associated Alerts:** `HostHighCpuUtilizationWarning`, `HostHighCpuUtilizationCritical`
- **PromQL Triggers:**
  - `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85` (Warning: >85% for 5m)
  - `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100) > 95` (Critical: >95% for 2m)
- **Severity:** Warning / Critical
- **SLO Impact:** Causes request latency spikes, Prometheus scrape delays, and thread scheduling timeouts.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect CPU Mode Breakdown:**
   ```bash
   mpstat -P ALL 1 3
   top -b -n 1 | head -n 15
   bash scripts/monitoring/monitor_cpu.sh
   ```
2. **Identify Leading CPU Consumer Processes:**
   ```bash
   ps -eo pid,ppid,user,%cpu,cputime,cmd --sort=-%cpu | head -n 15
   ```
3. **Check Container CPU Consumption:**
   ```bash
   docker stats --no-stream --format "table {{.Name}}	{{.CPUPerc}}	{{.MemUsage}}"
   ```

---

## 3. Resolution Procedures
1. **Identify Mode Root Cause:**
   - `%usr` high: Application CPU spike or tight algorithmic loop.
   - `%sys` high: Heavy kernel syscalls, context switching, or interrupt handling.
   - `%iowait` high: Blocked waiting on disk/storage. (See `disk-latency.md`).
2. **Throttle or Restrict Processes:**
   ```bash
   sudo renice -n 10 -p <PID>
   kill -TERM <PID>
   ```
3. **Execute Lab CPU Remediation Controller:**
   ```bash
   python3 scripts/remediation/remediate_cpu.py --mode execute
   ```

---

## 4. Recovery Verification
- Confirm CPU utilization falls below 75% in Prometheus:
  ```bash
  curl -sG http://127.0.0.1:9091/api/v1/query --data-urlencode 'query=100-(avg(rate(node_cpu_seconds_total{mode="idle"}[2m]))*100)' | jq .
  ```
