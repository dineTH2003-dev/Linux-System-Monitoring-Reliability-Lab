# Implementation Roadmap & Phased Rollout Strategy

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Principal SRE Architect & Technical Integration Lead  
**Document Status:** Approved Engineering Plan  
**Date:** October 2026  

---

## 1. Rollout Strategy & Execution Principles

To ensure zero downtime, prevent metric corruption, and protect the host's existing production services (native Prometheus on `:9090` and Grafana on `:3000`), the Linux System Monitoring & Reliability Lab executes across **five (5) gated implementation phases**.

### 1.1 Core Execution Invariants

1. **Host Non-Interference:** Never bind container ports to unassigned `0.0.0.0` interfaces; all exposed ports MUST bind strictly to `127.0.0.1` loopback with non-colliding port allocations (`9091`, `3001`, `9093`, `9115`, `3100`, `12345`).
2. **Strict Phase Gating:** A phase cannot transition to active execution until all preceding gate criteria have been empirically verified via automated test scripts.
3. **Reversibility & Idempotence:** All scripts and Compose states must be idempotent and fully reversible without manual filesystem surgery.

---

## 2. Dependency Graph & Phase Sequencing

```
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE A: Base Telemetry & Custom Agent                                  │
│ • Host Node Exporter verification (:9100)                              │
│ • Custom Python Monitoring Agent (:9101)                               │
│ • Standalone POSIX Bash diagnostic tools                              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Gate A: 100% Collector Tests Pass
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE B: Observability Core                                            │
│ • Master Hardened Docker Network (lab_monitoring_network)              │
│ • Lab Prometheus Server (:9091)                                        │
│ • Metric Scrape Pipeline & Recording Rules                             │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Gate B: TSDB Scrapes Healthy & UP
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE C: Incident Detection, Synthetics & Centralized Logging          │
│ • Alertmanager Incident Router (:9093)                                 │
│ • Blackbox Synthetic Prober (:9115) with NET_RAW capability           │
│ • Grafana Loki v3.0 TSDB Engine (:3100)                                │
│ • Grafana Alloy Journald Log Shipper (:12345)                          │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Gate C: Synthetic Probes & LogQL Ready
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE D: Visualization & SRE Reliability Governance                     │
│ • Grafana Operational Dashboards 01–05 (:3001)                         │
│ • SRE SLI/SLO Recording Rules & Error Budget Policies                  │
│ • Multi-Window Multi-Burn-Rate Alert Rules                             │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Gate D: Dashboards Render & Budgets Tracked
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE E: Reliability Verification, Self-Healing & Security Hardening   │
│ • Automated Failure Injection Scenarios (01–09)                        │
│ • Automated Runbook Remediations (01–06)                               │
│ • Security Auditing (least-privilege, container limits, secrets)       │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Phase Breakdown & Milestone Targets

### Phase A: Base Telemetry & Host Agent Platform
- **Scope:** Host instrumentation and localized diagnostics.
- **Components:**
  - Native Linux Node Exporter running via host systemd on port `9100`.
  - Custom Python Monitoring Agent running on port `9101` with 9 kernel collectors.
  - POSIX Bash diagnostic suite in `scripts/monitoring/`.
- **Parallelism:** Agents 1, 2, 3, and 4 execute concurrently during analysis and unit testing.
- **Definition of Done (DoD):**
  - Node Exporter HTTP endpoint returns valid Prometheus metrics on `http://127.0.0.1:9100/metrics`.
  - Python agent passes all 30 pytest unit tests in `tests/python/`.
  - All 7 Bash diagnostic tools pass the 83 assertion test suite (`scripts/tests/test_runner.sh`).
  - Python monitoring agent systemd unit file is validated for background execution (`deployment/systemd/`).

### Phase B: Observability Core
- **Scope:** Metrics TSDB infrastructure and ingestion pipeline.
- **Components:**
  - Dedicated Docker bridge network (`lab-monitoring-net`, `172.28.0.0/16`).
  - Containerized Prometheus (`prom/prometheus:v2.51.0`) bound to `127.0.0.1:9091:9090`.
  - Persistent volume `lab_prometheus_data` with 15-day / 10GB retention limits.
  - Recording rule evaluation for CPU, memory, storage, and network rates.
- **Parallelism:** Sequential execution following Phase A.
- **Definition of Done (DoD):**
  - `lab-prometheus` container passes container healthcheck.
  - Prometheus targets `node` (`host.docker.internal:9100`) and `python-agent` (`host.docker.internal:9101`) report state `UP`.
  - Recording rules evaluate cleanly without PromQL syntax errors.

### Phase C: Incident Detection, Synthetics & Centralized Logging
- **Scope:** Alert routing, synthetic probing, and log ingestion.
- **Components:**
  - Containerized Alertmanager (`prom/alertmanager:v0.27.0`) bound to `127.0.0.1:9093:9093`.
  - Blackbox Exporter (`prom/blackbox-exporter:v0.25.0`) bound to `127.0.0.1:9115:9115` with `NET_RAW` capability.
  - Grafana Loki (`grafana/loki:3.0.0`) bound to `127.0.0.1:3100:3100` using TSDB v13 schema.
  - Grafana Alloy (`grafana/alloy:v1.0.0`) bound to `127.0.0.1:12345:12345` reading `/var/log/journal`.
- **Parallelism:** Alerting (Agent 7) and Logging (Agent 8) components deploy in parallel on the shared network.
- **Definition of Done (DoD):**
  - Alertmanager renders notification templates and routes mock alerts without errors.
  - Blackbox exporter successfully completes HTTP, TCP, DNS, and ICMP synthetic probes.
  - Loki accepts push requests on `/loki/api/v1/push` and answers LogQL queries on `/ready`.
  - Alloy harvests host journal logs and forwards them to Loki with structured metadata.

### Phase D: Visualization & SRE Governance
- **Scope:** User dashboards, service-level tracking, and error budget alerting.
- **Components:**
  - Containerized Grafana (`grafana/grafana:10.4.1`) bound to `127.0.0.1:3001:3000`.
  - Declarative provisioning of Prometheus and Loki datasources.
  - Auto-provisioning of Dashboards 01 through 05.
  - Activation of SRE recording rules and multi-window burn rate alerts (`prometheus/rules/sre_rules.yml`).
- **Parallelism:** Agent 6 (Dashboards) and Agent 9 (SRE) integrate simultaneously.
- **Definition of Done (DoD):**
  - Grafana starts cleanly and provisions both datasources without manual UI steps.
  - All 5 dashboards load and display live telemetry from Node Exporter, Python Agent, and Loki.
  - SRE availability SLI (`node_exporter_availability:ratio5m`) evaluates to $\ge 0.999$.

### Phase E: Reliability Verification, Self-Healing & Security Hardening
- **Scope:** Fault injection, automated remediation, and compliance auditing.
- **Components:**
  - Execution of 9 reversible failure scenarios via `scripts/reliability/run_scenario.sh`.
  - Automated self-healing runbooks (`scripts/reliability/remediation/`).
  - Security audit validation using `security/audit_permissions.sh` and `security/container_audit.sh`.
- **Parallelism:** Executes after full platform deployment.
- **Definition of Done (DoD):**
  - All 9 failure scenarios demonstrate complete inject-detect-remediate-verify lifecycle.
  - Zero residual artifacts or background processes remaining after test teardown.
  - Security scanners verify all containers run as non-root with read-only root filesystems and dropped capabilities.

---

---

## 4. Static Validation Suite & Verification Results

Before any container launch or daemon startup, the platform must satisfy all static validation checks. The following results have been empirically captured:

| Check # | Validation Target | Tool / Command | Verification Scope | Status | Result / Output |
|---|---|---|---|---|---|
| **V-01** | Master Docker Compose | `docker compose config` | 6 hardened services, network aliases, volume mappings | **PASSED** | Syntax valid; exits 0 |
| **V-02** | Prometheus Config & Rules | `promtool check config prometheus/prometheus.yml` | 5 rule files, 80 rules (recording, SRE, alerts) | **PASSED** | SUCCESS: 5 rule files found |
| **V-03** | Prometheus Unit Tests | `promtool test rules prometheus/tests/*.yml` | Recording rules, SRE burn-rate rules, infrastructure alerts | **PASSED** | 3/3 test suites SUCCESS |
| **V-04** | Alertmanager Config | `amtool check-config /etc/alertmanager/alertmanager.yml` | 7 inhibit rules, 5 mock receivers, templates | **PASSED** | SUCCESS: 7 inhibit rules verified |
| **V-05** | Loki Storage & TSDB | `loki -verify-config -config.file=loki-config.yaml` | Schema v13, TSDB engine, retention compactor | **PASSED** | "config is valid" (exits 0) |
| **V-06** | Alloy Journal Pipeline | `alloy fmt /etc/alloy/config.alloy` | Journal scraping syntax, label relabeling, Loki sink | **PASSED** | Syntax parsed cleanly (exits 0) |
| **V-07** | Repository YAML Syntax | `yaml.safe_load_all()` | All 23 YAML configuration and compose files | **PASSED** | 23/23 YAML files valid |
| **V-08** | Grafana Dashboards | `json.load()` | All 5 declarative dashboard JSON files | **PASSED** | 5/5 dashboards valid (90 panels total) |
| **V-09** | Python Test Suite | `.venv/bin/pytest tests/ -v` | 30 Agent tests + 25 SRE reliability tests | **PASSED** | 55/55 passed in 22.55s |
| **V-10** | POSIX Bash Test Suite | `bash scripts/tests/test_runner.sh` | 7 monitoring test suites and safety assertions | **PASSED** | 83/83 assertions passed |
| **V-11** | Bash Syntax Check | `bash -n <script.sh>` | All 44 Bash scripts across scripts/, deployment/, security/ | **PASSED** | 44/44 scripts syntactically valid |
| **V-12** | Git Formatting Check | `git diff --check` | Working tree whitespace, conflict markers, trailing spaces | **PASSED** | Clean (exits 0, zero errors) |

---

## 5. Live Host Pre-Flight Telemetry & Resource Audit

An empirical pre-flight inspection of the physical host (`rubi`) establishes the following operational baseline:

### 5.1 Port Allocation & Native Service Coexistence
- **Port 9090 (Native Prometheus):** `LISTEN` on `*:9090` (Active host systemd service).
- **Port 9100 (Native Node Exporter):** `LISTEN` on `*:9100` (Active host systemd service). Verified exporting `node_cpu_seconds_total`.
- **Port 3000 (Native Grafana):** `LISTEN` on `*:3000` (Active host systemd service).
- **Port 9101 (Custom Python Agent):** Unallocated on loopback; ready for Phase A startup.
- **Port 9091 (Lab Prometheus):** Reserved for container TSDB; strict loopback mapping `127.0.0.1:9091:9090`.
- **Port 3001 (Lab Grafana):** Unallocated on loopback; ready for Phase D startup.
- **Port 9093 (Lab Alertmanager):** Dedicated loopback mapping `127.0.0.1:9093:9093`.
- **Port 9115 (Lab Blackbox):** Dedicated loopback mapping `127.0.0.1:9115:9115`.
- **Port 3100 (Lab Loki):** Dedicated loopback mapping `127.0.0.1:3100:3100`.
- **Port 12345 (Lab Alloy):** Dedicated loopback mapping `127.0.0.1:12345:12345`.

### 5.2 Compute, Storage & Kernel Headroom
- **Root Filesystem (`/`):** 468 GB total NVMe capacity, 128 GB used, **316 GB available (29% utilization)**. Ample headroom for 10 GB TSDB and 7-day log retention bounds.
- **Physical Memory (RAM):** 15.0 GiB total, 12.0 GiB used, **2.8 GiB available**; container memory limits capped at 3.0 GiB aggregate across all 6 services.
- **Docker Host Gateway:** `host.docker.internal:host-gateway` configured in Compose for transparent container-to-host scraping.
