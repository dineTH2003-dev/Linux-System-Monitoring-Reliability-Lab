# Operational Runbook: Backup & Disaster Recovery

**Project:** Linux System Monitoring & Reliability Lab  
**Runbook ID:** RB-OPS-01 — Backup & Recovery Procedures  
**Severity:** P1 / SRE Operational Standard  
**Target Architecture:** Docker Named Volumes & Monorepo Configuration  

---

## 1. Objectives & RPO / RTO Targets

- **Recovery Point Objective (RPO)**: <= 24 hours (nightly automated or pre-change snapshot).
- **Recovery Time Objective (RTO)**: <= 15 minutes to fully restored, verified operational status.
- **Data Covered**:
  - Prometheus TSDB time-series history (`lab_prometheus_data`).
  - Grafana SQLite database, annotations, and user preferences (`lab_grafana_data`).
  - Alertmanager notification silence states and active alerts (`lab_alertmanager_data`).
  - Loki log streams and TSDB index tables (`lab_loki_data`).
  - Monorepo configurations and environment variables (`.env`).

---

## 2. Operational Phases: Verification, Preflight, and Full Recovery

To eliminate the risk of accidental data loss or split-brain corruption during disaster recovery operations, the lab architecture establishes three strictly distinct operational tiers:

### Tier 1: Backup Verification (Read-Only, Zero Impact)
- **Objective**: Cryptographically verify the integrity of a published backup set without touching running services or the Docker engine.
- **Scope**:
  - Validates the SHA-256 cryptographic checksum against `backup-set-*.sha256`.
  - Validates the Schema 2.0.0 JSON metadata manifest (`backup-set-*.manifest.json`) verifying volume byte counts, component digests, and Git commit hashes.
  - Inspects the tar table of contents (TOC) verifying required configuration directories (`prometheus/`, `grafana/`, `alertmanager/`, etc.) and volume payloads (`volumes/lab_*_data.tar.gz`).
- **Safety**: 100% non-destructive. Can be executed on a live production workstation without stopping containers.

### Tier 2: Restore Preflight (--dry-run, Read-Only Gate)
- **Objective**: Verify whether the target host environment satisfies all prerequisites for restoration before any write operations occur.
- **Execution**:
  ```bash
  ./deployment/restore.sh --dry-run ~/.local/share/lab-monitoring/backups/backup-set-<ID>
  ```
- **Evaluated Conditions**:
  - Docker daemon availability and socket permissions.
  - Verification that the target archive is uncorrupted and matches its checksum.
  - Verification that target volume names exist within the strict allowlist (`lab_prometheus_data`, `lab_grafana_data`, `lab_alertmanager_data`, `lab_loki_data`, `lab_alloy_data`).
  - **Offline Stack Gate (Exit Code 3)**: Asserts that all lab monitoring containers are stopped. If any container writing to named volumes is running, the restore immediately aborts to prevent concurrent write corruption.

### Tier 3: Full Disaster Recovery (Destructive / Write Operation)
- **Objective**: Rebuild corrupted volumes or reconstruct the observability platform following host failure.
- **Prerequisites**: Target stack MUST be stopped. Explicit `--replace-volumes` flag required.
- **Workflow**:
  1. Safe shutdown of monitoring containers (`./deployment/deploy.sh down`).
  2. Execution of `./deployment/restore.sh --replace-volumes <BACKUP_PATH>`.
  3. Automatic creation of rollback snapshots of existing volumes prior to extraction.
  4. Volume extraction via temporary worker container.
  5. Permission re-hardening (`security/harden_permissions.sh`).
  6. Stack startup and health check validation (`./deployment/healthcheck.sh`).

---

## 3. Docker Desktop Staging Directory Requirement

> [!IMPORTANT]
> **Docker Desktop for Linux VM Filesystem Boundary**:
> On Linux systems utilizing Docker Desktop (`desktop-linux` context), the container engine executes inside a virtual machine.
> The host's standard `/tmp` directory is **not** shared with the Docker VM by default. Attempting to mount `/tmp/...` into a container yields a `mount denied` error.
>
> Therefore, all backup and restore staging directories must reside within `$HOME` (which is shared with the VM):
> - **Default Staging Path**: `~/.local/share/lab-monitoring/tmp/`
> - **Default Backup Archive Path**: `~/.local/share/lab-monitoring/backups/`
>
> The backup and restore scripts automatically configure and enforce this staging root.

---

## 4. Backup Execution Procedure

### Creating a Verified Backup
Execute the automated backup orchestrator from the repository root:
```bash
./deployment/backup.sh --mode=checkpoint
```

### Verification Checklist:
1. Confirm exit code is `0`.
2. Locate the published backup set directory:
   ```bash
   ls -la ~/.local/share/lab-monitoring/backups/
   ```
3. Verify SHA-256 integrity:
   ```bash
   sha256sum -c ~/.local/share/lab-monitoring/backups/backup-set-*/backup-*.tar.gz.sha256
   ```
4. Verify JSON Schema 2.0.0 manifest:
   ```bash
   python3 -m json.tool ~/.local/share/lab-monitoring/backups/backup-set-*/backup-*.manifest.json > /dev/null && echo "Manifest valid"
   ```

---

## 5. Isolated Restore Demonstration (Non-Destructive Testing)

> [!NOTE]
> **Operational Verification Status**:
> In the current live workstation environment:
> - **Demonstrated & Verified**: Backup creation (`deployment/backup.sh`), SHA-256 cryptographic checksum verification, Schema 2.0.0 JSON metadata manifest validation, and `--dry-run` preflight safety verification (`deployment/restore.sh --dry-run`).
> - **Not Yet Demonstrated**: An end-to-end full restore execution (actual live extraction and volume overwriting) has **not yet been demonstrated**, as doing so would require tearing down active monitoring containers and risking live persistent TSDB data. Full restoration is governed by strict safety gates (`--replace-volumes`, offline stack check) and should be validated in a dedicated isolated staging drill.

To demonstrate or test the disaster recovery procedure in an operational environment without stopping live containers or risking production volume data:

### Method A: Execute Preflight Simulation (--dry-run)
```bash
./deployment/restore.sh --dry-run ~/.local/share/lab-monitoring/backups/backup-set-<ID>
```
*Expected Behavior:* If the stack is currently running, the preflight validates archive integrity, displays all volume manifests, and safely halts at Step 4 (Offline Stack Gate) with Exit Code `3 (ERR_STACK_ACTIVE)`, proving safety guardrails prevent accidental data overwrite.

### Method B: Isolated Offline Extraction to Sandbox Directory
To inspect and verify extracted files without modifying the live workspace or Docker named volumes:
```bash
SANDBOX_DIR=$(mktemp -d -p "${HOME}/.local/share/lab-monitoring/tmp" sandbox-XXXXXX)
tar -zxvf ~/.local/share/lab-monitoring/backups/backup-set-*/backup-*.tar.gz -C "$SANDBOX_DIR"
ls -la "$SANDBOX_DIR/configs"
ls -la "$SANDBOX_DIR/volumes"
rm -rf "$SANDBOX_DIR"
```

### Method C: Staging Volume Restoration
If testing volume extraction without altering production volumes:
1. Extract volume archives directly into uniquely named test volumes (e.g., `test_restore_prometheus`):
   ```bash
   docker volume create test_restore_prometheus
   docker run --rm -v test_restore_prometheus:/target -v ~/.local/share/lab-monitoring/backups/backup-set-<ID>:/source:ro alpine:latest tar -zxvf /source/volumes/lab_prometheus_data.tar.gz -C /target
   docker run --rm -v test_restore_prometheus:/data alpine:latest ls -la /data/wal
   docker volume rm test_restore_prometheus
   ```

---

## 6. Full Disaster Recovery Execution (Operational Outage)

When recovering from an actual node failure or corrupted volume incident:

1. **Cleanly stop all monitoring services**:
   ```bash
   ./deployment/deploy.sh down
   docker ps | grep -E 'lab-(prometheus|grafana|alertmanager|loki|alloy)' || echo "Containers stopped cleanly."
   ```

2. **Execute Full Restoration**:
   ```bash
   ./deployment/restore.sh --replace-volumes ~/.local/share/lab-monitoring/backups/backup-set-<ID>
   ```

3. **Verify and Relaunch Stack**:
   ```bash
   ./deployment/deploy.sh up
   ./deployment/healthcheck.sh
   ```
4. Confirm historical metric and log queries in Prometheus (`http://127.0.0.1:9091`) and Grafana (`http://127.0.0.1:3001`).
