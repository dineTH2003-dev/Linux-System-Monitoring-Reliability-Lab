# Secrets Management Architecture & Policy

**Project:** Linux System Monitoring & Reliability Lab  
**Document Ref:** SEC-03 — Secrets Management & Cryptographic Hygiene  
**Author:** Agent 11 (Infrastructure Security & Deployment Engineer)  

---

## 1. Secrets Classification & Taxonomy

The monitoring and observability infrastructure processes several classes of sensitive tokens and configuration data:

| Classification | Sensitivity Level | Examples | Target Service | Storage Mechanism |
|---|---|---|---|---|
| **Administrative Credentials** | Critical | Grafana Admin Password (`GF_SECURITY_ADMIN_PASSWORD`), local database passwords | Grafana UI, Postgres | Environment variable (`.env`), protected mode `0600` |
| **Notification Webhooks** | High | Slack Incoming Webhook URL (`ALERTMANAGER_SLACK_WEBHOOK_URL`), Discord webhooks | Alertmanager | Injected via `.env` or mounted secret template |
| **API & Service Keys** | High | PagerDuty Integration Key, external SMS gateway keys | Alertmanager | Environment variables, sealed templates |
| **Transport Encryption Keys** | Critical | TLS Private Keys (`*.key`, `*.pem`), SSL certificates | Prometheus TLS, Grafana HTTPS | Filesystem volume mounted `:ro`, mode `0400` |
| **SMTP Relay Credentials** | Medium | Mail server username and passwords for alert dispatching | Alertmanager | Environment variables (`.env`) |

---

## 2. Secrets Handling Invariants & Anti-Patterns

### Core Rules:
1. **Never Commit Live Secrets**: Under no circumstances may real API tokens, private keys, production passwords, or unmasked webhook URLs be committed to the Git repository.
2. **Deterministic Exclusion**: Git ignore patterns must enforce broad regex exclusions for `.env`, `.env.*`, `*.pem`, `*.key`, `*.pfx`, `*.kdbx`, `*.tfvars`, `*.kubeconfig`, while explicitly permitting `.env.example`.
3. **Least Privilege File Modes**: Any active `.env` file containing local development credentials must be restricted to mode `0600` (readable and writable only by the file owner).
4. **Sanitized Public Templates**: `.env.example` must contain only synthetic placeholders (e.g., `CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS`) that fail gracefully or prompt immediate configuration by operators.
5. **Continuous Verification**: Static secret scanning (`security/secret_scanner.sh`) must be executed prior to any deployment or code promotion.

---

## 3. Environment Configuration Lifecycle

```
┌────────────────────────┐
│      .env.example      │ ── (Tracked in Git, zero secrets, documented schema)
└───────────┬────────────┘
            │  Operator executes:
            │  cp .env.example .env && chmod 600 .env
            ▼
┌────────────────────────┐
│          .env          │ ── (Untracked, excluded by .gitignore, mode 0600)
└───────────┬────────────┘
            │  Injected at runtime via Docker Compose
            ▼
┌────────────────────────┐
│   Running Containers   │ ── (Variables consumed in memory; never written to image)
└────────────────────────┘
```

### 3.1 Initializing Local Development Secrets
To initialize the monitoring lab with secure credentials:
```bash
# 1. Copy template to active configuration
cp .env.example .env

# 2. Restrict permissions to owner only
chmod 600 .env

# 3. Generate a strong cryptographic password for Grafana admin (min 24 characters)
NEW_ADMIN_PW=$(openssl rand -base64 24)
sed -i "s/CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS/${NEW_ADMIN_PW}/" .env

# 4. Verify permissions
ls -la .env
# Output must show: -rw------- 1 dineth dineth ... .env
```

---

## 4. Secret Scanner Implementation & Usage

The project includes an automated secret scanner (`security/secret_scanner.sh`) that audits both the current working tree and the full Git commit history.

### Scanned Signatures:
- RSA, EC, OpenSSH, DSA, PGP private key headers.
- AWS Access Key IDs (`AKIA...`) and secret keys.
- GitHub personal access tokens (`ghp_...`, `gho_...`).
- Slack incoming webhook service URLs (`hooks.slack.com/services/...`).
- Generic high-entropy bearer tokens and JWT credentials.
- Unmasked password assignments in configuration files.

### Execution:
```bash
./security/secret_scanner.sh
```
Exit code `0` confirms clean status; exit code `1` halts deployment and reports offending files and line numbers.

---

## 5. Incident Response: Remediation of Compromised Credentials

If a credential or token is accidentally committed or exposed:
1. **Immediate Revocation**: Instantly invalidate the token at the provider (e.g., revoke Slack webhook, rotate SMTP password, regenerate PagerDuty key). Do not assume removing the commit eliminates exposure.
2. **Git History Purge**: If committed to a branch, use `git filter-repo` or BFG Repo-Cleaner to permanently scrub the signature from all refs.
3. **Rotate Local Secret**: Generate a new credential and update the local `.env` file.
4. **Audit Logs**: Inspect service logs (e.g., mail relay, Slack integration logs) for unauthorized invocations occurring during the exposure window.
