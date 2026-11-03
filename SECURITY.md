# Security Policy: Linux System Monitoring & Reliability Lab

The **Linux System Monitoring & Reliability Lab** is designed with defense-in-depth principles, enforcing strict host-level isolation, CIS container security benchmarks, and automated static credential detection.

---

## 1. Supported Versions

Security updates and patches are applied to the active mainline release:

| Release Tier | Supported | Status |
|---|---|---|
| `main` (v1.0.x) | Yes | Actively maintained & validated |
| Historical branches | No | Deprecated |

---

## 2. Reporting a Vulnerability

If you discover a security vulnerability or credential leak within this repository, please do not file a public issue.

1. **Email Disclosure:** Report findings privately to the repository owner via GitHub profile contact details.
2. **Details to Include:**
   - Nature of the vulnerability (e.g. secret exposure, capability leak, privilege escalation, unauthenticated socket).
   - Exact steps or proof of concept (PoC) to reproduce the vulnerability safely.
   - Recommended remediation or patch.
3. **Response Timeline:** You will receive an initial response within 48 hours and an assessment/fix within 7 business days.

---

## 3. Platform Security Architecture & Threat Invariants

The platform implements five strict security invariants across all configurations:

### 1. Loopback Port Binding (Network Isolation)
All published service ports are strictly bound to `127.0.0.1`:
- Prometheus: `127.0.0.1:9091`
- Grafana: `127.0.0.1:3001`
- Alertmanager: `127.0.0.1:9093`
- Loki: `127.0.0.1:3100`
- Blackbox Exporter: `127.0.0.1:9115`
- Grafana Alloy: `127.0.0.1:12345`
- Custom Python Agent: `127.0.0.1:9101`
- Mock Alert Receiver: `127.0.0.1:5002`

Zero container or agent listeners are exposed on `0.0.0.0`. External networks cannot reach or exploit monitoring sockets directly.

### 2. Container Hardening Profile (CIS Docker Benchmark)
All container definitions in `docker-compose.yml` pass 42/42 CIS Docker Benchmark checks (`security/container_audit.sh`):
- **Explicit Non-Root Users:**
  - Prometheus & Blackbox Exporter: `user: "65534:65534"` (`nobody:nogroup`)
  - Grafana: `user: "472:472"` (`grafana:grafana`)
  - Loki: `user: "10001:10001"` (`loki:loki`)
  - Alloy: `user: "0:999"` (non-root `systemd-journal` GID mapping for read-only log access)
  - Alertmanager: `user: "65534:65534"`
- **Read-Only Root Filesystems:** All containers enforce `read_only: true`. Temporary or stateful directories are mounted via isolated named volumes (`lab_*`) or tmpfs.
- **Capabilities Dropped:** All Linux capabilities are dropped (`cap_drop: [ALL]`), with strictly scoped exceptions where necessary (`NET_RAW` for Blackbox ICMP and `NET_BIND_SERVICE` for Alloy).
- **Privilege Escalation Prevention:** Enforced via `security_opt: ["no-new-privileges:true"]`.

### 3. Secrets & Credential Management
- Sensitive values (e.g., `GF_SECURITY_ADMIN_PASSWORD`) are loaded strictly via an untracked, local `.env` file with restrictive permissions (`chmod 600 .env`).
- Default or placeholder passwords (e.g. `CHANGEME_*`) are automatically rejected during deployment preflight (`deployment/deploy.sh` and `test_placeholder_password_rejected`).
- Static scanning (`security/secret_scanner.sh`) scans all working tree files and the entire commit history for credentials and API tokens.

### 4. Least-Privilege Daemon Execution
Native host daemons (custom Python agent) operate under non-privileged service accounts without `sudo` privileges. The agent accesses `/proc` and `/sys` strictly using read-only filesystem permissions.

### 5. Automated Security Audit Tools
The repository includes automated verification scripts executed in CI/validation:
```bash
# Verify zero cleartext credentials across working tree and Git history:
bash security/secret_scanner.sh

# Verify 100% compliance with container hardening invariants:
bash security/container_audit.sh
```
