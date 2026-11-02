# LogQL Query Language & Incident Investigation Reference

**Project:** Linux System Monitoring & Reliability Lab  
**Role:** Senior Observability Engineer (Agent 8 — Centralized Logging)  
**Target Engine:** Grafana Loki v3.0 / Grafana Explore  
**Document Status:** Production Operational Reference  

---

## 1. LogQL Fundamentals & Query Architecture

LogQL is Grafana Loki's Prometheus-inspired query language. Every LogQL query begins with a **Stream Selector**, flows through optional **Pipeline Stages** (line filters, parsers, label filters, line formatters), and can optionally be wrapped in **Metric Aggregations**.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             LOGQL QUERY ANATOMY                                  │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   {job="systemd-journal", unit="ssh.service"}   ◀── 1. Log Stream Selector       │
│     |= "Failed password"                         ◀── 2. Line Filter Expression    │
│     | json                                       ◀── 3. Parser Expression         │
│     | level = "warning"                          ◀── 4. Label Filter Expression   │
│     | line_format "{{.timestamp}} [AUTH] {{.msg}}"◀── 5. Line Formatter Expression│
│                                                                                  │
│   Wrapped Metric Query:                                                          │
│   sum by (unit) (                                                                │
│     rate({job="systemd-journal"} |= "error" [5m])                                │
│   )                                              ◀── 6. Metric Range Vector      │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Log Stream Selectors

Stream selectors determine which log streams Loki fetches from the TSDB index before scanning chunks. Efficient queries prune streams early:

| Syntax | Description | Example |
|---|---|---|
| `=` | Exact string match | `{job="systemd-journal"}` |
| `!=` | Exact string negative match | `{job!="conky"}` |
| `=~` | Regular expression match | `{unit=~"ssh\\.service|cron\\.service"}` |
| `!~` | Regular expression negative match | `{unit!~"user@.*"}` |

> [!TIP]
> **Performance Rule**: Always include at least one high-selectivity label (`job`, `unit`, `logger`, `container`) in your stream selector. Avoid bare `{environment="lab"}` queries across large datasets.

---

## 3. Pipeline Operators

### 3.1 Line Filter Expressions
Line filters perform fast substring or regex scans across raw log text:

- `|= "string"`: Log line contains literal string (case-sensitive).
- `!= "string"`: Log line does not contain literal string.
- `|~ "regex"`: Log line matches regular expression.
- `!~ "regex"`: Log line does not match regular expression.

```logql
// Fast literal match followed by exclusion
{job="systemd-journal"} |= "error" != "ignored"
```

### 3.2 Parser Expressions
Parsers extract dynamic keys from log lines and promote them to ephemeral query-time labels:

- `| json`: Parses JSON strings into label key-value pairs.
- `| json field="nested.key"`: Extracts specific nested JSON attributes.
- `| logfmt`: Parses standard key=value logfmt pairs.
- `| pattern "<pattern>"`: Extracts tokens delimited by fixed structure.
- `| regexp "<re>"`: Extracts named capture groups (`(?P<name>...)`).
- `| unpack`: Unpacks JSON log envelopes created by Promtail/Alloy.

```logql
// Parse Python Agent JSON logs and filter on extracted 'logger' attribute
{job="python-agent"} | json | logger = "agent.collector.cpu"
```

### 3.3 Label Filter Expressions
Label filters evaluate boolean conditions on labels (indexed or dynamically extracted by parsers):

```logql
// Extract JSON latency_ms and filter for slow queries
{job="python-agent"} | json | latency_ms > 500
```

Supported comparison operators: `=`, `!=`, `>`, `>=`, `<`, `<=`.  
Supported unit types: `duration` (`500ms`, `2s`, `1m`), `bytes` (`10KiB`, `2MiB`).

### 3.4 Formatting & Mutation Expressions
- `| line_format "{{.timestamp}} [{{.level}}] {{.message}}"`: Reconstructs the displayed log line.
- `| label_format new_label="{{.old_label}}"`: Renames or calculates labels.
- `| drop <label_names>`: Removes extracted labels from result sets.
- `| keep <label_names>`: Retains only specified labels.

---

## 4. Log Metric Queries (Log-to-Metric Engine)

LogQL converts log events into Prometheus-compatible time series:

### 4.1 Range Vector Aggregations
- `rate(v[1m])`: Number of log entries per second over the time range.
- `count_over_time(v[5m])`: Total count of log lines in the range.
- `bytes_rate(v[1m])`: Log volume in bytes per second.
- `bytes_over_time(v[10m])`: Total byte volume ingested.

```logql
// Ingestion rate per unit over 5 minutes
sum by (unit) (rate({job="systemd-journal"}[5m]))
```

### 4.2 Unwrapped Range Aggregations
Extracts numeric values from log lines to compute mathematical percentiles and averages:

```logql
// Compute 99th percentile collector scrape latency from Python agent logs
quantile_over_time(0.99,
  {job="python-agent"}
  | json
  | unwrap scrape_duration_seconds [5m]
) by (logger)
```

---

## 5. Production Incident Investigation Queries

### Scenario 1: SSH Brute-Force Authentication Attempt Hunting
**Objective**: Identify IP addresses and usernames targeted by automated SSH credential stuffing attacks.

```logql
// 1. Inspect raw failed password events
{job="systemd-journal", unit="ssh.service"} |= "Failed password"

// 2. Extract attacker IP and targeted username via regexp
{job="systemd-journal", unit="ssh.service"}
  |~ "Failed password for (invalid user )?(?P<user>\\S+) from (?P<attacker_ip>\\S+)"
  | line_format "Target User: {{.user}} | Attacker IP: {{.attacker_ip}}"

// 3. Compute failed login rate per attacker IP (Metric panel)
sum by (attacker_ip) (
  rate(
    {job="systemd-journal", unit="ssh.service"}
    |~ "Failed password for (invalid user )?\\S+ from (?P<attacker_ip>\\S+)" [5m]
  )
) > 0.05
```

---

### Scenario 2: Linux Kernel Out-Of-Memory (OOM) Killer Execution Audit
**Objective**: Track when the Linux kernel invokes the OOM killer, identify terminated process names, and measure killed memory footprint.

```logql
// 1. Locate all OOM killer invocations in kernel ring buffer
{job="systemd-journal", transport="kernel"} |= "Out of memory"

// 2. Extract killed process name, PID, and total allocated memory
{job="systemd-journal", transport="kernel"}
  |~ "Out of memory: Killed process (?P<killed_pid>\\d+) \\((?P<proc_name>[^)]+)\\) total-vm:(?P<total_vm_kb>\\d+)kB"
  | line_format "OOM KILL -> Process: {{.proc_name}} (PID: {{.killed_pid}}) | Allocated VM: {{.total_vm_kb}} KiB"

// 3. Alerting Rule Expression: Detect any OOM killer execution in last 10 minutes
count_over_time({job="systemd-journal", transport="kernel"} |= "Out of memory" [10m]) > 0
```

---

### Scenario 3: Storage Block I/O Degradation & Filesystem Remount Detection
**Objective**: Detect hardware disk errors, bad sectors, timeout faults, and emergency read-only remounts.

```logql
// 1. Search for kernel disk I/O errors and filesystem corruption
{job="systemd-journal", transport="kernel"}
  |~ "(?i)(I/O error|remounting filesystem read-only|EXT4-fs error|XFS error|blk_update_request)"

// 2. Isolate device name and sector failures
{job="systemd-journal", transport="kernel"}
  |~ "blk_update_request: I/O error, dev (?P<device>\\S+), sector (?P<sector>\\d+)"
  | line_format "CRITICAL: I/O Failure on {{.device}} at Sector {{.sector}}"

// 3. Rate of storage error messages per device
sum by (device) (
  rate(
    {job="systemd-journal", transport="kernel"}
    |~ "blk_update_request: I/O error, dev (?P<device>\\S+)" [5m]
  )
)
```

---

### Scenario 4: Systemd Service Crash-Looping & Unit Failure Analysis
**Objective**: Detect services that are failing repeatedly or restarting in rapid succession.

```logql
// 1. Identify services logging emergency, alert, or error priorities
{job="systemd-journal", level=~"err|error|crit|alert|emerg"}

// 2. Detect systemd unit restart and exit failure logs
{job="systemd-journal"} |~ "(?i)(Failed with result|Main process exited, code=exited, status=)"

// 3. Metric: Error log rate per systemd unit (identifies top failing service)
topk(5,
  sum by (unit) (
    rate({job="systemd-journal", level=~"err|error|crit|alert|emerg"} [5m])
  )
)
```

---

### Scenario 5: Python Monitoring Agent Collector Latency & Scrape Failure Tracking
**Objective**: Detect collectors timing out, failing to parse `/proc`, or throwing unhandled exceptions.

```logql
// 1. Inspect Python agent exceptions
{job="python-agent"} | json | exception != ""

// 2. Filter agent errors by specific collector module
{job="python-agent"}
  | json
  | level = "ERROR"
  | line_format "{{.timestamp}} [{{.logger}}]: {{.message}}"

// 3. Metric: Rate of exceptions grouped by collector
sum by (logger) (
  rate({job="python-agent"} |= "exception" [5m])
)
```

---

### Scenario 6: High-Frequency Log Flood Anomaly Detection
**Objective**: Detect noisy services generating excessive log spam that threatens disk capacity or Loki ingestion quotas.

```logql
// 1. Calculate top 5 log producers by line ingestion rate
topk(5,
  sum by (job, unit) (
    rate({job=~".+"} [1m])
  )
)

// 2. Calculate top log producers by byte volume (throughput in MB/s)
topk(5,
  sum by (unit) (
    bytes_rate({job="systemd-journal"} [5m])
  ) / 1024 / 1024
)
```

---

### Scenario 7: User Sudo & Privilege Escalation Tracking
**Objective**: Audit security events, sudo invocations, and root command execution on the host.

```logql
// 1. Inspect sudo command executions
{job="systemd-journal", unit="sudo.service"} |= "COMMAND="

// 2. Extract requesting user, target user, and command executed
{job="systemd-journal"}
  |~ "sudo:\\s+(?P<requesting_user>\\S+) : TTY=\\S+ ; PWD=\\S+ ; USER=(?P<target_user>\\S+) ; COMMAND=(?P<command>.*)"
  | line_format "SUDO: User {{.requesting_user}} executed '{{.command}}' as {{.target_user}}"

// 3. Count of sudo executions by user
sum by (requesting_user) (
  count_over_time({job="systemd-journal"} |= "COMMAND=" [1h])
)
```

---

### Scenario 8: Network Interface Packet Drop & Flapping Analysis
**Objective**: Correlate Prometheus network drop alerts with kernel link state changes (`wlo1`, `docker0`).

```logql
// 1. Search for link state and carrier loss events
{job="systemd-journal", transport="kernel"}
  |~ "(?i)(link is not ready|carrier lost|link became ready|NIC Link is Down)"

// 2. Extract network interface name
{job="systemd-journal", transport="kernel"}
  |~ "(?P<interface>[a-zA-Z0-9]+): (link is not ready|carrier lost|NIC Link is Down)"
  | line_format "NETWORK ALERT: Interface {{.interface}} link down / lost carrier"
```

---

### Scenario 9: Container Runtime OOM & Abnormal Exit Detection
**Objective**: Monitor Docker engine events for container process termination.

```logql
// 1. Search container logs for fatal panics or exit signals
{job="container-logs"} |~ "(?i)(panic:|fatal error:|SIGKILL|SIGTERM|exit status 137)"

// 2. Rate of container crash events per container
sum by (container) (
  rate({job="container-logs"} |~ "(?i)(panic:|fatal:|exit status)" [5m])
)
```

---

### Scenario 10: Prometheus Scrape Timeout Correlated Log Search
**Objective**: When Prometheus records `up{job="python-agent"} == 0`, query logs in the exact timestamp window to find the root cause.

```logql
// Find Python agent termination or socket bind errors within the incident window
{job="systemd-journal"}
  |~ "(?i)(python_agent|9101|Address already in use|Connection refused)"
  | line_format "{{.timestamp}} [{{.unit}}]: {{.message}}"
```

---

## 6. Query Optimization Best Practices

1. **Order of Operations Matters**:
   ```
   [Stream Selector] ──▶ [Line Filter (Fast Substring)] ──▶ [Parser (JSON/Logfmt)] ──▶ [Label Filter]
   ```
   Always place fast literal filters (`|= "Failed password"`) **before** CPU-intensive parsers (`| json` or `| regexp`). This reduces the number of log lines that require parsing by 95%+.
2. **Limit Result Sets in Explore**: Use `max_entries_limit_per_query: 5000` to prevent browser tab crashes during incident triage.
3. **Use Binary Rates Over String Counts**: When measuring throughput, `bytes_rate()` provides true network and disk impact, whereas `rate()` only reflects line counts.
