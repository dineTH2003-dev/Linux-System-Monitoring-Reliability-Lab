# Troubleshooting Runbook: Prometheus Scrape Target Unavailable

## 1. Alert Overview
- **Associated Alert:** `NodeExporterUnavailable`
- **PromQL Trigger:** `up{job="node"} == 0` (for 3m)
- **Severity:** Critical
- **SLO Impact:** Gaps in time-series telemetry.

---

## 2. Immediate Triage & Diagnostics
1. **Inspect Prometheus Target Dashboard:**
   - Navigate to `http://127.0.0.1:9091/targets` and locate the failed target.
2. **Query Target Status via Prometheus API:**
   ```bash
   curl -s http://127.0.0.1:9091/api/v1/targets | jq '.data.activeTargets[] | select(.health!="up")'
   ```

---

## 3. Resolution Procedures
1. **Verify Target Listener:**
   ```bash
   ss -tulpn | grep -E "(9100|9101|9115|12345)"
   ```
2. **Restart Failing Daemon:**
   ```bash
   # If Python Agent:
   python3 agent/main.py --daemon
   # If Containerized Exporter:
   docker compose restart <service_name>
   ```

---

## 4. Recovery Verification
- Confirm target health returns to `up` on `http://127.0.0.1:9091/targets`.
