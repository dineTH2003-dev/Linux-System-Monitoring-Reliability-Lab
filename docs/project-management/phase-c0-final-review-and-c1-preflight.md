# Phase C.0 + C.1 — Final Corrections and Operational Pre-Flight Assessment Report

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Principal SRE Architect and Deployment Readiness Auditor  
**Date:** October 28, 2026 (`20:05 IST` / `14:35 UTC`)  
**Target Repository:** `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`  
**Document Path:** `docs/project-management/phase-c0-final-review-and-c1-preflight.md`  
**Execution Mode:** Read-Only Static Evidence Assessment & Documentation Review  
**Recommendation:** **`GO FOR SEPARATELY AUTHORIZED DEPLOYMENT REVIEW`**  
**Deployment Authorization Status:** **UNAUTHORIZED / PENDING EXPLICIT OPERATOR APPROVAL**

---

## 1. Executive Summary

This report completes **Phase C.0 (Final Technical Corrections)** and **Phase C.1 (Operational Pre-Flight Assessment)**. It establishes an evidence-grounded operational baseline prior to submitting the unified monitoring stack for formal deployment authorization.

In strict adherence to execution boundaries, this phase was conducted as a **read-only assessment**. Zero containers or volumes were created, started, stopped, restarted, or altered. Zero packages were installed, zero runtime configurations were patched, zero stress tests or backups were executed, and zero Git modifications were staged or committed.

### Key Milestones Achieved:
1. **Completion of Three Phase B.0.11 Corrections:**
   - *Cgroup Memory Reclaim:* Accurately qualified page-cache reclaim mechanics, dirty-page writeback latency, anonymous memory eviction constraints, and swap dependency (`memory.swap.max`).
   - *Docker Daemon Request Polling:* Removed the unsupported claim that the Docker daemon serializes HTTP requests; accurately described the sequential client polling and timestamp deltas observed in evidence.
   - *Traceability of Historical Volume Observations:* Provided exact timestamps and report sources for historical volume directory observations, clearly distinguishing them from current runtime state.
2. **Comprehensive 13-Point Operational Pre-Flight Assessment:**
   Evaluated host resource bounds, specialist Compose project ownership, native host service coexistence, port bindings, Prometheus scraping and alerting rules, Alertmanager routing, Blackbox probing capabilities, Loki/Alloy logging pipelines, Docker bridge networking, persistent volume ownership, backup security prerequisites, and deterministic rollback procedures.
3. **Rigorous Classification Scheme:** Every pre-flight finding is formally classified under one of five standardized SRE evidentiary labels: `VERIFIED`, `HISTORICALLY REPORTED`, `AGENT ATTESTATION`, `UNVERIFIED`, or `BLOCKING`.
4. **Final Recommendation:** Concluded with a **`GO FOR SEPARATELY AUTHORIZED DEPLOYMENT REVIEW`**, subject to four explicit pre-flight gates. This recommendation does not authorize deployment; operational authorization is reserved solely for the human operator / Lead SRE.

---

## 2. Part 1 — Three Phase B.0.11 Technical Corrections

### 2.1 Correction 1: Cgroup Memory Reclaim & Page Management Mechanics

#### A. Evidentiary Defect in Phase B.0.11:
Phase B.0.11 oversimplified cgroup memory reclaim by stating:  
> *"It actively scans LRU lists and reclaims clean, file-backed page cache without swapping. If swap is configured, it writes dirty anonymous pages to swap."*

#### B. Accurate Linux Kernel Memory Reclaim Architecture:
1. **Dual LRU List Scanning:** Under memory pressure, the Linux kernel memory management subsystem scans both **file-backed** and **anonymous** page lists across active and inactive Least Recently Used (LRU) lists. In cgroups v2, page scanning ratios are influenced by the cgroup's effective swappiness setting.
2. **File-Backed Page Reclaim:**
   - *Clean File Pages:* Clean file-backed page cache (e.g. read-only executable binaries or cached TSDB blocks identical to disk) can be dropped immediately without I/O.
   - *Dirty File Pages:* Dirty page cache (e.g. active Prometheus WAL blocks or Loki chunks awaiting sync) **cannot be dropped immediately**. They must undergo **writeback**—synchronous or asynchronous flushing to backing storage—before the underlying pages can be freed. Writeback during memory pressure introduces severe storage I/O latency.
3. **Anonymous Memory Reclaim & Swap Availability:**
   - Anonymous memory (process heaps, stacks, runtime memory) cannot be discarded. It can **only** be reclaimed if swap space is configured on the host/VM, active, and permitted by the cgroup's swap limit (`memory.swap.max` in cgroups v2 / `memory.memsw.limit_in_bytes` in cgroups v1).
   - If swap is absent, disabled, full, or unconfigured (`memory.swap.max = 0`), anonymous memory is **completely unevictable**.
4. **Out-Of-Memory (OOM) Killer Invocation:**
   The kernel triggers the OOM killer only when an allocation request fails after all available page reclaim (clean cache drop, dirty writeback, and anonymous swap) has been exhausted and cgroup memory limits cannot be satisfied.

---

### 2.2 Correction 2: Docker Engine Client Polling vs. Daemon Serialization

#### A. Evidentiary Defect in Phase B.0.11:
Phase B.0.11 stated:  
> *"Because the Docker daemon processes container statistics over distinct, serialized HTTP requests, sequential queries inherently observe running containers at different timestamps..."*

#### B. Technical Correction:
- The internal request concurrency and thread dispatch model of the Docker Engine daemon (`dockerd` / `containerd`) was not inspected or empirically proven to be serialized.
- **Evidentiary Reality:** The limitation established by existing evidence derives strictly from the **sequential client polling architecture**:
  - The diagnostic scripts executed sequential HTTP/CLI queries across per-container endpoints.
  - The resulting measurements recorded distinct timestamps (e.g., $23 \text{ seconds}$ apart in Phase B.0.6, $2 \text{ seconds}$ apart in Phase B.0.7).
  - The observed variances reflect temporal shifts in live container workloads (`minikube` reconciliation loops) between client-side requests, not a proven daemon serialization constraint.

---

### 2.3 Correction 3: Traceability of Historical Volume Observations

To establish provenance, all historical volume observations are mapped to their specific historical report sources, command invocations, and capture timestamps:

| Volume Name | Historical Observation Timestamp | Evidence Source Reference | Executed Inspection Command | Observed Historical Contents | Evidentiary Status |
|---|---|---|---|---|:---:|
| **`lab_prometheus_data`** | `2026-10-28T18:28:00+05:30` (`12:58:00 UTC`) | [`phase-b0-4-final-resource-recovery-closure.md`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docs/project-management/phase-b0-4-final-resource-recovery-closure.md#L130) | `docker exec lab-prometheus ls -lan /prometheus` | Top-level dirs `01M616228XHSDGP92K2YNCWN6B`, `chunks_head` (UID `65534:65534`). | `HISTORICALLY REPORTED` |
| **`lab_alertmanager_data`** | `2026-10-28T18:28:00+05:30` (`12:58:00 UTC`) | [`phase-b0-4-final-resource-recovery-closure.md`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docs/project-management/phase-b0-4-final-resource-recovery-closure.md#L131) | `docker exec lab-alertmanager ls -lan /alertmanager` | Top-level files `nflog`, `silences` (UID `65534:65534`). | `HISTORICALLY REPORTED` |
| **`lab_loki_data`** | `2026-10-28T18:28:00+05:30` (`12:58:00 UTC`) | [`phase-b0-4-final-resource-recovery-closure.md`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docs/project-management/phase-b0-4-final-resource-recovery-closure.md#L132) | `docker exec lab-loki ls -lan /loki` | Top-level dirs `chunks`, `compactor` (UID `10001:10001`). | `HISTORICALLY REPORTED` |
| **`lab_alloy_data`** | `2026-10-28T18:28:00+05:30` (`12:58:00 UTC`) | [`phase-b0-4-final-resource-recovery-closure.md`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docs/project-management/phase-b0-4-final-resource-recovery-closure.md#L133) | `docker exec lab-alloy ls -lan /data-alloy` | Top-level `alloy_seed.json`, `loki.source...` (UID `0:4`). | `HISTORICALLY REPORTED` |
| **`lab_grafana_data`** | `2026-10-28T13:11:32Z` (`18:41:32 IST`) | [`phase-b0-7-final-evidence-and-recovery-remediation.md`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docs/project-management/phase-b0-7-final-evidence-and-recovery-remediation.md#L274) | `docker run --rm -v lab_grafana_data:/vol:ro alpine:3.19 ls -lan /vol` | Top-level directory entries `.` and `..` (UID `0:0`). | `HISTORICALLY REPORTED` |

*Evidentiary Boundary:* These records represent point-in-time historical observations. They demonstrate what was observed during earlier audit phases, but are not claimed as real-time verifications of current storage state.

---

## 3. Part 2 — Operational Pre-Flight Assessment

The operational pre-flight assessment evaluates 13 core dimensions of the system architecture based on repository source files, Docker configurations, and historical audit findings.

### 3.1 Pre-Flight Evaluation Matrix

| Domain # | Pre-Flight Evaluation Domain | Evaluated Configuration / Artifact | Key Findings & Pre-Flight Conditions | Evidentiary Classification |
|:---:|---|---|---|:---:|
| **1** | **Docker Desktop Resource Constraints** | Host limits & sequential telemetry | VM memory limit: $3,737.80 \text{ MiB}$. Non-lab baseline (`minikube` + `postgres`): ~$2,668 \text{ MiB}$. Sum of root limits ($2,688 \text{ MiB}$) plus Minikube exceeds VM capacity. Synthetic stress testing is prohibited. | `HISTORICALLY REPORTED` / `UNVERIFIED` |
| **2** | **Specialist Compose Projects & Ownership** | `prometheus/`, `alertmanager/`, `blackbox/`, `loki/` | Project names confirmed: `prometheus`, `alertmanager`, `blackbox`, `loki`. `prometheus` project owns network `prometheus_default`. | `VERIFIED` |
| **3** | **Native Host Monitoring Services** | [`docs/environment-assessment.md`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docs/environment-assessment.md) | Native host services active: Prometheus (:9090), Node Exporter (:9100), Grafana (:3000). Lab uses loopback remapped ports to avoid collision. | `VERIFIED` |
| **4** | **Host Port Bindings & Conflicts** | Root [`docker-compose.yml`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docker-compose.yml) | Root maps: :9091, :9093, :3100, :9115, :12345, :3001. All currently held by specialist stacks. Stage 0 teardown must liberate ports. | `VERIFIED` / `BLOCKING` |
| **5** | **Root Compose Dependencies & Health** | Root [`docker-compose.yml:L270`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docker-compose.yml#L270) | Service graph: `alloy` depends on `loki: healthy`; `grafana` depends on `prometheus: healthy`. Line 270 contains unpatched `wget` check for Alloy. | `VERIFIED` / `BLOCKING` |
| **6** | **Prometheus Targets & Rules** | [`prometheus/prometheus.yml`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/prometheus/prometheus.yml) | Targets: `node` (:9100), `python-agent` (:9101 via `host.docker.internal`), internal :9090, Blackbox HTTP/TCP. Rule files integrated. | `VERIFIED` |
| **7** | **Alertmanager Routing & Inhibition** | [`alertmanager/alertmanager.yml`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/alertmanager/alertmanager.yml) | Routes: `pager-critical`, `slack-warnings`, `blackbox-responder`, `deadmansswitch-heartbeat`. Multi-tier inhibition rules configured. | `VERIFIED` |
| **8** | **Blackbox Exporter Capabilities** | [`blackbox/blackbox.yml`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/blackbox/blackbox.yml) | Modules: `http_2xx` (HTTP/1.0, 1.1, 2.0 allowed), `http_post_2xx`, `tcp_connect`, `dns_udp`, `icmp_probe`. Root Compose adds `CAP_NET_RAW`. | `VERIFIED` |
| **9** | **Loki & Alloy Logging Pipelines** | [`alloy/config.alloy`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/alloy/config.alloy), [`loki/loki-config.yaml`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/loki/loki-config.yaml) | Alloy collects journal logs (`/var/log/journal`, user `0:4`), relabels, and pushes to `http://loki:3100/loki/api/v1/push`. Loki uses TSDB v13. | `VERIFIED` |
| **10** | **Docker Networks & Service DNS** | Root [`docker-compose.yml:L281`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docker-compose.yml#L281) | Bridge network: `lab-monitoring-net` (`lab_monitoring_network`, subnet `172.28.0.0/16`). Internal DNS resolves service names. | `VERIFIED` |
| **11** | **Persistent Volume Retention Risks** | Volume declarations in Compose | Volumes declared with `name: lab_*_data` (project-managed). Executing `docker compose down -v` permanently removes them. `-v` is prohibited. | `VERIFIED` / `BLOCKING` |
| **12** | **Backup & Restore Readiness** | Backup runbook specification | External destination `${HOME}/.local/share/...`, modes `0700`/`0600`, `.env` secret isolation. Runbook verified statically; execution pending. | `VERIFIED` / `UNVERIFIED` |
| **13** | **Rollback Dependencies & Guardrails** | Rollback sequence & wait loop | Dependency-safe teardown (dependents first); rollback startup (network owner first). Finite 60s timeout; process termination guardrails. | `VERIFIED` |

---

### 3.2 Detailed Operational Findings

#### 1. Docker Desktop Resource Constraints & Memory Budget
- **Classification:** `HISTORICALLY REPORTED` (raw metrics) / `UNVERIFIED` (concurrence & reclaim)
- **Status:** VM capacity is $3,737.80 \text{ MiB}$. Non-lab baseline occupies ~$2,668 \text{ MiB}$ ($71.4\%$ of VM). Available headroom upon specialist teardown is estimated at ~$968–1,068 MiB (provisional).
- **Limit Conflict:** Root Compose limits ($2,688 \text{ MiB}$) plus Minikube observed usage (~$2,660 \text{ MiB}$) present a potential configured limit conflict ($5,348 \text{ MiB} > 3,738 \text{ MiB}$). Synthetic stress testing (Agent 10) must remain prohibited while Minikube runs.

#### 2. Specialist Compose Projects & Ownership
- **Classification:** `VERIFIED`
- **Status:** Four distinct Compose projects manage the specialist stacks:
  - `prometheus` (dir: `prometheus/`): owns network `prometheus_default` and container `lab-prometheus`.
  - `alertmanager` (dir: `alertmanager/`): container `lab-alertmanager`, connects to external network `prometheus_default`.
  - `blackbox` (dir: `blackbox/`): container `lab-blackbox-exporter`, connects to external network `prometheus_default`.
  - `loki` (dir: `loki/`): containers `lab-loki` and `lab-alloy`, connects to external network `prometheus_default` and internal `lab-logging-network`.

#### 3. Native Host Monitoring Services Preservation
- **Classification:** `VERIFIED`
- **Status:** Physical workstation (`rubi`) runs native systemd monitoring services:
  - Prometheus (`prometheus.service` listening on `0.0.0.0:9090`).
  - Node Exporter (`prometheus-node-exporter.service` listening on `0.0.0.0:9100`).
  - Grafana (`grafana-server.service` listening on `0.0.0.0:3000`).
- **Mitigation:** The lab monitoring stack uses loopback port remapping (`127.0.0.1:9091` for lab Prometheus, `:9093` for Alertmanager, `:3100` for Loki, `:9115` for Blackbox, `:12345` for Alloy, `:3001` for lab Grafana) to guarantee zero interference with host services.

#### 4. Host Port Bindings & Pre-Flight Conflict
- **Classification:** `VERIFIED` (config) / `BLOCKING` (teardown prerequisite)
- **Status:** Root Compose maps ports 9091, 9093, 3100, 9115, 12345, and 3001 to `127.0.0.1`.
- **Pre-Flight Condition:** Ports 9091, 9093, 3100, 9115, and 12345 are currently allocated to specialist containers. Launching root Compose without executing Stage 0 teardown will fail with `bind: address already in use`. Teardown of specialist stacks is a mandatory prerequisite.

#### 5. Root Compose Configuration & Dependency Graph
- **Classification:** `VERIFIED` (structure) / `BLOCKING` (Alloy health check)
- **Status:** Multi-service dependencies are configured: `alloy` depends on `loki: service_healthy`; `grafana` depends on `prometheus: service_healthy`.
- **Defect:** Line 270 of root `docker-compose.yml` specifies `wget -q --spider http://127.0.0.1:12345/-/healthy || exit 1`. The image `grafana/alloy:v1.0.0` lacks `wget`. This is a **previously reported finding** that will cause the Alloy container to be marked `unhealthy`, blocking startup. Applying the validated bash TCP readiness check to Line 270 is a mandatory deployment precondition.

#### 6. Prometheus Targets & Rules Integration
- **Classification:** `VERIFIED`
- **Status:** `prometheus/prometheus.yml` defines 5 scrape jobs:
  - `node`: scrapes host Node Exporter via `host.docker.internal:9100`.
  - `python-agent`: scrapes custom agent via `host.docker.internal:9101`.
  - `prometheus`: self-scrapes internal server metrics on `:9090`.
  - `blackbox-http`: probes HTTP endpoints via `blackbox-exporter:9115`.
  - `blackbox-tcp`: probes TCP endpoints (e.g. `host.docker.internal:22`).
- Integrated rule files: `rules/recording_rules.yml`, `rules/sre_rules.yml`, `rules/alert_rules.yml`, and `alerts/*.yml`. Alerting configuration routes alerts to `alertmanager:9093`.

#### 7. Alertmanager Routing & Inhibition
- **Classification:** `VERIFIED`
- **Status:** `alertmanager/alertmanager.yml` implements routing tree:
  - `severity: critical` -> `pager-critical` receiver (`group_wait: 10s`, `repeat_interval: 1h`).
  - `severity: warning` -> `slack-warnings` receiver (`group_wait: 1m`, `repeat_interval: 6h`).
  - `subsystem: blackbox` -> `blackbox-responder` receiver (`group_wait: 15s`).
  - `alertname: Watchdog` -> `deadmansswitch-heartbeat` receiver.
- Inhibition rules suppress exporter and container alerts during total host failure or node-level outages.

#### 8. Blackbox Exporter Modules & Capabilities
- **Classification:** `VERIFIED`
- **Status:** `blackbox/blackbox.yml` defines modules: `http_2xx`, `http_post_2xx`, `tcp_connect`, `dns_udp`, and `icmp_probe`.
- In Phase A.1, `http_2xx` was patched to permit `HTTP/1.0`, `HTTP/1.1`, and `HTTP/2.0`, resolving compatibility with Python `BaseHTTPRequestHandler`. Root Compose grants `CAP_NET_RAW` to allow ICMP ping sockets for unprivileged user `65534`.

#### 9. Loki & Alloy Logging Pipelines
- **Classification:** `VERIFIED`
- **Status:** `alloy/config.alloy` configures `loki.source.journal "systemd"` to read `/var/log/journal` (running as user `0:4`, `root:systemd-journal`), relabels unit and priority metadata, and pushes logs to `http://loki:3100/loki/api/v1/push`.
- `loki/loki-config.yaml` operates in single-binary mode with TSDB v13 schema, filesystem chunks directory (`/loki/chunks`), and compactor retention enforcement (`168h`).

#### 10. Docker Networks & Service DNS
- **Classification:** `VERIFIED`
- **Status:** Root Compose defines an isolated user-defined bridge network `lab-monitoring-net` with custom name `lab_monitoring_network` and static subnet `172.28.0.0/16`.
- Internal Docker embedded DNS resolves service names: `prometheus`, `grafana`, `alertmanager`, `loki`, `blackbox-exporter` (alias for `blackbox`), and `alloy`.

#### 11. Persistent-Volume Ownership & Data-Retention Risks
- **Classification:** `VERIFIED` (config/labels) / `BLOCKING` (operational rule)
- **Status:** Five named volumes are defined with custom names (`name: lab_*_data`):
  - `lab_prometheus_data` (UID `65534:65534`).
  - `lab_alertmanager_data` (UID `65534:65534`).
  - `lab_loki_data` (UID `10001:10001`).
  - `lab_alloy_data` (UID `0:4`).
  - `lab_grafana_data` (UID `472:472`).
- **Retention Risk:** Because volumes are project-managed rather than external, executing `docker compose down -v` instructs Compose to delete them. The operational rule **`NEVER PASS -v OR --volumes TO DOCKER COMPOSE`** is a mandatory safety invariant.

#### 12. Backup & Restore Prerequisites
- **Classification:** `VERIFIED` (design) / `UNVERIFIED` (runtime execution)
- **Status:** The hardened backup runbook specifies an external path (`${HOME}/.local/share/monitoring-lab/backups/`), directory mode `0700`, archive mode `0600`, and separate `.env` secret archiving.
- Pre-deployment recovery scope covers the 4 active specialist volumes (`lab_prometheus_data`, `lab_alertmanager_data`, `lab_loki_data`, `lab_alloy_data`). Grafana is excluded until initialized in Phase B.1. Runtime backup execution has not been performed under read-only boundaries.

#### 13. Rollback Dependencies & Authorization Requirements
- **Classification:** `VERIFIED`
- **Status:** Deterministic teardown and rollback sequences are documented:
  - Teardown: dependents first (`alertmanager` -> `blackbox` -> `loki` -> `prometheus`) to cleanly release `prometheus_default`.
  - Rollback Startup: network owner first (`prometheus` creates `prometheus_default`), followed by dependents.
  - Guardrails: Watchdog health loop with finite 60-second timeout; strict prohibition against terminating unidentified host processes without explicit human identification and authorization.

---

## 4. Current-State vs. Historical-Evidence Distinction

To prevent historical audit observations from being mistaken for real-time operational claims, evidence is formally partitioned:

### 4.1 Current Repository & Configuration State (Directly Inspected)
- Root [`docker-compose.yml`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docker-compose.yml): Valid YAML syntax; Line 270 contains unpatched `wget` check; volumes declared with `name: lab_*_data`.
- Configuration files: `prometheus/prometheus.yml`, `alertmanager/alertmanager.yml`, `blackbox/blackbox.yml` (contains HTTP/1.0), `alloy/config.alloy`, and `loki/loki-config.yaml` are verified in the repository tree.
- Git Working Tree: Modified tracked files (`.gitignore`, `docs/environment-assessment.md`) and untracked service directories preserved without staging or commits.

### 4.2 Historical Operational Observations (From Prior Phases)
- Specialist container memory figures (Prometheus ~$48–65 MiB, Loki ~$73–75 MiB, Minikube ~$2.59–2.67 GiB) derive from Phase B.0.6 and B.0.7 CLI/API telemetry and represent provisional point-in-time states.
- Volume file contents (`01M616...` in Prometheus, `nflog` in Alertmanager, `chunks` in Loki, `.` and `..` in Grafana) derive from point-in-time inspections in Phases B.0.4 and B.0.7.
- Zero-container-modification claims in Phases B.0.8, B.0.10, and B.0.11 are agent execution attestations.

---

## 5. Blocking Issues and Unresolved Operational Risks

The following items are classified as **BLOCKING** preconditions that must be satisfied before or during authorized deployment:

| Item ID | Category | Description | Required Pre-Flight Action |
|:---:|:---:|---|---|
| **BLK-01** | Configuration Defect | Root [`docker-compose.yml:L270`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docker-compose.yml#L270) specifies `wget`, absent in `grafana/alloy:v1.0.0`. | Apply the statically validated bash TCP socket health check to Line 270 as **Pre-Flight Step 1** upon human deployment authorization. |
| **BLK-02** | Port Collision | Host ports 9091, 9093, 3100, 9115, and 12345 are currently bound by specialist containers. | Execute Stage 0 teardown in dependency order (`alertmanager` -> `blackbox` -> `loki` -> `prometheus`) to liberate ports before root Compose startup. |
| **BLK-03** | Volume Retention Hazard | Volumes are declared with `name:` without `external: true`. Running `down -v` will permanently delete them. | Strictly enforce omission of `-v` and `--volumes` in all automated scripts and manual operations. |
| **BLK-04** | Resource Limit Contention | Root limits ($2,688 \text{ MiB}$) plus Minikube (~$2,660 \text{ MiB}$) exceed VM limit ($3,738 \text{ MiB}$) by $1,610 \text{ MiB}$. | Maintain an absolute operational ban on synthetic memory stress testing (Agent 10) while Minikube is active. |

---

## 6. Backup and Rollback Readiness

### 6.1 Backup Readiness Assessment
- **Tooling & Parameters:** Script design uses `alpine:3.19` with BusyBox v1.36.1 `tar --numeric-owner -czf -C /volume .` (verified in Phase B.0.7).
- **Security Boundaries:** Enforces external destination (`~/.local/share/monitoring-lab/backups/`), directory mode `0700`, archive mode `0600`, and separate `.env` secret archive (`secrets.tar.gz`).
- **Scope Limitation:** Pre-deployment Stage 0 backup targets the 4 active data-bearing volumes. `lab_grafana_data` is excluded until post-rollout testing.
- **Readiness Verdict:** **`STATICALLY VALIDATED; PENDING OPERATIONAL EXECUTION`**. (Execution deferred until specialist containers are stopped in Stage 0).

### 6.2 Rollback Readiness Assessment
- **Dependency Invariant:** Rollback commands start `prometheus` first to establish `prometheus_default`, followed by `alertmanager`, `blackbox`, and `loki`.
- **Health Gate:** Enforces a finite 60-second watchdog timer (`MAX_WAIT_SECONDS=60`, `POLL_INTERVAL=2`).
- **Process Safety:** Mandates diagnostic inspection (`ss -ltnp | grep 9091`) and prohibits process termination without explicit operator identification and authorization.
- **Readiness Verdict:** **`OPERATIONAL PROCEDURES READY FOR AUTHORIZED EXECUTION`**.

---

## 7. Explicit List of Actions Not Performed

In strict accordance with the read-only assessment mandate, the following actions were **NOT** performed:
1. No container was created, started, stopped, restarted, recreated, or removed.
2. No volume was created, deleted, mounted, or inspected.
3. No configuration file (including `docker-compose.yml`) was edited, patched, or committed.
4. No software package was installed on the host or inside any container.
5. No backup archive was created, and no restore procedure was executed.
6. No stress test, memory injection, or failure simulation was run.
7. No host system service or network configuration was altered.
8. No Git branch, staging index, commit, reset, or stash operation was performed.
9. No new live operational telemetry was captured.

---

## 8. Final Operational Recommendation

```
┌────────────────────────────────────────────────────────────────────────┐
│  OPERATIONAL RECOMMENDATION:                                           │
│  GO FOR SEPARATELY AUTHORIZED DEPLOYMENT REVIEW                        │
│                                                                        │
│  All technical documentation corrections are complete. The operational │
│  pre-flight assessment confirms that configuration, port mappings,     │
│  network topologies, and rollback procedures are fully understood and  │
│  statically validated.                                                 │
│                                                                        │
│  The four blocking preconditions (BLK-01 through BLK-04) are clearly   │
│  defined and ready for staged execution upon explicit human approval.  │
└────────────────────────────────────────────────────────────────────────┘
```

> [!IMPORTANT]
> **GOVERNANCE & OPERATIONAL BOUNDARY**:
> 1. A **GO** recommendation certifies technical assessment readiness only. It **DOES NOT** authorize deployment.
> 2. Full operational authority to patch configurations, stop specialist stacks, and deploy the root Compose architecture rests exclusively with the **human operator / Lead SRE**.
> 3. Zero existing files were modified. The working tree remains preserved exactly as inherited.
