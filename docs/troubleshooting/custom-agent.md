# Troubleshooting Runbook: Custom Python Monitoring Agent Unavailable / Collector Errors

## 1. Alert Overview
- **Associated Alerts:** `PythonAgentUnavailable`, `CustomAgentCollectorErrors`
- **PromQL Triggers:**
  - `up{job="custom-agent"} == 0` (for 2m)
  - `rate(custom_agent_collector_errors_total[5m]) > 0` (for 3m)
- **Severity:** Critical / Warning
- **SLO Impact:** Directly impacts Agent Health and Custom Telemetry SLIs.

---

## 2. Immediate Triage & Diagnostics
1. **Check Agent Process State:**
   ```bash
   pgrep -a -f "python.*agent/main.py"
   curl -s http://127.0.0.1:9101/healthz
   curl -s http://127.0.0.1:9101/metrics | head -n 20
   ```
2. **Inspect Agent Error Logs:**
   ```bash
   tail -n 50 ~/.local/share/lab-monitoring/logs/agent.log 2>/dev/null || journalctl -u linux-monitoring-agent -n 50
   ```

---

## 3. Resolution Procedures
1. **Restart Agent Daemon:**
   ```bash
   pkill -f "agent/main.py" || true
   nohup ./.venv/bin/python3 agent/main.py --host 127.0.0.1 --port 9101 > /dev/null 2>&1 &
   ```
2. **Verify Configuration YAML Integrity:**
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('agent/config.yaml'))"
   ```
3. **Execute Unit Tests to Verify Collectors:**
   ```bash
   ./.venv/bin/pytest tests/python/test_main.py tests/python/test_server.py
   ```

---

## 4. Recovery Verification
- Confirm `up{job="custom-agent"} == 1` and `custom_agent_collector_errors_total == 0`.
