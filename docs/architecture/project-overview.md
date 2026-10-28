# Architecture & System Design Overview

**Project:** Linux System Monitoring & Reliability Lab  
**Document Status:** Foundation Architecture Specification (Phase 0)  
**Author:** Senior Site Reliability & Observability Engineer  

---

## 1. High-Level System Architecture

The Linux System Monitoring & Reliability Lab couples native Linux kernel observability with an automated containerized monitoring platform. 

The primary architectural principle is **direct host instrumentation**: metric collectors execute directly on the physical Ubuntu host to access bare-metal kernel counters (`/proc`, `/sys`, `cgroups`, `systemd`), while the time-series storage, alert routing, and visualization engines run inside managed container environments.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Kernel Subsystems:                                                   │
│   • /proc/stat (CPU time, context switches)                            │
│   • /proc/meminfo (Active, Inactive, Dirty, Buffers, Cache)            │
│   • /proc/diskstats (I/O operations, sectors, ms in I/O)               │
│   • /proc/net/dev (RX/TX bytes, packets, drops, errors)                │
│   • systemd D-Bus (Unit states, restarts, failures)                    │
│                                 ▲                                      │
│                ┌────────────────┴───────────────┐                      │
│                │                                │                      │
│     ┌──────────┴─────────────┐      ┌───────────┴────────────┐         │
│     │ Node Exporter (:9100)  │      │ Custom Agent (:9101)   │         │
│     │ Status: [HOST SYSTEMD] │      │ Status: [PLANNED PH 2] │         │
│     └──────────┬─────────────┘      └───────────┬────────────┘         │
│                │                                │                      │
│                │ HTTP Metrics Scrape            │ HTTP Metrics Scrape  │
│                └────────────────┬───────────────┘                      │
│                                 │                                      │
│                                 ▼                                      │
│     ┌────────────────────────────────────────────────────────────┐     │
│     │           OBSERVABILITY ENGINE (DOCKER COMPOSE)            │     │
│     │                                                            │     │
│     │  ┌───────────────────────┐      ┌───────────────────────┐  │     │
│     │  │   Prometheus (:9090)  │─────▶│ Alertmanager (:9093)  │  │     │
│     │  │   TSDB & PromQL Engine│      │ Alert Group & Route   │  │     │
│     │  │   Status: [PLANNED]   │      │ Status: [PLANNED PH5] │  │     │
│     │  └───────────┬───────────┘      └───────────┬───────────┘  │     │
│     │              │                              │                      │
│     │              ▼                              ▼                      │
│     │  ┌───────────────────────┐      ┌───────────────────────┐  │     │
│     │  │    Grafana (:3000)    │      │ Webhook / Telegram    │  │     │
│     │  │    Dashboards & SLIs  │      │ Notification Channel  │  │     │
│     │  │    Status: [PLANNED]   │      │ Status: [PLANNED PH5] │  │     │
│     │  └───────────────────────┘      └───────────────────────┘  │     │
│     │              ▲                                             │     │
│     │              │ LogQL                                       │     │
│     │  ┌───────────┴───────────┐      ┌───────────────────────┐  │     │
│     │  │   Grafana Loki (:3100)│◀─────│ Blackbox Exp (:9115)  │  │     │
│     │  │   Log Aggregation     │      │ Endpoint Probing      │  │     │
│     │  │   Status: [PLANNED PH6│      │ Status: [PLANNED PH3] │  │     │
│     │  └───────────────────────┘      └───────────────────────┘  │     │
│     └────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Major Components & Implementation Status

To maintain engineering clarity, each component is explicitly categorized by its implementation lifecycle:

| Component | Layer | Execution Target | Port | Status | Purpose |
|---|---|---|---|---|---|
| **Node Exporter** | Host Telemetry | Host (systemd) | `9100` | **Existing** (Host deb package active) | Exports kernel CPU, memory, disk, network, and system uptime counters |
| **Custom Agent** | Custom Telemetry | Host (Python service) | `9101` | **Planned (Phase 2)** | Custom psutil-based metrics collector and Prometheus HTTP exporter |
| **Bash Diagnostics** | Automation | Host CLI scripts | CLI | **Planned (Phase 2)** | Standalone POSIX Bash diagnostic tools for operator intervention |
| **Prometheus** | Metrics TSDB | Container / Compose | `9090` | **Planned (Phase 3)** | Scrapes targets, evaluates alert rules, evaluates PromQL queries |
| **Blackbox Exporter** | Synthetics | Container / Compose | `9115` | **Planned (Phase 3)** | Synthetically probes HTTP, TCP, and ICMP endpoints |
| **Grafana** | Visualization | Container / Compose | `3000` | **Planned (Phase 4)** | Renders operational dashboards and tracks SLO metrics |
| **Alertmanager** | Incident Mgmt | Container / Compose | `9093` | **Planned (Phase 5)** | Groups, deduplicates, silences, and routes alerts to notification sinks |
| **Loki & Alloy** | Log Intelligence| Container / Compose | `3100` | **Planned (Phase 6)** | Ingests structured host logs from `journald` and enables LogQL correlation |
| **Remediation Daemon**| Self-Healing | Host (Python service) | Background | **Planned (Phase 8)** | Automated recovery handler with retry limits and circuit breaking |

---

## 3. Metrics Collection Architecture

Prometheus utilizes a pull-based metrics collection architecture. Every scrape interval (e.g., 15 seconds), Prometheus issues an HTTP GET request to `/metrics` endpoints.

### 3.1 Host Telemetry Flow
```
[Kernel Counters]
   ├── /proc/stat
   ├── /proc/meminfo
   ├── /proc/diskstats
   └── /proc/net/dev
          │
          ▼
 [Node Exporter :9100]  ──(Prometheus Pull)──▶ [Prometheus TSDB]
                                                     │
                                                     ▼
                                          [PromQL Query Engine]
```

### 3.2 Custom Metrics Flow
Our custom Python agent samples granular process-level and service-level data not provided out-of-the-box by standard exporters:
- Process state counts (`running`, `sleeping`, `zombie`, `stopped`).
- High-resolution systemd unit state verification.
- Custom memory saturation markers (`linux_custom_memory_pressure`).
- Exposes metrics via Python Prometheus client at `http://localhost:9101/metrics`.

---

## 4. Alerting Architecture & Incident Flow

Alerting follows SRE best practices to prevent alert noise and fatigue:
1. **Rule Evaluation**: Prometheus evaluates PromQL alert expressions every 15 seconds against stored time-series data.
2. **Pending State**: An alert condition must remain true for a duration threshold (`for: 5m`) before moving from `PENDING` to `FIRING`.
3. **Alertmanager Ingestion**: Firing alerts are sent via HTTP POST to Alertmanager (`:9093`).
4. **Grouping & Deduplication**: Alertmanager aggregates related alerts (e.g., multiple alerts sharing `instance="rubi"`) into a single notification event.
5. **Inhibition**: Critical alerts automatically suppress dependent warning alerts (e.g., `NodeDown` inhibits `HighCPUUsage`).
6. **Notification Routing**: Alerts are routed to webhook receivers or notification endpoints (Telegram / Discord / Slack).

```
[PromQL Rule Evaluator]
          │
          │ (Condition true > threshold)
          ▼
   [Alert: FIRING]
          │
          ▼
 [Alertmanager :9093]
    ├── 1. Deduplication
    ├── 2. Grouping by Cluster/Host
    ├── 3. Inhibition of Cascades
    └── 4. Silencing Filters
          │
          ▼
 [Notification Dispatcher] ──▶ [Telegram / Webhook]
```

---

## 5. Log Aggregation Architecture (Phase 6)

Incident troubleshooting requires correlating **metrics anomalies** with **system log messages**.
- **Log Source**: `systemd-journald` captures structured logs for kernel events (`kmsg`), SSH auth attempts, system service lifecycle transitions, and core dumps.
- **Log Collector**: Grafana Alloy (or Promtail) tails `/var/log/journal/` and system files.
- **Log Indexing**: Grafana Loki indexes metadata labels (e.g., `job="systemd"`, `unit="ssh.service"`, `level="error"`) without indexing full log text, optimizing storage efficiency.
- **Querying**: Grafana combines PromQL (metrics) and LogQL (logs) in a unified split-screen view.

---

## 6. SRE Reliability Engineering Objectives

The platform is designed around quantitative reliability engineering:

### 6.1 Service Level Indicators (SLIs)
- **Availability SLI**: Ratio of successful synthetic endpoint probes over total probes:
  $$\text{SLI}_{\text{avail}} = \frac{\sum \text{successful probes}}{\sum \text{total probes}} \times 100$$
- **Latency SLI**: 95th percentile ($p95$) response latency of the monitored service:
  $$\text{SLI}_{\text{latency}} = \text{histogram\_quantile}(0.95, \text{rate}(\text{http\_request\_duration\_seconds\_bucket}[5m]))$$
- **Error Rate SLI**: Percentage of failed requests against total requests.

### 6.2 Service Level Objectives (SLOs)
- Target Availability: **99.9%** across a 30-day sliding window.
- Target Latency: 95% of synthetic health requests completed under 500 ms.
- Error Rate: Less than 0.1% failed transactions.

### 6.3 Error Budgets
For a 99.9% SLO across 30 days:
- **Allowed Downtime**: 43 minutes and 12 seconds per 30-day window.
- The platform will track **burn rate** alerting to warn operators when the error budget is exhausting faster than sustainable.

---

## 7. Safety & Isolation Guardrails

Because this lab executes on a physical workstation:
1. **Storage Protection**: No disk saturation test may write directly to the root mount (`/`). Tests will operate within bounded tmpfs or loopback mounts with pre-allocated size limits.
2. **Memory Protection**: Memory stress tests (`stress-ng --vm`) will be bounded to a fraction of available RAM (max 2 GiB) to avoid triggering the host Linux Out-Of-Memory (OOM) killer on desktop applications.
3. **Network Protection**: Network partition experiments will use isolated Docker bridge networks or network namespaces (`ip netns`), never dropping `wlo1` or physical interfaces.
4. **Remediation Guardrails**: The automated remediation controller will enforce exponential backoff, retry limits (maximum 3 attempts), and a 10-minute cooldown window to prevent destructive service restart loops.
