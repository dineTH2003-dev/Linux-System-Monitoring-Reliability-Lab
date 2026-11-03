# Troubleshooting Runbook: Critical Host systemd Unit Failure

## 1. Alert Overview
- **Associated Alert:** `HostCriticalServiceDown`
- **PromQL Trigger:** `node_systemd_unit_state{name=~".+",state="failed"} == 1`
- **Severity:** Critical
- **SLO Impact:** Directly compromises host service integrity or core daemon operation.

---

## 2. Immediate Triage & Diagnostics
1. **List Failed Units:**
   ```bash
   systemctl --failed
   bash scripts/monitoring/monitor_systemd.sh
   ```
2. **Inspect Failed Unit Status & Journal Logs:**
   ```bash
   UNIT="<failed_service_name>"
   systemctl status ${UNIT}
   journalctl -u ${UNIT} -n 50 --no-pager
   ```

---

## 3. Resolution Procedures
1. **Restart Failed Service:**
   ```bash
   sudo systemctl reset-failed ${UNIT}
   sudo systemctl restart ${UNIT}
   ```
2. **Check Configuration Syntax (if applicable):**
   ```bash
   sudo systemd-analyze verify /etc/systemd/system/${UNIT}
   ```
3. **Verify Service Active State:**
   ```bash
   systemctl is-active ${UNIT}
   ```

---

## 4. Recovery Verification
- Confirm `systemctl --failed` returns 0 failed units.
- Prometheus metric `node_systemd_unit_state{name="...",state="failed"}` returns 0.
