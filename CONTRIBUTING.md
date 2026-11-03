# Contributing to the Linux System Monitoring & Reliability Lab

Thank you for your interest in contributing to the **Linux System Monitoring & Reliability Lab**. This project is engineered to production Site Reliability Engineering (SRE) standards. All contributions must adhere to the architectural invariants, testing standards, and safety boundaries defined below.

---

## 1. Architectural Invariants & Safety Guardrails

Every contribution must preserve these core platform invariants:
1. **Loopback Port Isolation (Dual-Stack Coexistence):**
   - All container-published ports and native daemon endpoints must strictly bind to `127.0.0.1` (e.g. `127.0.0.1:9091:9090`).
   - Zero ports may be exposed on public interfaces (`0.0.0.0`) without explicit architectural review.
   - Do not interfere with native host services (e.g. host PostgreSQL `:5432` or default Node Exporter `:9100`).
2. **Container Least-Privilege & Hardening:**
   - All Docker services must run as explicit non-root users (`user: "uid:gid"`).
   - Root filesystems must remain `read_only: true` with writable state mounted via named volumes or tmpfs.
   - Drop all Linux capabilities (`cap_drop: [ALL]`) and enforce `no-new-privileges: true`.
3. **Non-Destructive Testing & Operational Safety:**
   - Chaos simulations and test scripts must never target root mounts (`/`), critical system directories (`/etc`, `/boot`, `/usr`), or production workloads.
   - All disk write tests must operate inside dedicated, bounded temporary directories (`/tmp/lab-*`).
   - All remediation actions must implement pre-conditions, retry ceilings (circuit breakers), and rollback handlers.
4. **Zero Credential Exposure:**
   - Never commit `.env`, API tokens, private IP addresses, passwords, or workstation paths.

---

## 2. Development Setup

### Prerequisites
- Ubuntu 24.04 LTS (or compatible Linux distribution)
- Docker & Docker Compose (v2.20+)
- Python 3.12+ with `venv`
- `promtool` (Prometheus rule validation tool)
- Standard Linux diagnostics (`procps`, `sysstat`, `iproute2`, `curl`, `jq`)

### Environment Initialization
```bash
# Clone the repository
git clone https://github.com/dineTH2003-dev/Linux-System-Monitoring-Reliability-Lab.git
cd Linux-System-Monitoring-Reliability-Lab

# Initialize virtual environment and install dependencies
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Verify environment integrity
docker compose config --quiet
```

---

## 3. Code Standards & Style Guides

### Python Components (`agent/`, `scripts/reliability/`, `tests/`)
- Follow **PEP 8** conventions.
- Implement explicit type annotations for function signatures.
- Collector modules in `agent/collectors/` must inherit from `BaseCollector` and implement `collect() -> List[Metric]`.
- All metric collectors must be fault-isolated: an exception in one collector must never crash the agent daemon or suppress other collectors.

### Bash Automation Toolkit (`scripts/monitoring/`, `scripts/lib/`, `deployment/`)
- Must adhere strictly to POSIX / Bash standards:
  ```bash
  #!/usr/bin/env bash
  set -Eeuo pipefail
  ```
- Modular functions with explicit local variables (`local var_name`).
- All scripts must provide `--help` and `--version` flags.
- Exit codes must follow Nagios/Monitoring standards:
  - `0`: OK / Healthy
  - `1`: Informational / General Warning
  - `2`: Invalid CLI Argument / Precondition Failure
  - `3`: Warning Threshold Breached
  - `4`: Critical Threshold Breached

### Prometheus Alert Rules & Promtool Tests (`prometheus/`)
- Metrics must follow OpenMetrics and Prometheus naming conventions (`<subsystem>_<noun>_<unit>`).
- Alert rules must define explicit labels: `severity` (`critical`, `warning`), `component`, and `tier`.
- Alert annotations must include `summary`, `description`, and a valid `runbook_url` pointing to `docs/troubleshooting/<name>.md`.
- Every alert rule must have corresponding unit test assertions in `prometheus/tests/*.yml`.

### Grafana Dashboards (`grafana/dashboards/`)
- All panel queries must use `$instance` and `$__rate_interval` template variables.
- Vector matching operations must preserve label symmetry (`sum by (...)` / `avg by (...)`).
- Avoid manual vector joins when native aggregation functions (`avg by (...)`) provide mathematical equivalence.

---

## 4. Mandatory Pre-Commit Validation Suite

Before submitting a Pull Request, all 5 automated validation suites must pass with zero errors:

```bash
# 1. Python Unit, Contract, and Deployment Safety Tests
./.venv/bin/pytest tests/python/ tests/reliability/ -v

# 2. Bash Monitoring & POSIX Compliance Tests
bash scripts/tests/test_runner.sh

# 3. Prometheus Rule Syntax and Promtool Unit Tests
promtool check config prometheus/prometheus.yml
promtool check rules prometheus/rules/*.yml prometheus/alerts/*.yml
promtool test rules prometheus/tests/*.yml

# 4. Security & CIS Container Compliance Scans
bash security/secret_scanner.sh
bash security/container_audit.sh

# 5. Docker Compose Configuration Integrity
docker compose config --quiet
```

---

## 5. Git Commit & Pull Request Guidelines

- Format commit messages using **Conventional Commits**:
  - `feat(<component>): description` (e.g. `feat(agent): add PSI CPU stall metric collector`)
  - `fix(<component>): description` (e.g. `fix(grafana): resolve vector join mismatch in mode panels`)
  - `docs(<subsystem>): description` (e.g. `docs(troubleshooting): add runbook for swap thrashing`)
  - `test(<area>): description` (e.g. `test(promtool): add unit test for disk read latency alert`)
  - `refactor(<area>): description` (e.g. `refactor(docs): consolidate historical phase management audits`)
- Do not rewrite existing Git history on `main`. Keep commits focused, self-contained, and tested.
