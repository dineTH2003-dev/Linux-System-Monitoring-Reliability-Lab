# Phase E.1.6 — Final Retention Integrity and Cleanup Corrections Audit Report

**Date:** 2026-10-29  
**Role:** Senior Site Reliability Engineer / Disaster Recovery & Linux Storage Engineer  
**Repository:** `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`  
**Target File Modified:** `deployment/backup.sh` (exclusive authorized modification)  
**Report Document:** `docs/project-management/phase-e1-6-retention-integrity-and-cleanup-audit.md`  
**Final Review Verdict:** `PATCH READY FOR INDEPENDENT REVIEW`

---

## 1. Executive Summary

Phase E.1.6 delivers the final, definitive source-code remediation of the backup and disaster recovery automation in [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh) following the independent review of Phase E.1.5. This phase addresses the remaining operational reliability, integrity verification, and cleanup safety requirements without expanding the project scope or modifying container infrastructure.

### Key Changes Implemented
1. **Manifest and Archive Cross-Consistency Verification:** The retention validator `validate_retention_candidate()` now parses the `.sha256` sidecar file, extracts the exact cryptographic digest, and cross-verifies it against the manifest's `archive_sha256` attribute. Furthermore, it extracts the actual file byte size of the candidate archive via `stat -c "%s"` and enforces exact numeric equality with the manifest's `archive_size_bytes` attribute. Any discrepancy, malformation, or missing attribute triggers immediate candidate preservation with explanatory warnings.
2. **Complete Manifest Schema Version 2.0.0 Enforcement:** The pure-Bash retention parser is strictly constrained to YAML Schema `2.0.0`. Unsupported YAML constructs (inline/flow mappings `{...}`, anchors `&`, aliases `*`, and custom tags `!`) are identified and rejected. The parser enforces the complete set of 21 mandatory structural keys, requires duplicate-free configuration and volume arrays, verifies exact set equality between `required_volumes` and `archived_volumes` for `SUCCESS` backup sets, enforces empty `missing_volumes` and `failed_volumes` lists, and rigorously validates each volume's record under `volume_validation_results` (`status == "PASSED"`, `exists == true`, `archive_verified == true`, `archive_bytes > 0`).
3. **Strict Archive Permission Handling and Error Classification:** The unsafe pattern `chmod 0600 "$VOL_ARCHIVE" 2>/dev/null || true` has been eliminated. If setting `0600` permissions fails or if post-application file permissions differ from `0600`, the volume is classified as `FAILED_PERMISSIONS`, registered in `VOLUMES_FAILED`, and excluded from `VOLUMES_ARCHIVED`. Both checkpoint mode and routine mode enforce strict failure gates for volume processing errors, preventing the publication of improperly permissioned archives. Similar strict enforcement and verification are applied to canonical destination directories, temporary staging directories, lockfiles, unified archives, checksums, and manifest files.
4. **Idempotent Cleanup, Safe Signal Handling, and Status Preservation:** `cleanup_temp_artifacts()` has been refactored to be safely idempotent. Variable reset (`TEMP_STAGE=""`, `TMP_SET_DIR=""`) prevents repeated removal attempts and secondary errors. Signal handlers (`on_exit`, `on_sigint`, `on_sigterm`) cleanly disarm traps prior to teardown, preventing recursive handler loops while strictly preserving original exit codes (`rc`, `130`, `143`). Cleanup is explicitly invoked prior to emitting the execution summary; if temporary artifact cleanup fails, execution fails closed with exit code `1` (`ERR_CLEANUP_FAILURE`), preventing a false report of success.
5. **Abandoned Staging Liveness Safeguard:** Staging directories (`.tmp-set-*`) are inspected for lockfile PID liveness (`kill -0 "$lock_pid"`). Automated age-based deletion of staging directories remains disabled to prevent race conditions during long-running or delayed operations, providing actionable warnings for operator inspection.

### Scope and Boundary Attestation
* **Target Modified:** ONLY [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh).
* **New Report Generated:** ONLY [`docs/project-management/phase-e1-6-retention-integrity-and-cleanup-audit.md`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docs/project-management/phase-e1-6-retention-integrity-and-cleanup-audit.md).
* **Validation Method:** Static analysis, structural code review, and syntax verification via `bash -n deployment/backup.sh` (Exit Status `0`).
* **Operational Restrictions Respected:** No backups executed, no containers started/stopped/modified, no Docker commands executed, no Docker volumes mounted/inspected/modified, no host configuration or packages altered, and no Git state-changing operations performed.

---

## 2. Manifest and Archive Consistency Hardening

### 2.1 Sidecar Checksum Extraction and Manifest Cross-Validation
In previous iterations, the retention pruner verified archive integrity by executing `sha256sum -c "$expected_sha"`. While this validated that the candidate archive matched its sidecar checksum file, it did not verify whether the manifest metadata had been tampered with, corrupted, or desynchronized from the sidecar.

In Phase E.1.6, `validate_retention_candidate()` introduces a dual-channel cross-validation mechanism:
```bash
# Extract actual SHA-256 value from the checksum sidecar
local sidecar_sha=""
local sidecar_file=""
if ! read -r sidecar_sha sidecar_file < "$candidate_set/$expected_sha" || [[ -z "$sidecar_sha" ]]; then
    echo "  [WARN] Skipping candidate '$set_name': checksum sidecar '$expected_sha' is empty or unreadable." >&2
    return 1
fi
sidecar_sha="$(echo "$sidecar_sha" | tr -d ' \t\r\n')"
sidecar_sha="${sidecar_sha,,}"
if [[ ! "$sidecar_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "  [WARN] Skipping candidate '$set_name': sidecar '$expected_sha' contains invalid SHA-256 format ('$sidecar_sha')." >&2
    return 1
fi
```
The manifest scalar `archive_sha256` is extracted and normalized, and both values are evaluated:
1. Manifest `archive_sha256` must match the canonical 64-hexadecimal character regex `^[0-9a-f]{64}$`.
2. Manifest `archive_sha256` must exactly equal `sidecar_sha`.
3. Sidecar filename field (if specified) must match `$expected_archive`.

### 2.2 Archive Byte-Size Verification
Manifest metadata includes the exact byte size of the unified archive (`archive_size_bytes`). To prevent truncated archives or forged manifests from being evaluated as valid, the actual archive byte size is retrieved directly from the filesystem:
```bash
local actual_archive_bytes
actual_archive_bytes="$(stat -c "%s" "$candidate_set/$expected_archive" 2>/dev/null || echo "")"
if [[ -z "$actual_archive_bytes" || ! "$actual_archive_bytes" =~ ^[1-9][0-9]*$ ]]; then
    echo "  [WARN] Skipping candidate '$set_name': unable to obtain valid archive byte size for '$expected_archive'." >&2
    return 1
fi
```
The manifest scalar `archive_size_bytes` is validated:
1. Manifest `archive_size_bytes` must be a strictly positive integer (`^[1-9][0-9]*$`).
2. Manifest `archive_size_bytes` must exactly equal `$actual_archive_bytes`.

### 2.3 Fail-Safe Candidate Preservation
If any verification step fails (missing sidecar, unparseable hash, mismatched hash, invalid byte size, or size mismatch), the candidate is **not pruned**. The pruner emits an informative warning to stderr and returns `1`. Under no circumstances is a candidate deleted if its internal metadata cannot be conclusively proven identical to physical on-disk artifacts.

---

## 3. Complete Manifest Schema Version 2.0.0 Enforcement

### 3.1 Prohibited YAML Constructs
To prevent security vulnerabilities and parsing ambiguities inherent in non-standard YAML parsers, `validate_retention_candidate()` rejects unsupported YAML constructs:
* Flow/inline mappings: `{...}`
* Anchors and aliases: `&anchor`, `*alias`
* Custom/explicit YAML tags: `!tag`, `!!type`

```bash
# Reject unsupported YAML constructs outside consistency notice
if [[ "$current_section" != "storage_consistency_notice" ]]; then
    local re_unsupported='[*&{}]'
    local re_yaml_tag='^[[:space:]]*!'
    if [[ "$line" =~ $re_unsupported ]] || [[ "$line" =~ $re_yaml_tag ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num contains unsupported YAML construct." >&2
        return 1
    fi
fi
```

### 3.2 Mandatory Top-Level Keys
The schema definition specifies exactly 21 mandatory top-level structural keys:
1. `manifest_schema_version` (must equal `"2.0.0"`)
2. `backup_id` (matches `^[0-9]{8}-[0-9]{6}Z-[0-9a-f]{16}$`)
3. `created_at_utc` (matches `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)
4. `created_at_epoch` (matches `^[1-9][0-9]*$`)
5. `backup_mode` (`"checkpoint"` or `"routine"`)
6. `backup_status` (must equal `"SUCCESS"` for pruning eligibility)
7. `consistency_classification` (must match exact standard live backup disclosure)
8. `repository_root` (absolute path `^/`)
9. `backup_set_directory` (matches `backup-set-<BACKUP_ID>`)
10. `archive_filename` (matches `backup-<BACKUP_ID>.tar.gz`)
11. `archive_sha256` (matches 64-hex regex and sidecar checksum)
12. `archive_size_bytes` (positive integer matching filesystem `stat -c "%s"`)
13. `archive_size_human`
14. `permissions_directory` (`"0700"`)
15. `permissions_files` (`"0600"`)
16. `secret_exclusion_policy` (exact standard exclusion disclosure)
17. `required_config_dirs` (list)
18. `required_volumes` (list)
19. `archived_volumes` (list)
20. `missing_volumes` (list)
21. `failed_volumes` (list)
22. `volume_validation_results` (mapping)

Duplicate occurrences of any top-level key are detected via associative array tracking (`SEEN_TOP_KEYS`) and cause candidate rejection.

### 3.3 List and Volume Result Parity
1. **Configuration Directories:** `required_config_dirs` must contain exactly the 10 canonical lab configuration directories without duplicates (`prometheus`, `grafana`, `alertmanager`, `loki`, `blackbox`, `alloy`, `agent`, `scripts`, `security`, `deployment`).
2. **Volume Set Parity:** `required_volumes` must contain exactly the 5 canonical Docker volume targets without duplicates (`lab_prometheus_data`, `lab_grafana_data`, `lab_alertmanager_data`, `lab_loki_data`, `lab_alloy_data`).
3. **Archived Volumes Equality:** In a `SUCCESS` backup, `archived_volumes` must contain all 5 required volumes with zero duplicates.
4. **Clean Volume State:** `missing_volumes` and `failed_volumes` must be completely empty (`[]`).
5. **Per-Volume Validation Invariants:**
   Under `volume_validation_results`, every required volume must be represented exactly once with:
   - `status: "PASSED"`
   - `exists: true`
   - `archive_verified: true`
   - `archive_bytes: <positive_integer>`

No unrecognized volume names or duplicate volume result entries are permitted.

---

## 4. Archive Permission Handling and Error Classification

### 4.1 Elimination of Silent Permission Failures
In earlier revisions, setting archive permissions used the suppressing idiom:
```bash
chmod 0600 "$VOL_ARCHIVE" 2>/dev/null || true
```
This allowed underlying filesystem errors (such as read-only mounts, permission denied errors, or SELinux denials) to pass undetected.

In Phase E.1.6, this has been replaced with a strict, multi-step validation block:
```bash
if ! chmod 0600 "$VOL_ARCHIVE" 2>/dev/null; then
    echo "    [ERROR] Volume archive security validation failed for '$vol': unable to enforce 0600 permissions." >&2
    VOLUMES_FAILED+=("$vol")
    VOLUME_VALIDATION_STATUS["$vol"]="FAILED_PERMISSIONS"
    continue
fi

local v_perm
v_perm="$(stat -c "%a" "$VOL_ARCHIVE" 2>/dev/null || echo "")"
if [[ "$v_perm" != "600" && "$v_perm" != "0600" ]]; then
    echo "    [ERROR] Volume archive security validation failed for '$vol': mode '$v_perm' is not 0600." >&2
    VOLUMES_FAILED+=("$vol")
    VOLUME_VALIDATION_STATUS["$vol"]="FAILED_PERMISSIONS"
    continue
fi
```

### 4.2 Error Classification and Policy Impact
* **Exclusion from Archive Set:** A volume that fails permission enforcement is **never** added to `VOLUMES_ARCHIVED`. It is recorded in `VOLUMES_FAILED` with status `FAILED_PERMISSIONS`.
* **Checkpoint Mode Gate:** If `${#VOLUMES_FAILED[@]} -gt 0`, checkpoint mode immediately triggers failure (`FAILED_CHECKPOINT`) and aborts with `exit 2`.
* **Routine Mode Gate:** Routine mode is designed to tolerate missing volumes (`VOLUMES_MISSING`), but it strictly rejects processing failures. If `${#VOLUMES_FAILED[@]} -gt 0`, routine mode immediately aborts with `exit 2`.
* **Publication Invariant:** No backup set containing an unverified or insecurely permissioned volume archive can ever be published as `SUCCESS` or `PARTIAL_ROUTINE`.

### 4.3 End-to-End Permission Architecture
Strict permissions are enforced and verified across all lifecycle assets:
| Artifact | Path Variable | Required Mode | Enforcement / Verification Mechanism |
| :--- | :--- | :---: | :--- |
| Canonical Backup Directory | `$CANONICAL_BACKUP_DIR` | `0700` | Revalidated 4 times via `revalidate_destination_security` (`exit 10`) |
| Temporary Staging Directory | `$TMP_SET_DIR` | `0700` | Created via `mktemp -d`; checked via `stat -c "%a"` (`exit 10`) |
| Staging Process Lockfile | `$TMP_SET_DIR/.process_lock` | `0600` | Created via `umask 077`; verified `0600` (`exit 10`) |
| Config Staging Directory | `$TEMP_STAGE` | `0700` | Created via `mktemp -d`; verified `0700` (`exit 10`) |
| Volume Archive Files | `$VOL_ARCHIVE` | `0600` | `chmod 0600` verified with `stat -c "%a"`; records `FAILED_PERMISSIONS` |
| Unified Outer Archive | `$TMP_ARCHIVE` | `0600` | `chmod 0600` verified with `stat -c "%a"` (`exit 13`) |
| Cryptographic Sidecar | `$TMP_SHA` | `0600` | `chmod 0600` verified with `stat -c "%a"` (`exit 13`) |
| Manifest File | `$TMP_MANIFEST` | `0600` | `chmod 0600` verified with `stat -c "%a"` (`exit 13`) |

---

## 5. Idempotent Cleanup, Signal Handling, and Status Preservation

### 5.1 Idempotent Cleanup Implementation
`cleanup_temp_artifacts()` can now be invoked multiple times throughout execution without emitting errors or failing on already-deleted paths:
```bash
cleanup_temp_artifacts() {
    local err=0
    if [[ -n "${TEMP_STAGE:-}" ]]; then
        if [[ -e "$TEMP_STAGE" || -L "$TEMP_STAGE" ]]; then
            if rm -rf "$TEMP_STAGE" 2>/dev/null && [[ ! -e "$TEMP_STAGE" && ! -L "$TEMP_STAGE" ]]; then
                TEMP_STAGE=""
            else
                echo "  [ERROR] Failed to remove temporary staging directory: $TEMP_STAGE" >&2
                err=1
                CLEANUP_FAILED=1
            fi
        else
            TEMP_STAGE=""
        fi
    fi

    if [[ -n "${TMP_SET_DIR:-}" ]]; then
        if [[ -e "$TMP_SET_DIR" || -L "$TMP_SET_DIR" ]]; then
            if rm -rf "$TMP_SET_DIR" 2>/dev/null && [[ ! -e "$TMP_SET_DIR" && ! -L "$TMP_SET_DIR" ]]; then
                TMP_SET_DIR=""
            else
                echo "  [ERROR] Failed to remove temporary backup set staging directory: $TMP_SET_DIR" >&2
                err=1
                CLEANUP_FAILED=1
            fi
        else
            TMP_SET_DIR=""
        fi
    fi

    if [[ "$err" -ne 0 || "$CLEANUP_FAILED" -ne 0 ]]; then
        return 1
    fi
    return 0
}
```
* Once a staging path is successfully unlinked, its reference variable is cleared (`TEMP_STAGE=""`, `TMP_SET_DIR=""`). Subsequent invocations evaluate `[[ -n "${VAR:-}" ]]` as false and return successfully (`0`).
* If filesystem deletion fails, `CLEANUP_FAILED=1` persists across subsequent checks, guaranteeing that failure state is never lost.

### 5.2 Clean Trap Disarming & Signal Exit Code Preservation
When signal handlers invoke cleanup, earlier implementations suffered from signal recursion or exit code masking when `EXIT` traps triggered consecutively.

Handlers now explicitly disarm all traps before teardown:
```bash
on_exit() {
    local rc=$?
    trap - EXIT
    trap - SIGINT
    trap - SIGTERM
    if ! cleanup_temp_artifacts; then
        echo "  [WARN] Temporary artifact cleanup encountered removal errors." >&2
        if [[ "$rc" -eq 0 ]]; then
            exit 1
        fi
    fi
    exit "$rc"
}

on_sigint() {
    trap - SIGINT
    trap - EXIT
    trap - SIGTERM
    echo ""
    echo "  [INTERRUPT] Backup interrupted by operator (SIGINT / Ctrl+C). Cleaning up..." >&2
    if ! cleanup_temp_artifacts; then
        echo "  [ERROR] Failed to completely remove temporary artifacts during interrupt cleanup." >&2
    fi
    exit 130
}

on_sigterm() {
    trap - SIGTERM
    trap - EXIT
    trap - SIGINT
    echo ""
    echo "  [TERMINATE] Backup terminated by signal (SIGTERM). Cleaning up..." >&2
    if ! cleanup_temp_artifacts; then
        echo "  [ERROR] Failed to completely remove temporary artifacts during termination cleanup." >&2
    fi
    exit 143
}
```
* **Preservation of Root Exit Codes:** In `on_exit`, if primary execution returned non-zero (e.g., `exit 2`, `exit 10`, `exit 14`), `$rc` is strictly preserved.
* **Preservation of Signal Exit Codes:** `SIGINT` exits with `130`; `SIGTERM` exits with `143`.
* **Fail-Closed on Zero Exit:** If primary execution succeeded (`rc == 0`) but cleanup failed, `on_exit` elevates the exit code to `1` (`ERR_CLEANUP_FAILURE`).

### 5.3 Pre-Summary Cleanup Invocation
To ensure that a backup run is never visually presented to operators as a success when temporary artifacts remain stranded on disk, cleanup is explicitly called immediately prior to rendering the final execution summary:
```bash
# ------------------------------------------------------------------------------
# 11. Final Status Determination and Execution Summary
# ------------------------------------------------------------------------------
CLEANUP_EXEC_ERROR=0
if ! cleanup_temp_artifacts; then
    echo "  [ERROR] Cleanup of sensitive temporary staging directory failed." >&2
    CLEANUP_EXEC_ERROR=1
    BACKUP_STATUS="FAILED_CLEANUP"
fi

echo ""
echo "======================================================================"
echo "  BACKUP EXECUTION SUMMARY"
echo "  Backup ID:   $BACKUP_ID"
echo "  Mode:        $BACKUP_MODE"
echo "  Status:      $BACKUP_STATUS"
echo "  Backup Set:  $FINAL_BACKUP_SET"

if [[ "$CLEANUP_EXEC_ERROR" -ne 0 ]]; then
    echo "  Notice:      Backup set published, but cleanup of temporary staging artifacts failed."
    echo "  Exit Code:   1 (ERR_CLEANUP_FAILURE)"
    echo "======================================================================"
    exit 1
elif [[ "$BACKUP_STATUS" == "SUCCESS" ]]; then
    ...
```

### 5.4 Abandoned Staging Directory Inspection
To prevent race conditions where automated cleanup deletes a staging directory belonging to an active or slow backup process, automated deletion of `.tmp-set-*` directories is prohibited.

Instead, the pruner inspects each directory's `.process_lock`:
```bash
while IFS= read -r -d '' tmp_dir; do
    if [[ -f "$tmp_dir/.process_lock" ]]; then
        lock_pid="$(grep -E '^pid=' "$tmp_dir/.process_lock" | cut -d'=' -f2 | tr -d '\r\n')"
        lock_time="$(grep -E '^started_at=' "$tmp_dir/.process_lock" | cut -d'=' -f2 | tr -d '\r\n')"
        if [[ -n "$lock_pid" && "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "  [INFO] Staging directory '$tmp_dir' belongs to active backup process (PID $lock_pid, started $lock_time). Preserving."
        else
            echo "  [WARN] Abandoned staging directory detected: '$tmp_dir' (PID ${lock_pid:-unknown} is inactive, started ${lock_time:-unknown})." >&2
            echo "         Automated deletion disabled to prevent race conditions. Verify no active process and prune manually." >&2
        fi
    else
        echo "  [WARN] Unlocked temporary staging directory detected: '$tmp_dir'." >&2
        echo "         Automated deletion disabled to prevent race conditions. Verify no active process and prune manually." >&2
    fi
done < <(find -P "$CANONICAL_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name ".tmp-set-*" -print0)
```
This guarantees complete process safety without automated race-condition risks.

---

## 6. Retention Pruning Policy Matrix

| Candidate Status in Manifest | Sidecar & Archive Consistency | Volume Results in Manifest | Outer & Inner Tar Verification | Action Taken | Rationale |
| :--- | :--- | :--- | :--- | :---: | :--- |
| `SUCCESS` | SHA matches sidecar; byte size matches `stat` | All 5 volumes `PASSED`, `>0` bytes | Valid outer tar & inner tars pass | **PRUNED** | Verified expired candidate meeting 100% of schema and integrity gates. |
| `SUCCESS` | Sidecar SHA differs from manifest | All 5 volumes `PASSED` | N/A | **PRESERVED** | Metadata desynchronization detected; potential corruption. Logged as `[WARN]`. |
| `SUCCESS` | Archive byte size differs from manifest | All 5 volumes `PASSED` | N/A | **PRESERVED** | Size mismatch detected; truncated archive or metadata spoofing. Logged as `[WARN]`. |
| `SUCCESS` | Missing sidecar `.sha256` file | All 5 volumes `PASSED` | N/A | **PRESERVED** | Sidecar missing or empty. Logged as `[WARN]`. |
| `PARTIAL_ROUTINE` | Any | 1+ missing volumes | N/A | **PRESERVED** | Incomplete routine backup preserved by policy for disaster recovery. Logged as `[NOTICE]`. |
| `FAILED` / other | Any | Any | N/A | **PRESERVED** | Failed backup set preserved for post-incident forensic analysis. Logged as `[NOTICE]`. |
| `SUCCESS` (Corrupt Tar) | Checksums match | All 5 volumes `PASSED` | Tar read error | **PRESERVED** | Archive corrupted after creation; preserved for diagnostics. Logged as `[WARN]`. |
| `SUCCESS` (Corrupt Volume) | Checksums match | All 5 volumes `PASSED` | Nested tar unreadable | **PRESERVED** | Inner volume archive corrupted or truncated. Logged as `[WARN]`. |
| Malformed Manifest | Unsupported YAML / missing keys | Any | N/A | **PRESERVED** | Schema violation (`2.0.0` mismatch, foreign key, duplicate key). Logged as `[WARN]`. |

---

## 7. Validation & Independent Review Verdict

### 7.1 Static Syntax Verification Command and Output
Static validation was executed using GNU Bash 5.2 syntax validation against [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh):

```bash
dineth@dineth-Aspire-A715-42G:~/dev/Linux-System-Monitoring-Reliability-Lab$ bash -n deployment/backup.sh
dineth@dineth-Aspire-A715-42G:~/dev/Linux-System-Monitoring-Reliability-Lab$ echo $?
0
```

### 7.2 Static Verification Findings
* **Exit Status:** `0` (Strictly clean syntax; zero parse errors, warnings, or unclosed blocks).
* **Regex Construction:** Variable-based pattern evaluation (`re_unsupported='[*&{}]'`, `re_yaml_tag='^[[:space:]]*!'`) eliminates character escaping hazards in `[[ ... =~ ... ]]`.
* **Associative Array Integrity:** Scoped declarations (`local -A`) correctly isolate candidate parsing state between loop iterations.
* **Trap Handling Safety:** Handler disarming prevents signal recursion across nested exits.
* **Fail-Closed Guarantees:** All error branches produce documented non-zero exit codes.

### 7.3 Attestation of Non-Execution
As mandated by the engineering constraints:
* `deployment/backup.sh` was **NOT** executed.
* Docker commands and container operations were **NOT** performed.
* No volumes were mounted, modified, or snapshotted.
* No backups were taken or destroyed.
* No Git state changes were committed or staged.

### 7.4 Final Verdict

**Verdict:** `PATCH READY FOR INDEPENDENT REVIEW`
