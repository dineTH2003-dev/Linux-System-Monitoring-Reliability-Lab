# Changelog

All notable changes to the **Linux System Monitoring & Reliability Lab** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-11-03

### Added
- **Linux Kernel & Host Telemetry:**
  - Bare-metal system monitoring across CPU, memory, process states, block devices, filesystems, network interfaces, and systemd services.
  - Linux Pressure Stall Information (PSI) metrics integration across CPU, memory, and I/O.
- **Custom Automation & Monitoring Agent:**
  - Native Python 3 monitoring agent (`:9101`) exposing Prometheus metrics via an isolated multi-collector registry (`agent/collectors/`).
  - Modular POSIX Bash diagnostics toolkit (`scripts/monitoring/`) with 7 standalone health-check scripts conforming to Nagios exit code conventions.
- **Time-Series Metrics & Probing Pipeline:**
  - Hardened Prometheus TSDB (`:9091`) scraping host Node Exporter, Python agent, and container metrics.
  - Multi-target Blackbox Exporter (`:9115`) probing HTTP health endpoints and public DNS resolvers (`1.1.1.1`, `8.8.8.8`).
- **Operational Visualization (Grafana):**
  - 5 production-engineered dashboards (`:3001`): `01 - Linux System Overview`, `02 - CPU and Memory`, `03 - Storage and Filesystem`, `04 - Network and systemd`, `05 - Python Agent & SRE Overview`.
- **Alert Engineering & Webhook Triage:**
  - Alertmanager pipeline (`:9094`) with grouping, deduplication, inhibition rules, and webhook routing.
  - Standalone mock alert receiver daemon (`:5002`) capturing and persisting firing/resolved JSON payloads.
  - 20 comprehensive SRE operational runbooks in `docs/troubleshooting/` corresponding to Alertmanager alert annotations.
- **Centralized Log Aggregation:**
  - Grafana Loki (`:3100`) containerized log aggregation engine.
  - Grafana Alloy (`:12345`) forwarding host `systemd-journald` logs with label extraction and tenant isolation.
- **SRE Reliability Framework:**
  - Defined Service Level Indicators (SLIs) and 99.9% Service Level Objectives (SLOs) across host telemetry and synthetic probing.
  - Multi-window, multi-burn-rate error budget alerting rules (`sre_rules.yml`).
  - Empirical MTTD, MTTR, and MTBF tracking algorithms (`scripts/reliability/lifecycle_math.py`).
- **Chaos Engineering & Automated Remediation:**
  - Controlled failure simulations for CPU saturation, memory starvation, storage capacity, inode pressure, network latency, and service termination.
  - Automated self-healing controllers (`scripts/remediation/`) with idempotency checks, retry ceilings (circuit breakers), and rollback capabilities.
- **Disaster Recovery & Backup Automation:**
  - Automated volume backup engine (`deployment/backup.sh`) with Schema 2.0.0 metadata manifests and SHA-256 integrity verification.
  - Disaster recovery restoration engine (`deployment/restore.sh`) with safety preflight checks and `--dry-run` validation.
- **Governance & Open-Source Compliance:**
  - MIT License (`LICENSE`), Contribution Guidelines (`CONTRIBUTING.md`), Security Policy (`SECURITY.md`), and comprehensive documentation directory index.

### Changed
- **Documentation Streamlining & Noise Elimination:**
  - Removed 52 historical prompt-by-prompt development sprint boards, intermediate audits, and incremental phase reports to establish a pristine, industry-standard SRE repository.
  - Consolidated live demonstration reports into an empirical report (`docs/reports/live-demonstration.md`) while archiving raw evidence logs in `docs/reports/final-live-demonstration/`.
  - Organized documentation into 8 focused operational directories: `architecture/`, `deployment/`, `monitoring/`, `reliability/`, `reports/`, `security/`, `sre/`, and `troubleshooting/`.
- **Directory Cleanliness:**
  - Removed empty directory placeholders (`reports/`, `docs/setup/`, `deployment/templates/`).

### Fixed
- **Grafana CPU Utilization by Mode Vector Matching:**
  - Resolved PromQL vector-join mismatch on Panel ID 7 in `01-linux-system-overview.json` and `02-cpu-and-memory.json`.
  - Replaced fragile binary vector division with `avg by (mode) (rate(node_cpu_seconds_total{mode!="idle",job="node",instance=~"$instance"}[$__rate_interval])) * 100`, eliminating "No data" panels while accurately displaying all 7 CPU modes.
- **Blackbox HTTP Probing Compatibility:**
  - Standardized Blackbox Exporter HTTP module headers to prevent HTTP 400 errors during loopback endpoint probing.
