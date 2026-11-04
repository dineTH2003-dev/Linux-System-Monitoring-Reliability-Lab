# Alerting Architecture & Incident Detection

**Project:** Linux System Monitoring & Reliability Lab  
**Scope:** Prometheus Alert Rules, Alertmanager Routing, Inhibition Trees & Blackbox Synthetic Probing  

---

## 1. High-Level Incident Detection Architecture

The alerting platform connects bare-metal Linux kernel telemetry with automated synthetic probing and multi-tier incident routing:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Native Kernel Subsystems:                                            │
│   • /proc/stat, /proc/meminfo, /proc/diskstats, /proc/net/dev          │
│   • Linux PSI: /proc/pressure/{cpu, memory, io}                        │
│   • systemd D-Bus unit lifecycle states                                │
│                                 ▲                                      │
│                ┌────────────────┴───────────────┐                      │
│                │                                │                      │
│     ┌──────────┴─────────────┐      ┌───────────┴────────────┐         │
│     │ Node Exporter (:9100)  │      │ Custom Agent (:9101)   │         │
│     │ [Direct Kernel Metrics]│      │ [Process & Systemd]    │         │
│     └──────────┬─────────────┘      └───────────┬────────────┘         │
│                │                                │                      │
│                │ HTTP Metrics Pull              │ HTTP Metrics Pull    │
│                └────────────────┬───────────────┘                      │
│                                 │                                      │
│                                 ▼                                      │
│     ┌────────────────────────────────────────────────────────────┐     │
│     │             CONTAINERIZED OBSERVABILITY STACK              │     │
│     │                                                            │     │
│     │  ┌───────────────────────┐      ┌───────────────────────┐  │     │
│     │  │   Prometheus (:9091)  │─────▶│ Alertmanager (:9093)  │  │     │
│     │  │   • Rule Engine       │Push  │ • Grouping & Deduc    │  │     │
│     │  │   • Duration Gating   │      │ • Cascading Inhibition│  │     │
│     │  │   • 72 Total Rules    │      │ • Multi-Tier Routing  │  │     │
│     │  └───────────▲───────────┘      └───────────┬───────────┘  │     │
│     │              │                              │              │     │
│     │              │ Scrape /probe                │ Dispatches   │     │
│     │              │                              ▼              │     │
│     │  ┌───────────┴───────────┐      ┌───────────────────────┐  │     │
│     │  │ Blackbox Exp (:9115)  │      │ Notification Sinks    │  │     │
│     │  │ Synthetics:           │      │ • PagerDuty (Crit)    │  │     │
│     │  │ HTTP, TCP, DNS, ICMP  │      │ • Slack (Warning)     │  │     │
│     │  └───────────┬───────────┘      │ • Webhook Triage      │  │     │
│     │              │                  └───────────────────────┘  │     │
│     └──────────────┼─────────────────────────────────────────────┘     │
│                    │ Synthetic Probes                                  │
│                    ▼                                                   │
│   Host & Container Endpoints (:22, :9100, :9101, :9090, :9093)         │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. SRE Alert Engineering Principles

In modern Site Reliability Engineering, alerting is the front line of defense against system degradation. Poorly configured alerts cause **alert fatigue**, leading operators to ignore critical warnings.

### 2.1 Symptom-Based vs. Cause-Based Alerting
- **Symptoms (Alert on Impact)**: Alerts must prioritize user-visible symptoms (e.g., endpoint returning HTTP 500, storage nearing full capacity, disk read latency > 30ms).
- **Causes (Provide Diagnostic Context)**: Root causes (e.g., a specific compilation script consuming CPU or unlinked deleted files holding disk locks) are included as **diagnostic context** and triage commands within the alert annotations, rather than generating separate noisy alerts.

### 2.2 Duration Gating (`for:` Clause)
Transient spikes in CPU or momentary network packet drops are normal occurrences in a modern multi-tasking operating system. An alert must NEVER fire on a single sample:
- **`for: 1m - 2m`**: Applied to hard availability outages (`HostUnavailable`, `BlackboxEndpointDown`, `CriticalServiceDown`) where swift response is necessary.
- **`for: 3m - 5m`**: Applied to resource saturation (`HostHighCpuUtilization`, `HostDiskReadLatencyHigh`, `HostLowMemoryAvailable`) to smooth out temporary burst workloads.
- **`for: 10m - 15m`**: Applied to capacity trends (`HostFilesystemSpaceWarning`, `HostFilesystemFillRatePredict`, `HostInodeExhaustionWarning`) to avoid paging on routine batch writes.

### 2.3 Meaningful Severity Taxonomy

| Severity | Operational Meaning | Response Requirement | Group Wait | Repeat Interval | Target Receiver |
|---|---|---|---|---|---|
| **`critical`** | Complete service outage, data corruption, or imminent crash (OOM, ENOSPC, dead critical daemon). | Immediate operator action required (24/7 pager). | `10s` | `1h` | `pager-critical` |
| **`warning`** | Capacity exhaustion trend, performance degradation, or redundant component failure. | Attention required during business hours / triage queue. | `1m` | `6h` | `slack-warnings` |
| **`informational`** | State audit, configuration changes, or synthetic watchdog heartbeats. | Logged for auditing; no pager dispatch. | `5m` | `12h` | `info-log` / `deadmansswitch` |

---

## 3. Comprehensive Alert Inventory (16 Domains)

The platform implements 29 dedicated alerting rules organized into two modular suites:
1. `prometheus/alerts/infrastructure_alerts.yml` (23 rules)
2. `prometheus/alerts/blackbox_alerts.yml` (6 rules)

### 3.1 Host & Collector Availability

#### 1. Host Unavailable (`HostUnavailable`)
- **Severity**: `critical`
- **Expression**:
  ```promql
  (up{job="node"} == 0 and on(instance) up{job="python-agent"} == 0) or (probe_success{job="blackbox-icmp"} == 0)
  ```
- **Duration**: `2m`
- **Summary**: `Host {{ $labels.instance }} is unavailable or unreachable`
- **Description**: All primary telemetry exporters (`node`, `python-agent`) or ICMP echo ping probes for the host have failed for >2 minutes.
- **Diagnostic Command**: `ping -c 3 127.0.0.1 && ip neigh`
- **Runbook**: `docs/troubleshooting/host-unavailable.md`

#### 2. Node Exporter Unavailable (`NodeExporterUnavailable`)
- **Severity**: `critical`
- **Expression**: `up{job="node"} == 0`
- **Duration**: `2m`
- **Summary**: `Node Exporter scrape failure on {{ $labels.instance }}`
- **Description**: Prometheus cannot scrape Node Exporter at `:9100`. Host kernel and hardware metrics are dark.
- **Diagnostic Command**: `systemctl status prometheus-node-exporter.service`
- **Runbook**: `docs/troubleshooting/target-down.md`

#### 3. Python Agent Unavailable (`PythonAgentUnavailable`)
- **Severity**: `warning`
- **Expression**: `up{job="python-agent"} == 0`
- **Duration**: `2m`
- **Summary**: `Custom Python monitoring agent down on {{ $labels.instance }}`
- **Description**: Prometheus cannot scrape custom agent on port `9101`. Custom process and systemd metrics unavailable.
- **Diagnostic Command**: `ps aux | grep 'agent/main.py' && curl -s http://127.0.0.1:9101/metrics | head -n 5`
- **Runbook**: `docs/troubleshooting/custom-agent.md`

---

### 3.2 Compute & Scheduling (CPU)

#### 4. High CPU Utilization (`HostHighCpuUtilizationWarning` & `HostHighCpuUtilizationCritical`)
- **Severity**: `warning` (>85% for `5m`) / `critical` (>95% for `3m`)
- **Expressions**:
  - Warning: `(100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)) > 85`
  - Critical: `(100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[3m])) * 100)) > 95`
- **Summary**: `Elevated CPU utilization on {{ $labels.instance }} ({{ $value | printf "%.1f" }}%)`
- **Rationale**: On a multi-core Linux host, sustained utilization >85% leaves insufficient headroom for bursty workloads, and >95% causes severe thread queueing.
- **Diagnostic Command**: `top -b -n 1 -o %CPU | head -n 20`
- **Runbook**: `docs/troubleshooting/cpu-saturation.md`

#### 5. CPU Pressure Stall (`HostCpuPressureHigh`)
- **Severity**: `warning`
- **Expression**: `rate(node_pressure_cpu_waiting_seconds_total[2m]) * 100 > 25`
- **Duration**: `5m`
- **Summary**: `High CPU scheduling pressure on {{ $labels.instance }} ({{ $value | printf "%.1f" }}%)`
- **Rationale**: Uses kernel Pressure Stall Information (PSI). Measures true run-queue starvation: non-idle tasks spending >25% of wall-clock time waiting for an available CPU core.
- **Diagnostic Command**: `cat /proc/pressure/cpu`
- **Runbook**: `docs/troubleshooting/cpu-pressure.md`

---

### 3.3 Memory & Swap

#### 6. Low Available Memory (`HostLowMemoryAvailable` & `HostCriticalMemoryAvailable`)
- **Severity**: `warning` (<10% for `5m`) / `critical` (<5% for `2m`)
- **Expressions**:
  - Warning: `(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.10`
  - Critical: `(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.05`
- **Summary**: `Low available physical memory on {{ $labels.instance }}`
- **Rationale**: Strictly uses `MemAvailable` from `/proc/meminfo` (accounting for reclaimable page cache and kernel watermarks) rather than raw `MemFree`.
- **Diagnostic Command**: `free -h && ps -eo pid,ppid,cmd,%mem --sort=-%mem | head -n 15`
- **Runbook**: `docs/troubleshooting/memory-starvation.md`

#### 7. Memory Pressure (`HostMemoryPressureWaiting` & `HostMemoryPressureStalled`)
- **Severity**: `warning` (>20% for `3m`) / `critical` (>10% for `2m`)
- **Expressions**:
  - Waiting (`some`): `rate(node_pressure_memory_waiting_seconds_total[1m]) * 100 > 20`
  - Stalled (`full`): `rate(node_pressure_memory_stalled_seconds_total[1m]) * 100 > 10`
- **Rationale**: PSI `some` captures direct reclaim latency. PSI `full` captures total execution freeze where all non-idle tasks are blocked on memory allocation.
- **Diagnostic Command**: `cat /proc/pressure/memory && vmstat 1 5`
- **Runbook**: `docs/troubleshooting/memory-pressure.md`

#### 8. High Swap Activity (`HostSwapThrashingActive`)
- **Severity**: `warning`
- **Expression**:
  ```promql
  ((rate(node_vmstat_pswpin[1m]) + rate(node_vmstat_pswpout[1m])) * 4096 > 10485760)
  and
  ((node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.15)
  ```
- **Duration**: `3m`
- **Summary**: `Active swap thrashing detected on {{ $labels.instance }}`
- **Rationale**: Distinguishes harmless inactive swap from dynamic page in/out churn (>10 MB/s). Prevents false alarms on systems with static swap allocations.
- **Diagnostic Command**: `vmstat 1 5 && swapon --show`
- **Runbook**: `docs/troubleshooting/swap-thrashing.md`

---

### 3.4 Filesystem & Inodes

#### 9. Low Filesystem Capacity (`HostFilesystemSpaceWarning` & `HostFilesystemSpaceCritical`)
- **Severity**: `warning` (<15% for `10m`) / `critical` (<5% for `3m`)
- **Expressions**:
  - Warning: `(node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes{fstype=~"ext4|xfs"}) < 0.15`
  - Critical: `(node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes{fstype=~"ext4|xfs"}) < 0.05`
- **Rationale**: Explicitly filters `{fstype=~"ext4|xfs"}` to avoid false positives on read-only SquashFS Snap packages and RAM-backed `tmpfs` mounts.
- **Diagnostic Command**: `df -hT {{ $labels.mountpoint }} && du -xh --max-depth=2 {{ $labels.mountpoint }} | sort -hr | head -n 10`
- **Runbook**: `docs/troubleshooting/disk-capacity.md`

#### 10. Filesystem Depletion Forecast (`HostFilesystemFillRatePredict`)
- **Severity**: `warning`
- **Expression**:
  ```promql
  predict_linear(node_filesystem_avail_bytes{fstype=~"ext4|xfs"}[1h], 4 * 3600) < 0
  and
  (node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes{fstype=~"ext4|xfs"}) < 0.25
  ```
- **Duration**: `15m`
- **Summary**: `Filesystem {{ $labels.mountpoint }} projected to exhaust within 4 hours`
- **Rationale**: Linear regression across preceding 1 hour. Fires when a runaway process or un-rotated log is actively depleting storage, well before static thresholds breach.
- **Diagnostic Command**: `find {{ $labels.mountpoint }} -xdev -type f -mmin -60 -size +50M`
- **Runbook**: `docs/troubleshooting/disk-capacity.md`

#### 11. Inode Exhaustion (`HostInodeExhaustionWarning` & `HostInodeExhaustionCritical`)
- **Severity**: `warning` (<10% for `10m`) / `critical` (<2% for `3m`)
- **Expressions**:
  - Warning: `(node_filesystem_files_free{fstype=~"ext4|xfs"} / node_filesystem_files{fstype=~"ext4|xfs"}) < 0.10`
  - Critical: `(node_filesystem_files_free{fstype=~"ext4|xfs"} / node_filesystem_files{fstype=~"ext4|xfs"}) < 0.02`
- **Rationale**: Inode exhaustion returns `ENOSPC` even if gigabytes of free disk space remain. Detects rogue directory structures or unbounded small-file creation.
- **Diagnostic Command**: `df -i {{ $labels.mountpoint }}`
- **Runbook**: `docs/troubleshooting/disk-inodes.md`

---

### 3.5 Storage Block I/O

#### 12. High Disk I/O Latency (`HostDiskReadLatencyHigh` & `HostDiskWriteLatencyHigh`)
- **Severity**: `warning`
- **Expressions**:
  - Read: `(rate(node_disk_read_time_seconds_total{device=~"nvme.*|sd.*|vd.*"}[1m]) / clamp_min(rate(node_disk_reads_completed_total{device=~"nvme.*|sd.*|vd.*"}[1m]), 0.001)) > 0.030`
  - Write: `(rate(node_disk_write_time_seconds_total{device=~"nvme.*|sd.*|vd.*"}[1m]) / clamp_min(rate(node_disk_writes_completed_total{device=~"nvme.*|sd.*|vd.*"}[1m]), 0.001)) > 0.050`
- **Duration**: `5m`
- **Rationale**: Evaluates average request service time ($r\_await > 30\text{ms}$ and $w\_await > 50\text{ms}$). `clamp_min` eliminates division-by-zero during idle intervals.
- **Diagnostic Command**: `iostat -xz 1 5`
- **Runbook**: `docs/troubleshooting/disk-latency.md`

#### 13. High I/O Pressure Stall (`HostIoPressureWaitingHigh` & `HostIoPressureStalledCritical`)
- **Severity**: `warning` (>25% for `5m`) / `critical` (>10% for `2m`)
- **Expressions**:
  - Waiting (`some`): `rate(node_pressure_io_waiting_seconds_total[2m]) * 100 > 25`
  - Stalled (`full`): `rate(node_pressure_io_stalled_seconds_total[1m]) * 100 > 10`
- **Rationale**: Directly reflects tasks entering `D` (uninterruptible sleep) state waiting on storage controller queues.
- **Diagnostic Command**: `cat /proc/pressure/io && ps -eo pid,stat,cmd | grep ' D'`
- **Runbook**: `docs/troubleshooting/io-pressure.md`

---

### 3.6 Network Layer

#### 14. Network Errors & Drops (`HostNetworkDropsHigh` & `HostNetworkErrorsDetected`)
- **Severity**: `warning` (drops > 10/s for `5m`) / `critical` (errors > 0 for `2m`)
- **Expressions**:
  - Drops: `sum by (instance, device) (rate(node_network_receive_drop_total{device!~"lo|docker.*|veth.*"}[1m]) + rate(node_network_transmit_drop_total{device!~"lo|docker.*|veth.*"}[1m])) > 10`
  - Errors: `sum by (instance, device) (rate(node_network_receive_errs_total{device!~"lo|docker.*|veth.*"}[1m]) + rate(node_network_transmit_errs_total{device!~"lo|docker.*|veth.*"}[1m])) > 0`
- **Rationale**: Filters out loopback and virtual Docker bridge adapters to focus on physical interfaces (`wlo1`). Packet drops indicate buffer overflows; errors indicate physical signal degradation.
- **Diagnostic Command**: `ip -s link show {{ $labels.device }}`
- **Runbook**: `docs/troubleshooting/network-errors.md`

---

### 3.7 Services & Synthetics

#### 15. Critical Service Unavailable (`HostCriticalServiceDown`)
- **Severity**: `critical`
- **Expression**:
  ```promql
  node_systemd_unit_state{name=~"ssh.service|docker.service|systemd-journald.service|prometheus.service|prometheus-node-exporter.service", state="active"} == 0
  ```
- **Duration**: `1m`
- **Summary**: `Critical systemd service down: {{ $labels.name }}`
- **Rationale**: Explicitly guards the 5 core services necessary for physical host management, logging, and container execution.
- **Diagnostic Command**: `systemctl status {{ $labels.name }} && journalctl -u {{ $labels.name }} -n 25 --no-pager`
- **Runbook**: `docs/troubleshooting/systemd-unit.md`

#### 16. Endpoint Unavailable (`BlackboxEndpointDown` & Synthetic Suite)
- **Severity**: `critical` / `warning`
- **Rules Configured**:
  - `BlackboxEndpointDown`: `probe_success == 0` for `1m` (`critical`).
  - `BlackboxHttpProbeFailed`: non-2xx status code returned (`critical`).
  - `BlackboxProbeLatencyHigh`: `probe_duration_seconds > 1.0` for `3m` (`warning`).
  - `BlackboxProbeSlowCritical`: `probe_duration_seconds > 3.0` for `1m` (`critical`).
  - `BlackboxSslCertExpiring`: cert expiry < 14 days (`warning`).
  - `BlackboxTcpConnectFailed`: raw TCP connection refused (`critical`).
- **Diagnostic Command**: `curl -iv {{ $labels.instance }} || nc -zv {{ $labels.instance }}`
- **Runbook**: `docs/troubleshooting/blackbox-probe.md`

---

## 4. Alertmanager Mechanics & Notification Routing

Alertmanager (`alertmanager/alertmanager.yml`) orchestrates notification dispatch through a multi-tier routing tree:

### 4.1 Grouping & Deduplication
To prevent alert floods when multiple services or cores degrade simultaneously:
- **`group_by: ['alertname', 'instance', 'subsystem']`**: Groups related alerts sharing the same alert type and host instance into a single notification batch.
- **`group_wait: 30s`**: Waits 30 seconds after the first alert arrives to bundle subsequent alerts in the same group.
- **`group_interval: 5m`**: Waits 5 minutes before sending an updated batch when additional alerts arrive in an existing group.
- **`repeat_interval: 4h`**: Sends a reminder every 4 hours if the alert remains firing.

### 4.2 Cascading Inhibition Rules
Inhibition automatically silences redundant downstream alerts when a parent root cause is already actively firing:

| Inhibiting Alert (Source) | Suppressed Alerts (Target) | Matching Condition | SRE Justification |
|---|---|---|---|
| `HostUnavailable` | All `critical` and `warning` alerts | `instance` | If the host is completely unreachable, all metric-based alerts on that host are redundant noise. |
| `NodeExporterUnavailable` | All CPU, memory, storage, network, and disk alerts | `instance` | If the exporter is down, metric values are invalid or absent; alerting on old metrics is misleading. |
| `HostFilesystemSpaceCritical` | `HostFilesystemSpaceWarning` | `instance`, `mountpoint` | A critical capacity breach supersedes the warning alert for the same mount. |
| `HostInodeExhaustionCritical` | `HostInodeExhaustionWarning` | `instance`, `mountpoint` | A critical inode breach supersedes the warning alert. |
| `HostCriticalMemoryAvailable` | `HostLowMemoryAvailable` | `instance` | Critical memory starvation (<5%) supersedes low memory (<10%). |
| `HostHighCpuUtilizationCritical`| `HostHighCpuUtilizationWarning` | `instance` | Critical CPU saturation (>95%) supersedes high CPU (>85%). |
| `BlackboxEndpointDown` | `BlackboxProbeLatencyHigh`, `BlackboxHttpProbeFailed` | `instance` | If the endpoint cannot be reached, latency measurements are irrelevant. |

### 4.3 Safe Placeholder Configuration
In strict compliance with repository security:
- **No real credentials are committed to source control.**
- SMTP, Slack, and PagerDuty receiver definitions utilize safe placeholders (`PLACEHOLDER_SMTP_USER`, `PLACEHOLDER_PAGERDUTY_INTEGRATION_KEY`, `PLACEHOLDER_SLACK_WEBHOOK`).
- The default lab route dispatches to `default-webhook` (`http://host.docker.internal:5001/api/alerts`), ensuring zero external notifications are dispatched without operator approval.

---

## 5. Blackbox Exporter Probing Semantics

Blackbox Exporter (`blackbox/blackbox.yml`) enables external synthetic probing across 5 distinct modules:

| Module Name | Prober | Protocol | Validation Mechanism | Typical Target |
|---|---|---|---|---|
| **`http_2xx`** | `http` | HTTP/1.1 & HTTP/2 | Validates HTTP status code is in 2xx range; enforces TLS validation. | Prometheus (`/healthy`), Node Exporter (`/metrics`), Grafana (`/api/health`) |
| **`http_post_2xx`**| `http` | HTTP POST | Sends JSON healthcheck payload `{"probe": "synthetic_healthcheck"}` and expects 2xx. | API receivers, Webhooks |
| **`tcp_connect`** | `tcp` | TCP | Evaluates standard 3-way TCP handshake latency and completion. | SSH (`:22`), Exporters (`:9100`, `:9101`), DB (`:5432`) |
| **`dns_udp`** | `dns` | UDP | Queries A-record for `example.com` and validates `NOERROR` rcode. | `1.1.1.1:53` (Cloudflare), `8.8.8.8:53` (Google) [External]; Host `127.0.0.53` monitored via systemd |
| **`icmp_probe`** | `icmp` | ICMP Echo | Sends ICMP ping packets to evaluate round-trip latency and packet loss. Requires `NET_RAW` capability. | `host.docker.internal` |

### 5.1 Probe Metrics Taxonomy
When Blackbox probes an endpoint, it exports high-resolution phase latency breakdown metrics:
- **`probe_success`**: $1$ if the probe succeeded according to module rules, $0$ otherwise.
- **`probe_duration_seconds`**: Total wall-clock time for the probe transaction.
- **`probe_dns_lookup_time_seconds`**: Time spent resolving DNS names.
- **`probe_http_status_code`**: Numerical HTTP response code.
- **`probe_ssl_earliest_cert_expiry`**: Epoch timestamp when TLS certificate expires.
- **`probe_failed_due_to_regex`**: $1$ if response body failed regex matching.

---

## 6. On-Call Operational Triage Playbook

When an alert fires in Alertmanager, on-call SREs should follow this fast-triage decision matrix:

| Alert Category | Immediate First-Step Diagnostic Command | Root Cause Remediation Action |
|---|---|---|
| **Host / Exporter Down** | `ping -c 3 127.0.0.1 && systemctl status prometheus-node-exporter.service` | Restart fallen service via `systemctl restart prometheus-node-exporter`. Check kernel dmesg for OOM kill. |
| **Critical CPU Saturation** | `ps -eo pid,ppid,cmd,%cpu --sort=-%cpu \| head -n 15` | Inspect runaway processes. Renice or terminate rogue compilations (`kill -15 <pid>`). |
| **Critical Memory Starvation** | `free -h && vmstat 1 5 && dmesg -T \| grep -i oom \| tail -n 10` | Identify top memory consumers (`ps aux --sort=-%mem`). Free cached buffers or restart leaking services. |
| **Filesystem Critical Space** | `df -hT && du -xh --max-depth=2 / \| sort -hr \| head -n 10` | Clean journal logs (`journalctl --vacuum-time=2d`), prune Docker images (`docker system prune -f`), or purge `/tmp`. |
| **High Disk Latency / PSI** | `iostat -xz 1 5 && cat /proc/pressure/io` | Check background backup dumps or PostgreSQL sync writes. Throttle disk-intensive batch jobs. |
| **Critical Service Inactive** | `systemctl status <unit> && journalctl -u <unit> -n 30 --no-pager` | Review unit failure reason and restart service. |
| **Blackbox Endpoint Down** | `curl -iv <target> && nc -zv <target>` | Check target service process state, port binding (`ss -tulpn`), and Docker bridge network routing. |
