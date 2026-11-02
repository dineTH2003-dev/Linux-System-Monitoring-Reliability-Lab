# Centralized Logging Architecture & Operations Guide

**Project:** Linux System Monitoring & Reliability Lab  
**Role:** Senior Observability Engineer (Agent 8 — Centralized Logging)  
**Target Environment:** Local Ubuntu 24.04 LTS (`rubi`, Linux Kernel `7.0.0-38-generic`)  
**Core Technologies:** Grafana Loki v3.0, Grafana Alloy v1.0, systemd journal, Grafana Explore  
**Document Status:** Production Engineering Specification  

---

## 1. High-Level Architecture & Design

The centralized logging architecture establishes an end-to-end, privacy-hardened, low-overhead log aggregation pipeline. The architecture is engineered around the principle of **direct kernel and host telemetry capture** coupled with **isolated containerized processing**.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                UBUNTU 24.04 LINUX HOST                                 │
│                                                                                        │
│  Host Log Sources:                                                                     │
│  • Linux Kernel (/dev/kmsg, /proc/kmsg) ──▶ [systemd-journald]                         │
│  • System Daemons (ssh, cron, docker)    ──▶ [/var/log/journal]                        │
│  • Custom Python Agent (:9101)           ──▶ [/agent/logs/*.log (JSONFormatter)]       │
│                                                     │                                  │
│                                                     ▼                                  │
│     ┌────────────────────────────────────────────────────────────────────────────┐     │
│     │            PROJECT-OWNED CENTRALIZED LOGGING STACK (DOCKER COMPOSE)        │     │
│     │                                                                            │     │
│     │  ┌──────────────────────────────────────────────────────────────────────┐  │     │
│     │  │  Grafana Alloy Collector (:12345)                                    │  │     │
│     │  │  • loki.source.journal: Ingests systemd journal streams              │  │     │
│     │  │  • loki.source.file: Tails structured Python monitoring agent logs   │  │     │
│     │  │  • discovery.docker: Discovers monitoring container logs             │  │     │
│     │  │  • loki.relabel: Normalizes metadata ('unit', 'level', 'transport') │  │     │
│     │  │  • loki.process: Redacts passwords, tokens, session IDs, /home paths │  │     │
│     │  │  • loki.write: Batches & pushes compressed streams to Loki (:3100)   │  │     │
│     │  └───────────────────────────────────┬──────────────────────────────────┘  │     │
│     │                                      │ HTTP /loki/api/v1/push              │     │
│     │                                      ▼                                     │     │
│     │  ┌──────────────────────────────────────────────────────────────────────┐  │     │
│     │  │  Grafana Loki TSDB Engine (:3100)                                    │  │     │
│     │  │  • Schema: TSDB v13 (daily index partitions)                         │  │     │
│     │  │  • Storage: Local filesystem chunk store (/loki/chunks)              │  │     │
│     │  │  • Compactor: Enforces 7-day retention (168h) & unlinks stale chunks │  │     │
│     │  │  • Ruler: Evaluates LogQL alert & recording rules                    │  │     │
│     │  └───────────────────────────────────┬──────────────────────────────────┘  │     │
│     │                                      │                                     │     │
│     │                                      ▼                                     │     │
│     │  ┌──────────────────────────────────────────────────────────────────────┐  │     │
│     │  │  Grafana Explore Console (:3000)                                     │  │     │
│     │  │  • LogQL stream filtering, line parsing, live tailing               │  │     │
│     │  │  • Split-view correlation with Prometheus metrics (:9091)            │  │     │
│     │  └──────────────────────────────────────────────────────────────────────┘  │     │
│     └────────────────────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Architectural Principles
1. **Zero Text Indexing**: Loki deliberately avoids full-text inverted indexes (unlike Elasticsearch or OpenSearch). Loki indexes exclusively metadata labels (`job`, `unit`, `level`, `environment`, `host`), storing raw log entries as compressed chunk blobs. This reduces index memory and storage overhead by 85–90%.
2. **Strict Loopback Isolation**: Both Loki (`127.0.0.1:3100`) and Alloy (`127.0.0.1:12345`) bind strictly to host loopback interfaces, ensuring that zero log data or query APIs are exposed to external physical networks (`wlo1`).
3. **Structured Ingestion**: Where applications emit structured data (such as the Python monitoring agent's `JSONFormatter`), logs are parsed dynamically at ingestion or query time without polluting the stream label space.

---

## 2. Log Collection Targets

| Target Source | Mechanism | Collector Component | Extracted Labels | Redaction Applied |
|---|---|---|---|---|
| **Linux Kernel** | `/var/log/journal` (`_TRANSPORT=kernel`) | `loki.source.journal` | `job="systemd-journal"`, `transport="kernel"`, `level="alert"` | Memory addresses, sensitive boot arguments |
| **systemd Services** | `/var/log/journal` (`_SYSTEMD_UNIT`) | `loki.source.journal` | `job="systemd-journal"`, `unit="ssh.service"`, `level="warning"` | Passwords, authorization tokens, user session noise |
| **Python Agent** | `/agent/logs/*.log` & stdout | `loki.source.file` + `stage.json` | `job="python-agent"`, `level="ERROR"`, `logger="agent.collector.cpu"` | Passwords, API tokens, `/home/[USER]` file paths |
| **Monitoring Stack** | Docker Engine Socket (`/var/run/docker.sock`) | `discovery.docker` + `loki.source.docker` | `job="container-logs"`, `container="lab-prometheus"` | Database credentials, API keys in command args |

---

## 3. Log Quality, Engineering Principles & Lifecycle

### 3.1 Log Levels and Priority Mapping
The Linux kernel and `systemd-journald` categorize events using the standard **RFC 5424** syslog priority hierarchy (0 through 7). In modern observability pipelines, high-granularity numeric priorities must be normalized into readable log levels for consistent triage:

| RFC 5424 Priority | Keyword | Description | Normalized Loki `level` | Actionability |
|---|---|---|---|---|
| `0` | `emerg` | Emergency: system is unusable (kernel panic, hardware fault) | `emergency` | Immediate paging, automated failover |
| `1` | `alert` | Action must be taken immediately (OOM killer, disk corruption) | `alert` | Immediate SRE intervention |
| `2` | `crit` | Critical conditions (critical daemon crash) | `critical` | High-priority ticket, on-call alert |
| `3` | `err` | Error conditions (failed disk read, failed authentication) | `error` | SRE review, error budget impact |
| `4` | `warning` | Warning conditions (high latency, degraded redundancy) | `warning` | Proactive investigation |
| `5` | `notice` | Normal but significant condition (service started, mount active) | `notice` | Informational audit trail |
| `6` | `info` | Informational messages (scrape completed, config reloaded) | `info` | Routine telemetry |
| `7` | `debug` | Debug-level messages (verbose function tracing) | `debug` | Suppressed in production |

Alloy automatically normalizes `__journal_priority_keyword` into the indexed `level` label via `loki.relabel`.

### 3.2 Structured Logging
Unstructured string messages (`printf("user %s failed", user)`) require fragile regular expressions to parse at query time. Structured logging emits log entries as structured records (primarily JSON or logfmt):

```json
{
  "timestamp": "2026-10-28T15:10:00.123456Z",
  "level": "ERROR",
  "logger": "agent.collector.disk_io",
  "message": "Disk read failure on /dev/nvme0n1p2: timeout waiting for I/O completion",
  "device": "/dev/nvme0n1p2",
  "latency_ms": 3004.2,
  "exception": "Traceback (most recent call last):\n  File 'disk_io.py', line 45\nIOError: Device timeout"
}
```

#### Best Practices for Structured Schemas:
1. **Top-Level Standard Fields**: Every log entry must include `timestamp` (ISO 8601 UTC), `level` (uppercase string), `logger` (module namespace), and `message` (human-readable string).
2. **Contextual Key-Value Pairs**: Auxiliary attributes (`device`, `latency_ms`) must remain key-value pairs inside the JSON payload, **not** concatenated into the message string.
3. **Never Index Arbitrary Payload Keys**: Keep payload attributes unindexed. LogQL extracts them dynamically using `| json` at query execution.

### 3.3 Timestamp Handling & Monotonic Sequencing
1. **Source vs. Ingestion Timestamp**:
   - `_SOURCE_REALTIME_TIMESTAMP`: Hardware clock timestamp recorded when the process invoked `write()` or `sd_journal_send()`.
   - `__REALTIME_TIMESTAMP`: System clock timestamp recorded by `systemd-journald` upon receiving the datagram.
   - Ingestion Timestamp: Timestamp assigned by Loki upon receiving the HTTP push.
2. **Clock Skew & Rejection Window**:
   - Loki rejects entries with timestamps older than `limits_config.reject_old_samples_max_age` (configured to `168h` / 7 days).
   - Loki accommodates forward clock drift via `limits_config.creation_grace_period: 10m`.
3. **Monotonic Order**:
   - Within an individual stream ($S = \{l_1=v_1, l_2=v_2\}$), entries must arrive with non-decreasing timestamps. Out-of-order logs within a single stream trigger ingestion drops in older engines. Loki 3.0 supports out-of-order ingestion within the compactor window, but Alloy preserves local FIFO sequencing per stream.

### 3.4 Log Labels vs. Log Streams
A **Log Stream** in Loki is uniquely identified by the exact combination of its indexed label key-value pairs:

$$\text{Stream ID} = \text{hash}(l_1=v_1, l_2=v_2, \dots, l_k=v_k)$$

- **Stream Creation**: When a log arrives with a new label combination (e.g. `unit="docker.service"`), Loki instantiates a new stream, creates an in-memory chunk buffer, and appends incoming log lines.
- **Chunk Lifecycle**:
  - `chunk_idle_period: 30m`: If no log arrives for 30 minutes, the chunk is flushed to disk.
  - `max_chunk_age: 2h`: Chunks older than 2 hours are forced to flush to prevent memory accumulation.
  - `chunk_target_size: 1.5MB`: Once uncompressed log lines reach ~1.5MB, the chunk is compressed (using gzip or snappy) and persisted to `/loki/chunks`.

### 3.5 Cardinality Management
**Cardinality** refers to the total number of unique stream combinations generated by label permutations:

$$C = \prod_{i=1}^{n} |V_i| = |V_{\text{job}}| \times |V_{\text{unit}}| \times |V_{\text{level}}| \times |V_{\text{host}}|$$

#### The Cardinality Multiplier Trap:
If high-cardinality values are turned into Loki labels:
- `host` (1 value) $\times$ `job` (3 values) $\times$ `unit` (10 values) $\times$ `level` (5 values) = **150 streams** (Healthy).
- If `process_id` (PID, ~30,000 values) is added as a label: $150 \times 30,000 =$ **4,500,000 streams** (Catastrophic).
- Result: Loki creates 4.5 million in-memory chunk buffers, consumes gigabytes of RAM, exhausts file descriptors, degrades query performance, and crashes with Out Of Memory (OOM).

#### Strict Cardinality Rules:
- **Allowed as Labels**: Low-cardinality, bounded attributes (`job`, `environment`, `host`, `unit`, `level`, `transport`, `container`).
- **Forbidden as Labels**: Process IDs (`PID`), thread IDs, user IDs (`UID`), user names, IP addresses, URL query parameters, full file paths, transaction IDs, UUIDs.
- **Structured Metadata (Loki 3.0)**: Use Loki 3.0 structured metadata (`allow_structured_metadata: true`) or log line payload JSON attributes for high-cardinality fields.

### 3.6 Retention & Storage Compaction
1. **Compactor Engine**: Loki 3.0 utilizes the standalone `compactor` component (`retention_enabled: true`) to manage data retention.
2. **Chunk Expiration**:
   - `limits_config.retention_period: 168h` (7 days).
   - Every compaction cycle, the compactor identifies chunk files in `/loki/chunks` whose end timestamps exceed 168 hours.
   - Expired chunk references are removed from the TSDB v13 index, and chunk files are physically unlinked after a safety buffer (`retention_delete_delay: 2h`).
3. **Zero Table Overhead**: The TSDB schema uses 24-hour index buckets (`period: 24h`), allowing whole-day partition pruning without scanning table rows.

### 3.7 Host Log Rotation Coexistence
1. **systemd journal Rotation**:
   - Configured in `/etc/systemd/journald.conf`:
     - `SystemMaxUse=1G`: Caps persistent journal size on disk.
     - `RuntimeMaxUse=200M`: Caps volatile in-memory journal under `/run`.
     - `MaxFileSec=1month`: Rotates journal files periodically.
   - Host maintenance command: `journalctl --vacuum-size=500M` or `journalctl --vacuum-time=7d`.
2. **Alloy Journal Position Tracking**:
   - Alloy persists journal cursor positions in `/data-alloy/` (or in-memory cursor offsets).
   - When journal files rotate (e.g. `system@...journal~`), `sd_journal` automatically follows the active journal cursor without losing records or duplicating entries.

### 3.8 Metric-Log Correlation Architecture
In modern SRE incident triage, logs and metrics are two facets of the same operational reality. To enable instantaneous dual-direction navigation in **Grafana Explore**:

1. **Unified Label Equivalence**:
   - Prometheus metrics emitted by Node Exporter and Python Agent use:
     `{environment="lab", host="rubi", role="host_telemetry"}`
   - Loki log streams use the identical label keys:
     `{environment="lab", host="rubi", job="systemd-journal", unit="ssh.service"}`
2. **Correlation Workflow**:
   - **Step 1 (Anomaly Detection in Prometheus)**: An alert fires in Grafana (`HighDiskLatencyDetected`, `device="nvme0n1p2"` at `15:10:00`).
   - **Step 2 (Explore Split View)**: Operator splits the panel and selects Loki datasource.
   - **Step 3 (Targeted LogQL Inspection)**: Operator runs:
     `{job="systemd-journal", transport="kernel"} |~ "(?i)nvme|I/O error"`
   - **Step 4 (Root Cause Grounding)**: Direct kernel log verifies: `blk_update_request: I/O error, dev nvme0n1, sector 4589201`.
   - **Result**: MTTD and MTTR reduced from 30 minutes to under 60 seconds.

---

## 4. Security, Privacy & Data Sanitization Policies

Centralized logging poses severe data leakage risks if personal files or credentials enter search indexes. The lab implements strict automated sanitization:

### 4.1 Automated Redaction Rules in Alloy Pipeline

```alloy
loki.process "journal_sanitization" {
  // 1. Cleartext Passwords & API Tokens
  stage.replace {
    expression = "(?i)(password|passwd|pwd|secret|token|api[_-]?key|bearer)\\s*[:=]\\s*([\"']?)([^\\s\"',;]+)([\"']?)"
    replace    = "$1=[REDACTED]"
  }

  // 2. HTTP Authorization Headers
  stage.replace {
    expression = "(?i)Authorization:\\s*(Bearer\\s+)?[a-zA-Z0-9_\\-\\.]+"
    replace    = "Authorization: [REDACTED]"
  }

  // 3. Command-Line Argument Flags
  stage.replace {
    expression = "(?i)(--password|--token|--api-key|--secret)\\s+([^\\s]+)"
    replace    = "$1 [REDACTED]"
  }

  // 4. Session Cookies & Identifiers
  stage.replace {
    expression = "(?i)(session_id|sessionid|connect\\.sid)=([^\\s;,]+)"
    replace    = "$1=[REDACTED]"
  }

  // 5. Personal Home Directory Paths
  stage.replace {
    expression = "/home/[a-zA-Z0-9_-]+"
    replace    = "/home/[REDACTED_USER]"
  }
}
```

### 4.2 Noise and Privacy Drop Policies
Alloy drops noisy userland and desktop processes before they reach Loki:
- `user@1000.service` (Desktop session manager)
- `session-*.scope` (Interactive terminal sessions)
- `conky.desktop` (Desktop system monitors)
- `pipewire*.service` (Audio stream events)
- `gnome-*.service` (Desktop GUI utilities)

Only system daemons, core infrastructure, kernel subsystems, and monitoring agents are forwarded.

---

## 5. Operational Verification & Troubleshooting

### 5.1 Verification Commands
- Check Loki Ready Status:
  ```bash
  curl -s http://127.0.0.1:3100/ready
  ```
- Check Alloy Healthy Status:
  ```bash
  curl -s http://127.0.0.1:12345/-/healthy
  ```
- Query Loki Labels:
  ```bash
  curl -s http://127.0.0.1:3100/loki/api/v1/labels | jq .
  ```
- Test Log Ingestion Query:
  ```bash
  curl -G -s http://127.0.0.1:3100/loki/api/v1/query \
    --data-urlencode 'query={job=~".+"}' | jq .
  ```

### 5.2 Common Operational Failure Modes
1. **Loki Port Conflict (`3100`)**: If host port 3100 is occupied, verify via `ss -tulpn | grep 3100`. The container port mapping binds strictly to `127.0.0.1:3100:3100`.
2. **Permission Denied Reading `/var/log/journal`**: The host journal directory has permissions `drwxr-sr-x+ root systemd-journal`. Alloy runs with user `0:4` (root user with gid 4 `adm`/`systemd-journal`) to ensure read access without modifying host filesystem permissions.
3. **Ingestion Rate Limit Exceeded (`429 Too Many Requests`)**: If a host service floods logs, Loki rejects excess lines once ingestion exceeds `8MB/s` (burst `16MB/s`). Increase `ingestion_rate_mb` in `loki/loki-config.yaml` if sustained high volume is expected.
