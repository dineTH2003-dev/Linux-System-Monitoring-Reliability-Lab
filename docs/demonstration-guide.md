# Reviewer Demonstration Guide: 5-Minute Technical Tour

Welcome to the **Linux System Monitoring & Reliability Lab**. This guide is designed for engineering leads, SRE recruiters, and technical reviewers to independently inspect, test, and verify every major subsystem in **under 10 minutes** without disrupting existing host telemetry.

---

## 1. Quick Environment & Stack Health Check (30 Seconds)

The monitoring lab runs as an isolated Docker Compose stack bound exclusively to `127.0.0.1`.

```bash
# Verify all 6 lab containers are running and healthy
docker ps --filter "name=lab-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

**Expected Output:**
```text
NAMES                   STATUS                    PORTS
lab-alloy               Up (healthy)              127.0.0.1:12345->12345/tcp
lab-grafana             Up (healthy)              127.0.0.1:3001->3000/tcp
lab-prometheus          Up (healthy)              127.0.0.1:9091->9090/tcp
lab-alertmanager        Up (healthy)              127.0.0.1:9094->9093/tcp
lab-loki                Up (healthy)              127.0.0.1:3100->3100/tcp
lab-blackbox-exporter   Up (healthy)              127.0.0.1:9115->9115/tcp
```

Run the built-in automated healthcheck suite:
```bash
./deployment/healthcheck.sh
```

---

## 2. Interactive Grafana Dashboard Tour (2 Minutes)

Open your browser at **http://127.0.0.1:3001**:
- **Username:** `labadmin`
- **Password:** The password configured in your local `.env` file (`GF_SECURITY_ADMIN_PASSWORD`).

Navigate to **Dashboards**:

| # | Dashboard Name | Panels | Key SRE Insights & Operational Focus |
|---|----------------|:------:|--------------------------------------|
| **01** | **Linux System Overview** | 19 | High-level host status, uptime, core gauges (CPU, RAM, Disk), active firing alerts, and systemd service failures. |
| **02** | **CPU and Memory** | 17 | Core utilization breakdown, load average vs core capacity, Pressure Stall Information (PSI `some` / `full`), Swap thrashing rates. |
| **03** | **Storage and Filesystem** | 17 | Filesystem space & inode saturation (with time-to-exhaustion forecasts), disk I/O throughput, read/write latency, and loop-device filtering. |
| **04** | **Network and Processes** | 19 | Interface bandwidth, RX/TX error and drop rates, TCP socket allocation, top CPU/RAM consuming processes, zombie thread detection. |
| **05** | **Reliability Overview** | 18 | SRE Golden Signals, 99.9% SLO status, error budget burn rates (1h & 6h windows), Blackbox synthetic probe latency, MTBF & MTTR metrics. |

### Dashboard Verification Methodology:
- **JSON Inventory:** 5 dashboard definitions containing 90 panels and 111 embedded PromQL query targets.
- **Programmatic Validation:** All 111 PromQL expressions were tested programmatically against the Prometheus HTTP query API (`http://127.0.0.1:9091/api/v1/query`) on `primary-node`:
  - **109 targets returned live metric data (>0 series)**.
  - **2 targets returned 0 series as expected** (`ALERTS{alertstate="firing"}` in Dashboard 01 and `ALERTS` in Dashboard 05), representing normal healthy baseline operation with no active alerts.
  - **0 query syntax or execution errors**.
- **Visual UI Inspection:** Reviewers can manually inspect panel layout, graphing, and threshold rendering in the Grafana UI at `http://127.0.0.1:3001`.

---

## 3. Custom Python Host Telemetry Verification (1 Minute)

The lab includes a custom Python exporter (`agent/`) that gathers granular kernel telemetry via `/proc` and `/sys` using `psutil`, `prometheus_client`, and `PyYAML`:

```bash
# Check the Python agent's live Prometheus metrics endpoint
curl -s http://127.0.0.1:9101/metrics | grep -E "^(node_cpu_load|systemd_service_status|node_process_count)" | head -n 10
```

Verify that Prometheus is actively scraping it:
```bash
curl -s "http://127.0.0.1:9091/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job=="python-agent") | {instance: .labels.instance, health: .health, lastScrape: .lastScrape}'
```

---

## 4. Host Journal Log Shipping & Secret Masking (1 Minute)

The systemd journal log shipper runs via Grafana Alloy (`/etc/alloy/config.alloy`). It reads native journals, structures entries into JSON, masks sensitive tokens, and forwards them to central Loki with `host="primary-node"`.

1. **Emit a unique test message to the host systemd journal:**
   ```bash
   logger -t lab-demo-audit "Reviewer audit test message: code=$(date +%s)"
   ```

2. **Query Grafana Loki for the exact message and verify stream labels:**
   ```bash
   curl -s -G "http://127.0.0.1:3100/loki/api/v1/query" \
     --data-urlencode 'query={host="primary-node", job="systemd-journal"} |= "Reviewer audit test message"' | jq '.data.result[0].stream'
   ```
   **Expected Stream Labels:**
   ```json
   {
     "host": "primary-node",
     "job": "systemd-journal",
     "unit": "user@1000.service"
   }
   ```

3. **Verify sensitive token masking:**
   ```bash
   logger -t lab-security-test "Authorization: Bearer test-dummy-token-sample"
   sleep 2
   curl -s -G "http://127.0.0.1:3100/loki/api/v1/query" \
     --data-urlencode 'query={host="primary-node"} |= "Bearer"' | jq -r '.data.result[0].values[][1]'
   ```
   Notice that `test-dummy-token-sample` is automatically masked to `Bearer [REDACTED]`.

---

## 5. Non-Destructive E2E Alert Delivery Drill

Alertmanager is configured with multi-tier routing (Critical PagerDuty, Warning Slack, and Blackbox Synthetic Triage). You can verify the complete alert delivery pipeline using the built-in mock receiver.

The following script safely deploys a temporary canary rule, verifies alert ingestion, and uses a shell trap to guarantee cleanup even if interrupted:

```bash
(
  CANARY_RULE="prometheus/alerts/demo_canary.yml"
  STARTED_RECEIVER_PID=""

  cleanup() {
    echo ""
    echo "[Cleanup] Removing temporary canary rule..."
    rm -f "$CANARY_RULE"
    curl -s -X POST http://127.0.0.1:9091/-/reload >/dev/null 2>&1 || true
    if [ -n "$STARTED_RECEIVER_PID" ] && kill -0 "$STARTED_RECEIVER_PID" 2>/dev/null; then
      echo "[Cleanup] Stopping temporary mock alert receiver (PID: $STARTED_RECEIVER_PID)..."
      kill "$STARTED_RECEIVER_PID" 2>/dev/null || true
    fi
    echo "[Cleanup] Complete."
  }
  trap cleanup EXIT INT TERM

  # 1. Guard against overwriting an existing rule file
  if [ -e "$CANARY_RULE" ]; then
    echo "Error: $CANARY_RULE already exists. Aborting to prevent overwriting existing rules." >&2
    exit 1
  fi

  # 2. Positively identify existing mock receiver or start a temporary one
  if curl -s http://127.0.0.1:5002/healthz 2>/dev/null | grep -q ""service": "mock-alert-receiver""; then
    echo "[Step 1] Positively identified existing mock alert receiver on port 5002."
  else
    echo "[Step 1] Starting temporary mock alert receiver on port 5002..."
    python3 scripts/reliability/mock_alert_receiver.py --port 5002 >/dev/null 2>&1 &
    STARTED_RECEIVER_PID=$!
    sleep 1
    if ! curl -s http://127.0.0.1:5002/healthz 2>/dev/null | grep -q ""service": "mock-alert-receiver""; then
      echo "Error: Failed to verify mock alert receiver on port 5002." >&2
      exit 1
    fi
  fi

  # Clear any previous test events
  curl -s -X DELETE http://127.0.0.1:5002/api/blackbox-triage >/dev/null 2>&1 || true

  # 3. Deploy temporary canary alert rule
  echo "[Step 2] Deploying temporary canary alert rule..."
  cat << 'EOF' > "$CANARY_RULE"
groups:
  - name: demo_canary
    rules:
      - alert: ReviewerCanaryAlert
        expr: vector(1) == 1
        for: 0s
        labels:
          severity: info
          subsystem: blackbox
        annotations:
          summary: "E2E Alert Delivery Verification"
EOF

  # Reload Prometheus
  curl -s -X POST http://127.0.0.1:9091/-/reload

  # 4. Wait for Prometheus evaluation cycle and Alertmanager group_wait
  echo "[Step 3] Waiting for alert evaluation and Alertmanager dispatch..."
  RECEIVED=0
  for i in $(seq 1 12); do
    sleep 3
    STATUS=$(curl -s http://127.0.0.1:5002/api/blackbox-triage | jq -r ".events[-1].payload.status" 2>/dev/null || echo "none")
    ALERTNAME=$(curl -s http://127.0.0.1:5002/api/blackbox-triage | jq -r ".events[-1].payload.alerts[0].labels.alertname" 2>/dev/null || echo "none")
    if [ "$STATUS" = "firing" ] && [ "$ALERTNAME" = "ReviewerCanaryAlert" ]; then
      echo "[Step 4] Alert received! (attempt $i: status=$STATUS, alertname=$ALERTNAME)"
      RECEIVED=1
      break
    fi
  done

  if [ "$RECEIVED" -eq 1 ]; then
    echo "VERIFICATION PASSED: Canary alert firing delivery confirmed!"
  else
    echo "VERIFICATION FAILED: Expected firing alert not received within 36s."
  fi
)
```

> [!NOTE]
> **Delivery Scope:** This demonstration explicitly validates **Firing Alert Delivery** to the webhook receiver within 3–15 seconds. Full resolution webhook delivery (`status="resolved"`) occurs once the rule is removed and Alertmanager's `resolve_timeout` (5m) expires, as verified during integration testing.

---

## 6. Multi-Host Dynamic Discovery Simulation (1 Minute)

Prometheus utilizes File-Based Service Discovery (`file_sd_configs`) in `prometheus/targets/`. Target registration takes effect in under 30 seconds with **zero downtime**:

```bash
# Run the automated multi-host verification suite (28 assertions)
bash tests/multihost/test_multihost_monitoring.sh
```

**Output:**
```text
======================================================================
  MULTI-HOST VERIFICATION SUMMARY
  Passed: 28
  Failed: 0
======================================================================
  SUCCESS: All multi-host observability tests passed!
```

*Note: Multi-host functionality is demonstrated using local containerized Node Exporter fixtures (`node-02`, `node-03`). Actual physical multi-host deployment across separate physical hardware has not yet been demonstrated in this lab environment.*

---

## 7. Disaster Recovery Dry-Run Verification (30 Seconds)

Test the disaster recovery restoration pipeline without touching live databases or configurations:

```bash
LATEST_BACKUP=$(ls -td ~/.local/share/lab-monitoring/backups/backup-set-* | head -n 1)
./deployment/restore.sh --configs-only --dry-run "$LATEST_BACKUP"
```

**Expected Outcome:**
Cryptographic SHA-256 verification passes, Schema 2.0.0 manifest validates (all 23 mandatory keys), deep nested archive structures are checked pre-extraction, and stack safety gates enforce non-destructive execution.

---

## 8. Security Benchmark & Hardening Audits (30 Seconds)

Run the CIS Docker Benchmark and static secret security scans:

```bash
# 1. Container security audit (42 automated CIS benchmark checks)
bash security/container_audit.sh

# 2. Static secret and credential scanner
bash security/secret_scanner.sh

# 3. Network exposure and socket binding audit
bash security/network_exposure_audit.sh
```

**Results:**
- All containers drop all Linux capabilities (`cap_drop: [ALL]`), enforce `read_only: true` root filesystems, run under dedicated non-root UIDs, and bind exclusively to `127.0.0.1`.
- Zero credentials or secrets in Git history or working tree.

---

## 9. Test Battery & Execution Evidence

To run and verify the test suites:

```bash
# 1. Python Unit & Reliability Suites (88 tests)
.venv/bin/pytest tests/python/ tests/reliability/ -q

# 2. Shell Assertion Test Runner (83 assertions across 55 test blocks in 7 scripts)
bash scripts/tests/test_runner.sh

# 3. Multi-Host Verification (28 assertions across 5 groups)
bash tests/multihost/test_multihost_monitoring.sh

# 4. Prometheus Static Syntax Validation (1 config file, 80 rules across 5 files)
promtool check config prometheus/prometheus.yml
promtool check rules prometheus/rules/*.yml prometheus/alerts/*.yml
```

### Exact Reconciled Assertion Counts:
- **Python Tests (88 passed):**
  - `tests/python/`: 58 passed (custom collectors, HTTP server, integration contracts, configuration safety).
  - `tests/reliability/`: 30 passed (lifecycle math, remediation guardrails, circuit breakers, safety invariants, E2E drill scenarios).
- **Bash Subsystem Assertions (83 passed across 55 test blocks in 7 test scripts):**
  - `test_cli_and_errors.sh`: 20 assertions
  - `test_cpu.sh`: 10 assertions
  - `test_memory.sh`: 11 assertions
  - `test_network.sh`: 14 assertions
  - `test_process.sh`: 12 assertions
  - `test_storage.sh`: 8 assertions
  - `test_systemd.sh`: 8 assertions
- **Multi-Host Verification Assertions (28 passed across 5 groups):**
  - File-SD Inventory: 4 assertions
  - Target Scrape States: 4 assertions
  - Metric Isolation: 4 assertions
  - Log Stream Isolation: 5 assertions
  - Alloy Installer & Rollback Mechanics: 11 assertions
- **Prometheus Static Syntax Validation:**
  - `prometheus/prometheus.yml`: 1 configuration file verified.
  - `prometheus/rules/*.yml`, `prometheus/alerts/*.yml`: 80 rules across 5 files verified.
- **Container Hardening Configuration Checks:**
  - `security/container_audit.sh`: 42 checks passed across 6 container service definitions.
