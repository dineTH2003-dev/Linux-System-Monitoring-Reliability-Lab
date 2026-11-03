# Troubleshooting Runbook: Synthetic Blackbox Probing & Endpoint Availability

## 1. Alert Overview
- **Associated Alerts:** `BlackboxEndpointDown`, `BlackboxHttpProbeFailed`, `BlackboxProbeLatencyHigh`, `BlackboxProbeSlowCritical`, `BlackboxTcpConnectFailed`
- **PromQL Triggers:**
  - `probe_success{job="blackbox-http"} == 0` (for 2m)
  - `probe_http_status_code{job="blackbox-http"} >= 400` (for 2m)
  - `probe_duration_seconds{job="blackbox-http"} > 0.500` (Warning: 500ms for 5m)
  - `probe_duration_seconds{job="blackbox-http"} > 2.000` (Critical: 2s for 2m)
  - `probe_success{job="blackbox-tcp"} == 0` (for 2m)
- **Severity:** Warning / Critical
- **SLO Impact:** Directly impacts Synthetic HTTP Availability and Prober Latency SLIs.

---

## 2. Immediate Triage & Diagnostics
1. **Check Blackbox Exporter Container Health:**
   ```bash
   docker ps --filter "name=lab-blackbox-exporter"
   curl -s http://127.0.0.1:9115/probe?target=http://127.0.0.1:9101/healthz&module=http_2xx
   ```
2. **Inspect Blackbox Exporter Logs:**
   ```bash
   docker logs --tail 50 lab-blackbox-exporter
   ```
3. **Manual Endpoint Curl Verification:**
   ```bash
   # Test Agent healthz
   curl -iv http://127.0.0.1:9101/healthz
   # Test Prometheus health
   curl -iv http://127.0.0.1:9091/-/healthy
   # Test Grafana health
   curl -iv http://127.0.0.1:3001/api/health
   ```
4. **Inspect DNS Probe Resolutions:**
   ```bash
   dig @1.1.1.1 example.com
   dig @8.8.8.8 example.com
   ```

---

## 3. Common Failure Modes & Resolution
- **HTTP 400 Client Error on Loopback Probing:**
  - *Cause:* Older Blackbox module omitting HTTP/1.1 `Host` header or Python agent HTTP server rejecting absent Host.
  - *Fix:* Ensure `blackbox/blackbox.yml` configures `preferred_ip_protocol: ip4` and correct module headers.
- **Connection Refused:**
  - *Cause:* Target process (e.g. Python agent or Prometheus) crashed or stopped.
  - *Fix:* Restart target service or container:
    ```bash
    python3 agent/main.py --daemon
    docker restart lab-prometheus
    ```
- **External DNS Latency / Timeout:**
  - *Cause:* Transient uplink latency or DNS throttle from public resolvers (1.1.1.1/8.8.8.8).
  - *Fix:* Verify host internet routing via `ip route` and outbound UDP/53 firewall rules.

---

## 4. Recovery Verification
- Confirm `probe_success == 1` in Prometheus:
  ```bash
  curl -sG http://127.0.0.1:9091/api/v1/query --data-urlencode 'query=probe_success' | jq .
  ```
- Verify alerts resolve in Alertmanager: `http://127.0.0.1:9094/#/alerts`.
