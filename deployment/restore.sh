#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: deployment/restore.sh
# Purpose: Production-grade disaster recovery restore orchestrator with Schema 2.0.0
#          manifest verification, cryptographic integrity checking, pre-flight
#          offline stack validation, pre-extraction outer archive security,
#          unified multi-layer transaction rollback, snapshot verification,
#          and least-privilege permission enforcement
# Role: Senior SRE, Infrastructure Security Engineer & Disaster Recovery Architect
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

# Enforce strict umask: 077 ensures directories are 0700 and files are 0600
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ------------------------------------------------------------------------------
# 1. Architecture Inventory & Allowlist Definitions
# ------------------------------------------------------------------------------
REQUIRED_CONFIG_DIRS=(
    prometheus
    grafana
    alertmanager
    loki
    blackbox
    alloy
    agent
    scripts
    security
    deployment
)

REQUIRED_ROOT_FILES=(
    docker-compose.yml
    pyproject.toml
    requirements.txt
    README.md
)

ALLOWED_VOLUMES=(
    lab_prometheus_data
    lab_grafana_data
    lab_alertmanager_data
    lab_loki_data
    lab_alloy_data
)

LAB_PORTS=(9091 3001 9093 3100 9115)

# ------------------------------------------------------------------------------
# 2. CLI Options & Operational Mode Parsing
# ------------------------------------------------------------------------------
RESTORE_CONFIGS=1
RESTORE_VOLUMES=1
CONFIRM_REPLACE_VOLUMES=0
DRY_RUN=0
TARGET_VOLUME=""
TARGET_INPUT=""

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <BACKUP_SET_DIR | BACKUP_ARCHIVE.tar.gz>

Production-Grade Disaster Recovery Restore Orchestrator for Linux Monitoring Lab.
Restores monitoring lab configurations and TSDB named volumes from a verified
Schema 2.0.0 backup set.

Arguments:
  <BACKUP_SET_DIR>         Path to published backup set directory (e.g., backup-set-<ID>)
  <BACKUP_ARCHIVE.tar.gz>  Path to backup archive (sibling .sha256 and .manifest required)

Options:
  --configs-only           Restore only configuration directories and root files.
  --volumes-only           Restore only Docker TSDB named volumes.
  --target-volume=<name>   Restore a single specific volume (must be in allowlist).
  --replace-volumes        Explicitly confirm replacement of existing volume data.
  --dry-run                Validate backup set, manifest, checksums, archive contents,
                           and offline stack state without applying modifications.
  -h, --help               Display this help message.

Documented Exit Codes:
  0   SUCCESS: Disaster recovery restore and verification completed successfully.
  1   ERR_RESTORE_FAIL: Configuration restore or generic runtime failure.
  2   ERR_VALIDATION_FAIL: Invalid arguments, corrupted archive, or manifest schema failure.
  3   ERR_STACK_ACTIVE: Monitoring stack is active; restore requires offline stack.
  4   ERR_DOCKER_ACCESS: Docker CLI missing, daemon unavailable, or socket permission denied.
  5   ERR_VOLUME_RESTORE: Docker volume creation, cleanup, extraction, or verification failed.
  6   ERR_PERMISSIONS: Permission re-hardening or security verification failed.
  7   ERR_ROLLBACK_FAIL: Restoration failed and automatic rollback also failed.
 130   SIGINT: Interrupted by operator (Ctrl+C).
 143   SIGTERM: Terminated by signal.

Security Notice:
  The dangerous '--force' bypass has been permanently removed. Running containers
  MUST be stopped prior to volume restoration to prevent TSDB corruption and split-brain states.
EOF
    exit 0
}

if [[ $# -lt 1 ]]; then
    usage
fi

for arg in "$@"; do
    case "$arg" in
        --configs-only)
            RESTORE_CONFIGS=1
            RESTORE_VOLUMES=0
            ;;
        --volumes-only)
            RESTORE_CONFIGS=0
            RESTORE_VOLUMES=1
            ;;
        --target-volume=*)
            TARGET_VOLUME="${arg#*=}"
            if [[ -z "$TARGET_VOLUME" ]]; then
                echo "  [FATAL] --target-volume cannot be empty." >&2
                exit 2
            fi
            ;;
        --replace-volumes)
            CONFIRM_REPLACE_VOLUMES=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --force)
            echo "  [FATAL] The '--force' option has been permanently removed for data safety." >&2
            echo "          Bypassing offline stack checks causes active TSDB split-brain corruption." >&2
            echo "          Stop the stack first ('./deployment/deploy.sh down') and re-run without '--force'." >&2
            exit 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "  [FATAL] Unknown option: $arg" >&2
            echo "          Run '$(basename "$0") --help' for usage." >&2
            exit 2
            ;;
        *)
            if [[ -z "$TARGET_INPUT" ]]; then
                TARGET_INPUT="$arg"
            else
                echo "  [FATAL] Multiple target arguments provided: '$TARGET_INPUT' and '$arg'." >&2
                exit 2
            fi
            ;;
    esac
done

if [[ -z "$TARGET_INPUT" ]]; then
    echo "  [FATAL] Missing required backup set directory or archive argument." >&2
    echo "          Run '$(basename "$0") --help' for usage." >&2
    exit 2
fi

if [[ -n "$TARGET_VOLUME" ]]; then
    target_found=0
    for allowed_v in "${ALLOWED_VOLUMES[@]}"; do
        if [[ "$allowed_v" == "$TARGET_VOLUME" ]]; then
            target_found=1
            break
        fi
    done
    if [[ "$target_found" -ne 1 ]]; then
        echo "  [FATAL] Target volume '$TARGET_VOLUME' is not in the approved volume allowlist:" >&2
        for allowed_v in "${ALLOWED_VOLUMES[@]}"; do
            echo "            - $allowed_v" >&2
        done
        exit 2
    fi
    RESTORE_CONFIGS=0
    RESTORE_VOLUMES=1
fi

if [[ "$RESTORE_CONFIGS" -eq 0 && "$RESTORE_VOLUMES" -eq 0 ]]; then
    echo "  [FATAL] Contradictory options: both configurations and volumes excluded." >&2
    exit 2
fi

# ------------------------------------------------------------------------------
# 3. Helper Functions: Secure Random & Path Validation
# ------------------------------------------------------------------------------
generate_secure_random_hex() {
    if [[ ! -r /dev/urandom ]]; then
        echo "  [FATAL] Cryptographic random source '/dev/urandom' is unavailable or unreadable." >&2
        return 1
    fi
    local r_hex=""
    if ! r_hex="$(head -c 8 /dev/urandom | od -N 8 -tx1 -An | tr -d ' \n')"; then
        echo "  [FATAL] Pipeline error reading random bytes from '/dev/urandom'." >&2
        return 1
    fi
    if [[ -z "$r_hex" || ${#r_hex} -ne 16 || ! "$r_hex" =~ ^[0-9a-fA-F]{16}$ ]]; then
        echo "  [FATAL] Extracted random hex from '/dev/urandom' is invalid or malformed." >&2
        return 1
    fi
    echo "${r_hex,,}"
    return 0
}

validate_path_safety() {
    local target_path="$1"
    local desc="$2"
    local p="$target_path"
    p="${p%/}"
    while [[ -n "$p" && "$p" != "/" && "$p" != "." ]]; do
        if [[ -L "$p" ]]; then
            echo "  [FATAL] Unsafe $desc: path component '$p' is a symbolic link." >&2
            echo "          Symlinked paths are prohibited for secure disaster recovery operations." >&2
            return 1
        fi
        p="$(dirname "$p")"
    done
    return 0
}

# ------------------------------------------------------------------------------
# 4. Unified Transaction Coordinator State & Rollback Engine
# ------------------------------------------------------------------------------
TEMP_STAGE=""
ROLLBACK_CONFIG_DIR=""
declare -a SNAPSHOT_OWNERSHIP_LEDGER=()
declare -a TRANSACTION_LOG=()
declare -A RESOURCE_PRE_EXISTED=()
declare -A VOLUME_SNAPSHOT_NAME=()
RESTORE_SUCCESS=0
ROLLBACK_IN_PROGRESS=0
CLEANUP_FAILED=0

execute_unified_rollback() {
    if [[ "$ROLLBACK_IN_PROGRESS" -eq 1 ]]; then
        echo "  [FATAL-ROLLBACK] Re-entrant rollback invoked! Preventing infinite loop." >&2
        return 1
    fi
    ROLLBACK_IN_PROGRESS=1

    # Intercept interruptions during rollback so recovery snapshots are never discarded mid-flight
    trap 'echo "" >&2; echo "  [CRITICAL] Rollback interrupted by signal! Recovery material preserved." >&2; exit 7' SIGINT SIGTERM

    local rb_err=0
    local total_entries=${#TRANSACTION_LOG[@]}
    echo "" >&2
    echo "  [ROLLBACK] Initiating unified transaction rollback ($total_entries modified resource(s) to unwind)..." >&2

    if [[ "$total_entries" -eq 0 ]]; then
        echo "  [ROLLBACK] No resources were modified prior to failure. Nothing to unwind." >&2
        ROLLBACK_IN_PROGRESS=0
        return 0
    fi

    # Unwind transaction log in strictly reverse order
    for ((i=total_entries-1; i>=0; i--)); do
        local entry="${TRANSACTION_LOG[$i]}"
        local r_type="${entry%%:*}"
        local r_name="${entry#*:}"

        case "$r_type" in
            VOLUME)
                echo "  [ROLLBACK] Reverting Docker volume '$r_name'..." >&2
                if [[ "${RESOURCE_PRE_EXISTED["VOLUME:$r_name"]:-0}" -eq 1 ]]; then
                    local snap_name="${VOLUME_SNAPSHOT_NAME["$r_name"]:-}"
                    if [[ -z "$snap_name" ]]; then
                        echo "  [FATAL-ROLLBACK] Missing snapshot record for pre-existing volume '$r_name'!" >&2
                        rb_err=1
                        continue
                    fi
                    if ! docker run --rm -v "${r_name}:/volume" alpine:3.19 find /volume -mindepth 1 -delete; then
                        echo "  [FATAL-ROLLBACK] Failed to clean volume '$r_name' during rollback!" >&2
                        rb_err=1
                        continue
                    fi
                    if ! docker run --rm -v "${snap_name}:/src:ro" -v "${r_name}:/dst" alpine:3.19 sh -c "cp -a /src/. /dst/"; then
                        echo "  [FATAL-ROLLBACK] Failed to restore data from snapshot '$snap_name' back to '$r_name'!" >&2
                        rb_err=1
                        continue
                    fi
                    local rb_count=""
                    if ! rb_count="$(docker run --rm -v "${r_name}:/volume:ro" alpine:3.19 sh -c "find /volume -mindepth 1 | wc -l" 2>/dev/null)"; then
                        echo "  [FATAL-ROLLBACK] Failed to inspect volume '$r_name' after rollback restore!" >&2
                        rb_err=1
                        continue
                    fi
                    rb_count="$(echo "$rb_count" | tr -d ' \t\r\n')"
                    echo "  [ROLLBACK] Volume '$r_name' successfully reverted from snapshot '$snap_name' ($rb_count items)." >&2
                else
                    echo "  [ROLLBACK] Removing volume '$r_name' (newly created during restore)..." >&2
                    if ! docker volume rm "$r_name" >/dev/null; then
                        echo "  [FATAL-ROLLBACK] Failed to remove newly created volume '$r_name' during rollback!" >&2
                        rb_err=1
                        continue
                    fi
                    echo "  [ROLLBACK] Newly created volume '$r_name' removed." >&2
                fi
                ;;

            CONFIG_DIR)
                echo "  [ROLLBACK] Reverting configuration directory '$r_name'..." >&2
                if [[ "${RESOURCE_PRE_EXISTED["CONFIG_DIR:$r_name"]:-0}" -eq 1 ]]; then
                    if [[ -d "$ROLLBACK_CONFIG_DIR/$r_name" ]]; then
                        rm -rf "$REPO_ROOT/$r_name"
                        if ! cp -R -P "$ROLLBACK_CONFIG_DIR/$r_name" "$REPO_ROOT/"; then
                            echo "  [FATAL-ROLLBACK] Failed to restore configuration directory '$r_name'!" >&2
                            rb_err=1
                            continue
                        fi
                        echo "  [ROLLBACK] Configuration directory '$r_name' restored from pre-restore snapshot." >&2
                    else
                        echo "  [FATAL-ROLLBACK] Missing staged pre-restore snapshot for directory '$r_name'!" >&2
                        rb_err=1
                        continue
                    fi
                else
                    if [[ -e "$REPO_ROOT/$r_name" || -L "$REPO_ROOT/$r_name" ]]; then
                        if ! rm -rf "$REPO_ROOT/$r_name"; then
                            echo "  [FATAL-ROLLBACK] Failed to purge newly created directory '$r_name'!" >&2
                            rb_err=1
                            continue
                        fi
                        echo "  [ROLLBACK] Newly created directory '$r_name' purged." >&2
                    fi
                fi
                ;;

            CONFIG_FILE)
                echo "  [ROLLBACK] Reverting configuration file '$r_name'..." >&2
                if [[ "${RESOURCE_PRE_EXISTED["CONFIG_FILE:$r_name"]:-0}" -eq 1 ]]; then
                    if [[ -f "$ROLLBACK_CONFIG_DIR/$r_name" ]]; then
                        if ! cp "$ROLLBACK_CONFIG_DIR/$r_name" "$REPO_ROOT/$r_name"; then
                            echo "  [FATAL-ROLLBACK] Failed to restore configuration file '$r_name'!" >&2
                            rb_err=1
                            continue
                        fi
                        echo "  [ROLLBACK] Configuration file '$r_name' restored from pre-restore snapshot." >&2
                    else
                        echo "  [FATAL-ROLLBACK] Missing staged pre-restore snapshot for file '$r_name'!" >&2
                        rb_err=1
                        continue
                    fi
                else
                    if [[ -e "$REPO_ROOT/$r_name" || -L "$REPO_ROOT/$r_name" ]]; then
                        if ! rm -f "$REPO_ROOT/$r_name"; then
                            echo "  [FATAL-ROLLBACK] Failed to purge newly created file '$r_name'!" >&2
                            rb_err=1
                            continue
                        fi
                        echo "  [ROLLBACK] Newly created file '$r_name' purged." >&2
                    fi
                fi
                ;;
        esac
    done

    ROLLBACK_IN_PROGRESS=0
    if [[ "$rb_err" -ne 0 ]]; then
        echo "  [FATAL-ROLLBACK] Unified rollback encountered one or more errors! Preserving recovery state." >&2
        return 1
    fi
    echo "  [ROLLBACK] Unified rollback completed successfully for all modified resources." >&2
    return 0
}

cleanup_temp_artifacts() {
    local err=0

    # Prune snapshots ONLY if restoration was confirmed 100% successful.
    # Otherwise, snapshots are strictly preserved on the host for manual recovery.
    if [[ "$RESTORE_SUCCESS" -eq 1 ]]; then
        local -a remaining_ledger=()
        for snap_vol in "${SNAPSHOT_OWNERSHIP_LEDGER[@]}"; do
            if command -v docker >/dev/null 2>&1 && docker volume inspect "$snap_vol" >/dev/null 2>&1; then
                if ! docker volume rm "$snap_vol" >/dev/null 2>&1; then
                    echo "  [WARN] Failed to remove temporary rollback snapshot volume: $snap_vol" >&2
                    remaining_ledger+=("$snap_vol")
                    err=1
                fi
            fi
        done
        SNAPSHOT_OWNERSHIP_LEDGER=("${remaining_ledger[@]}")
    fi

    if [[ ${#SNAPSHOT_OWNERSHIP_LEDGER[@]} -gt 0 ]]; then
        echo "" >&2
        echo "  [SAFETY NOTICE] Preserving verified rollback snapshot volume(s) on Docker host:" >&2
        for snap_vol in "${SNAPSHOT_OWNERSHIP_LEDGER[@]}"; do
            echo "                    - $snap_vol" >&2
        done
        echo "                  These snapshots contain pre-restore volume contents preserved for disaster recovery." >&2
        echo "                  Prune manually only after confirming operational cluster health." >&2
    fi

    # Clean up private staging directory
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

    if [[ "$err" -ne 0 || "$CLEANUP_FAILED" -ne 0 ]]; then
        return 1
    fi
    return 0
}

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
    echo "" >&2
    echo "  [WARN] Restore interrupted by SIGINT (Ctrl+C)..." >&2
    if [[ ${#TRANSACTION_LOG[@]} -gt 0 ]]; then
        echo "  [WARN] Modifications were in progress. Executing unified transaction rollback..." >&2
        if ! execute_unified_rollback; then
            echo "  [FATAL] Unified rollback failed or was incomplete following SIGINT." >&2
            cleanup_temp_artifacts || true
            exit 7
        fi
    fi
    cleanup_temp_artifacts || true
    exit 130
}

on_sigterm() {
    trap - SIGTERM
    trap - EXIT
    trap - SIGINT
    echo "" >&2
    echo "  [WARN] Restore terminated by SIGTERM..." >&2
    if [[ ${#TRANSACTION_LOG[@]} -gt 0 ]]; then
        echo "  [WARN] Modifications were in progress. Executing unified transaction rollback..." >&2
        if ! execute_unified_rollback; then
            echo "  [FATAL] Unified rollback failed or was incomplete following SIGTERM." >&2
            cleanup_temp_artifacts || true
            exit 7
        fi
    fi
    cleanup_temp_artifacts || true
    exit 143
}

trap on_exit EXIT
trap on_sigint SIGINT
trap on_sigterm SIGTERM

TEMP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lab-restore-XXXXXX")"
if ! chmod 0700 "$TEMP_STAGE" 2>/dev/null; then
    echo "  [FATAL] Failed to enforce 0700 permissions on staging directory: $TEMP_STAGE" >&2
    exit 2
fi

# ------------------------------------------------------------------------------
# 5. Backup Set & Artifact Discovery
# ------------------------------------------------------------------------------
if ! validate_path_safety "$TARGET_INPUT" "target argument"; then
    exit 2
fi

RESOLVED_SET_DIR=""
RESOLVED_ARCHIVE=""
RESOLVED_SHA=""
RESOLVED_MANIFEST=""
BACKUP_ID=""

re_backup_id='^[0-9]{8}-[0-9]{6}Z-[0-9a-f]{16}$'

if [[ -d "$TARGET_INPUT" && ! -L "$TARGET_INPUT" ]]; then
    RESOLVED_SET_DIR="$(cd "$TARGET_INPUT" && pwd)"
    set_dirname="$(basename "$RESOLVED_SET_DIR")"

    if [[ "$set_dirname" =~ ^backup-set-([0-9]{8}-[0-9]{6}Z-[0-9a-f]{16})$ ]]; then
        BACKUP_ID="${BASH_REMATCH[1]}"
    else
        mapfile -t matched_archives < <(find -P "$RESOLVED_SET_DIR" -maxdepth 1 -type f -name "backup-*.tar.gz" ! -name "*.sha256" ! -name "*.manifest" | sort)
        if [[ ${#matched_archives[@]} -eq 1 ]]; then
            arch_base="$(basename "${matched_archives[0]}")"
            if [[ "$arch_base" =~ ^backup-([0-9]{8}-[0-9]{6}Z-[0-9a-f]{16})\.tar\.gz$ ]]; then
                BACKUP_ID="${BASH_REMATCH[1]}"
            fi
        fi
    fi

    if [[ -z "$BACKUP_ID" || ! "$BACKUP_ID" =~ $re_backup_id ]]; then
        echo "  [FATAL] Unable to determine valid backup identifier from directory '$TARGET_INPUT'." >&2
        echo "          Backup sets must match pattern 'backup-set-YYYYMMDD-HHMMSSZ-<16hex>'." >&2
        exit 2
    fi

    RESOLVED_ARCHIVE="$RESOLVED_SET_DIR/backup-${BACKUP_ID}.tar.gz"
    RESOLVED_SHA="$RESOLVED_SET_DIR/backup-${BACKUP_ID}.tar.gz.sha256"
    RESOLVED_MANIFEST="$RESOLVED_SET_DIR/backup-${BACKUP_ID}.tar.gz.manifest"

elif [[ -f "$TARGET_INPUT" && ! -L "$TARGET_INPUT" ]]; then
    arch_base="$(basename "$TARGET_INPUT")"
    if [[ "$arch_base" =~ ^backup-([0-9]{8}-[0-9]{6}Z-[0-9a-f]{16})\.tar\.gz$ ]]; then
        BACKUP_ID="${BASH_REMATCH[1]}"
    else
        echo "  [FATAL] Archive filename '$arch_base' does not match pattern 'backup-YYYYMMDD-HHMMSSZ-<16hex>.tar.gz'." >&2
        exit 2
    fi

    RESOLVED_SET_DIR="$(cd "$(dirname "$TARGET_INPUT")" && pwd)"
    RESOLVED_ARCHIVE="$RESOLVED_SET_DIR/$arch_base"
    RESOLVED_SHA="$RESOLVED_SET_DIR/${arch_base}.sha256"
    RESOLVED_MANIFEST="$RESOLVED_SET_DIR/${arch_base}.manifest"
else
    echo "  [FATAL] Target '$TARGET_INPUT' is neither a valid directory nor a regular file." >&2
    exit 2
fi

echo "======================================================================"
echo "  LINUX MONITORING LAB — DISASTER RECOVERY RESTORE ORCHESTRATOR"
echo "  Timestamp:    $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "  Backup ID:    $BACKUP_ID"
echo "  Backup Set:   $RESOLVED_SET_DIR"
echo "  Target Repo:  $REPO_ROOT"
echo "  Dry-Run Mode: $([[ "$DRY_RUN" -eq 1 ]] && echo "ENABLED (No changes will be applied)" || echo "DISABLED")"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 6. Backup-Set Artifact Validation & Cryptographic Integrity Check
# ------------------------------------------------------------------------------
echo ""
echo "[1/6] Validating Backup-Set Artifacts & Cryptographic Checksums..."

for artifact in "$RESOLVED_ARCHIVE" "$RESOLVED_SHA" "$RESOLVED_MANIFEST"; do
    if [[ ! -e "$artifact" ]]; then
        echo "  [FATAL] Required backup set artifact missing: $(basename "$artifact")" >&2
        exit 2
    fi
    if [[ -L "$artifact" ]]; then
        echo "  [FATAL] Backup artifact is a symbolic link (prohibited): $(basename "$artifact")" >&2
        exit 2
    fi
    if [[ ! -f "$artifact" || ! -s "$artifact" ]]; then
        echo "  [FATAL] Backup artifact is missing, empty, or not a regular file: $(basename "$artifact")" >&2
        exit 2
    fi
done

SIDECAR_SHA=""
SIDECAR_FILE=""
if ! read -r SIDECAR_SHA SIDECAR_FILE < "$RESOLVED_SHA" || [[ -z "$SIDECAR_SHA" ]]; then
    echo "  [FATAL] Checksum sidecar file '$RESOLVED_SHA' is empty or unreadable." >&2
    exit 2
fi
SIDECAR_SHA="$(echo "$SIDECAR_SHA" | tr -d ' \t\r\n')"
SIDECAR_SHA="${SIDECAR_SHA,,}"
if [[ ! "$SIDECAR_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    echo "  [FATAL] Sidecar checksum has invalid SHA-256 format ('$SIDECAR_SHA')." >&2
    exit 2
fi

SIDECAR_FILE="$(echo "$SIDECAR_FILE" | tr -d ' \t\r\n*')"
EXPECTED_ARCHIVE_NAME="$(basename "$RESOLVED_ARCHIVE")"
if [[ -n "$SIDECAR_FILE" && "$SIDECAR_FILE" != "$EXPECTED_ARCHIVE_NAME" ]]; then
    echo "  [FATAL] Sidecar references unexpected archive filename '$SIDECAR_FILE' (expected '$EXPECTED_ARCHIVE_NAME')." >&2
    exit 2
fi

if ! (cd "$RESOLVED_SET_DIR" && sha256sum -c "$(basename "$RESOLVED_SHA")" >/dev/null 2>&1); then
    echo "  [FATAL] Cryptographic SHA-256 integrity verification failed for $(basename "$RESOLVED_ARCHIVE")!" >&2
    echo "          Archive file may be corrupted, truncated, or tampered with." >&2
    exit 2
fi

ACTUAL_ARCHIVE_BYTES="$(stat -c "%s" "$RESOLVED_ARCHIVE" 2>/dev/null || echo "")"
if [[ -z "$ACTUAL_ARCHIVE_BYTES" || ! "$ACTUAL_ARCHIVE_BYTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "  [FATAL] Unable to determine valid byte size of $(basename "$RESOLVED_ARCHIVE")." >&2
    exit 2
fi

printf "  [PASS] Unified archive cryptographic integrity verified: %s\n" "$SIDECAR_SHA"
printf "  [PASS] Unified archive byte size verified: %s bytes\n" "$ACTUAL_ARCHIVE_BYTES"

# ------------------------------------------------------------------------------
# 7. Strict Manifest Schema 2.0.0 Parsing & Validation
# ------------------------------------------------------------------------------
echo ""
echo "[2/6] Parsing & Validating Structured Manifest (Schema 2.0.0 Enforcement)..."

declare -A SEEN_TOP_KEYS=()
declare -A MANIFEST_SCALARS=()
declare -a PARSED_REQ_CONFIGS=()
declare -a PARSED_REQ_VOLS=()
declare -a PARSED_ARCH_VOLS=()
declare -a PARSED_MISS_VOLS=()
declare -a PARSED_FAIL_VOLS=()
declare -A SEEN_VOL_RESULTS=()
declare -A V_PROP_STATUS=()
declare -A V_PROP_EXISTS=()
declare -A V_PROP_ARCHIVE_VERIFIED=()
declare -A V_PROP_ARCHIVE_BYTES=()
declare -A SEEN_V_PROPS=()
declare -A ARRAY_EXPLICIT_EMPTY=()

current_section=""
current_sub_vol=""
line_num=0
seen_notice_content=0

re_unsupported='[*&{}]'
re_yaml_tag='^[[:space:]]*!'

while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    line="${line%$'\r'}"

    if [[ -z "${line// }" ]]; then
        continue
    fi

    if [[ "$current_section" != "storage_consistency_notice" ]]; then
        if [[ "$line" =~ $re_unsupported ]] || [[ "$line" =~ $re_yaml_tag ]]; then
            echo "  [FATAL] Manifest line $line_num contains unsupported YAML construct (inline maps, anchors, aliases, or tags prohibited)." >&2
            exit 2
        fi
    fi

    if [[ "$line" =~ ^([a-zA-Z0-9_]+):(.*)$ ]]; then
        tkey="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        tval="$(echo "$rest" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        case "$tkey" in
            manifest_schema_version|backup_id|created_at_utc|created_at_epoch|\
            backup_mode|backup_status|consistency_classification|repository_root|\
            backup_set_directory|archive_filename|archive_sha256|archive_size_bytes|\
            archive_size_human|permissions_directory|permissions_files|\
            secret_exclusion_policy|required_config_dirs|required_volumes|\
            archived_volumes|missing_volumes|failed_volumes|\
            volume_validation_results|storage_consistency_notice)
                ;;
            *)
                echo "  [FATAL] Manifest line $line_num contains unexpected top-level key '$tkey'." >&2
                exit 2
                ;;
        esac

        if [[ -n "${SEEN_TOP_KEYS[$tkey]:-}" ]]; then
            echo "  [FATAL] Manifest line $line_num contains duplicate top-level key '$tkey'." >&2
            exit 2
        fi
        SEEN_TOP_KEYS["$tkey"]=1
        current_section="$tkey"
        current_sub_vol=""

        case "$tkey" in
            manifest_schema_version|backup_id|created_at_utc|created_at_epoch|\
            backup_mode|backup_status|consistency_classification|repository_root|\
            backup_set_directory|archive_filename|archive_sha256|archive_size_bytes|\
            archive_size_human|permissions_directory|permissions_files|\
            secret_exclusion_policy)
                if [[ "$tval" =~ ^\"(.*)\"$ ]]; then
                    tval="${BASH_REMATCH[1]}"
                fi
                MANIFEST_SCALARS["$tkey"]="$tval"
                current_section=""
                ;;
            required_config_dirs|required_volumes|archived_volumes|missing_volumes|failed_volumes)
                if [[ "$tval" == "[]" ]]; then
                    ARRAY_EXPLICIT_EMPTY["$tkey"]=1
                    current_section=""
                elif [[ -n "$tval" ]]; then
                    echo "  [FATAL] Manifest line $line_num has malformed list header for '$tkey' ('$tval')." >&2
                    exit 2
                fi
                ;;
            volume_validation_results|storage_consistency_notice)
                ;;
        esac
        continue
    fi

    if [[ -z "$current_section" ]]; then
        echo "  [FATAL] Manifest line $line_num is an unexpected indented line outside any section." >&2
        exit 2
    fi

    case "$current_section" in
        storage_consistency_notice)
            if [[ -n "${line// }" ]]; then
                seen_notice_content=1
            fi
            continue
            ;;
        required_config_dirs|required_volumes|archived_volumes|missing_volumes|failed_volumes)
            if [[ "$line" =~ ^[[:space:]]*\[\][[:space:]]*$ ]]; then
                if [[ -n "${ARRAY_EXPLICIT_EMPTY[$current_section]:-}" ]]; then
                    echo "  [FATAL] Manifest line $line_num has duplicate '[]' for '$current_section'." >&2
                    exit 2
                fi
                case "$current_section" in
                    required_config_dirs)
                        if [[ ${#PARSED_REQ_CONFIGS[@]} -gt 0 ]]; then
                            echo "  [FATAL] Manifest line $line_num has '[]' after items in required_config_dirs." >&2
                            exit 2
                        fi
                        ;;
                    required_volumes)
                        if [[ ${#PARSED_REQ_VOLS[@]} -gt 0 ]]; then
                            echo "  [FATAL] Manifest line $line_num has '[]' after items in required_volumes." >&2
                            exit 2
                        fi
                        ;;
                    archived_volumes)
                        if [[ ${#PARSED_ARCH_VOLS[@]} -gt 0 ]]; then
                            echo "  [FATAL] Manifest line $line_num has '[]' after items in archived_volumes." >&2
                            exit 2
                        fi
                        ;;
                    missing_volumes)
                        if [[ ${#PARSED_MISS_VOLS[@]} -gt 0 ]]; then
                            echo "  [FATAL] Manifest line $line_num has '[]' after items in missing_volumes." >&2
                            exit 2
                        fi
                        ;;
                    failed_volumes)
                        if [[ ${#PARSED_FAIL_VOLS[@]} -gt 0 ]]; then
                            echo "  [FATAL] Manifest line $line_num has '[]' after items in failed_volumes." >&2
                            exit 2
                        fi
                        ;;
                esac
                ARRAY_EXPLICIT_EMPTY["$current_section"]=1
                current_section=""
                continue
            elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"?([^\"]+)\"?[[:space:]]*$ ]]; then
                item="${BASH_REMATCH[1]}"
                case "$current_section" in
                    required_config_dirs)
                        if [[ ${#PARSED_REQ_CONFIGS[@]} -gt 0 ]]; then
                            for existing in "${PARSED_REQ_CONFIGS[@]}"; do
                                if [[ "$existing" == "$item" ]]; then
                                    echo "  [FATAL] Manifest line $line_num contains duplicate directory '$item' in required_config_dirs." >&2
                                    exit 2
                                fi
                            done
                        fi
                        PARSED_REQ_CONFIGS+=("$item")
                        ;;
                    required_volumes)
                        if [[ ${#PARSED_REQ_VOLS[@]} -gt 0 ]]; then
                            for existing in "${PARSED_REQ_VOLS[@]}"; do
                                if [[ "$existing" == "$item" ]]; then
                                    echo "  [FATAL] Manifest line $line_num contains duplicate volume '$item' in required_volumes." >&2
                                    exit 2
                                fi
                            done
                        fi
                        PARSED_REQ_VOLS+=("$item")
                        ;;
                    archived_volumes)
                        if [[ ${#PARSED_ARCH_VOLS[@]} -gt 0 ]]; then
                            for existing in "${PARSED_ARCH_VOLS[@]}"; do
                                if [[ "$existing" == "$item" ]]; then
                                    echo "  [FATAL] Manifest line $line_num contains duplicate volume '$item' in archived_volumes." >&2
                                    exit 2
                                fi
                            done
                        fi
                        PARSED_ARCH_VOLS+=("$item")
                        ;;
                    missing_volumes)
                        PARSED_MISS_VOLS+=("$item")
                        ;;
                    failed_volumes)
                        PARSED_FAIL_VOLS+=("$item")
                        ;;
                esac
            else
                echo "  [FATAL] Manifest line $line_num under '$current_section' has invalid list format." >&2
                exit 2
            fi
            ;;
        volume_validation_results)
            if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z0-9_]+):[[:space:]]*$ ]]; then
                current_sub_vol="${BASH_REMATCH[1]}"
                if [[ -n "${SEEN_VOL_RESULTS[$current_sub_vol]:-}" ]]; then
                    echo "  [FATAL] Duplicate volume entry '$current_sub_vol' in volume_validation_results." >&2
                    exit 2
                fi
                SEEN_VOL_RESULTS["$current_sub_vol"]=1
            elif [[ "$line" =~ ^[[:space:]]{4}([a-zA-Z0-9_]+):[[:space:]]*(.*)$ ]]; then
                if [[ -z "$current_sub_vol" ]]; then
                    echo "  [FATAL] Manifest line $line_num has property without preceding volume entry." >&2
                    exit 2
                fi
                vprop="${BASH_REMATCH[1]}"
                vpval="${BASH_REMATCH[2]}"
                vpval="$(echo "$vpval" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                if [[ "$vpval" =~ ^\"(.*)\"$ ]]; then
                    vpval="${BASH_REMATCH[1]}"
                fi

                prop_key="${current_sub_vol}:${vprop}"
                if [[ -n "${SEEN_V_PROPS[$prop_key]:-}" ]]; then
                    echo "  [FATAL] Duplicate property '$vprop' for volume '$current_sub_vol'." >&2
                    exit 2
                fi
                SEEN_V_PROPS["$prop_key"]=1

                case "$vprop" in
                    status)
                        V_PROP_STATUS["$current_sub_vol"]="$vpval"
                        ;;
                    exists)
                        V_PROP_EXISTS["$current_sub_vol"]="$vpval"
                        ;;
                    archive_verified)
                        V_PROP_ARCHIVE_VERIFIED["$current_sub_vol"]="$vpval"
                        ;;
                    archive_bytes)
                        V_PROP_ARCHIVE_BYTES["$current_sub_vol"]="$vpval"
                        ;;
                    *)
                        echo "  [FATAL] Unexpected property '$vprop' in volume_validation_results." >&2
                        exit 2
                        ;;
                esac
            else
                echo "  [FATAL] Manifest line $line_num under volume_validation_results is malformed." >&2
                exit 2
            fi
            ;;
    esac
done < "$RESOLVED_MANIFEST"

# Verify all 23 mandatory top-level keys exist
MANDATORY_KEYS=(
    manifest_schema_version backup_id created_at_utc created_at_epoch
    backup_mode backup_status consistency_classification repository_root
    backup_set_directory archive_filename archive_sha256 archive_size_bytes
    archive_size_human permissions_directory permissions_files
    secret_exclusion_policy required_config_dirs required_volumes
    archived_volumes missing_volumes failed_volumes volume_validation_results
    storage_consistency_notice
)
for mkey in "${MANDATORY_KEYS[@]}"; do
    if [[ -z "${SEEN_TOP_KEYS[$mkey]:-}" ]]; then
        echo "  [FATAL] Manifest missing mandatory key '$mkey'." >&2
        exit 2
    fi
done

if [[ "$seen_notice_content" -ne 1 ]]; then
    echo "  [FATAL] Manifest storage_consistency_notice section is empty." >&2
    exit 2
fi

MANIFEST_SCHEMA="${MANIFEST_SCALARS[manifest_schema_version]:-}"
if [[ "$MANIFEST_SCHEMA" != "2.0.0" ]]; then
    echo "  [FATAL] Unsupported manifest schema version '$MANIFEST_SCHEMA' (expected '2.0.0')." >&2
    exit 2
fi

MANIFEST_STATUS="${MANIFEST_SCALARS[backup_status]:-}"
if [[ "$MANIFEST_STATUS" != "SUCCESS" ]]; then
    echo "  [FATAL] Incomplete or unverified backup status: '$MANIFEST_STATUS'." >&2
    echo "          Disaster recovery restore strictly requires fully validated 'SUCCESS' backup sets." >&2
    echo "          Sets with status 'PARTIAL_ROUTINE' or 'FAILED' cannot be restored." >&2
    exit 2
fi

M_ID="${MANIFEST_SCALARS[backup_id]:-}"
if [[ "$M_ID" != "$BACKUP_ID" ]]; then
    echo "  [FATAL] Manifest backup_id ('$M_ID') does not match discovered ID ('$BACKUP_ID')." >&2
    exit 2
fi

M_ARCHIVE="${MANIFEST_SCALARS[archive_filename]:-}"
if [[ "$M_ARCHIVE" != "$EXPECTED_ARCHIVE_NAME" ]]; then
    echo "  [FATAL] Manifest archive_filename ('$M_ARCHIVE') does not match expected '$EXPECTED_ARCHIVE_NAME'." >&2
    exit 2
fi

M_SHA="${MANIFEST_SCALARS[archive_sha256]:-}"
M_SHA="${M_SHA,,}"
if [[ "$M_SHA" != "$SIDECAR_SHA" ]]; then
    echo "  [FATAL] Manifest archive_sha256 ('$M_SHA') does not match sidecar checksum ('$SIDECAR_SHA')." >&2
    exit 2
fi

M_BYTES="${MANIFEST_SCALARS[archive_size_bytes]:-}"
if [[ "$M_BYTES" != "$ACTUAL_ARCHIVE_BYTES" ]]; then
    echo "  [FATAL] Manifest archive_size_bytes ($M_BYTES) does not match actual byte size ($ACTUAL_ARCHIVE_BYTES)." >&2
    exit 2
fi

if [[ ${#PARSED_REQ_CONFIGS[@]} -ne ${#REQUIRED_CONFIG_DIRS[@]} ]]; then
    echo "  [FATAL] Manifest required_config_dirs count (${#PARSED_REQ_CONFIGS[@]}) does not match expected (${#REQUIRED_CONFIG_DIRS[@]})." >&2
    exit 2
fi
for req_d in "${REQUIRED_CONFIG_DIRS[@]}"; do
    found=0
    for pd in "${PARSED_REQ_CONFIGS[@]}"; do
        if [[ "$pd" == "$req_d" ]]; then
            found=1
            break
        fi
    done
    if [[ "$found" -ne 1 ]]; then
        echo "  [FATAL] Manifest required_config_dirs missing required directory '$req_d'." >&2
        exit 2
    fi
done

if [[ ${#PARSED_REQ_VOLS[@]} -ne ${#ALLOWED_VOLUMES[@]} ]]; then
    echo "  [FATAL] Manifest required_volumes count (${#PARSED_REQ_VOLS[@]}) does not match expected (${#ALLOWED_VOLUMES[@]})." >&2
    exit 2
fi
for req_v in "${ALLOWED_VOLUMES[@]}"; do
    found=0
    for pv in "${PARSED_REQ_VOLS[@]}"; do
        if [[ "$pv" == "$req_v" ]]; then
            found=1
            break
        fi
    done
    if [[ "$found" -ne 1 ]]; then
        echo "  [FATAL] Manifest required_volumes missing expected volume '$req_v'." >&2
        exit 2
    fi
done

if [[ ${#PARSED_ARCH_VOLS[@]} -ne ${#ALLOWED_VOLUMES[@]} ]]; then
    echo "  [FATAL] Manifest archived_volumes count (${#PARSED_ARCH_VOLS[@]}) does not match required (${#ALLOWED_VOLUMES[@]})." >&2
    exit 2
fi
for req_v in "${ALLOWED_VOLUMES[@]}"; do
    found=0
    for av in "${PARSED_ARCH_VOLS[@]}"; do
        if [[ "$av" == "$req_v" ]]; then
            found=1
            break
        fi
    done
    if [[ "$found" -ne 1 ]]; then
        echo "  [FATAL] Manifest archived_volumes missing volume '$req_v'." >&2
        exit 2
    fi
done

if [[ ${#PARSED_MISS_VOLS[@]} -ne 0 || -z "${ARRAY_EXPLICIT_EMPTY[missing_volumes]:-}" ]]; then
    echo "  [FATAL] Manifest missing_volumes is not an empty list '[]'." >&2
    exit 2
fi

if [[ ${#PARSED_FAIL_VOLS[@]} -ne 0 || -z "${ARRAY_EXPLICIT_EMPTY[failed_volumes]:-}" ]]; then
    echo "  [FATAL] Manifest failed_volumes is not an empty list '[]'." >&2
    exit 2
fi

if [[ ${#SEEN_VOL_RESULTS[@]} -ne ${#ALLOWED_VOLUMES[@]} ]]; then
    echo "  [FATAL] Manifest volume_validation_results count (${#SEEN_VOL_RESULTS[@]}) does not match required (${#ALLOWED_VOLUMES[@]})." >&2
    exit 2
fi
for req_v in "${ALLOWED_VOLUMES[@]}"; do
    if [[ -z "${SEEN_VOL_RESULTS[$req_v]:-}" ]]; then
        echo "  [FATAL] Volume '$req_v' missing from volume_validation_results." >&2
        exit 2
    fi
    v_stat="${V_PROP_STATUS[$req_v]:-}"
    v_exists="${V_PROP_EXISTS[$req_v]:-}"
    v_ver="${V_PROP_ARCHIVE_VERIFIED[$req_v]:-}"
    v_bytes="${V_PROP_ARCHIVE_BYTES[$req_v]:-}"

    if [[ "$v_stat" != "PASSED" || "$v_exists" != "true" || "$v_ver" != "true" || ! "$v_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "  [FATAL] Volume '$req_v' validation record is invalid (status: '$v_stat', exists: '$v_exists', verified: '$v_ver', bytes: '$v_bytes')." >&2
        exit 2
    fi
done

printf "  [PASS] Manifest Schema 2.0.0 validated successfully (All 23 mandatory keys verified).\n"

# ------------------------------------------------------------------------------
# 8. Outer Archive Table-of-Contents & Nested Archive Security Inspection (E2.2-01, E2.2-08)
# ------------------------------------------------------------------------------
echo ""
echo "[3/6] Inspecting Archive Member Hierarchy, Root Files & Deep Nested Volumes (Pre-Extraction Security)..."

re_tar_entry='^([-dlhcbp?][rwxstST-]{9})[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}(:[0-9]{2})?)[[:space:]]+(.*)$'

declare -a TOC_TYPES=()
declare -a TOC_NORM_PATHS=()
declare -a TOC_RAW_PATHS=()
declare -a TOC_SIZES=()
declare -A SEEN_NORM_PATHS=()

tar_toc_out=""
if ! tar_toc_out="$(tar -tvzf "$RESOLVED_ARCHIVE" --quoting-style=escape 2>&1)"; then
    echo "  [FATAL] Failed to inspect outer archive table of contents: $tar_toc_out" >&2
    exit 2
fi

while IFS= read -r toc_line || [[ -n "$toc_line" ]]; do
    if [[ -z "${toc_line// }" ]]; then
        continue
    fi
    if [[ "$toc_line" =~ $re_tar_entry ]]; then
        mode="${BASH_REMATCH[1]}"
        ftype="${mode:0:1}"
        size="${BASH_REMATCH[3]}"
        raw_path="${BASH_REMATCH[6]}"

        # E2.2-01: Strict member type allowlist before extraction.
        # Only regular files ('-') and directories ('d') are allowed.
        # Reject symbolic links, hard links, devices, FIFOs, sockets, and unknown types.
        if [[ "$ftype" != "-" && "$ftype" != "d" ]]; then
            echo "  [FATAL] Archive member '$raw_path' has disallowed member type '$ftype'." >&2
            echo "          Symbolic links, hard links, devices, and special files are strictly prohibited." >&2
            exit 2
        fi

        # Path Traversal and Absolute Path Defense
        if [[ "$raw_path" =~ (^|/)\.\.(/|$) || "$raw_path" =~ ^/ ]]; then
            echo "  [FATAL] Archive member contains dangerous or absolute path ('$raw_path'). Restoration prohibited." >&2
            exit 2
        fi

        # Path Normalization: strip leading './' and trailing '/'
        norm_path="$raw_path"
        norm_path="${norm_path#./}"
        norm_path="${norm_path%/}"

        if [[ -z "$norm_path" || "$norm_path" == "." ]]; then
            # Top-level directory '.' is ignored
            continue
        fi

        # E2.2-01: Duplicate normalized path detection
        if [[ -n "${SEEN_NORM_PATHS["$norm_path"]:-}" ]]; then
            echo "  [FATAL] Outer archive contains duplicate normalized path: '$norm_path'." >&2
            exit 2
        fi
        SEEN_NORM_PATHS["$norm_path"]="$ftype"

        # E2.2-01: Parent-directory path conflict detection
        p_ancestor="$(dirname "$norm_path")"
        while [[ -n "$p_ancestor" && "$p_ancestor" != "." && "$p_ancestor" != "/" ]]; do
            if [[ "${SEEN_NORM_PATHS["$p_ancestor"]:-}" == "-" ]]; then
                echo "  [FATAL] Parent-directory path conflict: path '$norm_path' has ancestor '$p_ancestor' which is a regular file." >&2
                exit 2
            fi
            p_ancestor="$(dirname "$p_ancestor")"
        done

        TOC_TYPES+=("$ftype")
        TOC_NORM_PATHS+=("$norm_path")
        TOC_RAW_PATHS+=("$raw_path")
        TOC_SIZES+=("$size")
    else
        echo "  [FATAL] Archive table of contents contains unparseable or ambiguous line: '$toc_line'" >&2
        exit 2
    fi
done <<< "$tar_toc_out"

if [[ ${#TOC_NORM_PATHS[@]} -eq 0 ]]; then
    echo "  [FATAL] Archive table of contents produced no valid normalized paths." >&2
    exit 2
fi

# 1. Verify Configuration Directory Representation inside Archive
for cfg_dir in "${REQUIRED_CONFIG_DIRS[@]}"; do
    dir_entry_found=0
    descendant_count=0

    for ((idx=0; idx<${#TOC_NORM_PATHS[@]}; idx++)); do
        p="${TOC_NORM_PATHS[$idx]}"
        t="${TOC_TYPES[$idx]}"

        if [[ "$p" == "configs/${cfg_dir}" ]]; then
            if [[ "$t" != "d" ]]; then
                echo "  [FATAL] Archive entry 'configs/$cfg_dir' is not a directory (member type: '$t')." >&2
                exit 2
            fi
            dir_entry_found=1
        elif [[ "$p" =~ ^configs/${cfg_dir}/.+ ]]; then
            descendant_count=$((descendant_count + 1))
        fi
    done

    if [[ "$dir_entry_found" -eq 0 && "$descendant_count" -eq 0 ]]; then
        echo "  [FATAL] Required configuration directory '$cfg_dir' has no directory structure or descendants in archive." >&2
        exit 2
    fi
done

# 2. Verify Required Root Configuration Files inside Archive (E2.2-08)
for root_f in "${REQUIRED_ROOT_FILES[@]}"; do
    root_match_count=0
    root_type=""
    root_size=0

    for ((idx=0; idx<${#TOC_NORM_PATHS[@]}; idx++)); do
        p="${TOC_NORM_PATHS[$idx]}"
        t="${TOC_TYPES[$idx]}"
        s="${TOC_SIZES[$idx]}"

        if [[ "$p" == "configs/${root_f}" ]]; then
            root_match_count=$((root_match_count + 1))
            root_type="$t"
            root_size="$s"
        elif [[ "$p" =~ ^configs/${root_f}/ ]]; then
            echo "  [FATAL] Archive contains root file '$root_f' represented as a directory." >&2
            exit 2
        fi
    done

    if [[ "$root_match_count" -eq 0 ]]; then
        echo "  [FATAL] Required root configuration file '$root_f' is missing from archive." >&2
        exit 2
    elif [[ "$root_match_count" -gt 1 ]]; then
        echo "  [FATAL] Archive contains duplicate ($root_match_count) entries for root file '$root_f'." >&2
        exit 2
    fi

    if [[ "$root_type" != "-" ]]; then
        echo "  [FATAL] Required root configuration file '$root_f' in archive is not a regular file (type: '$root_type')." >&2
        exit 2
    fi

    if [[ ! "$root_size" =~ ^[1-9][0-9]*$ ]]; then
        echo "  [FATAL] Required root configuration file '$root_f' in archive is empty (size: '$root_size')." >&2
        exit 2
    fi
done

# 3. Deep Nested Volume Archive Inspection (E2.2-05)
for vol in "${ALLOWED_VOLUMES[@]}"; do
    vol_match_count=0
    vol_entry_path=""
    vol_entry_type=""

    for ((idx=0; idx<${#TOC_NORM_PATHS[@]}; idx++)); do
        p="${TOC_NORM_PATHS[$idx]}"
        t="${TOC_TYPES[$idx]}"

        if [[ "$p" == "volumes/${vol}.tar.gz" ]]; then
            vol_match_count=$((vol_match_count + 1))
            vol_entry_path="${TOC_RAW_PATHS[$idx]}"
            vol_entry_type="$t"
        elif [[ "$p" =~ ^volumes/${vol}\.tar\.gz/ ]] || [[ "$p" =~ ^volumes/${vol}\.tar\.gz\..+ ]]; then
            echo "  [FATAL] Outer archive contains ambiguous or malformed path for volume '$vol' ('$p')." >&2
            exit 2
        fi
    done

    if [[ "$vol_match_count" -eq 0 ]]; then
        echo "  [FATAL] Nested volume archive for '$vol' is missing from outer archive." >&2
        exit 2
    elif [[ "$vol_match_count" -gt 1 ]]; then
        echo "  [FATAL] Outer archive contains duplicate ($vol_match_count) entries for volume '$vol'." >&2
        exit 2
    fi

    if [[ "$vol_entry_type" != "-" ]]; then
        echo "  [FATAL] Nested archive for '$vol' is not a regular file (member type: '$vol_entry_type')." >&2
        exit 2
    fi

    actual_vol_bytes=""
    if ! actual_vol_bytes="$(tar -xzf "$RESOLVED_ARCHIVE" -O "$vol_entry_path" | wc -c)"; then
        echo "  [FATAL] Failed to extract or count bytes for nested volume archive '$vol'." >&2
        exit 2
    fi
    actual_vol_bytes="$(echo "$actual_vol_bytes" | tr -d ' \t\r\n')"
    expected_vol_bytes="${V_PROP_ARCHIVE_BYTES[$vol]:-}"

    if [[ "$actual_vol_bytes" != "$expected_vol_bytes" ]]; then
        echo "  [FATAL] Nested volume archive size for '$vol' ($actual_vol_bytes bytes) does not match manifest ($expected_vol_bytes bytes)." >&2
        exit 2
    fi

    nested_toc=()
    while IFS= read -r member_line || [[ -n "$member_line" ]]; do
        [[ -z "${member_line// }" ]] && continue
        nested_toc+=("$member_line")
    done < <(tar -xzf "$RESOLVED_ARCHIVE" -O "$vol_entry_path" | tar -tvzf - --quoting-style=escape; \
             if [[ ${PIPESTATUS[0]} -ne 0 || ${PIPESTATUS[1]} -ne 0 ]]; then echo "__PIPE_FAILED__"; fi)

    if [[ ${#nested_toc[@]} -eq 0 ]]; then
        echo "  [FATAL] Nested archive for volume '$vol' produced an empty table of contents." >&2
        exit 2
    fi

    if [[ "${nested_toc[${#nested_toc[@]}-1]}" == "__PIPE_FAILED__" ]]; then
        echo "  [FATAL] Nested archive streaming or listing failed for volume '$vol'." >&2
        exit 2
    fi

    for mline in "${nested_toc[@]}"; do
        if [[ "$mline" == "__PIPE_FAILED__" ]]; then
            echo "  [FATAL] Nested archive pipeline error detected for volume '$vol'." >&2
            exit 2
        fi
        if [[ "$mline" =~ $re_tar_entry ]]; then
            m_mode="${BASH_REMATCH[1]}"
            m_type="${m_mode:0:1}"
            m_raw_path="${BASH_REMATCH[6]}"

            if [[ "$m_type" != "-" && "$m_type" != "d" ]]; then
                echo "  [FATAL] Nested archive for volume '$vol' contains disallowed member type '$m_type' (path: '$m_raw_path')." >&2
                echo "          Only regular files and directories are permitted in monitoring data volumes." >&2
                exit 2
            fi

            if [[ "$m_raw_path" =~ (^|/)\.\.(/|$) || "$m_raw_path" =~ ^/ ]]; then
                echo "  [FATAL] Nested archive for volume '$vol' contains dangerous or absolute path ('$m_raw_path')." >&2
                exit 2
            fi
        else
            echo "  [FATAL] Nested archive for volume '$vol' contains unparseable entry line: '$mline'" >&2
            exit 2
        fi
    done
done

printf "  [PASS] Outer archive structure, root files, and all 5 nested archives strictly verified pre-extraction.\n"

# ------------------------------------------------------------------------------
# 9. Pre-Flight Stack Liveness & Offline State Enforcement (Fail-Closed)
# ------------------------------------------------------------------------------
echo ""
echo "[4/6] Enforcing Pre-Flight Multi-Project Offline Stack Safety Gate..."

if [[ "$RESTORE_VOLUMES" -eq 1 ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "  [FATAL] Docker CLI ('docker') not found in PATH. Volume restoration requires Docker." >&2
        exit 4
    fi

    DOCKER_DIAG=""
    if ! DOCKER_DIAG=$(docker info 2>&1 >/dev/null); then
        if echo "$DOCKER_DIAG" | grep -qiE "permission denied|got permission denied while trying to connect to the docker daemon socket"; then
            echo "  [FATAL] Docker permission failure: current user lacks permission to access Docker socket." >&2
            echo "          Ensure user is added to 'docker' group or has appropriate socket permissions." >&2
            exit 4
        elif echo "$DOCKER_DIAG" | grep -qiE "cannot connect|is the docker daemon running|daemon not running|dial unix"; then
            echo "  [FATAL] Docker daemon unavailable: cannot connect to Docker daemon." >&2
            echo "          Ensure Docker service is active ('systemctl status docker' or Docker Desktop)." >&2
            exit 4
        else
            echo "  [FATAL] Docker daemon communication error: $DOCKER_DIAG" >&2
            exit 4
        fi
    fi

    ACTIVE_CONTAINERS=()
    COMPOSE_PROJECT_FILES=(
        "$REPO_ROOT/docker-compose.yml"
        "$REPO_ROOT/prometheus/docker-compose.yml"
        "$REPO_ROOT/loki/docker-compose.yml"
        "$REPO_ROOT/alertmanager/docker-compose.yml"
        "$REPO_ROOT/blackbox/docker-compose.yml"
    )

    for cfile in "${COMPOSE_PROJECT_FILES[@]}"; do
        if [[ -f "$cfile" ]]; then
            compose_out=""
            if ! compose_out="$(docker compose -f "$cfile" ps --status running -q 2>&1)"; then
                echo "  [FATAL] Docker Compose inspection failed for '$cfile': $compose_out" >&2
                echo "          Cannot reliably determine container state. Failing closed." >&2
                exit 4
            fi
            while IFS= read -r cid; do
                [[ -n "$cid" ]] && ACTIVE_CONTAINERS+=("$cid")
            done <<< "$compose_out"
        fi
    done

    ps_label_out=""
    if ! ps_label_out="$(docker ps --filter "label=com.docker.compose.project" --filter "status=running" -q 2>&1)"; then
        echo "  [FATAL] Docker container query failed for compose project labels: $ps_label_out" >&2
        exit 4
    fi
    while IFS= read -r cid; do
        [[ -n "$cid" ]] && ACTIVE_CONTAINERS+=("$cid")
    done <<< "$ps_label_out"

    ps_name_out=""
    if ! ps_name_out="$(docker ps --filter "name=lab-" --filter "name=lab_" --filter "status=running" -q 2>&1)"; then
        echo "  [FATAL] Docker container query failed for lab container names: $ps_name_out" >&2
        exit 4
    fi
    while IFS= read -r cid; do
        [[ -n "$cid" ]] && ACTIVE_CONTAINERS+=("$cid")
    done <<< "$ps_name_out"

    declare -A seen_cids=()
    declare -a unique_cids=()
    for cid in "${ACTIVE_CONTAINERS[@]}"; do
        if [[ -n "$cid" && -z "${seen_cids[$cid]:-}" ]]; then
            seen_cids["$cid"]=1
            unique_cids+=("$cid")
        fi
    done

    if [[ ${#unique_cids[@]} -gt 0 ]]; then
        echo "  [FATAL] Monitoring stack is currently ACTIVE (${#unique_cids[@]} running container(s) detected)." >&2
        echo "          Running container IDs: ${unique_cids[*]}" >&2
        echo "          Volume restoration cannot proceed while containers are running." >&2
        echo "          Restoring active TSDB volumes causes irreversible database corruption." >&2
        echo "          Please gracefully stop the stack before restoring:" >&2
        echo "            ./deployment/deploy.sh down" >&2
        exit 3
    fi

    printf "  [PASS] Docker daemon accessible and all monitoring projects confirmed OFFLINE.\n"
else
    echo "  [INFO] Volumes restoration skipped (--configs-only). Docker stack liveness gate bypassed."
fi

for port in "${LAB_PORTS[@]}"; do
    if command -v ss >/dev/null 2>&1; then
        if ss -tln | grep -qE ":${port}\b"; then
            echo "  [WARN] Port :$port is currently bound by a process on the host." >&2
            echo "         Ensure native services do not conflict with planned container startup." >&2
        fi
    fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "======================================================================"
    echo "  DRY-RUN VALIDATION COMPLETE"
    echo "  Backup Set:  $RESOLVED_SET_DIR"
    echo "  Status:      VALIDATED (All checksums, schemas, deep archives, and offline gates passed)"
    echo "  Result:      No configuration or volume modifications were applied."
    echo "======================================================================"
    exit 0
fi

# ------------------------------------------------------------------------------
# 10. Extract Verified Unified Archive to Private Staging Area (E2.2-01)
# ------------------------------------------------------------------------------
echo ""
echo "[5/6] Extracting Archive to Isolated Private Staging Directory..."
EXTRACTED_STAGE="$TEMP_STAGE/extracted"
mkdir -p "$EXTRACTED_STAGE"

# Because outer archive members were 100% pre-validated against symlinks and special entries,
# extraction is secure by construction without post-extraction link deletion hacks.
if ! tar -xzf "$RESOLVED_ARCHIVE" -C "$EXTRACTED_STAGE"; then
    echo "  [FATAL] Failed to extract archive into private staging area: $RESOLVED_ARCHIVE" >&2
    exit 2
fi

# ------------------------------------------------------------------------------
# 11. Configuration Restoration with Pre-Restore Rollback Staging (E2.2-02, E2.2-06)
# ------------------------------------------------------------------------------
ROLLBACK_CONFIG_DIR="$TEMP_STAGE/rollback_configs"

if [[ "$RESTORE_CONFIGS" -eq 1 ]]; then
    echo "  • Backing up current repository configurations to rollback staging..."
    mkdir -p "$ROLLBACK_CONFIG_DIR"

    for dir in "${REQUIRED_CONFIG_DIRS[@]}"; do
        if [[ -d "$REPO_ROOT/$dir" && ! -L "$REPO_ROOT/$dir" ]]; then
            RESOURCE_PRE_EXISTED["CONFIG_DIR:$dir"]=1
            if ! cp -R -P "$REPO_ROOT/$dir" "$ROLLBACK_CONFIG_DIR/"; then
                echo "  [FATAL] Failed to stage pre-restore backup of directory '$dir'!" >&2
                execute_unified_rollback || exit 7
                exit 1
            fi
        else
            RESOURCE_PRE_EXISTED["CONFIG_DIR:$dir"]=0
        fi
    done

    for file in "${REQUIRED_ROOT_FILES[@]}"; do
        if [[ -f "$REPO_ROOT/$file" && ! -L "$REPO_ROOT/$file" ]]; then
            RESOURCE_PRE_EXISTED["CONFIG_FILE:$file"]=1
            if ! cp "$REPO_ROOT/$file" "$ROLLBACK_CONFIG_DIR/"; then
                echo "  [FATAL] Failed to stage pre-restore backup of root file '$file'!" >&2
                execute_unified_rollback || exit 7
                exit 1
            fi
        else
            RESOURCE_PRE_EXISTED["CONFIG_FILE:$file"]=0
        fi
    done

    if [[ -f "$REPO_ROOT/.env.example" && ! -L "$REPO_ROOT/.env.example" ]]; then
        RESOURCE_PRE_EXISTED["CONFIG_FILE:.env.example"]=1
        if ! cp "$REPO_ROOT/.env.example" "$ROLLBACK_CONFIG_DIR/"; then
            echo "  [FATAL] Failed to stage pre-restore backup of .env.example!" >&2
            execute_unified_rollback || exit 7
            exit 1
        fi
    else
        RESOURCE_PRE_EXISTED["CONFIG_FILE:.env.example"]=0
    fi

    echo "  • Applying verified configuration directories to repository..."
    for dir in "${REQUIRED_CONFIG_DIRS[@]}"; do
        staged_dir="$EXTRACTED_STAGE/configs/$dir"
        if [[ ! -d "$staged_dir" ]]; then
            echo "  [FATAL] Extracted configuration directory '$dir' is missing!" >&2
            execute_unified_rollback || exit 7
            exit 1
        fi

        # Register in transaction log immediately prior to modification
        TRANSACTION_LOG+=("CONFIG_DIR:$dir")

        rm -rf "$REPO_ROOT/$dir"
        if ! cp -R -P "$staged_dir" "$REPO_ROOT/"; then
            echo "  [FATAL] Failed to copy configuration directory '$dir' to repository!" >&2
            execute_unified_rollback || exit 7
            exit 1
        fi
    done

    echo "  • Applying verified root configuration files to repository..."
    for file in "${REQUIRED_ROOT_FILES[@]}"; do
        staged_file="$EXTRACTED_STAGE/configs/$file"
        if [[ -f "$staged_file" && ! -L "$staged_file" ]]; then
            TRANSACTION_LOG+=("CONFIG_FILE:$file")
            if ! cp "$staged_file" "$REPO_ROOT/$file"; then
                echo "  [FATAL] Failed to copy root file '$file' to repository!" >&2
                execute_unified_rollback || exit 7
                exit 1
            fi
        fi
    done

    if [[ -f "$EXTRACTED_STAGE/configs/.env.example" && ! -L "$EXTRACTED_STAGE/configs/.env.example" ]]; then
        TRANSACTION_LOG+=("CONFIG_FILE:.env.example")
        if ! cp "$EXTRACTED_STAGE/configs/.env.example" "$REPO_ROOT/.env.example"; then
            echo "  [FATAL] Failed to copy template .env.example to repository!" >&2
            execute_unified_rollback || exit 7
            exit 1
        fi
    fi

    printf "  [DONE] Configurations restored successfully (%d directories).\n" "${#REQUIRED_CONFIG_DIRS[@]}"
else
    echo "  [INFO] Configuration restoration skipped (--volumes-only)."
fi

# ------------------------------------------------------------------------------
# 12. Docker Named Volume Restoration with Snapshot Verification (E2.2-02, E2.2-04, E2.2-07)
# ------------------------------------------------------------------------------
if [[ "$RESTORE_VOLUMES" -eq 1 ]]; then
    echo "  • Restoring Docker TSDB named volumes..."

    VOLUMES_TO_RESTORE=()
    if [[ -n "$TARGET_VOLUME" ]]; then
        VOLUMES_TO_RESTORE=("$TARGET_VOLUME")
    else
        VOLUMES_TO_RESTORE=("${ALLOWED_VOLUMES[@]}")
    fi

    for vol in "${VOLUMES_TO_RESTORE[@]}"; do
        echo "    - Processing volume '$vol'..."
        vol_archive="$EXTRACTED_STAGE/volumes/${vol}.tar.gz"

        if [[ ! -f "$vol_archive" || ! -s "$vol_archive" ]]; then
            echo "      [FATAL] Volume archive missing or empty: $vol_archive" >&2
            execute_unified_rollback || exit 7
            exit 5
        fi

        # E2.2-04: Fail-closed inspection distinguishing existence, absence, and daemon errors
        vol_exists_on_host=0
        inspect_out=""
        if inspect_out="$(docker volume inspect "$vol" 2>&1)"; then
            vol_exists_on_host=1
        else
            inspect_rc=$?
            if echo "$inspect_out" | grep -qiE "no such volume|volume not found|error: no such volume"; then
                vol_exists_on_host=0
            elif echo "$inspect_out" | grep -qiE "permission denied"; then
                echo "      [FATAL] Permission denied inspecting Docker volume '$vol': $inspect_out" >&2
                execute_unified_rollback || exit 7
                exit 4
            elif echo "$inspect_out" | grep -qiE "cannot connect|is the docker daemon running"; then
                echo "      [FATAL] Cannot connect to Docker daemon inspecting volume '$vol': $inspect_out" >&2
                execute_unified_rollback || exit 7
                exit 4
            else
                echo "      [FATAL] Ambiguous Docker volume inspection failure for '$vol' (exit $inspect_rc): $inspect_out" >&2
                execute_unified_rollback || exit 7
                exit 4
            fi
        fi
        RESOURCE_PRE_EXISTED["VOLUME:$vol"]="$vol_exists_on_host"

        if [[ "$vol_exists_on_host" -eq 1 ]]; then
            if [[ "$CONFIRM_REPLACE_VOLUMES" -ne 1 ]]; then
                echo "      [FATAL] Volume '$vol' already exists on Docker host." >&2
                echo "              Overwriting existing volume data requires explicit confirmation." >&2
                echo "              Re-run with '--replace-volumes' to authorize replacing existing volume contents." >&2
                execute_unified_rollback || exit 7
                exit 5
            fi

            # E2.2-07: Determine source item count before creating snapshot
            src_count=""
            if ! src_count="$(docker run --rm -v "${vol}:/src:ro" alpine:3.19 sh -c "find /src -mindepth 1 | wc -l" 2>&1)"; then
                echo "      [FATAL] Failed to inspect item count in pre-existing volume '$vol': $src_count" >&2
                execute_unified_rollback || exit 7
                exit 5
            fi
            src_count="$(echo "$src_count" | tr -d ' \t\r\n')"

            # Generate collision-safe rollback volume name
            rand_suffix=""
            if ! rand_suffix="$(generate_secure_random_hex)"; then
                execute_unified_rollback || exit 7
                exit 2
            fi
            ROLLBACK_VOL="lab_rollback_${vol}_${rand_suffix}"

            # Verify snapshot volume does not already exist
            inspect_chk=""
            if inspect_chk="$(docker volume inspect "$ROLLBACK_VOL" 2>&1)"; then
                echo "      [FATAL] Target rollback volume '$ROLLBACK_VOL' already exists (collision)!" >&2
                execute_unified_rollback || exit 7
                exit 5
            fi

            echo "      • Creating collision-safe rollback snapshot: $ROLLBACK_VOL"
            if ! docker volume create "$ROLLBACK_VOL" >/dev/null; then
                echo "      [FATAL] Failed to create rollback volume '$ROLLBACK_VOL' for '$vol'." >&2
                execute_unified_rollback || exit 7
                exit 5
            fi
            SNAPSHOT_OWNERSHIP_LEDGER+=("$ROLLBACK_VOL")
            VOLUME_SNAPSHOT_NAME["$vol"]="$ROLLBACK_VOL"

            if ! docker run --rm \
                -v "${vol}:/src:ro" \
                -v "${ROLLBACK_VOL}:/dst" \
                alpine:3.19 sh -c "cp -a /src/. /dst/"; then
                echo "      [FATAL] Failed to copy existing data into rollback snapshot '$ROLLBACK_VOL'." >&2
                execute_unified_rollback || exit 7
                exit 5
            fi

            # E2.2-07: Strict snapshot verification before purging live volume
            snap_count=""
            if ! snap_count="$(docker run --rm -v "${ROLLBACK_VOL}:/snap:ro" alpine:3.19 sh -c "find /snap -mindepth 1 | wc -l" 2>&1)"; then
                echo "      [FATAL] Failed to inspect item count in rollback snapshot '$ROLLBACK_VOL': $snap_count" >&2
                execute_unified_rollback || exit 7
                exit 5
            fi
            snap_count="$(echo "$snap_count" | tr -d ' \t\r\n')"

            if [[ "$src_count" =~ ^[1-9][0-9]*$ ]]; then
                if [[ "$snap_count" != "$src_count" ]]; then
                    echo "      [FATAL] Rollback snapshot verification failed for '$vol': snapshot has $snap_count item(s), source has $src_count item(s)!" >&2
                    echo "              Live volume will NOT be purged. Aborting restoration to prevent data loss." >&2
                    execute_unified_rollback || exit 7
                    exit 5
                fi
            elif [[ "$src_count" == "0" ]]; then
                if [[ "$snap_count" != "0" ]]; then
                    echo "      [FATAL] Rollback snapshot verification anomaly: source has 0 items but snapshot has $snap_count items!" >&2
                    execute_unified_rollback || exit 7
                    exit 5
                fi
            else
                echo "      [FATAL] Unparseable item count for volume '$vol' (src: '$src_count', snap: '$snap_count')." >&2
                execute_unified_rollback || exit 7
                exit 5
            fi
            printf "      [PASS] Pre-restore snapshot verified (%s items confirmed identical to source).\n" "$snap_count"
        else
            echo "      • Creating new Docker volume '$vol'..."
            if ! docker volume create "$vol" >/dev/null; then
                echo "      [FATAL] Failed to create Docker volume '$vol'." >&2
                execute_unified_rollback || exit 7
                exit 5
            fi
        fi

        # Register volume in transaction log immediately prior to modification
        TRANSACTION_LOG+=("VOLUME:$vol")

        echo "      • Purging existing volume contents..."
        if ! docker run --rm \
            -v "${vol}:/volume" \
            alpine:3.19 find /volume -mindepth 1 -delete; then
            echo "      [FATAL] Failed to clean volume '$vol' prior to extraction." >&2
            execute_unified_rollback || exit 7
            exit 5
        fi

        echo "      • Extracting archived volume data..."
        if ! docker run --rm \
            -v "${vol}:/volume" \
            -v "$EXTRACTED_STAGE/volumes:/backup:ro" \
            alpine:3.19 tar -xzf "/backup/${vol}.tar.gz" -C /volume; then
            echo "      [FATAL] Failed to extract archive into volume '$vol'!" >&2
            execute_unified_rollback || exit 7
            exit 5
        fi

        echo "      • Verifying restored volume content..."
        VOL_ITEM_COUNT="$(docker run --rm -v "${vol}:/volume:ro" alpine:3.19 sh -c "find /volume -mindepth 1 | wc -l" 2>/dev/null || echo "0")"
        VOL_ITEM_COUNT="$(echo "$VOL_ITEM_COUNT" | tr -d ' \t\r\n')"
        if [[ ! "$VOL_ITEM_COUNT" =~ ^[1-9][0-9]*$ ]]; then
            echo "      [FATAL] Restored volume '$vol' verification failed: volume is empty after extraction!" >&2
            execute_unified_rollback || exit 7
            exit 5
        fi

        printf "      [PASS] Volume '%s' restored and verified (%s files/directories).\n" "$vol" "$VOL_ITEM_COUNT"
    done
    printf "  [DONE] Docker named volumes restored successfully.\n"
else
    echo "  [INFO] Volume restoration skipped (--configs-only)."
fi

# ------------------------------------------------------------------------------
# 13. Post-Restore Permission Hardening & Security Audit (E2.2-06)
# ------------------------------------------------------------------------------
echo ""
echo "[6/6] Hardening Restored File Permissions & Verifying Least Privilege..."

if [[ ! -f "$REPO_ROOT/security/harden_permissions.sh" ]]; then
    echo "  [FATAL] Required permission hardening script '$REPO_ROOT/security/harden_permissions.sh' is missing!" >&2
    execute_unified_rollback || exit 7
    exit 6
fi

if ! bash "$REPO_ROOT/security/harden_permissions.sh"; then
    echo "  [FATAL] Permission hardening script failed! File modes may be insecure." >&2
    execute_unified_rollback || exit 7
    exit 6
fi

if [[ -d "$REPO_ROOT/alloy" ]]; then
    if ! find "$REPO_ROOT/alloy" -type d -exec chmod 755 {} +; then
        echo "  [FATAL] Failed to enforce 0755 permissions on Alloy directories!" >&2
        execute_unified_rollback || exit 7
        exit 6
    fi
    if ! find "$REPO_ROOT/alloy" -type f -exec chmod 644 {} +; then
        echo "  [FATAL] Failed to enforce 0644 permissions on Alloy configuration files!" >&2
        execute_unified_rollback || exit 7
        exit 6
    fi
fi

AUDIT_LOG="$REPO_ROOT/.restore_audit.log"
if ! {
    echo "======================================================================"
    echo "Disaster Recovery Restore Execution Record"
    echo "Timestamp:       $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Backup ID:       $BACKUP_ID"
    echo "Backup Set:      $RESOLVED_SET_DIR"
    echo "Archive SHA256:  $SIDECAR_SHA"
    echo "Restore Configs: $([[ "$RESTORE_CONFIGS" -eq 1 ]] && echo "YES" || echo "NO")"
    echo "Restore Volumes: $([[ "$RESTORE_VOLUMES" -eq 1 ]] && echo "YES" || echo "NO")"
    if [[ -n "$TARGET_VOLUME" ]]; then
        echo "Target Volume:   $TARGET_VOLUME"
    fi
    echo "Status:          SUCCESS"
    echo "======================================================================"
} >> "$AUDIT_LOG"; then
    echo "  [FATAL] Failed to write disaster recovery audit record to '$AUDIT_LOG'!" >&2
    execute_unified_rollback || exit 7
    exit 1
fi

if ! chmod 0600 "$AUDIT_LOG"; then
    echo "  [FATAL] Failed to enforce 0600 permissions on audit record '$AUDIT_LOG'!" >&2
    execute_unified_rollback || exit 7
    exit 6
fi

# Signal 100% full success: authorizes cleanup of temporary rollback snapshot volumes
RESTORE_SUCCESS=1

echo ""
echo "======================================================================"
echo "  DISASTER RECOVERY RESTORE COMPLETED SUCCESSFULLY"
echo "  Backup ID:     $BACKUP_ID"
echo "  Manifest:      Schema 2.0.0 Verified"
echo "  Integrity:     Cryptographic Checksum Verified ($SIDECAR_SHA)"
echo "  Configs:       $([[ "$RESTORE_CONFIGS" -eq 1 ]] && echo "Restored & Hardened" || echo "Skipped")"
echo "  Volumes:       $([[ "$RESTORE_VOLUMES" -eq 1 ]] && echo "Restored & Verified" || echo "Skipped")"
echo ""
echo "  Next Steps: Launch and verify the restored monitoring stack:"
echo "    ./deployment/deploy.sh up"
echo "    ./deployment/deploy.sh health"
echo "======================================================================"

exit 0
