# Alerting & Incident Detection Implementation Report

**Project:** Linux System Monitoring & Reliability Lab  
**Document Ref:** Phase 5.2 — Alert Engineering, Alertmanager Pipeline & Blackbox Synthetics Final Report  
**Author:** Senior Site Reliability Engineer (Agent 7 — Incident Detection & Alert Engineering)  
**Execution Timestamp:** 2026-10-28 15:12:00 IST  
**Target Environment:** Local Ubuntu 24.04 LTS (`rubi`, Linux Kernel `7.0.0-38-generic`, Intel Core i7-1355U, NVMe SSD)  
**Platform Status:** Operational, Empirically Validated & Production-Hardened  

---

## 1. Executive Summary

This engineering report documents the architecture, implementation, formal verification, and empirical validation of the incident detection, alert engineering, Alertmanager routing, and Blackbox synthetic probing platform for the **Linux System Monitoring & Reliability Lab**.

The primary objective was to deliver a reliable, symptom-focused infrastructure alerting system grounded in physical Linux kernel interfaces without inventing metrics, while maintaining zero disruption to host services and strict credential hygiene.

### Key Milestones Delivered:
1. **Infrastructure & Synthetic Alert Rules**:
   - Engineered **29 production-grade alerting rules** across all **16 required failure domains**: Host unavailable, Node Exporter unavailable, Custom Python agent unavailable, High CPU utilization, CPU pressure, Low memory, Memory pressure, Swap thrashing, Filesystem capacity, Predictive fill rate, Inode exhaustion, Disk read/write latency, I/O pressure, Network drops/errors, Critical systemd services, and Synthetic endpoint availability.
   - Enforced duration gating (`for: 1m` to `15m`), diagnostic context annotations, and actionable troubleshooting runbook links.
2. **Alertmanager Incident Routing Pipeline**:
   - Configured multi-tier routing tree with rapid paging for critical outages (`group_wait: 10s`), dedicated warning queues, Blackbox triage, and watchdog heartbeat routing.
   - Engineered **7 cascading inhibition rules** to eliminate alert floods (empirically validated: endpoint down alerts automatically suppress dependent HTTP status and latency alerts).
   - Designed modular notification templates for Slack and Email with diagnostic commands and runbook links.
   - Implemented strict placeholder credential hygiene (`PLACEHOLDER_SMTP_USER`, `PLACEHOLDER_SLACK_WEBHOOK`, `PLACEHOLDER_PAGERDUTY_KEY`).
3. **Blackbox Exporter Synthetic Prober**:
   - Implemented 5 probing modules: `http_2xx`, `http_post_2xx`, `tcp_connect`, `dns_udp`, and `icmp_probe` (with Linux `NET_RAW` capability).
   - Configured Prometheus scrape jobs for HTTP health, TCP sockets, DNS resolution, and ICMP echo with dynamic target relabeling.
4. **Comprehensive Automated & Live Validation**:
   - `promtool check rules`: Passed (29 alert rules verified across 2 rule files).
   - `promtool test rules`: Passed (100% test success across synthetic unit test suite).
   - `amtool check-config`: Passed (global, routes, 7 inhibit rules, 5 receivers, templates verified).
   - `blackbox_exporter --config.check`: Passed (all 5 prober modules verified).
   - `promtool check config`: Passed (Prometheus server config with 72 total rules verified).
   - Live Prometheus TSDB & Alertmanager: Actively ingesting metrics, discovering `http://alertmanager:9093`, executing probes, evaluating rules, and firing alerts with active inhibition.

---

## 2. Platform Architecture & Coexistence Topology

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Native Services (Preserved & Untouched):                             │
│   • Native Prometheus (:9090) ── [SYSTEMD ACTIVE - UNTOUCHED]          │
│   • Native Grafana (:3000)    ── [SYSTEMD ACTIVE - UNTOUCHED]          │
│   • Native Node Exporter (:9100) ── [Direct Kernel Telemetry]         │
│   • Host SSH (:22)            ── [Direct Host Access]                  │
│                                 ▲                                      │
│                ┌────────────────┴───────────────┐                      │
│                │                                │                      │
│     ┌──────────┴─────────────┐      ┌───────────┴────────────┐         │
│     │ Node Exporter (:9100)  │      │ Custom Agent (:9101)   │         │
│     │ [Direct Kernel Metrics]│      │ [Process & Systemd]    │         │
│     └──────────┬─────────────┘      └───────────┬────────────┘         │
│                │                                │                      │
│                │ HTTP Metrics Pull              │ HTTP Metrics Pull    │
│                │ via host.docker.internal       │                      │
│                └────────────────┬───────────────┘                      │
│                                 │                                      │
│                                 ▼                                      │
│     ┌────────────────────────────────────────────────────────────┐     │
│     │             CONTAINERIZED OBSERVABILITY STACK              │     │
│     │                                                            │     │
│     │  ┌───────────────────────┐      ┌───────────────────────┐  │     │
│     │  │   Prometheus (:9091)  │─────▶│ Alertmanager (:9093)  │  │     │
│     │  │   • Rule Engine       │Push  │ • lab-alertmanager    │  │     │
│     │  │   • 72 Total Rules    │      │ • Grouping & Inhib    │  │     │
│     │  │   • lab-prometheus    │      │ • Multi-Tier Routing  │  │     │
│     │  └───────────▲───────────┘      └───────────┬───────────┘  │     │
│     │              │                              │              │     │
│     │              │ Scrape /probe                │ Dispatches   │     │
│     │              │                              ▼              │     │
│     │  ┌───────────┴───────────┐      ┌───────────────────────┐  │     │
│     │  │ Blackbox Exp (:9115)  │      │ Notification Sinks    │  │     │
│     │  │ • lab-blackbox-exp    │      │ • Mock Webhook (:5001)│  │     │
│     │  │ • HTTP, TCP, DNS, ICMP│      │ • PagerDuty / Slack   │  │     │
│     │  └───────────┬───────────┘      │   (Placeholders)      │  │     │
│     │              │                  └───────────────────────┘  │     │
│     └──────────────┼─────────────────────────────────────────────┘     │
│                    │ Synthetic Probes                                  │
│                    ▼                                                   │
│   Host Endpoints (host.docker.internal:22, :9100, :9101, :9090, :9093) │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Host Isolation & Safety Compliance
- **Zero Host Modification**: No systemd services were stopped, disabled, masked, or altered.
- **Strict Loopback Binding**: All container ports (`127.0.0.1:9091` Prometheus, `127.0.0.1:9093` Alertmanager, `127.0.0.1:9115` Blackbox) bind exclusively to loopback, preventing exposure to physical interfaces (`wlo1`).
- **Network Isolation**: Containers communicate internally across the Docker bridge network `prometheus_default`.
- **Zero Real Secrets**: All receiver definitions use non-functional, secure placeholder keys.

---

## 3. Configuration Files Delivered

The following configuration assets were engineered, deployed, and verified:

| File Path | Component | Purpose | Lines | Verification Status |
|---|---|---|---|---|
| `prometheus/alerts/infrastructure_alerts.yml` | Prometheus Rules | Host, compute, memory, storage, I/O, network, and systemd alerts | 258 | Verified (`23 rules, promtool`) |
| `prometheus/alerts/blackbox_alerts.yml` | Prometheus Rules | Synthetic endpoint, HTTP, TCP, DNS, latency, and SSL cert alerts | 83 | Verified (`6 rules, promtool`) |
| `prometheus/tests/alert_tests.yml` | Promtool Tests | Synthetic unit test cases for alert durations, pending states, and labels | 146 | Verified (`SUCCESS`) |
| `alertmanager/alertmanager.yml` | Alertmanager | Grouping, deduplication, 7 inhibition rules, 5 receivers, routing tree | 118 | Verified (`amtool check-config`) |
| `alertmanager/templates/alerts.tmpl` | Templates | Slack and HTML Email notification formatting with triage commands | 65 | Verified (`amtool check-config`) |
| `alertmanager/docker-compose.yml` | Runtime | Containerized Alertmanager service (`127.0.0.1:9093:9093`) | 32 | Verified (`docker compose up`) |
| `blackbox/blackbox.yml` | Blackbox | 5 prober modules (`http_2xx`, `http_post_2xx`, `tcp_connect`, `dns_udp`, `icmp_probe`) | 53 | Verified (`--config.check`) |
| `blackbox/docker-compose.yml` | Runtime | Containerized Blackbox service (`127.0.0.1:9115:9115`) with `NET_RAW` | 27 | Verified (`docker compose up`) |
| `prometheus/prometheus.yml` | Prometheus Core | Coordinated shared config: Alertmanager target, rules, 4 Blackbox scrape jobs | 154 | Verified (`promtool check config`) |
| `prometheus/docker-compose.yml` | Prometheus Stack | Coordinated shared compose: volume mount for `./alerts` read-only | 55 | Verified (`docker compose up`) |
| `docs/monitoring/alerting-and-incident-detection.md` | Documentation | SRE alerting manual, alert catalog, inhibition mechanics, triage playbooks | 370 | Verified |
| `docs/reports/alerting-implementation-report.md` | Report | Final engineering implementation and verification report | Current | Completed |

---

## 4. Alert Catalog & Severity Rationale (16 Domains)

Every alert includes a clear name, severity, PromQL expression, duration threshold, summary, description, diagnostic command, and runbook link:

| # | Alert Name | Subsystem | Severity | Expression Summary | Duration | SRE Justification & Threshold Rationale |
|---|---|---|---|---|---|---|
| 1 | `HostUnavailable` | `host` | `critical` | Exporters or ICMP echo probe down | `2m` | Critical outage. Machine powered off, kernel panic'd, or network partition. |
| 2 | `NodeExporterUnavailable` | `observability` | `critical` | `up{job="node"} == 0` | `2m` | Hardware and kernel metrics unobserved. Daemon crashed or port blocked. |
| 3 | `PythonAgentUnavailable` | `custom_agent` | `warning` | `up{job="python-agent"} == 0` | `2m` | Custom process and systemd telemetry offline. Agent process down. |
| 4a | `HostHighCpuUtilizationWarning` | `cpu` | `warning` | Active CPU > 85% | `5m` | Approaching saturation on 12-core host; task queueing begins. |
| 4b | `HostHighCpuUtilizationCritical`| `cpu` | `critical` | Active CPU > 95% | `3m` | Severe compute saturation; latency-sensitive workloads will stall. |
| 5 | `HostCpuPressureHigh` | `cpu` | `warning` | PSI CPU waiting > 25% | `5m` | Tasks spend >25% of time waiting for CPU time slices in run-queues. |
| 6a | `HostLowMemoryAvailable` | `memory` | `warning` | `MemAvailable / MemTotal < 0.10` | `5m` | <10% true headroom remaining. Reclaim accelerating; cache dropping. |
| 6b | `HostCriticalMemoryAvailable` | `memory` | `critical` | `MemAvailable / MemTotal < 0.05` | `2m` | Acute memory starvation (<5%). Kernel OOM killer invocation imminent. |
| 7a | `HostMemoryPressureWaiting` | `memory` | `warning` | PSI memory waiting (`some`) > 20% | `3m` | Tasks stalling in direct page reclaim or swap-in. |
| 7b | `HostMemoryPressureStalled` | `memory` | `critical` | PSI memory stalled (`full`) > 10% | `2m` | All non-idle tasks stalled on memory allocation. Complete execution freeze. |
| 8 | `HostSwapThrashingActive` | `swap` | `warning` | Swap I/O > 10 MB/s and MemAvail < 15% | `3m` | Distinguishes inactive cold swap from dynamic latency-inducing thrashing. |
| 9a | `HostFilesystemSpaceWarning` | `storage` | `warning` | Available blocks < 15% (ext4/xfs) | `10m` | Capacity depletion warning. Filters out snaps and tmpfs mounts. |
| 9b | `HostFilesystemSpaceCritical`| `storage` | `critical` | Available blocks < 5% (ext4/xfs) | `3m` | Imminent `ENOSPC` write failures for applications and system logging. |
| 10 | `HostFilesystemFillRatePredict`| `storage` | `warning` | `predict_linear` fills in < 4h & < 25% | `15m` | Predictive linear regression. Catches runaway logs before static limits. |
| 11a| `HostInodeExhaustionWarning` | `storage` | `warning` | Free inodes < 10% (ext4/xfs) | `10m` | High density of small files or unrotated logs. |
| 11b| `HostInodeExhaustionCritical`| `storage` | `critical` | Free inodes < 2% (ext4/xfs) | `3m` | File creation will fail with `ENOSPC` even if byte capacity remains. |
| 12a| `HostDiskReadLatencyHigh` | `disk_io` | `warning` | Read latency ($r\_await$) > 30ms | `5m` | NVMe/SSD read queue saturation or NAND controller stalls. |
| 12b| `HostDiskWriteLatencyHigh` | `disk_io` | `warning` | Write latency ($w\_await$) > 50ms | `5m` | Write queue bottleneck or un-flushed dirty page flushes. |
| 13a| `HostIoPressureWaitingHigh` | `disk_io` | `warning` | PSI I/O waiting (`some`) > 25% | `5m` | Tasks entering uninterruptible sleep (`D` state) waiting for storage. |
| 13b| `HostIoPressureStalledCritical`| `disk_io` | `critical` | PSI I/O stalled (`full`) > 10% | `2m` | System-wide block layer freeze. Controller lockup or write stall. |
| 14a| `HostNetworkDropsHigh` | `network` | `warning` | Packet drops > 10/s | `5m` | NIC ring buffer overflow or socket backlog saturation on physical NIC. |
| 14b| `HostNetworkErrorsDetected` | `network` | `critical` | Packet errors > 0 | `2m` | Physical layer CRC errors, frame align, or FIFO overrun. |
| 15 | `HostCriticalServiceDown` | `systemd` | `critical` | `ssh`, `docker`, `journald`, `prom` inactive | `1m` | Essential system service inactive. Operator triage required. |
| 16a| `BlackboxEndpointDown` | `blackbox` | `critical` | `probe_success == 0` | `1m` | Synthetic probe failed. Target service offline or connection rejected. |
| 16b| `BlackboxHttpProbeFailed` | `blackbox` | `critical` | HTTP status non-2xx | `1m` | Target application returning 4xx/5xx error responses. |
| 16c| `BlackboxProbeLatencyHigh` | `blackbox` | `warning` | Probe duration > 1.0s | `3m` | Degraded response latency. Approaching SLA breach. |
| 16d| `BlackboxProbeSlowCritical` | `blackbox` | `critical` | Probe duration > 3.0s | `1m` | Severe latency near 5.0s probe timeout. Worker thread exhaustion. |
| 16e| `BlackboxSslCertExpiring` | `blackbox` | `warning` | SSL cert expiry < 14 days | `1h` | TLS certificate expiration warning. Action required before browser block. |
| 16f| `BlackboxTcpConnectFailed` | `blackbox` | `critical` | TCP handshake failed | `1m` | Port closed or dropped by firewall. |

---

## 5. Alertmanager Specification & Empirical Inhibition Proof

### 5.1 Route Tree Hierarchy
```yaml
route:
  receiver: 'default-webhook'
  group_by: ['alertname', 'instance', 'subsystem']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: 'pager-critical'
      matchers: [severity = critical]
      group_wait: 10s
      group_interval: 2m
      repeat_interval: 1h
    - receiver: 'slack-warnings'
      matchers: [severity = warning]
      group_wait: 1m
      group_interval: 10m
      repeat_interval: 6h
    - receiver: 'blackbox-responder'
      matchers: [subsystem = blackbox]
      group_wait: 15s
      group_interval: 3m
      repeat_interval: 2h
    - receiver: 'deadmansswitch-heartbeat'
      matchers: [alertname = Watchdog]
      group_wait: 0s
      repeat_interval: 12h
```

### 5.2 Empirical Inhibition Validation
During live runtime verification, the custom Python agent was offline on port `9101`. Both `BlackboxEndpointDown` and `BlackboxHttpProbeFailed` were triggered simultaneously for target `http://host.docker.internal:9101/metrics`.

Querying the live Alertmanager API confirmed active suppression:
```json
{
  "alertname": "BlackboxEndpointDown",
  "instance": "http://host.docker.internal:9101/metrics",
  "severity": "critical",
  "state": "active"
}
{
  "alertname": "BlackboxHttpProbeFailed",
  "instance": "http://host.docker.internal:9101/metrics",
  "severity": "critical",
  "state": "suppressed"
}
```
**Conclusion**: `BlackboxHttpProbeFailed` was successfully **`suppressed`** by Alertmanager inhibition rule 7, proving that cascade alert storms are effectively prevented.

---

## 6. Blackbox Exporter Probing Specification

The Blackbox Exporter (`prom/blackbox-exporter:v0.25.0`) executes synthetic probes across 5 modules:

1. **`http_2xx`**: HTTP GET validating 2xx status codes and TLS certificate validity.
2. **`http_post_2xx`**: HTTP POST transmitting JSON payload `{"probe": "synthetic_healthcheck"}`.
3. **`tcp_connect`**: 3-way TCP socket handshake validation.
4. **`dns_udp`**: DNS UDP query for `localhost` A-record with `NOERROR` rcode check.
5. **`icmp_probe`**: ICMP Echo probe running with container `cap_add: [NET_RAW]`.

### 6.1 Empirical Target Probing Telemetry
Probes executed against host and container targets verified the following live metrics:

| Scrape Job | Target Monitored | Probe Module | `probe_success` | `probe_duration_seconds` | `probe_http_status_code` | Status |
|---|---|---|---|---|---|---|
| `blackbox-http` | `http://host.docker.internal:9100/metrics` | `http_2xx` | `1` | `0.419s` | `200` | UP (Node Exporter healthy) |
| `blackbox-http` | `http://lab-prometheus:9090/-/healthy` | `http_2xx` | `1` | `0.003s` | `200` | UP (Prometheus healthy) |
| `blackbox-http` | `http://alertmanager:9093/-/healthy` | `http_2xx` | `1` | `0.002s` | `200` | UP (Alertmanager healthy) |
| `blackbox-tcp` | `host.docker.internal:22` | `tcp_connect` | `1` | `0.006s` | N/A | UP (Host SSH responsive) |
| `blackbox-tcp` | `host.docker.internal:9100` | `tcp_connect` | `1` | `0.003s` | N/A | UP (Node Exporter socket open) |
| `blackbox-tcp` | `alertmanager:9093` | `tcp_connect` | `1` | `0.002s` | N/A | UP (Alertmanager socket open) |
| `blackbox-icmp` | `host.docker.internal` | `icmp_probe` | `1` | `0.001s` | N/A | UP (Host ICMP ping responsive) |
| `blackbox-http` | `http://host.docker.internal:9101/metrics` | `http_2xx` | `0` | `0.002s` | `0` | DOWN (Python agent offline - alert firing) |
| `blackbox-tcp` | `host.docker.internal:9101` | `tcp_connect` | `0` | `0.001s` | N/A | DOWN (Port 9101 closed - alert firing) |

---

## 7. Automated Verification Results

| Tool | Target File | Output / Result | Verification Status |
|---|---|---|---|
| `promtool check rules` | `prometheus/alerts/infrastructure_alerts.yml` | `SUCCESS: 23 rules found` | **PASSED** |
| `promtool check rules` | `prometheus/alerts/blackbox_alerts.yml` | `SUCCESS: 6 rules found` | **PASSED** |
| `promtool test rules` | `prometheus/tests/alert_tests.yml` | `Unit Testing: SUCCESS` | **PASSED** |
| `amtool check-config` | `alertmanager/alertmanager.yml` | `Checking: SUCCESS (global, route, 7 inhibit rules, 5 receivers, 1 templates)` | **PASSED** |
| `blackbox_exporter` | `blackbox/blackbox.yml` | `msg="Config file is ok exiting..."` | **PASSED** |
| `promtool check config` | `prometheus/prometheus.yml` | `SUCCESS: 4 rule files found, 72 rules found` | **PASSED** |

---

## 8. Safety, Credential Hygiene & Limitations

### 8.1 Safety Compliance Audit
- **Zero Unsolicited Notifications**: During lab validation, notifications route strictly to `default-webhook` (`http://host.docker.internal:5001/api/alerts`). No external webhooks or emails were transmitted.
- **Zero Real Credentials Committed**: All external credentials use explicit placeholder tokens (`PLACEHOLDER_SMTP_USER`, `PLACEHOLDER_PAGERDUTY_INTEGRATION_KEY`, `PLACEHOLDER_SLACK_WEBHOOK`).
- **Loopback Enforcement**: All management ports (`9091`, `9093`, `9115`) bind to `127.0.0.1`.
- **Zero Native Service Interference**: Host systemd services remained running and unaffected throughout.

### 8.2 Operational Limitations
1. **Mock Webhook Sink**: The `default-webhook` expects an HTTP listener on port `5001`. If no local webhook listener is active, Alertmanager logs an HTTP delivery warning after retrying; this does not affect alert state or inhibition inside Alertmanager.
2. **ICMP Probe Capabilities**: ICMP probing relies on the Docker container receiving `cap_add: [NET_RAW]`. On restrictive container runtimes without raw socket capabilities, TCP socket probing (`tcp_connect`) should be used as the preferred availability prober.

---

## 9. Handoff & Next Steps

1. **Grafana Dashboards (Phase 4)**: Alert status panels can be embedded into Grafana by querying Prometheus alerts (`ALERTS{alertstate="firing"}`) or Alertmanager data source plugins.
2. **Loki Log Aggregation (Phase 6)**: During incident triage, operators can link Prometheus alert timestamps directly to Loki journald queries using the diagnostic commands provided in the alert annotations.
3. **Automated Remediation (Phase 8)**: Self-healing daemons can subscribe to the Alertmanager webhook endpoint (`/api/alerts`) to trigger automated service recovery with circuit breakers.

---

*Report submitted by Agent 7 (Senior SRE — Alertmanager & Blackbox Monitoring Engineer).*
