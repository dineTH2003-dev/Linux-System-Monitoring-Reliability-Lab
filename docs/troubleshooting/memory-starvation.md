# Troubleshooting Runbook: Host Memory Starvation & Low Available RAM

## 1. Alert Overview
- **Associated Alerts:** `HostLowMemoryAvailable`, `HostCriticalMemoryAvailable`
- **PromQL Triggers:**
  - `(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10` (Warning: <10% for 5m)
  - `(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 5` (Critical: <5% for 2m)
- **Severity:** Warning / Critical
- **SLO Impact:** High risk of immediate kernel Out-Of-Memory (OOM) killer invocation and service termination.

---

## 2. Immediate Triage & Diagnostics
1. **Check System Memory Breakdown:**
   ```bash
   free -h
   cat /proc/meminfo | grep -E "(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Slab)"
   ```
2. **Identify Top Memory Consumers:**
   ```bash
   ps -eo pid,ppid,user,%mem,rss,cmd --sort=-rss | head -n 15
   bash scripts/monitoring/monitor_memory.sh
   ```
3. **Check Container Memory Usage:**
   ```bash
   docker stats --no-stream --format "table {{.Name}}	{{.MemUsage}}	{{.MemPerc}}"
   ```

---

## 3. Resolution Procedures
1. **Drop Reclaimable Page Cache (Safe Non-Destructive):**
   ```bash
   # Sync filesystem dirty pages first, then drop caches
   sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
   ```
2. **Terminate Unapproved Memory Leaking Processes:**
   ```bash
   kill -TERM <PID>
   ```
3. **Verify Container Resource Constraints:**
   - Confirm containers in `docker-compose.yml` have bounded `mem_limit` (e.g. Prometheus 1GB, Grafana 512MB).

---

## 4. Recovery Verification
- Verify available memory recovers above 15%:
  ```bash
  curl -sG http://127.0.0.1:9091/api/v1/query --data-urlencode 'query=(node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)*100' | jq .
  ```
