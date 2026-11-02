# Phase A — Controlled Python Monitoring Agent Runtime Verification Report

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Senior SRE Engineer and Runtime Verification Lead  
**Repository:** `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`  
**Execution Mode:** Controlled Phase A Runtime Verification (Strict Read-Only / Non-Destructive)

---

## 1. Test Date and Time

- **Execution Date:** Wednesday, October 28, 2026
- **Execution Timestamp:** `2026-10-28 17:19:10 IST` (Initial Baseline) to `2026-10-28 17:21:00 IST` (Completion)
- **Host Time (`date`):** `Wed Oct 28 05:19:10 PM +0530 2026`

---

## 2. Initial Host Baseline

Captured prior to starting the Python agent:

### Memory Snapshot (`free -h`)
```text
               total        used        free      shared  buff/cache   available
Mem:            15Gi        12Gi       449Mi       4.5Gi       7.0Gi       2.6Gi
Swap:          4.0Gi       4.0Gi        15Mi
```

### Active Swap (`swapon --show`)
```text
NAME      TYPE SIZE USED PRIO
/swap.img file   4G   4G   -1
```

### Kernel Memory Pressure Stalls (`/proc/pressure/memory`)
```text
some avg10=0.00 avg60=0.00 avg300=0.00 total=333241637
full avg10=0.00 avg60=0.00 avg300=0.00 total=277801683
```

### Port 9101 Availability (`ss -ltnp | grep ':9101'`)
```text
Port 9101 is FREE
```
*Verification:* Port 9101 was verified unallocated and free prior to agent execution.

---

## 3. Agent Startup Output

The monitoring agent was launched using the existing Python virtual environment:
```bash
.venv/bin/python3 -m agent.main \
  -c agent/config.yaml \
  --host 127.0.0.1 \
  --port 9101
```

### Captured Process Output
```text
2026-10-28 17:19:24 [INFO] [agent]: Initializing Linux System Monitoring Agent...
2026-10-28 17:19:24 [INFO] [agent.server]: Monitoring Agent listening on http://127.0.0.1:9101/metrics
```
*Evaluation:* Clean startup with zero exceptions, stack traces, or warnings emitted.

---

## 4. Health Endpoint Response

### Request
```bash
curl -i --max-time 5 http://127.0.0.1:9101/healthz
```

### Complete Response
```http
HTTP/1.0 200 OK
Server: BaseHTTP/0.6 Python/3.12.3
Date: Wed, 28 Oct 2026 11:49:40 GMT
Content-Type: application/json; charset=utf-8
Content-Length: 75

{
  "status": "healthy",
  "version": "1.0.0",
  "uptime_seconds": 15.98
}
```
*Evaluation:* The `/healthz` endpoint responded with HTTP 200, valid JSON formatting, and explicitly confirmed `status: healthy` with version `1.0.0`.

---

## 5. Metrics Endpoint Response and Sample Metrics

### Request
```bash
curl -i --max-time 5 http://127.0.0.1:9101/metrics
```

### Response Headers
```http
HTTP/1.0 200 OK
Server: BaseHTTP/0.6 Python/3.12.3
Date: Wed, 28 Oct 2026 11:49:48 GMT
Content-Type: text/plain; version=0.0.4; charset=utf-8
Content-Length: 25941
```

### First 40 Lines of Exposition Output (`curl -s ... | head -40`)
```text
# HELP linux_cpu_seconds_total Total CPU time spent in each mode in seconds.
# TYPE linux_cpu_seconds_total counter
linux_cpu_seconds_total{cpu="total",mode="user"} 288233.99
linux_cpu_seconds_total{cpu="total",mode="nice"} 85.73
linux_cpu_seconds_total{cpu="total",mode="system"} 71233.59
linux_cpu_seconds_total{cpu="total",mode="idle"} 1065980.53
linux_cpu_seconds_total{cpu="total",mode="iowait"} 1780.09
linux_cpu_seconds_total{cpu="total",mode="irq"} 0.0
linux_cpu_seconds_total{cpu="total",mode="softirq"} 1644.25
linux_cpu_seconds_total{cpu="total",mode="steal"} 0.0
linux_cpu_seconds_total{cpu="total",mode="guest"} 91431.25
linux_cpu_seconds_total{cpu="total",mode="guest_nice"} 0.0
linux_cpu_seconds_total{cpu="0",mode="user"} 23245.15
linux_cpu_seconds_total{cpu="0",mode="nice"} 9.28
linux_cpu_seconds_total{cpu="0",mode="system"} 5513.28
linux_cpu_seconds_total{cpu="0",mode="idle"} 89110.28
linux_cpu_seconds_total{cpu="0",mode="iowait"} 204.68
linux_cpu_seconds_total{cpu="0",mode="irq"} 0.0
linux_cpu_seconds_total{cpu="0",mode="softirq"} 99.01
linux_cpu_seconds_total{cpu="0",mode="steal"} 0.0
linux_cpu_seconds_total{cpu="0",mode="guest"} 6143.91
linux_cpu_seconds_total{cpu="0",mode="guest_nice"} 0.0
linux_cpu_seconds_total{cpu="1",mode="user"} 21209.62
linux_cpu_seconds_total{cpu="1",mode="nice"} 11.28
linux_cpu_seconds_total{cpu="1",mode="system"} 3858.66
linux_cpu_seconds_total{cpu="1",mode="idle"} 90894.65
linux_cpu_seconds_total{cpu="1",mode="iowait"} 107.18
linux_cpu_seconds_total{cpu="1",mode="irq"} 0.0
linux_cpu_seconds_total{cpu="1",mode="softirq"} 475.91
linux_cpu_seconds_total{cpu="1",mode="steal"} 0.0
linux_cpu_seconds_total{cpu="1",mode="guest"} 5997.51
linux_cpu_seconds_total{cpu="1",mode="guest_nice"} 0.0
linux_cpu_seconds_total{cpu="2",mode="user"} 26227.1
linux_cpu_seconds_total{cpu="2",mode="nice"} 13.85
linux_cpu_seconds_total{cpu="2",mode="system"} 5907.4
linux_cpu_seconds_total{cpu="2",mode="idle"} 83877.76
linux_cpu_seconds_total{cpu="2",mode="iowait"} 213.4
linux_cpu_seconds_total{cpu="2",mode="irq"} 0.0
linux_cpu_seconds_total{cpu="2",mode="softirq"} 66.47
linux_cpu_seconds_total{cpu="2",mode="steal"} 0.0
```
*Evaluation:* Output strictly adheres to Prometheus exposition text format 0.0.4. Custom Linux kernel and hardware metrics (`linux_cpu_seconds_total`, etc.) are actively exposed.

---

## 6. Actual Listening Socket

### Command
```bash
ss -ltnp | grep ':9101'
```

### Output
```text
LISTEN 0      5          127.0.0.1:9101       0.0.0.0:*    users:(("python3",pid=1755348,fd=10))
```
*Verification:* The process (PID `1755348`) is bound strictly and exclusively to `127.0.0.1:9101`. There is zero socket exposure on external network interfaces (`0.0.0.0` or `10.229.142.73`).

---

## 7. Docker-to-Host Network Test Results

### Running Prometheus Container Verification
```bash
docker ps --filter name=lab-prometheus
```
```text
CONTAINER ID   IMAGE                     COMMAND                  CREATED       STATUS                 PORTS                      NAMES
ae910bf20f58   prom/prometheus:v2.51.0   "/bin/prometheus --c…"   2 hours ago   Up 2 hours (healthy)   127.0.0.1:9091->9090/tcp   lab-prometheus
```

### Direct Probe: `/healthz` from inside `lab-prometheus`
```bash
docker exec lab-prometheus \
  wget -S -O- --timeout=5 \
  http://host.docker.internal:9101/healthz
```
```text
Connecting to host.docker.internal:9101 (192.168.65.2:9101)
  HTTP/1.0 200 OK
  Server: BaseHTTP/0.6 Python/3.12.3
  Date: Wed, 28 Oct 2026 11:50:04 GMT
  Content-Type: application/json; charset=utf-8
  Content-Length: 75

writing to stdout
-                    100% |********************************|    75  0:00:00 ETA
written to stdout
{
  "status": "healthy",
  "version": "1.0.0",
  "uptime_seconds": 39.96
}
```

### Direct Probe: `/metrics` from inside `lab-prometheus`
```bash
docker exec lab-prometheus \
  wget -S -O- --timeout=5 \
  http://host.docker.internal:9101/metrics
```
```text
Connecting to host.docker.internal:9101 (192.168.65.2:9101)
  HTTP/1.0 200 OK
  Server: BaseHTTP/0.6 Python/3.12.3
  Date: Wed, 28 Oct 2026 11:50:10 GMT
  Content-Type: text/plain; version=0.0.4; charset=utf-8
  Content-Length: 25913

writing to stdout
-                    100% |********************************| 25913  0:00:00 ETA
written to stdout
```
*Evaluation:* Direct, empirical confirmation that Docker Desktop's VM proxy (`192.168.65.2:9101`) forwards requests to host loopback `127.0.0.1:9101` with zero packet loss and immediate HTTP 200 responses.

---

## 8. Prometheus Target Status

### Query
```bash
curl -s http://127.0.0.1:9091/api/v1/targets \
  | jq '.data.activeTargets[] | select(.labels.job == "python-agent") | { health, scrapeUrl, lastError, lastScrape, lastScrapeDuration }'
```

### Result
```json
{
  "health": "up",
  "scrapeUrl": "http://host.docker.internal:9101/metrics",
  "lastError": "",
  "lastScrape": "2026-10-28T11:50:10.869376598Z",
  "lastScrapeDuration": 0.195301824
}
```
*Evaluation:* Prometheus target health transitioned from `down` to `up`. Scrapes succeed in ~195 ms with zero errors.

---

## 9. Prometheus `up` Metric Query

### Query
```bash
curl -s 'http://127.0.0.1:9091/api/v1/query?query=up%7Bjob%3D%22python-agent%22%7D' | jq .
```

### Result
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "up",
          "collector_type": "python_agent",
          "instance": "rubi",
          "job": "python-agent",
          "role": "custom_telemetry"
        },
        "value": [
          1793188219.778,
          "1"
        ]
      }
    ]
  }
}
```
*Evaluation:* `up{job="python-agent"} = 1`. Prometheus has officially validated the scraping pipeline for the Python agent.

---

## 10. Blackbox `probe_success` Results

### Query
```bash
curl -s 'http://127.0.0.1:9091/api/v1/query?query=probe_success' \
  | jq '.data.result[] | { job: .metric.job, instance: .metric.instance, success: .value[1] }'
```

### Extracted Telemetry
```json
{
  "job": "blackbox-tcp",
  "instance": "host.docker.internal:9101",
  "success": "1"
}
{
  "job": "blackbox-http",
  "instance": "http://host.docker.internal:9101/metrics",
  "success": "0"
}
```

### Technical Root-Cause Analysis: `blackbox-http` Probe Failure
While `blackbox-tcp` succeeded (`probe_success = 1`), `blackbox-http` returned `probe_success = 0`. Direct investigation revealed:
1. In `blackbox/blackbox.yml`, the `http_2xx` module defines:
   ```yaml
   modules:
     http_2xx:
       prober: http
       http:
         valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
   ```
2. The custom agent uses Python's standard `http.server.BaseHTTPRequestHandler`, which defaults protocol responses to `HTTP/1.0 200 OK`.
3. Directly querying `blackbox-exporter:9115/probe?module=http_2xx&target=http://host.docker.internal:9101/metrics` returned:
   - `probe_http_status_code: 200`
   - `probe_http_version: 1` (`HTTP/1.0`)
   - `probe_success: 0` (Failed because HTTP version was not `HTTP/1.1` or `HTTP/2.0`).

### Distinctions Explained
- **Prometheus Target Health:** Measures whether Prometheus successfully queried the scraper target endpoint.
- **Blackbox Exporter Scrape Health:** Measures whether Prometheus could reach the Blackbox exporter HTTP server (`blackbox-exporter:9115`).
- **The `probe_success` Metric:** The synthetic boolean result (1 or 0) indicating whether the probed target endpoint satisfied *all* probe constraints (network connectivity, status code, AND protocol version).

---

## 11. Agent Resource Consumption

### Process Telemetry (`ps -eo pid,ppid,rss,%mem,%cpu,cmd | grep '[a]gent.main'`)
```text
1755348 1216185 26464  0.1  1.2 .venv/bin/python3 -m agent.main -c agent/config.yaml --host 127.0.0.1 --port 9101
```
- **PID:** 1755348
- **Resident Set Size (RSS):** `26464` KB (**25.84 MiB**)
- **CPU Utilization:** **1.2%**
- **Memory Percentage:** **0.1%**

### Host Memory Comparison

| Metric | Initial Baseline | Step G Post-Verification | Delta |
|---|---|---|---|
| **Host Total RAM** | 15 GiB | 15 GiB | 0 |
| **Host Used RAM** | 12 GiB | 12 GiB | 0 |
| **Host Free RAM** | 449 MiB | 271 MiB | -178 MiB |
| **Host Available RAM**| 2.6 GiB | 2.4 GiB | -200 MiB |
| **Buff / Cache** | 7.0 GiB | 7.0 GiB | 0 |
| **Swap Used** | 4.0 GiB (15 MiB free) | 4.0 GiB (56 KiB free) | Saturated |
| **PSI Stall (`some`)**| 333,241,637 us | 333,334,276 us | +92.6 ms |
| **PSI Stall (`full`)**| 277,801,683 us | 277,877,862 us | +76.2 ms |

*Evaluation:* The Python agent's memory footprint is exceptionally lightweight (25.84 MiB RSS). However, host swap remains 99.9% saturated.

---

## 12. Errors and Warnings

- **Errors Encountered:** Zero errors during agent startup or endpoint servicing.
- **Warnings / Discrepancies:**
  - `blackbox-http` probe evaluates `probe_success = 0` due to `valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]` in `blackbox.yml` vs. `HTTP/1.0` emitted by Python's `BaseHTTPRequestHandler`.

---

## 13. Summary of Differences from Expected Behavior

1. **Expected:** Both Blackbox TCP and HTTP probes succeed with `probe_success = 1`.
2. **Actual:**
   - Blackbox TCP probe (`host.docker.internal:9101`) succeeded with `probe_success = 1`.
   - Blackbox HTTP probe (`http://host.docker.internal:9101/metrics`) returned HTTP 200, but registered `probe_success = 0` due to strict HTTP/1.1 version validation in Blackbox exporter configuration.
3. **Core Scraping:** Prometheus native scrape succeeded unconditionally with `health: "up"` and `up = 1`.

---

## 14. Final Engineering Verdict

### Selected Verdict:
**`PARTIAL PASS — LOCAL AGENT VERIFIED`**

### Engineering Justification:
1. **What Succeeded:**
   - Custom Python agent initialized cleanly and runs steadily on `127.0.0.1:9101`.
   - `/healthz` and `/metrics` endpoints function correctly with expected payloads.
   - Socket binding is strictly restricted to `127.0.0.1:9101` (zero external interface exposure).
   - Docker Desktop host loopback proxying was empirically proven from within running containers.
   - Prometheus native scraping is 100% operational (`up{job="python-agent"} = 1`).
   - Blackbox TCP probing to `host.docker.internal:9101` succeeded with `probe_success = 1`.
   - Agent resource footprint is minimal (25.84 MiB RSS, 1.2% CPU).
2. **Identified Blocker / Remediation Needed:**
   - `blackbox-http` fails synthetic validation because `http_2xx` expects `HTTP/1.1` while `BaseHTTPRequestHandler` emits `HTTP/1.0`.
   - **Remediation Option A:** Update `agent/server.py` to specify `protocol_version = "HTTP/1.1"`.
   - **Remediation Option B:** Update `blackbox/blackbox.yml` to include `"HTTP/1.0"` in `valid_http_versions`.

> [!NOTE]
> **Phase B Deployment Status:**  
> Phase B remains **UNAUTHORIZED**. Containers and sub-compose stacks remain undisturbed in their current operational states.
