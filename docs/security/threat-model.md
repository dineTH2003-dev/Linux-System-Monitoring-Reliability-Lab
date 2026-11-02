# Threat Model: Linux System Monitoring & Reliability Lab

**Document Version:** 1.0.0  
**Status:** Approved & Operational  
**Author:** Agent 11 (Infrastructure Security & Deployment Engineer)  
**Methodology:** STRIDE (Microsoft) & MITRE ATT&CK for Containers  
**Target Architecture:** Bare-Metal Linux Host (`rubi`, Ubuntu 24.04 LTS) + Isolated Docker Observability Stack  

---

## 1. System Overview & Architecture Decomposition

The **Linux System Monitoring & Reliability Lab** is a hybrid observability platform combining kernel-level host telemetry exporters with containerized storage, routing, and visualization engines.

### Core Architectural Layers:
1. **Bare-Metal Linux Host Layer**:
   - Physical hardware (MSI Modern 15 B13M, Intel Core i7-1355U, 16 GiB RAM, NVMe SSD).
   - Linux Kernel (`7.0.0-38-generic`) exposing raw telemetry via `/proc`, `/sys`, and systemd D-Bus.
   - Pre-existing native services: Prometheus (`:9090`), Grafana (`:3000`), Node Exporter (`:9100`), SSH (`:22`), PostgreSQL (`:5432`), MySQL (`:3306`).
2. **Custom Python Monitoring Agent Layer**:
   - Python 3.12 process leveraging `psutil` and `/proc` parsers to expose custom system metrics on `127.0.0.1:9101`.
   - Managed as an unprivileged systemd user service with Linux kernel sandboxing.
3. **Containerized Observability Engine (Docker Stack)**:
   - Prometheus server (`127.0.0.1:9091:9090`).
   - Grafana dashboard server (`127.0.0.1:3001:3000`).
   - Alertmanager incident dispatcher (`127.0.0.1:9093:9093`).
   - Loki log aggregation store (`127.0.0.1:3100:3100`).
   - Blackbox endpoint prober (`127.0.0.1:9115:9115`).
   - Network bridge (`lab_monitoring_network`, `172.28.0.0/16`).

```
┌────────────────────────────────────────────────────────────────────────┐
│ UNTRUSTED EXTERNAL NETWORK (Wi-Fi / LAN: wlo1 - 10.10.x.x)             │
└─────────────────────────────────┬──────────────────────────────────────┘
                                  │ (Blocked / Filtered by UFW)
══════════════════════════════════╪══════════════════════════════════════
TRUST BOUNDARY 1: Host Network Interface Boundary
══════════════════════════════════╪══════════════════════════════════════
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Native Host Services:                                                │
│   • prometheus (:9090) ── [SYSTEMD - RUNNING]                          │
│   • node-exporter (:9100) ── [SYSTEMD - RUNNING]                       │
│   • grafana-server (:3000) ── [SYSTEMD - RUNNING]                      │
│                                                                        │
│   Custom Agent:                                                        │
│   • python-agent (:9101) ── [Bound strictly to 127.0.0.1]             │
│                                                                        │
│   ════════════════════════════════════════════════════════════════     │
│   TRUST BOUNDARY 2: Container Runtime & LinuxKit VM Boundary          │
│   ════════════════════════════════════════════════════════════════     │
│                                                                        │
│   Docker Bridge Network (lab_monitoring_network - 172.28.0.0/16)       │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ Containerized Lab Services (All 127.0.0.1 Loopback Mapped): │     │
│   │ • Prometheus Server (:9091)                                  │     │
│   │ • Grafana Server (:3001)                                     │     │
│   │ • Alertmanager (:9093)                                       │     │
│   │ • Loki (:3100)                                               │     │
│   │ • Blackbox Exporter (:9115)                                  │     │
│   └──────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Threat Actor Characterization

| Threat Actor | Capabilities & Access | Motivations | Target Vector |
|---|---|---|---|
| **External Network Attacker** | Network access via Wi-Fi (`wlo1`, `10.10.x.x`), unauthenticated port probing. | Unauthorized reconnaissance, credential theft, denial of service. | Unauthenticated HTTP endpoints (Prometheus API, Node Exporter metrics). |
| **Local Unprivileged User / Compromised Process** | Local shell access on Ubuntu host as standard user (`dineth`). | Privilege escalation, data exfiltration, service disruption. | Writable configuration files, environment files (`.env`), UNIX sockets. |
| **Malicious / Compromised Container Workload** | Code execution inside an application container. | Container breakout, host root takeover, persistence. | Linux capabilities, Docker socket mount, writable host mounts. |
| **Supply Chain / Malicious Image** | Compromised container base image or Python package. | Remote code execution, credential exfiltration, backdoor injection. | Third-party PyPI dependencies, untrusted Docker Hub tags. |

---

## 3. STRIDE Threat Analysis & Security Controls

### 3.1 Spoofing (Identity & Telemetry Authenticity)

| Threat ID | Threat Scenario | Impact | Applied Security Control | Residual Risk |
|---|---|---|---|---|
| **T-SP-01** | Attacker on local network injects fraudulent metrics into Prometheus scrape pipeline by impersonating Node Exporter. | Corrupted dashboards, masked failures, triggered false alerts. | Prometheus scrapes exclusively via authenticated container routing (`host.docker.internal`); host endpoints bound to loopback or protected by host firewall. | Low. Host firewall must enforce drop on external `:9100`. |
| **T-SP-02** | Attacker spoofs Alertmanager webhook notifications to trigger unauthorized incident response workflows. | False alarms, operational exhaustion. | Webhook receivers require secret tokens or local loopback routing (`127.0.0.1:5001`). | Low. |

### 3.2 Tampering (Data & Configuration Integrity)

| Threat ID | Threat Scenario | Impact | Applied Security Control | Residual Risk |
|---|---|---|---|---|
| **T-TM-01** | Unauthorized tampering with Prometheus alerting rules (`alert_rules.yml`) to suppress critical alerts. | SRE blindness to catastrophic host failures. | Configuration files mounted strictly read-only (`:ro`) into containers; host files owned by `dineth` with mode `0644`. | Low. Requires host user compromise to edit. |
| **T-TM-02** | Overwriting Grafana declarative dashboards or datasources to hide SLA breaches. | Falsified compliance records, metric manipulation. | Provisioning directory mounted `:ro`; Grafana user prohibited from UI-based dashboard edits (`editable: false`). | Minimal. |
| **T-TM-03** | Malicious injection into TSDB storage volumes (`lab_prometheus_data`). | Historical metric tampering, corrupted time series. | Named volumes isolated inside Docker storage pool; no external volume sharing. | Low. |

### 3.3 Repudiation (Audit Trail & Logging)

| Threat ID | Threat Scenario | Impact | Applied Security Control | Residual Risk |
|---|---|---|---|---|
| **T-RP-01** | Attacker modifies or deletes monitoring agent scrape logs to erase evidence of exploitation. | Inability to perform post-incident root-cause analysis (RCA). | Systemd journald collects immutable stdout/stderr; log rotation configured with retention bounds. | Low. |
| **T-RP-02** | Container restarts or crashes without audit telemetry. | Undetected container compromise or crash loops. | Docker container health checks log probe failures; Alertmanager Watchdog deadman alert verifies pipeline liveness. | Minimal. |

### 3.4 Information Disclosure (Confidentiality & PII)

| Threat ID | Threat Scenario | Impact | Applied Security Control | Residual Risk |
|---|---|---|---|---|
| **T-ID-01** | Sensitive command-line arguments (passwords, tokens) exposed via `/proc/[pid]/cmdline` scraped by Custom Agent. | Credential harvesting by dashboard viewers. | `ProcessCollector` enforces `sanitize_names: true`, stripping arguments and regex-cleaning process names. | Low. |
| **T-ID-02** | Prometheus metrics endpoint (`/metrics`) accessible from external Wi-Fi network exposing internal kernel topography. | Network reconnaissance, host fingerprinting. | All lab container ports strictly bound to `127.0.0.1` (`HOST_BIND_IP`); no public binding. | Low. |
| **T-ID-03** | Secrets (Grafana admin password, Slack webhook URL) leaked in Git repository. | Unauthorized cloud/notification takeover. | `.env` excluded in `.gitignore`; `.env.example` sanitizes tokens; `security/secret_scanner.sh` audits history. | Low. |

### 3.5 Denial of Service (Availability & Resource Exhaustion)

| Threat ID | Threat Scenario | Impact | Applied Security Control | Residual Risk |
|---|---|---|---|---|
| **T-DOS-01** | High-cardinality metric explosion exhausts Prometheus TSDB memory, crashing the container or host. | Total observability blackout, host OOM trigger. | Strict Docker resource limits (`cpus: 1.0`, `memory: 1024M`); TSDB retention bounded (`--storage.tsdb.retention.size=10GB`). | Low. Container OOM occurs in isolation without impacting host OS. |
| **T-DOS-02** | Excessive concurrent HTTP requests to `/metrics` saturates Python monitoring agent CPU. | Agent scrape timeout, high load average. | Threading HTTP server with strict 30s timeout; systemd CPU quotas. | Low. |
| **T-DOS-03** | Unbounded logging fills host root partition (`/`). | Filesystem exhaustion, host instability. | Containers log to console (`json-file`) with log rotation; tmpfs mounts bounded (`64M`, `32M`). | Minimal. |

### 3.6 Elevation of Privilege (Access Control & Breakout)

| Threat ID | Threat Scenario | Impact | Applied Security Control | Residual Risk |
|---|---|---|---|---|
| **T-EP-01** | Attacker exploits vulnerability in Prometheus or Grafana image to execute code as root inside container. | Full container compromise, pivot to host. | All containers run as non-root (`nobody: 65534`, `grafana: 472`, `loki: 10001`); `cap_drop: [ALL]`. | Minimal. |
| **T-EP-02** | Container breakout via Linux kernel capability abuse or setuid binary. | Host kernel compromise, root shell acquisition. | `security_opt: ["no-new-privileges:true"]`; `read_only: true` root filesystem prevents payload persistence. | Low. |
| **T-EP-03** | Docker socket (`/var/run/docker.sock`) mounted inside container allowing host takeover. | Full root host compromise via Docker daemon. | Audited and verified: Docker socket is **NEVER** mounted into any lab container. | Zero. |

---

## 4. MITRE ATT&CK for Containers Mapping

| ATT&CK Technique | Tactic | Threat Scenario in Lab | Applied Defense-in-Depth Control |
|---|---|---|---|
| **T1610 (Deploy Container)** | Execution | Malicious container spawned with elevated rights. | Compose file explicitly specifies unprivileged users and drops all capabilities. |
| **T1611 (Escape to Host)** | Privilege Escalation | Exploitation of kernel flaw to escape container. | `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges:true`, Docker Desktop QEMU VM isolation. |
| **T1059.004 (Unix Shell)** | Execution | Spawning shell inside container. | Minimal official distroless/alpine containers without unnecessary shell utilities. |
| **T1082 (System Information Discovery)** | Discovery | Scrapes `/proc` and `/sys` to discover host hardware and network. | Read-only access to host telemetry via specialized exporters; process name sanitization active. |
| **T1499 (Endpoint Denial of Service)** | Impact | Flood metrics scrape endpoints to exhaust RAM. | Hard memory and CPU limits defined in compose `deploy.resources.limits`. |

---

## 5. Security Architecture Invariants

1. **Host Preservation Invariant**: No lab deployment action may modify, restart, stop, or reconfigure pre-existing native host services (`prometheus.service`, `grafana-server.service`, `prometheus-node-exporter.service`).
2. **Loopback Invariant**: No container or agent port may bind to `0.0.0.0` or wildcard interfaces without documented authorization.
3. **Immutable Root Invariant**: All containerized services must execute with `read_only: true` root filesystems; writable operations are strictly confined to dedicated named volumes or memory-backed `tmpfs`.
4. **Least Privilege Invariant**: Containers must execute as dedicated non-root UIDs (`65534`, `472`, `10001`) with all Linux capabilities dropped (`cap_drop: [ALL]`).
5. **Zero Secrets in Git Invariant**: No cryptographic private keys, passwords, or live webhook tokens may exist in Git tracked files or commit history.
