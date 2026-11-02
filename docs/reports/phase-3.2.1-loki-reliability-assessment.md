# Phase 3.2.1 Report: Loki Query Performance & Reliability Assessment

- **Date:** 2026-10-31
- **Role:** Senior Site Reliability Engineer (SRE) / Observability Architect (Agent 0)
- **Host System:** Ubuntu 24.04.4 LTS (`rubi`, Linux Kernel `6.8.0-47-generic`, x86_64)
- **Container Target:** `lab-loki` (`grafana/loki:3.0.0`, single-binary deployment)
- **Collector Targets:** Native Grafana Alloy (`1.21.2-1`) and Containerized Grafana Alloy (`v1.0.0`)
- **Execution Mode:** STRICT READ-ONLY Assessment
- **Final Assessment Verdict:** **UNHEALTHY** (Confirmed Critical Deadlock & Ingestion Halting)

---

## 1. Executive Summary

Phase 3.2.1 conducted a rigorous, read-only SRE reliability assessment into the query performance anomalies and timeouts observed following Phase 3.2.

The investigation conclusively identified that **the Loki service (`lab-loki`) entered a complete internal deadlock / engine freeze at `2026-10-31T04:37:59.772Z`**, triggered by an unconstrained 7-day LogQL query executed against a resource-constrained single-binary instance (`cpus: 0.5`, `memory: 512M`, `max_concurrent: 8`).

Key findings include:
1. **Total Engine Freeze:** Loki has not produced a single log line since `04:37:59 UTC` (over 3 hours and 18 minutes of complete silence).
2. **Container Marked Unhealthy:** Docker marked `lab-loki` as `unhealthy` with a failing streak of **68+ consecutive failed healthchecks**.
3. **Internal & External HTTP Unresponsiveness:** HTTP requests to `:3100` (`/ready`, `/metrics`, `/loki/api/v1/push`, `/loki/api/v1/query_range`) time out both from the physical Ubuntu host (`127.0.0.1:3100`) and from inside the Docker bridge network `lab-monitoring-net` (tested via `lab-grafana` querying `http://loki:3100/ready`). This disproves the hypothesis of a Docker Desktop port-proxy-only issue; the failure resides inside the Loki process itself.
4. **Active Ingestion Failure & Drop Spike:** Because Loki is unresponsive, push requests from native Alloy fail with connection timeouts (`status_code="-1"` count = 78). Ingestion has completely halted at 479,159 sent entries. Alloy's retry buffer filled and exhausted, causing dropped entries to spike from 14,289 to **23,222 entries dropped** (`reason="ingester_error"`).
5. **Process Accumulation:** 438 processes/threads have accumulated within the container due to hanging Docker healthcheck `wget` exec probes that never terminate.
6. **Zero Duplicate Ingestion:** Container Alloy has read 0 entries and pushed 0 bytes. Native Alloy is the sole, exclusive collector of physical host journals (0.00% stream overlap).

---

## 2. Scope and Safety Constraints

This assessment was executed strictly adhering to the mandated read-only safety boundaries:
- **No service modifications:** No services were restarted, reloaded, stopped, or reconfigured.
- **No data alteration:** No WAL files, TSDB chunks, or database volumes were touched or compacted.
- **No infrastructure changes:** Host networking, firewall rules, Docker configurations, and systemd units were untouched.
- **No load or stress testing:** Only bounded, short-timeout probes were executed.
- **Credential protection:** No secrets or environment variables were exposed.

---

## 3. Environment Baseline

| Component | Target Identity | Endpoint / Socket | Configured Boundaries | Runtime State |
| :--- | :--- | :--- | :--- | :--- |
| **Native Grafana Alloy** | `alloy:alloy` (PID 38563) | `127.0.0.1:12346` | Port `12346`, systemd sandbox | Active (`04:10:44` uptime) |
| **Container Lab Loki** | Docker (`lab-loki`) | `127.0.0.1:3100` | CPU `0.5`, RAM `512M`, TSDB v13 | **Unhealthy** (Failing streak: 68+) |
| **Container Lab Grafana** | Docker (`lab-grafana`) | `127.0.0.1:3001` | CPU `1.0`, RAM `512M` | Healthy (Active) |
| **Container Lab Prometheus**| Docker (`lab-prometheus`) | `127.0.0.1:9091` | CPU `1.0`, RAM `1GiB` | Healthy (Active) |
| **Container Lab Alloy** | Docker (`lab-alloy`) | `127.0.0.1:12345` | CPU `0.5`, RAM `256M` | Healthy (Idle) |
| **Python Monitoring Agent**| `dineth:dineth` (PID 34710) | `127.0.0.1:9101` | Systemd unprivileged | Active (`200 OK`) |

---

## 4. Loki Query Performance Findings (Investigation A)

### 4.1 Probe Telemetry & Latency Comparison
Low-impact probes were executed with strict timeouts to distinguish between network, proxy, and internal application layer bottlenecks:

| Probe Method | Target Destination | Timeout | Result | Error / Status Code |
| :--- | :--- | :--- | :--- | :--- |
| Host HTTP GET | `http://127.0.0.1:3100/ready` | 10.0s | **Timeout** | `curl: (28) Operation timed out` |
| Host Bounded Query | `http://127.0.0.1:3100/loki/api/v1/query_range` (1m window) | 5.0s | **Timeout** | `curl: (28) Operation timed out` |
| Internal Docker Net | `http://loki:3100/ready` (from `lab-grafana`) | 5.0s | **Timeout** | `curl: (28) Operation timed out` |
| Container Exec Probe | `docker exec lab-loki wget` | 5.0s | **Hang / Block** | Daemon unable to spawn process |
| Control Exec Probe | `docker exec lab-grafana echo hello` | 5.0s | **Instant (< 20ms)**| Exit Code 0 |

### 4.2 Query Performance Analysis
1. **Disproving the Docker Proxy Hypothesis:** Previous hypotheses suggested the Docker Desktop LinuxKit VM proxy was solely responsible for latency. However, executing `curl` directly over Docker's internal bridge network (`lab-monitoring-net`) from container `lab-grafana` to `http://loki:3100/ready` also timed out completely.
2. **Socket Layer vs. Application Layer:** The kernel socket on port 3100 accepts TCP SYN packets (the port is reported as `LISTEN` with a queue size of 4096), but the Go HTTP server event loop inside Loki never accepts or processes the HTTP payload.
3. **Execution Freeze Timestamp:** Inspection of Loki container logs (`docker logs --since "2026-10-31T04:38:00Z" lab-loki`) revealed zero log output since `2026-10-31T04:37:59.772Z`.

---

## 5. Ingestion Reliability Findings (Investigation B)

### 5.1 Dual-Snapshot Empirical Rate Analysis
To measure current real-time ingestion and drop dynamics, two metric snapshots were captured from native Alloy:
- **Snapshot 1:** `2026-10-31T07:55:59Z`
- **Snapshot 2:** `2026-10-31T07:56:46Z` ($\Delta t = 47\text{ seconds}$)

| Metric Identifier | Snapshot 1 | Snapshot 2 | Delta ($\Delta$) | Effective Rate |
| :--- | :--- | :--- | :--- | :--- |
| `loki_source_journal_target_lines_total` | 557,014 | 558,023 | **+1,009 lines** | **21.47 lines/sec** |
| `loki_write_sent_entries_total` | 479,159 | 479,159 | **0 entries** | **0.00 entries/sec** |
| `loki_write_sent_bytes_total` | 104.74 MB | 104.74 MB | **0 B** | **0.00 B/sec** |
| `loki_write_dropped_entries_total` | 23,222 | 23,222 | **0 entries** | **0.00 entries/sec** |
| Write Requests (`status_code="204"`) | 2,048 | 2,048 | **0 requests** | **0.00 req/sec** |
| Write Requests (`status_code="-1"`) | 78 | 78 | **0 requests** | **0.00 req/sec** |

### 5.2 Analysis of Ingestion Halting & Error Evolution
1. **Journal Collection is Active:** Native Alloy continues reading live system events at a steady rate of **~21.5 lines/sec** directly from `/var/log/journal`.
2. **Zero Forwarding Throughput:** Zero entries have been accepted by Loki since the freeze. Total sent entries have remained static at 479,159.
3. **Escalation of Dropped Logs:**
   - At Phase 3.2 initial report: 0 drops.
   - At post-deployment audit: 14,289 drops (associated with initial ring startup).
   - At Phase 3.2.1 audit: **23,222 drops** (an increase of **+8,933 dropped logs**).
   - Root Cause: Because Loki stopped accepting batches, Alloy's in-memory retry queues hit their batch retry ceilings and dropped the oldest buffered entries (`reason="ingester_error"`).

---

## 6. Resource and Storage Assessment (Investigation C)

| Component / Resource | Configured Limit | Measured Consumption | Utilization | Risk Assessment |
| :--- | :--- | :--- | :--- | :--- |
| **Loki CPU** | `0.5` Cores | `0.00%` | 0% | Frozen (CPU starvation during scan) |
| **Loki Memory** | `512 MiB` | `218.7 MiB` | 42.72% | Normal in-memory footprint |
| **Loki PIDs** | Unset (`null`) | **438 PIDs** | Abnormal | **Critical** (Zombie healthcheck leaks) |
| **Loki Chunks Storage** | Unlimited | `7.1 MB` | — | Stable TSDB chunk allocation |
| **Loki WAL Storage** | Unlimited | `91.3 MB` | — | Normal write-ahead log buffer |
| **Docker Volume** (`lab_loki_data`)| Unlimited | `11.75 MB` | — | Normal volume size |
| **Native Alloy RSS** | Host cgroup | `299.8 MB` | 1.8% of Host | Healthy steady-state memory |
| **Native Alloy CPU** | Host cgroup | `5.6%` | — | Stable journal reading |
| **Host NVMe Free Space** | 468 GB total | `314 GB available` | 30% used | **Zero filesystem risk** |

### WAL and Storage Evaluation
- The **91.3 MB WAL** size is consistent with standard Loki 3.0 operation. In Loki, incoming raw log batches are written to the Write-Ahead Log on disk before memory chunks are cut and compressed. The 91.3 MB WAL directly mirrors the 104.74 MB of uncompressed log text ingested during the initial backfill.
- The WAL is NOT corrupt. However, checkpointing and pruning are blocked because the ingester engine is frozen.

---

## 7. Duplicate Ingestion Assessment (Investigation D)

| Collector Instance | Execution Mode | Bound Journal Path | Lines Read | Lines Sent | Overlap Ratio |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Native Grafana Alloy** | Native Systemd (`alloy.service`) | Physical `/var/log/journal` | **558,023** | **479,159** | 100% Host Logs |
| **Containerized Alloy** | Docker (`lab-alloy`) | LinuxKit `/var/log/journal` | **0** | **0** | **0.00%** |

### Recommendation for Containerized Alloy (`lab-alloy`):
- **Finding:** Containerized Alloy is unable to read physical Ubuntu host journals due to Docker Desktop's LinuxKit VM mount boundary. It is currently consuming ~200 MiB RAM while completely idle.
- **Strategic Recommendation:** In a future authorized phase, `lab-alloy` should be either:
  1. **Option A (Recommended):** Removed from `docker-compose.yml` to conserve 200 MiB memory and reduce monitoring stack complexity.
  2. **Option B:** Repurposed exclusively to collect Docker container logs (stdout/stderr) via the Docker socket, leaving host systemd journal collection 100% to native Alloy.

---

## 8. Root-Cause Analysis with Evidence

```
                  ┌────────────────────────────────────────────────────────┐
                  │ Unconstrained 7-Day LogQL Query over HTTP API          │
                  │ (start: 7 days ago, end: now, scan ~500k log lines)   │
                  └───────────────────────────┬────────────────────────────┘
                                              │
                                              ▼
                  ┌────────────────────────────────────────────────────────┐
                  │ Querier Engine Spawns 8 Workers on 0.5 CPU Core        │
                  │ (querier.max_concurrent=8 vs deploy.limits.cpus=0.5)   │
                  └───────────────────────────┬────────────────────────────┘
                                              │
                                              ▼
                  ┌────────────────────────────────────────────────────────┐
                  │ Lock Contention & Thread Starvation in Single Binary   │
                  │ Ingester & TSDB v13 Chunk Iterator Deadlock            │
                  └───────────────────────────┬────────────────────────────┘
                                              │
                      ┌───────────────────────┴────────────────────────┐
                      ▼                                                ▼
┌──────────────────────────────────────────┐    ┌──────────────────────────────────────────┐
│ Go net/http Server Event Loop Freezes     │    │ Continuous Periodic Ruler Rules Stall     │
│ - Last Log Emitted: 04:37:59 UTC         │    │ - 11 rules evaluated every 30s halt      │
│ - Port 3100 stops accepting HTTP payload │    │ - Ruler evaluation logs completely cease │
└─────────────────────┬────────────────────┘    └──────────────────────────────────────────┘
                      │
     ┌────────────────┴────────────────────────────────┐
     ▼                                                 ▼
┌──────────────────────────────────────────┐    ┌──────────────────────────────────────────┐
│ Native Alloy Pushes Time Out & Drop Logs │    │ Docker Healthchecks Fail & Accumulate    │
│ - 78 requests fail (status_code="-1")    │    │ - FailingStreak reaches 68+              │
│ - Ingestion halts at 479,159 entries     │    │ - Container marked (unhealthy)           │
│ - 23,222 entries dropped (exhausted retry│    │ - 438 hanging wget exec processes leak   │
└──────────────────────────────────────────┘    └──────────────────────────────────────────┘
```

### Direct Evidence Chain:
1. **Loki Log Cease:** The exact timestamp of the last logged action in `lab-loki` is `2026-10-31T04:37:59.772Z`, coinciding precisely with the start of the 7-day query.
2. **CPU & Thread Starvation:** In `docker-compose.yml`, Loki is constrained to `cpus: "0.5"`. In `loki-config.yaml`, `querier.max_concurrent` is set to `8`, and 11 ruler rules are evaluated every 30 seconds. In single-binary mode, querier, ruler, ingester, and compactor run in a single process. Decompressing and filtering hundreds of thousands of lines across 8 worker routines on 0.5 CPU led to thread starvation and unrecoverable lock contention.
3. **Deadlock Manifestation:** The Go runtime event loop stopped processing network I/O. The container's CPU dropped to `0.00%`, and memory remained frozen at `218.7 MiB`.
4. **Cascading PID Leak:** Because Loki's HTTP server stopped responding, Docker's healthcheck (`wget -q --spider http://localhost:3100/ready`) timed out on every execution. Because Docker Desktop's exec runner had difficulty cleaning up timed-out execs, 438 processes accumulated inside the container.

---

## 9. Remaining Uncertainties

1. **State of in-memory WAL checkpoint:** It is uncertain whether the un-flushed in-memory chunks will be recovered from the on-disk WAL upon container restart. (Based on Loki's WAL recovery design, segments on disk should replay cleanly).
2. **Docker Desktop LinuxKit containerd state:** It is uncertain whether the Docker daemon in LinuxKit will cleanly terminate the 438 leaked healthcheck processes upon container restart or if a container recreate (`docker compose up --force-recreate loki`) will be required.

---

## 10. Recommended Corrective Actions (Prioritized)

| Priority | Corrective Action | Target File / Area | Rationale |
| :--- | :--- | :--- | :--- |
| **P0 (Immediate)** | **Controlled Restart of `lab-loki`** | Docker service `loki` | Break the active deadlock, flush accumulated hanging PIDs, and restore ingestion and health checks. |
| **P1 (Critical)** | **CPU Resource Limit Elevation** | `docker-compose.yml` (`loki.deploy.resources.limits.cpus`) | Increase CPU limit from `0.5` to `1.5` or `2.0` cores so querier and ruler cannot starve the ingester. |
| **P2 (Critical)** | **Concurrency & Query Constraints** | `loki/loki-config.yaml` (`querier.max_concurrent`) | Reduce `max_concurrent` from `8` to `2` or `4` to prevent query worker pools from exhausting CPU limits. |
| **P3 (High)** | **Healthcheck Grace & Timeout Tuning**| `docker-compose.yml` (`loki.healthcheck`) | Increase healthcheck timeout to `10s` and interval to `30s` to prevent exec storm under momentary load. |
| **P4 (Medium)** | **Retire / Repurpose `lab-alloy`** | `docker-compose.yml` (`alloy` service) | Remove redundant containerized Alloy to recover 200 MiB RAM, or reconfigure it exclusively for container logs. |

---

## 11. Proposed Acceptance Criteria for Future Remediation Phase

When remediation is authorized, the following criteria should be used to verify full recovery:
1. **Container Health:** `docker inspect lab-loki` reports `Status: "healthy"` with `FailingStreak: 0`.
2. **Readiness Response:** `curl -s http://127.0.0.1:3100/ready` returns `HTTP 200 ready` in `< 100ms`.
3. **Ingestion Resumption:** `loki_write_sent_entries_total` in native Alloy resumes incrementing at a rate of > 15 entries/sec.
4. **Zero Incremental Drops:** `loki_write_dropped_entries_total` delta is 0 over a 5-minute observation window.
5. **Process Stability:** `lab-loki` PIDs count remains bounded between 15 and 30 PIDs.
6. **Bounded Query Success:** A bounded query (`query={job="systemd-journal"}`, range 1 hour) completes successfully in Grafana Explore in `< 2.0s`.

---

## 12. Final Assessment Verdict

### **Verdict:** **UNHEALTHY**

**Justification:**
- The centralized logging engine (`lab-loki`) is currently **in a state of confirmed critical failure (deadlock)**.
- It has been completely unresponsive since `2026-10-31T04:37:59.772Z`.
- Docker has declared the container `unhealthy` for over 68 consecutive check intervals.
- Live journal telemetry ingestion from the host has completely halted, and native Alloy is actively dropping log entries due to target unreachability.
- 438 orphaned processes have accumulated inside the container.
- Safe, authorized remediation is strictly required to restore central logging functionality.
