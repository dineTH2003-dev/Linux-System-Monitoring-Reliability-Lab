# Troubleshooting Runbook: Prometheus Scrape Duration Degradation

## 1. Alert Overview
- **Associated Alert:** `TargetScrapeSlow`
- **PromQL Trigger:** `scrape_duration_seconds > 5.0` (for 5m)
- **Severity:** Warning
- **SLO Impact:** Scrape timeouts cause telemetry metric gaps and irregular rate calculation artifacts.

---

## 2. Immediate Triage & Diagnostics
1. **Identify Slowest Scrape Targets in Prometheus:**
   ```bash
   curl -sG http://127.0.0.1:9091/api/v1/query --data-urlencode 'query=topk(5, scrape_duration_seconds)' | jq .
   ```
2. **Directly Benchmark Exporter Response Time:**
   ```bash
   time curl -s -o /dev/null http://127.0.0.1:9100/metrics
   time curl -s -o /dev/null http://127.0.0.1:9101/metrics
   time curl -s -o /dev/null http://127.0.0.1:9115/probe?target=http://127.0.0.1:9101/healthz&module=http_2xx
   ```

---

## 3. Resolution Procedures
1. **If Python Agent (:9101) is Slow:**
   - Check process inspection collector settings in `agent/config.yaml`.
   - Disable expensive per-process scanning if process count is exceptionally high.
2. **If Node Exporter (:9100) is Slow:**
   - Check for stalled NFS mounts or hung storage queries.
   - Disable slow textfile or systemd collector modules if needed.

---

## 4. Recovery Verification
- Verify that `scrape_duration_seconds < 1.0` across all targets.
