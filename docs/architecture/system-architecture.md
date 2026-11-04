# System Architecture

**Project:** Linux System Monitoring & Reliability Lab  
**Scope:** Host Metrics, Container Observability, Centralized Logging & Automated Remediation  

---

## 1. Architectural Philosophy & Coexistence Model

The **Linux System Monitoring & Reliability Lab** is engineered around the principle of **direct host instrumentation paired with containerized observability isolation**.

### 1.1 Coexistence Invariants with Native Host Services

The host system may run native instances of Prometheus (port `9090`) or Grafana (port `3000`), managed directly via systemd. Under no circumstances may the lab monitoring stack collide with, disrupt, or reconfigure these native services.

To ensure non-interference:
1. **Loopback Binding Isolation:** Every containerized lab service binds strictly to `127.0.0.1` (never `0.0.0.0`).
2. **Dedicated Port Allocations:**
   - Lab Prometheus: `127.0.0.1:9091` -> Container `9090`
   - Lab Grafana: `127.0.0.1:3001` -> Container `3000`
   - Lab Alertmanager: `127.0.0.1:9093` (or `9094`) -> Container `9093`
   - Lab Blackbox Exporter: `127.0.0.1:9115` -> Container `9115`
   - Lab Loki: `127.0.0.1:3100` -> Container `3100`
   - Lab Alloy: `127.0.0.1:12345` -> Container `12345`
   - Native Node Exporter: Port `9100` (Native host systemd service, default wildcard `0.0.0.0`)
   - Custom Python Monitoring Agent: `127.0.0.1:9101` (Host Python daemon)
3. **Dedicated Docker Bridge Network:** All containerized lab components communicate across a private, isolated bridge network named `lab_monitoring_network` (`lab-monitoring-net`, `172.28.0.0/16`) using internal container DNS names (`prometheus:9090`, `alertmanager:9093`, `blackbox-exporter:9115`, `loki:3100`).

---

## 2. End-to-End System Architecture

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              UBUNTU 24.04 LINUX HOST                                   │
│                                                                                        │
│   Kernel Subsystems & Hardware Counters:                                               │
│   • /proc/stat, /proc/cpuinfo, /proc/pressure/cpu (CPU & PSI)                          │
│   • /proc/meminfo, /proc/vmstat, /proc/pressure/memory (Memory & Swap)                 │
│   • /proc/diskstats, sysfs queue metrics, mount tables (Storage & I/O)                 │
│   • /proc/net/dev, /proc/net/sockstat, TCP diag sockets (Network)                      │
│   • systemd D-Bus, binary journals (/var/log/journal)                                  │
│                                      ▲                                                 │
│                     ┌────────────────┴────────────────┐                                │
│                     │                                 │                                │
│      ┌──────────────┴──────────────┐   ┌──────────────┴──────────────┐                 │
│      │ Native Node Exporter (:9100)│   │ Custom Python Agent (:9101) │                 │
│      │ Host systemd daemon         │   │ 9 Kernel/Process Collectors │                 │
│      └──────────────┬──────────────┘   └──────────────┬──────────────┘                 │
│                     │                                 │                                │
│                     │ Scraped via host.docker.internal│                                │
│                     └────────────────┬────────────────┘                                │
│                                      │                                                 │
│                                      ▼                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │             CONTAINERIZED LAB OBSERVABILITY STACK (Docker Bridge Network)        │  │
│  │                        Subnet: 172.28.0.0/16 (lab-monitoring-net)                │  │
│  │                                                                                  │  │
│  │   ┌──────────────────────────────────────────────────────────────────────────┐   │  │
│  │   │ PROMETHEUS SERVER (lab-prometheus :9091 -> :9090)                        │   │  │
│  │   │ • TSDB Storage (15d retention / 10GB limit)                              │   │  │
│  │   │ • Scrape Pipeline (node, python-agent, self, blackbox probes)            │   │  │
│  │   │ • Recording Rules (recording_rules.yml, sre_rules.yml)                   │   │  │
│  │   │ • Infrastructure Alerts (infrastructure_alerts.yml, blackbox_alerts.yml) │   │  │
│  │   └───────────────┬──────────────────────────────┬───────────────────────────┘   │  │
│  │                   │                              │                               │  │
│  │       Alert Push  │                              │ PromQL Queries                │  │
│  │                   ▼                              ▼                               │  │
│  │   ┌──────────────────────────────┐   ┌──────────────────────────────┐            │  │
│  │   │ ALERTMANAGER (:9093)         │   │ GRAFANA (:3001 -> :3000)     │            │  │
│  │   │ • Notification Routing Tree  │   │ • Dashboards 01–05           │            │  │
│  │   │ • Inhibition Rules           │   │ • Auto-provisioned Sources   │            │  │
│  │   │ • Webhook / Slack Templates  │   │ • SRE SLI/SLO Visualization  │            │  │
│  │   └──────────────────────────────┘   └──────────────▲───────────────┘            │  │
│  │                                                     │ LogQL Queries              │  │
│  │   ┌──────────────────────────────┐                  │                            │  │
│  │   │ BLACKBOX EXPORTER (:9115)    │   ┌──────────────┴───────────────┐            │  │
│  │   │ • HTTP / TCP / DNS / ICMP    │   │ GRAFANA LOKI (:3100)         │            │  │
│  │   │ • cap_add: [NET_RAW]         │   │ • TSDB v13 Log Engine        │            │  │
│  │   └───────────────▲──────────────┘   │ • Retention Compactor (7d)   │            │  │
│  │                   │                  └──────────────▲───────────────┘            │  │
│  │                   │ Probing                         │ Log Push (HTTP)            │  │
│  │                   │                  ┌──────────────┴───────────────┐            │  │
│  │                   │                  │ GRAFANA ALLOY (:12345)       │            │  │
│  │                   │                  │ • Reads /var/log/journal     │            │  │
│  │                   │                  │ • User 0:999 (systemd-journal)│            │  │
│  │                   │                  └──────────────▲───────────────┘            │  │
│  └───────────────────┼─────────────────────────────────┼────────────────────────────┘  │
│                      │                                 │ Host Journal Mount            │
│                      └──────────────────┬──────────────┘                               │
│                                         │                                              │
│                                         ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                SRE RELIABILITY, CHAOS & SELF-HEALING FRAMEWORK                   │  │
│  │                                                                                  │  │
│  │   ┌──────────────────────────────┐   ┌──────────────────────────────┐            │  │
│  │   │ FAILURE INJECTORS (01–09)    │   │ AUTOMATED RUNBOOKS (01–06)   │            │  │
│  │   │ • CPU Contention (load cores)│   │ • Remediate CPU Contention   │            │  │
│  │   │ • Memory Pressure (cgroup)   │   │ • Remediate Memory Leak      │            │  │
│  │   │ • Filesystem Space & Inodes  │   │ • Clear Disk Space / Inodes  │            │  │
│  │   │ • Network / Systemd Failures │   │ • Restart Agent / Systemd    │            │  │
│  │   └───────────────┬──────────────┘   └──────────────▲───────────────┘            │  │
│  │                   │                                 │                            │  │
│  │                   ▼                                 │ Execution Trigger          │  │
│  │   ┌─────────────────────────────────────────────────┴────────┐                   │  │
│  │   │ LIFECYCLE TRACKER (scripts/reliability/lifecycle_tracker.py)                     │
│  │   │ Calculates MTTD, MTTR, Telemetry Correlation & Generates RCA Markdown Logs    │  │
│  │   └──────────────────────────────────────────────────────────┘                   │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Subsystem Interactions & Bidirectional Data Flows

### 3.1 Host Metrics Collection Data Flow

```
[Physical Host Subsystems]
   ├── /proc/stat, /proc/meminfo, /proc/diskstats
   │      │
   │      ▼
   │  [Node Exporter :9100] ──(HTTP GET /metrics)──┐
   │                                               ▼
   └── psutil, cgroups, D-Bus, sockets             │
          │                                        │
          ▼                                        │
      [Custom Python Agent :9101] ─────────────────┤
                                                   │
                                                   ▼
                                         [Prometheus Server :9090]
                                                   │
                                        Evaluates Recording Rules
                                        Evaluates Alerting Rules
                                                   │
                                                   ├──▶ [Alertmanager :9093]
                                                   └──▶ [Grafana :3000]
```

1. **Scrape Execution:** Every 15 seconds, Prometheus dispatches HTTP GET requests to `host.docker.internal:9100` and `host.docker.internal:9101`.
2. **Gateway Resolution:** In Docker for Linux/Desktop, `host.docker.internal` resolves to the host's internal bridge IP address (`host-gateway`), allowing secure ingress from containers to host-bound loopback exporters.
3. **TSDB Storage:** Samples are written to the TSDB in `/prometheus` with write-ahead logging (WAL) and compacted into 2-hour blocks.
4. **Recording Rules:** Prometheus pre-computes rolling rate averages, utilization percentages, and SRE availability ratios every 15 seconds.

### 3.2 Host Log Collection & Correlation Flow

```
[Linux Kernel & systemd Services]
   │
   ▼
[/var/log/journal/ binary journal files]
   │
   ▼ (Read-Only Host Mount)
[Grafana Alloy Container (:12345)]
   │ Filters, parses, and extracts structured metadata
   │ (service, unit, priority, syslog_facility)
   ▼ (HTTP POST /loki/api/v1/push)
[Grafana Loki Container (:3100)]
   │ Indexes labels in TSDB v13 format
   │ Compactor flushes chunks to filesystem (/loki/chunks)
   ▼
[Grafana Dashboard Panel (LogQL)]
```

1. **Journal Access:** Grafana Alloy mounts `/var/log/journal` and `/etc/machine-id` read-only, running as `user: "0:999"` (root user with primary GID 999 `systemd-journal`). Primary GID 999 grants read access to mode 0640 journal files, while UID 0 is retained due to existing persistent volume ownership (`lab_alloy_data` owned by `0:4`). Hardening is enforced via `read_only: true`, `cap_drop: [ALL]`, and `no-new-privileges:true`.
2. **Ingestion & Labeling:** Alloy translates binary journal entries into structured streams tagged with `job="systemd-journal"`, `unit`, and `priority`.
3. **LogQL Exploration:** Operators in Grafana can click directly from a CPU or memory spike in Prometheus to correlate with journal logs from the exact same timestamp using unified labels (`instance="lab-host"` or `$instance`).

### 3.3 Incident Routing & Inhibition Hierarchy

```
[Prometheus Alert Evaluation]
   │
   ├── [HostUnavailable] (Node & Agent Down OR ICMP Down)
   │      │
   │      └── Inhibit ──▶ [All Subsystem Warnings & Criticals]
   │
   ├── [NodeExporterUnavailable]
   │      │
   │      └── Inhibit ──▶ [HostHighCpuUtilization*, HostFilesystemSpace*, etc.]
   │
   ├── [HostHighCpuUtilizationCritical]
   │      │
   │      └── Inhibit ──▶ [HostHighCpuUtilizationWarning]
   │
   └── [HostFilesystemSpaceCritical]
          │
          └── Inhibit ──▶ [HostFilesystemSpaceWarning]
```

1. **Group & Deduplicate:** Alertmanager groups alerts sharing `['alertname', 'instance', 'subsystem']` over a 30s window.
2. **Inhibition Firewalls:** If a root-cause alert fires (e.g., `NodeExporterUnavailable`), Alertmanager suppresses all downstream symptom alerts (e.g., `HostHighCpuUtilization`), preventing notification storms.
3. **Dispatch:** Critical alerts route to immediate notification sinks (`pager-critical`), while warnings batch into informational digests (`slack-warnings`).

---

## 4. Unified Docker Network & Storage Model

### 4.1 Master Docker Network Architecture

The containerized infrastructure operates on a single private bridge network:

```yaml
networks:
  lab-monitoring-net:
    name: lab_monitoring_network
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/16
          gateway: 172.28.0.1
```

- **Container DNS Resolution:**
  - `prometheus` -> `172.28.0.2` (Prometheus TSDB)
  - `grafana` -> `172.28.0.3` (Grafana UI)
  - `alertmanager` -> `172.28.0.4` (Alertmanager)
  - `blackbox-exporter` (alias: `blackbox`) -> `172.28.0.5` (Blackbox Prober)
  - `loki` -> `172.28.0.6` (Loki TSDB)
  - `alloy` -> `172.28.0.7` (Alloy Log Shipper)

### 4.2 Storage Volume & Mount Contract

| Service | Mount Source | Container Destination | Access Mode | Purpose |
|---|---|---|---|---|
| **Prometheus** | `./prometheus/prometheus.yml` | `/etc/prometheus/prometheus.yml` | `:ro` | Server configuration |
| **Prometheus** | `./prometheus/rules` | `/etc/prometheus/rules` | `:ro` | Recording and SRE rules |
| **Prometheus** | `./prometheus/alerts` | `/etc/prometheus/alerts` | `:ro` | Operational alert definitions |
| **Prometheus** | `lab_prometheus_data` | `/prometheus` | `:rw` (Volume) | Persistent TSDB time-series blocks |
| **Grafana** | `./grafana/provisioning` | `/etc/grafana/provisioning` | `:ro` | Auto-provisioning datasources & dashboards |
| **Grafana** | `./grafana/dashboards` | `/var/lib/grafana/dashboards` | `:ro` | Dashboard JSON definitions |
| **Grafana** | `lab_grafana_data` | `/var/lib/grafana` | `:rw` (Volume) | User settings and session state |
| **Alertmanager**| `./alertmanager/alertmanager.yml`| `/etc/alertmanager/alertmanager.yml` | `:ro` | Routing and inhibition config |
| **Alertmanager**| `./alertmanager/templates` | `/etc/alertmanager/templates` | `:ro` | Notification templates |
| **Alertmanager**| `lab_alertmanager_data` | `/alertmanager` | `:rw` (Volume) | Silences and notification state |
| **Blackbox** | `./blackbox/blackbox.yml` | `/etc/blackbox_exporter/config.yml` | `:ro` | Probe modules configuration |
| **Loki** | `./loki/loki-config.yaml` | `/etc/loki/local-config.yaml` | `:ro` | TSDB v13 storage & compactor config |
| **Loki** | `lab_loki_data` | `/loki` | `:rw` (Volume) | Compressed log chunks & TSDB index |
| **Alloy** | `./alloy/config.alloy` | `/etc/alloy/config.alloy` | `:ro` | Journal scraping pipeline config |
| **Alloy** | `/var/log/journal` | `/var/log/journal` | `:ro` (Host) | Binary systemd journal access |
| **Alloy** | `/etc/machine-id` | `/etc/machine-id` | `:ro` (Host) | Host identification for log labeling |

---

## 5. Security & Boundary Enforcement

1. **Least Privilege Principle:**
   - Prometheus and Alertmanager run as unprivileged `nobody:nobody` (`65534:65534`).
   - Grafana runs as unprivileged `grafana:grafana` (`472:472`).
   - Loki runs as unprivileged `loki:loki` (`10001:10001`).
   - Alloy runs as `0:999` (primary UID 0, primary GID 999 `systemd-journal`). Primary GID 999 provides read access to mode 0640 host journals, while UID 0 is retained due to existing state directory ownership in `lab_alloy_data` (`0:4`). The container is strictly hardened with `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges:true`, and `:ro` host journal mounts.
2. **Immutable Filesystem:** All containers declare `read_only: true` with writeable scratch space provided exclusively via memory-backed `tmpfs` mounts (`/tmp:noexec,nosuid,size=64M`).
3. **Capability Stripping:** All containers enforce `cap_drop: [ALL]`. The sole exception is `blackbox` which is granted `cap_add: [NET_RAW]` strictly to support raw ICMP echo probes.
4. **No Privilege Escalation:** All containers declare `security_opt: [no-new-privileges:true]`.
