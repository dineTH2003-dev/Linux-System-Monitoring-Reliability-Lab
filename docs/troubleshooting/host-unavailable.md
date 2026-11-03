# Troubleshooting Runbook: Host Node Exporter Scrape Unreachable

## 1. Alert Overview
- **Associated Alert:** `HostUnavailable`
- **PromQL Trigger:** `up{job="node"} == 0` (for 2m)
- **Severity:** Critical
- **SLO Impact:** Direct loss of host-level kernel telemetry. Immediately exhausts SRE error budget.

---

## 2. Immediate Triage & Diagnostics
1. **Verify Host Exporter Process / Service:**
   ```bash
   systemctl status prometheus-node-exporter || pgrep -a node_exporter
   ```
2. **Check Port 9100 Connectivity:**
   ```bash
   ss -tulpn | grep :9100
   curl -s http://127.0.0.1:9100/metrics | head -n 10
   ```
3. **Inspect Docker Container Bridge Routing to Host:**
   ```bash
   docker exec lab-prometheus curl -s http://host.docker.internal:9100/metrics | head -n 5
   ```

---

## 3. Resolution Procedures
1. **Restart Node Exporter Service:**
   ```bash
   sudo systemctl restart prometheus-node-exporter
   ```
2. **If Running via Docker:**
   ```bash
   docker compose restart node-exporter
   ```

---

## 4. Recovery Verification
- Verify `up{job="node"} == 1` in Prometheus.
