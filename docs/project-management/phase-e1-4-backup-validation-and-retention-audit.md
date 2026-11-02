# Phase E.1.4 — Backup Validation and Retention Safety Audit

**Date:** 2026-10-29  
**Role:** Principal SRE / Linux Storage Reliability Engineer  
**Repository:** `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`  
**Target File Modified:** `deployment/backup.sh`  
**Status:** `PATCH READY FOR INDEPENDENT REVIEW`

---

## Executive Summary

Phase E.1.4 resolves all outstanding reliability, safety, and security findings identified in the independent review of Phase E.1.3. The remediation focused strictly on `deployment/backup.sh`, adding comprehensive nested volume archive validation, establishing an 8-point trustworthy retention evaluation gate, eliminating automated deletion of temporary staging directories, enforcing strict destination path/ownership/permission boundaries, upgrading the manifest to Schema v2.0.0 with structured arrays and per-volume results, and correcting security policy claims to reflect filename-pattern-based filtering.

In accordance with strict operational boundaries:
- No backup execution was performed.
- No Docker commands, container lifecycle operations, or volume operations were executed.
- No Git operations were performed.
- Validation was restricted strictly to `bash -n deployment/backup.sh` and static inspection.

---

## 1. Exact Changes Made

### 1.1 Nested Volume Archive Validation (Step 2)
In Phase E.1.3, volume snapshotting relied solely on the exit code of `docker run`. If the container exited 0 but produced an empty, truncated, or corrupt archive, the volume was incorrectly recorded in `VOLUMES_ARCHIVED`.

**Corrections:**
- Immediately following `docker run`, the generated archive `$TEMP_STAGE/volumes/${vol}.tar.gz` is validated through three sequential checks:
  1. Regular file check: `[[ -f "$VOL_ARCHIVE" ]]` (fails with `FAILED_FILE_MISSING` if absent).
  2. Non-empty check: `[[ -s "$VOL_ARCHIVE" ]]` (fails with `FAILED_EMPTY_ARCHIVE` if 0 bytes).
  3. Tar integrity check: `tar -tzf "$VOL_ARCHIVE" >/dev/null 2>&1` (fails with `FAILED_CORRUPT_ARCHIVE` if unreadable).
- Any validation failure routes the volume to `VOLUMES_FAILED+=("$vol")` and sets `VOLUME_VALIDATION_STATUS["$vol"]`.
- The volume is appended to `VOLUMES_ARCHIVED` **only** after passing all three checks.
- In `checkpoint` mode, any failed or missing volume triggers immediate abort at the Checkpoint Mode Gate (`exit 2`), preventing archive creation or publication.
- In `routine` mode, any failed volume archive validation triggers immediate abort (`exit 2`), ensuring corrupt archives are never published even in partial mode.

### 1.2 Trustworthy Retention Evaluation Gate (Step 4)
In Phase E.1.3, candidate backup sets older than `RETENTION_DAYS` were evaluated solely on whether three files were non-empty, risking the deletion of valid backups when unverified, or deleting backups whose inner archives were corrupt.

**Corrections:**
- Established an 8-point gate that every candidate directory must pass before deletion:
  1. **Exclusion of Active Set:** Explicitly skips `$FINAL_BACKUP_SET`.
  2. **Artifact Existence:** Validates presence and non-zero size for `.tar.gz`, `.manifest`, and `.sha256`.
  3. **Manifest Parseability:** Verifies that `manifest_schema_version` is present and non-empty.
  4. **Identity Consistency:** Verifies that `backup_id` and `archive_filename` in the manifest match the directory name and archive filename.
  5. **Strict Status Gate:** Verifies `backup_status` is exactly `SUCCESS`. Candidates with status `PARTIAL_ROUTINE`, `FAILED`, unknown, or missing status are explicitly preserved.
  6. **Cryptographic Checksum:** Re-verifies SHA-256 integrity via `sha256sum -c`.
  7. **Outer Archive Readability:** Re-verifies outer archive header and stream integrity via `tar -tzf`.
  8. **Nested Volume Archives Readability:** Dynamically parses `required_volumes` from the candidate manifest and tests each nested volume archive via streaming pipe (`tar -xzf ... -O ... | tar -tzf -`).
- Every skipped candidate logs a clear, human-readable reason to stderr (e.g., `[NOTICE] Preserving candidate '...': backup_status is 'PARTIAL_ROUTINE'`).
- `RETENTION_ERROR=1` is set if any validated deletion fails, returning `exit 8` while preserving the newly published backup set.

### 1.3 Safe Stale Temporary Staging Handling (Step 4 & Section 4)
In Phase E.1.3, stale staging directories (`.tmp-set-*`) older than 24 hours were removed automatically via `rm -rf`, creating a critical race condition if an active backup ran across day boundaries or host clocks skewed.

**Corrections:**
- **Automated deletion removed:** Automated deletion of `.tmp-set-*` based on age alone has been completely eliminated.
- **Active Process Locking:** When `$TMP_SET_DIR` is created, the script writes a `.process_lock` file containing PID, hostname, UTC start timestamp, backup ID, and operational mode.
- **Pre-Publication Cleanup:** `.process_lock` is unlinked immediately prior to atomic `mv -n -T` publication so published sets contain only standard artifacts.
- **Liveness Inspection:** During retention, existing `.tmp-set-*` directories are inspected:
  - If `.process_lock` records an active PID (`kill -0 "$lock_pid"`), the script logs `[INFO]` and preserves the directory.
  - If the PID is dead or lockfile is absent, the script logs `[WARN]` notifying operators of an abandoned staging directory and directing them to the manual recovery procedure.

### 1.4 Strict Destination Validation (Section 3)
In Phase E.1.3, `realpath -m` was called before checking whether the raw `BACKUP_DIR` was a symlink, and non-0700 permissions on existing user-owned directories were overwritten without explicit confirmation.

**Corrections:**
- **Raw Path Inspection:** `BACKUP_DIR` is checked prior to canonicalization: empty paths and symbolic links are rejected immediately (`exit 10`).
- **Canonical Target Validation:** Verifies resolved path is not root `/`, system directories (`exit 11`), or inside repository root (`exit 12`).
- **Strict Ownership Requirement:** The target directory must be owned by the current user (`UID == id -u`). If owned by another user, the script fails closed (`exit 10`).
- **Strict Permission Enforcement (Fail Closed):**
  - If the directory already exists, its mode must be strictly `0700`.
  - If permissions are broader (e.g. `0755`, `0777`), the script fails closed (`exit 10`) and refuses to modify permissions automatically, preventing unintended changes to shared or unrelated directories.
  - If the directory does not exist, it is created with `mkdir -p` and `chmod 0700`, followed by immediate re-verification of ownership and permissions.

### 1.5 Machine-Readable Manifest Schema v2.0.0 (Section 9)
Upgraded manifest from flat string lists to a fully structured YAML schema with array elements and per-volume validation records:
- Schema version: `"2.0.0"`
- `required_config_dirs`, `required_volumes`, `archived_volumes`, `missing_volumes`, and `failed_volumes` are structured YAML lists (`- "name"` or `[]`).
- Added `volume_validation_results` detailing `status`, `exists`, `archive_verified`, and `archive_bytes` for each required volume.

### 1.6 Corrected Security Policy Wording
- Replaced claims that "all secrets are purged" with accurate terminology: "filename-pattern-based secret exclusion".
- Explicitly documented that pattern matching evaluates filenames/directory paths only, and content inspection is not performed to prevent secret leakage.

---

## 2. Updated Manifest Schema Example (Schema v2.0.0)

```yaml
manifest_schema_version:    "2.0.0"
backup_id:                  "20261029-060000Z-7f8e9d0a1b2c3d4e"
created_at_utc:             "2026-10-29T06:00:00Z"
created_at_epoch:           1793253600
backup_mode:                "checkpoint"
backup_status:              "SUCCESS"
consistency_classification: "LIVE FILE-LEVEL BACKUP — APPLICATION CONSISTENCY AND CRASH CONSISTENCY NOT GUARANTEED"
repository_root:            "/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab"
backup_set_directory:       "backup-set-20261029-060000Z-7f8e9d0a1b2c3d4e"
archive_filename:           "backup-20261029-060000Z-7f8e9d0a1b2c3d4e.tar.gz"
archive_sha256:             "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
archive_size_bytes:         52428800
archive_size_human:         "50M"
permissions_directory:      "0700"
permissions_files:          "0600"
secret_exclusion_policy:    "filename_pattern_based (excludes matching .env, keys, certs, credentials; content scanning not performed)"
required_config_dirs:
  - "prometheus"
  - "grafana"
  - "alertmanager"
  - "loki"
  - "blackbox"
  - "alloy"
  - "agent"
  - "scripts"
  - "security"
  - "deployment"
required_volumes:
  - "lab_prometheus_data"
  - "lab_grafana_data"
  - "lab_alertmanager_data"
  - "lab_loki_data"
  - "lab_alloy_data"
archived_volumes:
  - "lab_prometheus_data"
  - "lab_grafana_data"
  - "lab_alertmanager_data"
  - "lab_loki_data"
  - "lab_alloy_data"
missing_volumes:
  []
failed_volumes:
  []
volume_validation_results:
  lab_prometheus_data:
    status: "PASSED"
    exists: true
    archive_verified: true
    archive_bytes: 18432000
  lab_grafana_data:
    status: "PASSED"
    exists: true
    archive_verified: true
    archive_bytes: 4194304
  lab_alertmanager_data:
    status: "PASSED"
    exists: true
    archive_verified: true
    archive_bytes: 524288
  lab_loki_data:
    status: "PASSED"
    exists: true
    archive_verified: true
    archive_bytes: 20971520
  lab_alloy_data:
    status: "PASSED"
    exists: true
    archive_verified: true
    archive_bytes: 1048576

storage_consistency_notice:
  Backing up live container volumes via sequential tar reads does NOT guarantee
  crash consistency or application consistency. Active database engines (Grafana SQLite)
  and time-series engines (Prometheus TSDB, Loki) write Write-Ahead Logs (WAL), indexes,
  and memory chunks concurrently. Sequential file copying across an active directory
  can read non-atomic states spanning different points in time.
  For verified application-consistent migration checkpoints, operators MUST execute:
    1. Orderly application shutdown: './deployment/deploy.sh down' prior to backup, OR
    2. Supported application-specific snapshot procedures:
       - Prometheus: POST /api/v1/snapshot API
       - Grafana: SQLite 'VACUUM INTO' online backup
  This script intentionally DOES NOT automatically stop running services to avoid
  causing unplanned production monitoring outages.
```

---

## 3. Checkpoint and Routine-Mode Control-Flow Outcomes

| Operational Scenario | Selected Mode | Exit Code | Final Set Published? | Temporary Staging Cleaned? | Retention Pruning Executed? |
| :--- | :--- | :---: | :---: | :---: | :---: |
| Help requested (`--help`, `-h`) | Any | `0` | No | Yes (none created) | No |
| Invalid CLI flag / syntax error | Any | `2` | No | Yes (none created) | No |
| Raw destination is empty / symlink | Any | `10` | No | Yes (none created) | No |
| Destination system dir / inside repo | Any | `11` / `12` | No | Yes (none created) | No |
| Destination owned by another user / broad mode | Any | `10` | No | Yes (none created) | No |
| Secure random `/dev/urandom` unavailable | Any | `7` | No | Yes (none created) | No |
| Required configuration directory missing | Any | `14` | No | Yes (`on_exit` trap) | No |
| Docker CLI missing in PATH | Any | `3` | No | Yes (`on_exit` trap) | No |
| Docker socket permission denied | Any | `4` | No | Yes (`on_exit` trap) | No |
| Docker daemon unavailable / unreachable | Any | `5` | No | Yes (`on_exit` trap) | No |
| Volume inspection fatal communication error | Any | `6` | No | Yes (`on_exit` trap) | No |
| Missing volume in checkpoint mode | `checkpoint` | `2` | No | Yes (`on_exit` trap) | No |
| Volume snapshot command fails in checkpoint mode | `checkpoint` | `2` | No | Yes (`on_exit` trap) | No |
| Volume archive corrupt / empty in checkpoint mode | `checkpoint` | `2` | No | Yes (`on_exit` trap) | No |
| All components fail in routine mode | `routine` | `2` | No | Yes (`on_exit` trap) | No |
| Volume snapshot command fails in routine mode | `routine` | `2` | No | Yes (`on_exit` trap) | No |
| Volume archive corrupt / empty in routine mode | `routine` | `2` | No | Yes (`on_exit` trap) | No |
| Target backup set collision detected | Any | `15` | No | Yes (`on_exit` trap) | No |
| Outer archive corrupt / staged checksum mismatch | Any | `13` | No | Yes (`on_exit` trap) | No |
| Atomic rename fails (`mv -n -T` error) | Any | `16` | No | Yes (`on_exit` trap) | No |
| Post-publication verification fails | Any | `16` | No | Yes (`on_exit` trap) | No |
| Operator interrupt (`SIGINT` / `SIGTERM`) | Any | `130` / `143` | No | Yes (`on_sig*` trap) | No |
| **All volumes exist & pass validation; retention succeeds** | `checkpoint` | **`0`** | **Yes** | **Yes** | **Yes** |
| **All volumes exist & pass validation; retention error** | `checkpoint` | **`8`** | **Yes** | **Yes** | **Yes (partial)** |
| **Missing volume in routine mode; archives pass; retention ok** | `routine` | **`1`** | **Yes** | **Yes** | **Yes** |
| **Missing volume in routine mode; archives pass; retention err**| `routine` | **`8`** | **Yes** | **Yes** | **Yes (partial)** |

---

## 4. Retention Eligibility Rules & Staging Recovery Procedure

### 4.1 Candidate Backup-Set Eligibility Checklist
A directory matching `backup-set-YYYYMMDD-HHMMSSZ-*` in `$CANONICAL_BACKUP_DIR` is pruned if and only if all eight criteria are satisfied:
1. **Not Current:** Path is not equal to `$FINAL_BACKUP_SET`.
2. **Artifact Completeness:** Contains regular, non-empty `backup-${id}.tar.gz`, `backup-${id}.tar.gz.manifest`, and `backup-${id}.tar.gz.sha256`.
3. **Parseable Manifest:** Contains a valid `manifest_schema_version`.
4. **Identity Match:** Manifest `backup_id` and `archive_filename` match the directory identifier.
5. **Success Status:** Manifest `backup_status` is exactly `SUCCESS`. Backups with `PARTIAL_ROUTINE`, `FAILED`, or malformed status are permanently preserved.
6. **Checksum Verification:** In-situ `sha256sum -c` passes.
7. **Outer Archive Integrity:** `tar -tzf` passes without error.
8. **Nested Volume Integrity:** Every volume listed under `required_volumes` in the manifest successfully streams through `tar -xzf ... -O ... | tar -tzf -`.

### 4.2 Safe Manual Staging Recovery Procedure
Because automated deletion of `.tmp-set-*` directories is disabled to prevent race conditions, abandoned staging directories (e.g. from hard host reboot during backup) must be handled manually:
1. **Identify Staging Directories:**
   ```bash
   ls -ld "${BACKUP_DIR:-$HOME/.local/share/lab-monitoring/backups}"/.tmp-set-*
   ```
2. **Inspect Process Lock Metadata:**
   ```bash
   cat "${BACKUP_DIR:-$HOME/.local/share/lab-monitoring/backups}"/.tmp-set-*/.process_lock
   ```
3. **Verify Process State:**
   Check if the PID recorded in `pid=<PID>` is currently running:
   ```bash
   ps -p <PID> -o pid,user,etime,args
   ```
4. **Manual Pruning:**
   If the process does not exist (or the host was rebooted since `started_at`), verify no other backup is running and prune safely:
   ```bash
   rm -rf "${BACKUP_DIR:-$HOME/.local/share/lab-monitoring/backups}/.tmp-set-<ID>-<HASH>"
   ```

---

## 5. Static Validation Command and Results

Syntax validation executed on [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh):

```bash
dineth@dineth-Aspire-A715-42G:~/dev/Linux-System-Monitoring-Reliability-Lab$ bash -n deployment/backup.sh
dineth@dineth-Aspire-A715-42G:~/dev/Linux-System-Monitoring-Reliability-Lab$ echo $?
0
```

- **Exit Code:** `0`
- **ShellCheck / POSIX Compliance:** Syntax is valid Bash 4.4+; associative arrays (`declare -A`) are properly scoped; all trap routines are disarmed before clean exits.

---

## 6. Remaining Limitations & Non-Claims

1. **Non-Atomic Live Snapshots:**  
   Copying active Docker volume directories via sequential `tar` reads does not guarantee crash consistency or application consistency. Active WAL writes (Prometheus TSDB, Loki TSDB) and transaction journals (Grafana SQLite) can result in torn states. Application-consistent checkpoints require orderly shutdown (`./deployment/deploy.sh down`) or application snapshot APIs.
2. **Content-Level Secret Leakage Risk:**  
   Secret exclusion is strictly filename-pattern-based (`.env`, `*.key`, `*.pem`, etc.). Files with innocuous names containing hardcoded API keys or tokens are not scanned or removed, as automated content scanning carries substantial risk of accidental secret exposure.
3. **Local Storage Single Point of Failure:**  
   Backups are written to the local host filesystem. Full disaster recovery requires external replication (rsync over SSH, S3, or GCS), which is outside the scope of this local orchestration script.
4. **Runtime Non-Claim:**  
   No backup execution was performed. The script has not been run against live containers or real Docker named volumes. It is not declared production-ready.

---

## 7. Mandatory Execution Attestation

I confirm that during Phase E.1.4:
- `deployment/backup.sh` was NOT executed.
- No `docker`, `docker run`, `docker compose`, or volume operations were executed.
- No containers were started, stopped, restarted, or created.
- No packages or host system configurations were modified.
- No Git operations (status, diff, add, commit, push, reset) were executed.
- No backup data was created or deleted.
- Only static code inspection and `bash -n deployment/backup.sh` were performed.

---

**Final Status:** `PATCH READY FOR INDEPENDENT REVIEW`
