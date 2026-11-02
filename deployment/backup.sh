#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: deployment/backup.sh
# Purpose: Production-grade disaster recovery backup orchestrator with atomic
#          backup-set publication, filename-pattern-based secret exclusion, Docker daemon error
#          classification, signal isolation, nested archive verification, and cryptographic integrity verification
# Role: Principal SRE & Linux Storage Reliability Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

# Enforce strict umask: 077 ensures directories are 0700 and files are 0600
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ------------------------------------------------------------------------------
# 1. Operational Mode & Configuration Parsing
# ------------------------------------------------------------------------------
DEFAULT_BACKUP_DIR="${HOME}/.local/share/lab-monitoring/backups"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
BACKUP_MODE="${BACKUP_MODE:-checkpoint}" # 'checkpoint' (strict default) or 'routine'
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Production-Grade Disaster Recovery Backup Orchestrator for Linux Monitoring Lab.

Options:
  --mode=checkpoint    Enforce strict migration checkpoint (default): all required
                       volumes must exist and be archived. Fails if any volume is missing.
  --mode=routine       Allow routine partial backup: archives available volumes,
                       recording missing volumes with PARTIAL_ROUTINE status.
  -h, --help           Display this help message.

Environment Variables:
  BACKUP_DIR           Destination directory (default: ~/.local/share/lab-monitoring/backups)
  BACKUP_MODE          'checkpoint' (default) or 'routine'
  BACKUP_RETENTION_DAYS Retention period in days (default: 7)

Documented Exit Codes:
  0   SUCCESS: Backup set created, verified, and published; retention complete.
  1   PARTIAL_ROUTINE / ERR_CLEANUP_FAILURE: Routine backup completed with missing volume warnings, or temporary staging cleanup failed.
  2   FAILED_CHECKPOINT / FAILED: Checkpoint criteria not met, snapshot failed, or invalid backup mode.
  3   ERR_DOCKER_CLI: Docker CLI not found in PATH.
  4   ERR_DOCKER_PERM: Docker daemon socket permission failure.
  5   ERR_DOCKER_DAEMON: Docker daemon unavailable or socket unreachable.
  6   ERR_DOCKER_COMM: Docker communication or runtime error.
  7   ERR_SECURE_RANDOM_UNAVAILABLE: /dev/urandom unavailable or failed to produce random bytes.
  8   ERR_RETENTION_FAILURE: Backup set published, but retention pruning failed.
 10   ERR_UNSAFE_DEST: Unsafe backup destination (empty, symlink component, unowned, or insecure permissions).
 11   ERR_SYS_DEST: Unsafe backup destination (system directory).
 12   ERR_IN_REPO_DEST: Insecure backup destination (inside Git repository).
 13   ERR_VERIFY_FAILURE: Staged archive verification or checksum failed.
 14   ERR_CONFIG_MISSING: Required configuration directory missing, symlinked, or removed during filtering.
 15   ERR_COLLISION: Target backup set identifier collision.
 16   ERR_PUBLISH_FAILURE: Atomic publication failed or post-move verification failed.
130   SIGINT: Interrupted by operator (Ctrl+C).
143   SIGTERM: Terminated by signal.
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --mode=checkpoint|--checkpoint)
            BACKUP_MODE="checkpoint"
            ;;
        --mode=routine|--routine)
            BACKUP_MODE="routine"
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 2
            ;;
    esac
done

# Strict validation of backup mode: reject any invalid BACKUP_MODE immediately
case "$BACKUP_MODE" in
    checkpoint|routine)
        ;;
    *)
        echo "  [FATAL] Invalid backup mode: '$BACKUP_MODE'. Must be exactly 'checkpoint' or 'routine'." >&2
        echo "          Environment variable BACKUP_MODE or --mode must specify either 'checkpoint' or 'routine'." >&2
        exit 2
        ;;
esac

# ------------------------------------------------------------------------------
# 2. Signal Handling & Visible Temporary Artifact Cleanup
# ------------------------------------------------------------------------------
TEMP_STAGE=""
TMP_SET_DIR=""
CLEANUP_FAILED=0

cleanup_temp_artifacts() {
    # Idempotent cleanup: can safely be invoked multiple times
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
    echo "  [WARN] Backup interrupted by SIGINT (Ctrl+C). Cleaning up temporary artifacts..." >&2
    if ! cleanup_temp_artifacts; then
        echo "  [ERROR] Temporary artifact cleanup failed during SIGINT handling." >&2
    fi
    exit 130
}

on_sigterm() {
    trap - SIGTERM
    trap - EXIT
    trap - SIGINT
    echo "" >&2
    echo "  [WARN] Backup terminated by SIGTERM. Cleaning up temporary artifacts..." >&2
    if ! cleanup_temp_artifacts; then
        echo "  [ERROR] Temporary artifact cleanup failed during SIGTERM handling." >&2
    fi
    exit 143
}

trap on_exit EXIT
trap on_sigint SIGINT
trap on_sigterm SIGTERM

# ------------------------------------------------------------------------------
# 3. Destination Validation & Canonicalization
# ------------------------------------------------------------------------------
# Destination Security Policy:
# 1. Symlink Policy: The destination path and all existing ancestor path components
#    must NOT be symbolic links. Any symlink detected aborts immediately (exit 10).
# 2. Ownership & Permissions: The directory must be owned strictly by the executing
#    user (UID == $(id -u)) with restrictive 0700 permissions.
# 3. Non-Destructive Invariant: Existing directories with permissions other than 0700
#    are NOT modified; execution fails closed with instructions for the operator.
# 4. Immediate Revalidation: The destination is revalidated immediately before staging
#    and immediately before atomic publication.
# 5. TOCTOU Limitation: Filesystem operations across user-space scripts remain subject
#    to unavoidable kernel-level TOCTOU windows without O_NOFOLLOW file descriptors.

validate_no_symlink_components() {
    local target_path="$1"
    local desc="$2"
    local p="$target_path"
    p="${p%/}"
    while [[ -n "$p" && "$p" != "/" && "$p" != "." ]]; do
        if [[ -L "$p" ]]; then
            echo "  [FATAL] Unsafe destination: $desc path component '$p' is a symbolic link." >&2
            echo "          Symlinked destination paths and symlinked parent directories are strictly prohibited." >&2
            return 1
        fi
        p="$(dirname "$p")"
    done
    return 0
}

revalidate_destination_security() {
    local target_dir="$1"
    local phase_name="$2"

    if ! validate_no_symlink_components "$target_dir" "$phase_name"; then
        exit 10
    fi
    if [[ ! -e "$target_dir" ]]; then
        echo "  [FATAL] Destination revalidation failed during $phase_name: '$target_dir' does not exist." >&2
        exit 10
    fi
    if [[ -L "$target_dir" ]]; then
        echo "  [FATAL] Destination revalidation failed during $phase_name: '$target_dir' is a symbolic link." >&2
        exit 10
    fi
    if [[ ! -d "$target_dir" ]]; then
        echo "  [FATAL] Destination revalidation failed during $phase_name: '$target_dir' exists but is not a directory." >&2
        exit 10
    fi

    local d_owner
    d_owner="$(stat -c "%u" "$target_dir" 2>/dev/null || echo "-1")"
    if [[ "$d_owner" -ne "$(id -u)" ]]; then
        echo "  [FATAL] Destination revalidation failed during $phase_name: '$target_dir' is not owned by current user (UID $d_owner != $(id -u))." >&2
        exit 10
    fi

    local d_mode
    d_mode="$(stat -c "%a" "$target_dir" 2>/dev/null || echo "")"
    if [[ -z "$d_mode" ]]; then
        echo "  [FATAL] Unable to determine permissions of destination directory '$target_dir' during $phase_name." >&2
        exit 10
    fi
    if [[ "$d_mode" != "700" && "$d_mode" != "0700" ]]; then
        echo "  [FATAL] Destination revalidation failed during $phase_name: '$target_dir' has mode '$d_mode' (expected 0700)." >&2
        echo "          Group or other users may have access. For security, backup directories must have 0700 permissions." >&2
        echo "          To avoid altering unrelated existing directories, this script will not automatically chmod existing directories." >&2
        echo "          Please run 'chmod 0700 \"$target_dir\"' if this directory is the intended dedicated backup location." >&2
        exit 10
    fi
}

# Validate raw BACKUP_DIR before canonicalization
if [[ -z "${BACKUP_DIR// }" ]]; then
    echo "  [FATAL] Unsafe backup destination: BACKUP_DIR is empty." >&2
    exit 10
fi

if ! validate_no_symlink_components "$BACKUP_DIR" "raw BACKUP_DIR"; then
    exit 10
fi

CANONICAL_REPO_ROOT="$(realpath -e "$REPO_ROOT" 2>/dev/null || readlink -f "$REPO_ROOT")"
CANONICAL_BACKUP_DIR="$(realpath -m "$BACKUP_DIR" 2>/dev/null || readlink -f "$BACKUP_DIR")"

# Validate destination is not empty or filesystem root
if [[ -z "$CANONICAL_BACKUP_DIR" || "$CANONICAL_BACKUP_DIR" == "/" ]]; then
    echo "  [FATAL] Unsafe backup destination: '$BACKUP_DIR' resolves to filesystem root '/'." >&2
    exit 10
fi

if ! validate_no_symlink_components "$CANONICAL_BACKUP_DIR" "canonical BACKUP_DIR"; then
    exit 10
fi

# Reject unsafe system directories
case "$CANONICAL_BACKUP_DIR" in
    /bin*|/sbin*|/usr*|/etc*|/lib*|/sys*|/proc*|/dev*|/boot*|/root*)
        echo "  [FATAL] Unsafe backup destination: '$CANONICAL_BACKUP_DIR' is a system directory." >&2
        exit 11
        ;;
esac

# Reject backup destination inside the Git repository
if [[ "$CANONICAL_BACKUP_DIR" == "$CANONICAL_REPO_ROOT" || "$CANONICAL_BACKUP_DIR" == "$CANONICAL_REPO_ROOT"/* ]]; then
    echo "  [FATAL] Insecure backup destination: '$CANONICAL_BACKUP_DIR' is inside repository root '$CANONICAL_REPO_ROOT'." >&2
    echo "          Backups must be written outside the repository to prevent working-tree pollution and secret leaks." >&2
    exit 12
fi

# Validate destination directory properties or initialize newly created destination
if [[ -e "$CANONICAL_BACKUP_DIR" ]]; then
    revalidate_destination_security "$CANONICAL_BACKUP_DIR" "initialization"
else
    # Create dedicated backup directory with 0700 permissions
    mkdir -p "$CANONICAL_BACKUP_DIR"
    if ! chmod 0700 "$CANONICAL_BACKUP_DIR" 2>/dev/null; then
        echo "  [FATAL] Failed to enforce 0700 permissions on destination directory: $CANONICAL_BACKUP_DIR" >&2
        exit 10
    fi

    # Re-verify newly created directory ownership and permissions
    revalidate_destination_security "$CANONICAL_BACKUP_DIR" "initial-creation"
fi

# ------------------------------------------------------------------------------
# 4. Collision-Resistant Unique Identifier & Fail-Safe Random Generation
# ------------------------------------------------------------------------------
TIMESTAMP_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TIMESTAMP_EPOCH="$(date -u +"%s")"
TIMESTAMP_TAG="$(date -u +"%Y%m%d-%H%M%SZ")"

# Secure random source verification: strictly require /dev/urandom without insecure fallbacks
if [[ ! -r /dev/urandom ]]; then
    echo "  [FATAL] Cryptographic random source '/dev/urandom' is unavailable or unreadable." >&2
    exit 7
fi

# Extract exactly 8 random bytes (16 hex chars) from /dev/urandom
RAND_HEX="$(head -c 8 /dev/urandom 2>/dev/null | od -N 8 -tx1 -An 2>/dev/null | tr -d ' \n' || true)"

if [[ -z "$RAND_HEX" || ${#RAND_HEX} -ne 16 || ! "$RAND_HEX" =~ ^[0-9a-fA-F]{16}$ ]]; then
    echo "  [FATAL] Failed to extract secure 16-hex random suffix from '/dev/urandom'." >&2
    exit 7
fi
RAND_HEX="${RAND_HEX,,}"

BACKUP_ID="${TIMESTAMP_TAG}-${RAND_HEX}"
SET_BASENAME="backup-set-${BACKUP_ID}"
FINAL_BACKUP_SET="$CANONICAL_BACKUP_DIR/$SET_BASENAME"

# Prevent collision: never overwrite an existing backup set
if [[ -e "$FINAL_BACKUP_SET" || -L "$FINAL_BACKUP_SET" ]]; then
    echo "  [FATAL] Target backup set collision: '$FINAL_BACKUP_SET' already exists." >&2
    exit 15
fi

# Revalidate destination security immediately before creating temporary staging directory
revalidate_destination_security "$CANONICAL_BACKUP_DIR" "pre-staging"

# Colocated temporary set directory on the destination filesystem (enables atomic directory rename)
TMP_SET_DIR="$(mktemp -d "$CANONICAL_BACKUP_DIR/.tmp-set-${BACKUP_ID}-XXXXXX")"
if ! chmod 0700 "$TMP_SET_DIR" 2>/dev/null; then
    echo "  [FATAL] Failed to enforce 0700 permissions on staging directory: $TMP_SET_DIR" >&2
    exit 10
fi

# Write active process lock / ownership metadata file inside staging directory
printf "pid=%d\nhostname=%s\nstarted_at=%s\nbackup_id=%s\nmode=%s\n" \
    "$$" \
    "$(hostname 2>/dev/null || echo 'localhost')" \
    "$TIMESTAMP_ISO" \
    "$BACKUP_ID" \
    "$BACKUP_MODE" > "$TMP_SET_DIR/.process_lock"
if ! chmod 0600 "$TMP_SET_DIR/.process_lock" 2>/dev/null; then
    echo "  [FATAL] Failed to enforce 0600 permissions on process lock file: $TMP_SET_DIR/.process_lock" >&2
    exit 10
fi

ARCHIVE_BASENAME="backup-${BACKUP_ID}.tar.gz"
TMP_ARCHIVE="$TMP_SET_DIR/$ARCHIVE_BASENAME"
TMP_SHA="$TMP_SET_DIR/${ARCHIVE_BASENAME}.sha256"
TMP_MANIFEST="$TMP_SET_DIR/${ARCHIVE_BASENAME}.manifest"

TEMP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lab-backup-XXXXXX")"
if ! chmod 0700 "$TEMP_STAGE" 2>/dev/null; then
    echo "  [FATAL] Failed to enforce 0700 permissions on temporary staging directory: $TEMP_STAGE" >&2
    exit 10
fi

# ------------------------------------------------------------------------------
# 5. Architecture Inventory Definitions
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

REQUIRED_VOLUMES=(
    lab_prometheus_data
    lab_grafana_data
    lab_alertmanager_data
    lab_loki_data
    lab_alloy_data
)

CONFIGS_STAGED=()
CONFIG_ERRORS=0
VOLUMES_ARCHIVED=()
VOLUMES_MISSING=()
VOLUMES_FAILED=()

declare -A VOLUME_VALIDATION_STATUS=()
declare -A VOLUME_EXISTS=()
declare -A VOLUME_ARCHIVE_VERIFIED=()
declare -A VOLUME_ARCHIVE_BYTES=()

for vol in "${REQUIRED_VOLUMES[@]}"; do
    VOLUME_EXISTS["$vol"]=false
    VOLUME_ARCHIVE_VERIFIED["$vol"]=false
    VOLUME_ARCHIVE_BYTES["$vol"]=0
    VOLUME_VALIDATION_STATUS["$vol"]="PENDING"
done

echo "======================================================================"
echo "  LINUX MONITORING LAB — SECURE BACKUP ORCHESTRATOR"
echo "  Mode:         $BACKUP_MODE"
echo "  Backup ID:    $BACKUP_ID"
echo "  Target Set:   $FINAL_BACKUP_SET"
echo "  Permissions:  Directory 0700 | Files 0600 (umask 077)"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 6. Step 1: Configuration Staging & Filename-Pattern-Based Secret Exclusion
# ------------------------------------------------------------------------------
echo ""
echo "[1/4] Staging Configuration Assets & Enforcing Pattern-Based Secret Exclusions..."
mkdir -p "$TEMP_STAGE/configs"

# 1. Pre-copy source validation: strictly reject missing or symlinked configuration directories
for dir in "${REQUIRED_CONFIG_DIRS[@]}"; do
    src_dir="$REPO_ROOT/$dir"
    if [[ ! -e "$src_dir" ]]; then
        echo "  [ERROR] Required configuration directory '$dir' is missing from repository root!" >&2
        CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
    elif [[ -L "$src_dir" ]]; then
        echo "  [ERROR] Required configuration directory '$dir' in repository is a symbolic link. Symlinked configuration directories are prohibited." >&2
        CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
    elif [[ ! -d "$src_dir" ]]; then
        echo "  [ERROR] Required configuration directory '$dir' exists but is not a directory!" >&2
        CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
    fi
done

if [[ "$CONFIG_ERRORS" -gt 0 ]]; then
    echo "  [FATAL] $CONFIG_ERRORS required configuration directory/directories missing or invalid. Aborting backup." >&2
    exit 14
fi

# 2. Stage real directories and approved files
for dir in "${REQUIRED_CONFIG_DIRS[@]}"; do
    cp -R -P "$REPO_ROOT/$dir" "$TEMP_STAGE/configs/"
done

for file in "${REQUIRED_ROOT_FILES[@]}"; do
    if [[ -f "$REPO_ROOT/$file" && ! -L "$REPO_ROOT/$file" ]]; then
        cp "$REPO_ROOT/$file" "$TEMP_STAGE/configs/"
    else
        echo "  [WARN] Root asset '$file' not found or is a symlink (skipping)." >&2
    fi
done

# Stage approved non-secret configuration template if present
if [[ -f "$REPO_ROOT/.env.example" && ! -L "$REPO_ROOT/.env.example" ]]; then
    cp "$REPO_ROOT/.env.example" "$TEMP_STAGE/configs/.env.example"
fi

# 3. Purge all internal and external symlinks from staged configuration assets
while IFS= read -r -d '' symlink_item; do
    echo "  [SECURITY] Purging symlink in staged configurations: $(basename "$symlink_item")"
    rm -f "$symlink_item"
done < <(find "$TEMP_STAGE/configs" -type l -print0)

# 4. Filename-pattern-based secret exclusion scan over staged assets
# Excludes files and directories matching known credential patterns (.env, *.key, *.pem, etc.)
# NOTE: Pattern matching is based strictly on filenames and directory names; content inspection
# is not performed to avoid risk of exposing secret values. Operators must ensure secrets are
# not committed within tracked non-credential filenames.
EXCLUDED_SECRETS_COUNT=0
while IFS= read -r -d '' secret_item; do
    # Protect explicitly approved template
    if [[ "$(basename "$secret_item")" == ".env.example" ]]; then
        continue
    fi
    echo "  [SECURITY] Excluding sensitive-pattern asset: $(basename "$secret_item")"
    rm -rf "$secret_item"
    EXCLUDED_SECRETS_COUNT=$((EXCLUDED_SECRETS_COUNT + 1))
done < <(find "$TEMP_STAGE/configs" -mindepth 1 \( \
    -name ".env" -o \
    -name ".env.*" -o \
    -name "*.env" -o \
    -name "*.key" -o \
    -name "*.pem" -o \
    -name "*.pkcs12" -o \
    -name "*.pfx" -o \
    -name "id_rsa*" -o \
    -name "id_ecdsa*" -o \
    -name "id_ed25519*" -o \
    -iname "*credential*" -o \
    -iname "*password*" -o \
    -name "*.kdbx" -o \
    -name "*.netrc" -o \
    -iname "*token*" -o \
    -name ".git" -o \
    -name ".ssh" -o \
    -name ".gnupg" -o \
    -name ".vault" \
\) -print0)

# 5. Post-filtering integrity verification: ensure every required directory remains a real directory
CONFIGS_STAGED=()
POST_FILTER_ERRORS=0
for dir in "${REQUIRED_CONFIG_DIRS[@]}"; do
    staged_target="$TEMP_STAGE/configs/$dir"
    if [[ ! -e "$staged_target" ]]; then
        echo "  [FATAL] Required configuration directory '$dir' is missing after filtering!" >&2
        POST_FILTER_ERRORS=$((POST_FILTER_ERRORS + 1))
    elif [[ -L "$staged_target" ]]; then
        echo "  [FATAL] Required configuration directory '$dir' in staged tree is a symbolic link!" >&2
        POST_FILTER_ERRORS=$((POST_FILTER_ERRORS + 1))
    elif [[ ! -d "$staged_target" ]]; then
        echo "  [FATAL] Required configuration directory '$dir' in staged tree is not a real directory!" >&2
        POST_FILTER_ERRORS=$((POST_FILTER_ERRORS + 1))
    else
        CONFIGS_STAGED+=("$dir/")
    fi
done

for file in "${REQUIRED_ROOT_FILES[@]}"; do
    if [[ -f "$TEMP_STAGE/configs/$file" && ! -L "$TEMP_STAGE/configs/$file" ]]; then
        CONFIGS_STAGED+=("$file")
    fi
done
if [[ -f "$TEMP_STAGE/configs/.env.example" && ! -L "$TEMP_STAGE/configs/.env.example" ]]; then
    CONFIGS_STAGED+=(".env.example (template)")
fi

if [[ "$POST_FILTER_ERRORS" -gt 0 ]]; then
    echo "  [FATAL] Post-filtering validation failed ($POST_FILTER_ERRORS required configuration directory/directories missing or invalid). Aborting." >&2
    exit 14
fi

printf "  [DONE] Staged %d verified configuration components (%d sensitive-pattern assets excluded).\n" \
    "${#CONFIGS_STAGED[@]}" "$EXCLUDED_SECRETS_COUNT"

# ------------------------------------------------------------------------------
# 7. Step 2: Docker Daemon Verification & Volume Error Classification
# ------------------------------------------------------------------------------
echo ""
echo "[2/4] Snapshotting Docker Named Volumes (Read-Only Container Mounts)..."
mkdir -p "$TEMP_STAGE/volumes"

# Establish Docker CLI availability
if ! command -v docker >/dev/null 2>&1; then
    echo "  [FATAL] Docker CLI ('docker') not found in PATH." >&2
    exit 3
fi

# Establish Docker daemon accessibility and permission model
DOCKER_DIAG=""
if ! DOCKER_DIAG=$(docker info 2>&1 >/dev/null); then
    if echo "$DOCKER_DIAG" | grep -qiE "permission denied|got permission denied while trying to connect to the docker daemon socket"; then
        echo "  [FATAL] Docker permission failure: current user lacks permission to access Docker daemon socket." >&2
        echo "          Ensure user is added to 'docker' group or has appropriate socket permissions." >&2
        exit 4
    elif echo "$DOCKER_DIAG" | grep -qiE "cannot connect|is the docker daemon running|daemon not running|dial unix"; then
        echo "  [FATAL] Docker daemon unavailable: cannot connect to Docker daemon." >&2
        echo "          Ensure Docker service is active ('systemctl status docker' or Docker Desktop)." >&2
        exit 5
    else
        echo "  [FATAL] Docker daemon communication error: $DOCKER_DIAG" >&2
        exit 6
    fi
fi

# Inspect and snapshot each required volume
for vol in "${REQUIRED_VOLUMES[@]}"; do
    INSPECT_OUT=""
    if ! INSPECT_OUT=$(docker volume inspect "$vol" 2>&1); then
        if echo "$INSPECT_OUT" | grep -qiE "no such volume|volume not found|error: no such volume"; then
            echo "  • [WARN] Required volume '$vol' is genuinely missing from Docker engine (skipping)." >&2
            VOLUMES_MISSING+=("$vol")
            VOLUME_VALIDATION_STATUS["$vol"]="MISSING_FROM_DAEMON"
        elif echo "$INSPECT_OUT" | grep -qiE "permission denied"; then
            echo "  • [FATAL] Permission denied inspecting volume '$vol'." >&2
            exit 4
        elif echo "$INSPECT_OUT" | grep -qiE "cannot connect|is the docker daemon running"; then
            echo "  • [FATAL] Lost connection to Docker daemon while inspecting volume '$vol'." >&2
            exit 5
        else
            echo "  • [ERROR] Volume inspection failure for '$vol': $INSPECT_OUT" >&2
            VOLUMES_FAILED+=("$vol")
            VOLUME_VALIDATION_STATUS["$vol"]="FAILED_INSPECTION"
        fi
        continue
    fi

    VOLUME_EXISTS["$vol"]=true
    echo "  • Archiving volume '$vol'..."
    SNAPSHOT_OUT=""
    if ! SNAPSHOT_OUT=$(docker run --rm \
        -v "${vol}:/volume:ro" \
        -v "$TEMP_STAGE/volumes:/backup" \
        alpine:3.19 tar -czf "/backup/${vol}.tar.gz" -C /volume . 2>&1); then
        echo "    [ERROR] Volume snapshot command failed for '$vol': $SNAPSHOT_OUT" >&2
        VOLUMES_FAILED+=("$vol")
        VOLUME_VALIDATION_STATUS["$vol"]="FAILED_SNAPSHOT_CMD"
        continue
    fi

    # Rigorous validation of the generated nested volume archive
    VOL_ARCHIVE="$TEMP_STAGE/volumes/${vol}.tar.gz"
    if [[ ! -f "$VOL_ARCHIVE" ]]; then
        echo "    [ERROR] Volume archive validation failed for '$vol': archive file does not exist." >&2
        VOLUMES_FAILED+=("$vol")
        VOLUME_VALIDATION_STATUS["$vol"]="FAILED_FILE_MISSING"
        continue
    fi

    if [[ ! -s "$VOL_ARCHIVE" ]]; then
        echo "    [ERROR] Volume archive validation failed for '$vol': archive file is empty (0 bytes)." >&2
        VOLUMES_FAILED+=("$vol")
        VOLUME_VALIDATION_STATUS["$vol"]="FAILED_EMPTY_ARCHIVE"
        continue
    fi

    if ! tar -tzf "$VOL_ARCHIVE" >/dev/null 2>&1; then
        echo "    [ERROR] Volume archive validation failed for '$vol': archive is corrupt or unreadable by tar." >&2
        VOLUMES_FAILED+=("$vol")
        VOLUME_VALIDATION_STATUS["$vol"]="FAILED_CORRUPT_ARCHIVE"
        continue
    fi

    if ! chmod 0600 "$VOL_ARCHIVE" 2>/dev/null; then
        echo "    [ERROR] Volume archive security validation failed for '$vol': unable to enforce 0600 permissions." >&2
        VOLUMES_FAILED+=("$vol")
        VOLUME_VALIDATION_STATUS["$vol"]="FAILED_PERMISSIONS"
        continue
    fi

    v_perm="$(stat -c "%a" "$VOL_ARCHIVE" 2>/dev/null || echo "")"
    if [[ "$v_perm" != "600" && "$v_perm" != "0600" ]]; then
        echo "    [ERROR] Volume archive security validation failed for '$vol': mode '$v_perm' is not 0600." >&2
        VOLUMES_FAILED+=("$vol")
        VOLUME_VALIDATION_STATUS["$vol"]="FAILED_PERMISSIONS"
        continue
    fi
    VOL_BYTES="$(stat -c "%s" "$VOL_ARCHIVE" 2>/dev/null || echo "0")"
    VOLUME_ARCHIVE_BYTES["$vol"]="$VOL_BYTES"
    VOLUME_ARCHIVE_VERIFIED["$vol"]=true
    VOLUME_VALIDATION_STATUS["$vol"]="PASSED"
    VOLUMES_ARCHIVED+=("$vol")
    echo "    [PASS] Volume archive validated successfully: $vol (${VOL_BYTES} bytes)"
done

# ------------------------------------------------------------------------------
# 8. Checkpoint Mode Gate & Policy Evaluation
# ------------------------------------------------------------------------------
# In checkpoint mode, 100% volume success is strictly mandatory.
# Any missing or failed volume MUST abort execution immediately before archive creation or publication.
if [[ "$BACKUP_MODE" == "checkpoint" ]]; then
    if [[ "${#VOLUMES_FAILED[@]}" -gt 0 ]]; then
        echo "  [FATAL] Migration checkpoint aborted: ${#VOLUMES_FAILED[@]} volume snapshot(s) failed: ${VOLUMES_FAILED[*]}" >&2
        echo "          Checkpoint mode requires 100% volume success. No backup set will be created or published." >&2
        exit 2
    elif [[ "${#VOLUMES_MISSING[@]}" -gt 0 ]]; then
        echo "  [FATAL] Migration checkpoint aborted: ${#VOLUMES_MISSING[@]} required volume(s) missing from Docker engine: ${VOLUMES_MISSING[*]}" >&2
        echo "          Checkpoint mode requires 100% volume availability. No backup set will be created or published." >&2
        exit 2
    fi
    BACKUP_STATUS="SUCCESS"
else
    # Routine mode allows partial backup when volumes are missing, but aborts on snapshot errors or complete failure
    if [[ "${#VOLUMES_ARCHIVED[@]}" -eq 0 && "${#CONFIGS_STAGED[@]}" -eq 0 ]]; then
        echo "  [FATAL] Routine backup aborted: all components failed (no configurations and no volumes archived)." >&2
        exit 2
    elif [[ "${#VOLUMES_FAILED[@]}" -gt 0 ]]; then
        echo "  [FATAL] Routine backup aborted: ${#VOLUMES_FAILED[@]} volume snapshot(s) failed: ${VOLUMES_FAILED[*]}" >&2
        exit 2
    elif [[ "${#VOLUMES_MISSING[@]}" -gt 0 ]]; then
        BACKUP_STATUS="PARTIAL_ROUTINE"
        echo "  [WARN] Routine backup proceeding in partial mode: ${#VOLUMES_MISSING[@]} volume(s) missing." >&2
    else
        BACKUP_STATUS="SUCCESS"
    fi
fi

# ------------------------------------------------------------------------------
# 9. Step 3: Archive Verification, Manifest Generation & Atomic Set Publication
# ------------------------------------------------------------------------------
echo ""
echo "[3/4] Compressing Unified Archive, Verifying Readability & Publishing Backup Set Atomically..."

# 1. Compress into archive inside the temporary set directory
tar -czf "$TMP_ARCHIVE" -C "$TEMP_STAGE" .
if ! chmod 0600 "$TMP_ARCHIVE" 2>/dev/null; then
    echo "  [FATAL] Failed to enforce 0600 permissions on archive: $TMP_ARCHIVE" >&2
    exit 13
fi
a_perm="$(stat -c "%a" "$TMP_ARCHIVE" 2>/dev/null || echo "")"
if [[ "$a_perm" != "600" && "$a_perm" != "0600" ]]; then
    echo "  [FATAL] Archive '$TMP_ARCHIVE' mode '$a_perm' is not 0600." >&2
    exit 13
fi

# 2. Verify archive readability before publishing
if ! tar -tzf "$TMP_ARCHIVE" >/dev/null 2>&1; then
    echo "  [FATAL] Integrity verification failed: generated archive is corrupt or unreadable." >&2
    exit 13
fi

# 3. Generate SHA-256 integrity checksum
(
    cd "$TMP_SET_DIR"
    sha256sum "$ARCHIVE_BASENAME" > "${ARCHIVE_BASENAME}.sha256"
)
if ! chmod 0600 "$TMP_SHA" 2>/dev/null; then
    echo "  [FATAL] Failed to enforce 0600 permissions on checksum file: $TMP_SHA" >&2
    exit 13
fi
s_perm="$(stat -c "%a" "$TMP_SHA" 2>/dev/null || echo "")"
if [[ "$s_perm" != "600" && "$s_perm" != "0600" ]]; then
    echo "  [FATAL] Checksum file '$TMP_SHA' mode '$s_perm' is not 0600." >&2
    exit 13
fi

# 4. Cryptographically verify generated checksum file
if ! (cd "$TMP_SET_DIR" && sha256sum -c "${ARCHIVE_BASENAME}.sha256" >/dev/null 2>&1); then
    echo "  [FATAL] Checksum verification failed for generated archive." >&2
    exit 13
fi

HASH_VAL=$(awk '{print $1}' "$TMP_SHA")
ARCHIVE_SIZE=$(du -h "$TMP_ARCHIVE" | cut -f1)
ARCHIVE_BYTES=$(stat -c "%s" "$TMP_ARCHIVE" 2>/dev/null || echo "0")

# 5. Generate structured recovery manifest (Schema v2.0.0) inside TMP_SET_DIR
{
    cat << EOF
manifest_schema_version:    "2.0.0"
backup_id:                  "$BACKUP_ID"
created_at_utc:             "$TIMESTAMP_ISO"
created_at_epoch:           $TIMESTAMP_EPOCH
backup_mode:                "$BACKUP_MODE"
backup_status:              "$BACKUP_STATUS"
consistency_classification: "LIVE FILE-LEVEL BACKUP — APPLICATION CONSISTENCY AND CRASH CONSISTENCY NOT GUARANTEED"
repository_root:            "$CANONICAL_REPO_ROOT"
backup_set_directory:       "$SET_BASENAME"
archive_filename:           "$ARCHIVE_BASENAME"
archive_sha256:             "$HASH_VAL"
archive_size_bytes:         $ARCHIVE_BYTES
archive_size_human:         "$ARCHIVE_SIZE"
permissions_directory:      "0700"
permissions_files:          "0600"
secret_exclusion_policy:    "filename_pattern_based (excludes matching .env, keys, certs, credentials; content scanning not performed)"
EOF

    echo "required_config_dirs:"
    for d in "${REQUIRED_CONFIG_DIRS[@]}"; do
        echo "  - \"$d\""
    done

    echo "required_volumes:"
    for v in "${REQUIRED_VOLUMES[@]}"; do
        echo "  - \"$v\""
    done

    echo "archived_volumes:"
    if [[ ${#VOLUMES_ARCHIVED[@]} -eq 0 ]]; then
        echo "  []"
    else
        for v in "${VOLUMES_ARCHIVED[@]}"; do
            echo "  - \"$v\""
        done
    fi

    echo "missing_volumes:"
    if [[ ${#VOLUMES_MISSING[@]} -eq 0 ]]; then
        echo "  []"
    else
        for v in "${VOLUMES_MISSING[@]}"; do
            echo "  - \"$v\""
        done
    fi

    echo "failed_volumes:"
    if [[ ${#VOLUMES_FAILED[@]} -eq 0 ]]; then
        echo "  []"
    else
        for v in "${VOLUMES_FAILED[@]}"; do
            echo "  - \"$v\""
        done
    fi

    echo "volume_validation_results:"
    for v in "${REQUIRED_VOLUMES[@]}"; do
        echo "  $v:"
        echo "    status: \"${VOLUME_VALIDATION_STATUS[$v]:-UNKNOWN}\""
        echo "    exists: ${VOLUME_EXISTS[$v]:-false}"
        echo "    archive_verified: ${VOLUME_ARCHIVE_VERIFIED[$v]:-false}"
        echo "    archive_bytes: ${VOLUME_ARCHIVE_BYTES[$v]:-0}"
    done

    cat << EOF

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
EOF
} > "$TMP_MANIFEST"
if ! chmod 0600 "$TMP_MANIFEST" 2>/dev/null; then
    echo "  [FATAL] Failed to enforce 0600 permissions on manifest file: $TMP_MANIFEST" >&2
    exit 13
fi
m_perm="$(stat -c "%a" "$TMP_MANIFEST" 2>/dev/null || echo "")"
if [[ "$m_perm" != "600" && "$m_perm" != "0600" ]]; then
    echo "  [FATAL] Manifest file '$TMP_MANIFEST' mode '$m_perm' is not 0600." >&2
    exit 13
fi

# 6. Genuine Atomic No-Replace Publication & Independent Verification
# Pre-publication collision check
if [[ -e "$FINAL_BACKUP_SET" || -L "$FINAL_BACKUP_SET" ]]; then
    echo "  [FATAL] Target backup set collision: '$FINAL_BACKUP_SET' already exists." >&2
    exit 15
fi

# Revalidate destination security immediately before publication
revalidate_destination_security "$CANONICAL_BACKUP_DIR" "pre-publication"

# Clean up temporary staging lockfile prior to publication rename
rm -f "$TMP_SET_DIR/.process_lock"

# Attempt atomic directory rename on the same filesystem
if ! mv -n -T "$TMP_SET_DIR" "$FINAL_BACKUP_SET" 2>/dev/null; then
    echo "  [FATAL] Atomic directory rename failed: unable to move '$TMP_SET_DIR' to '$FINAL_BACKUP_SET'." >&2
    exit 16
fi

# Post-move independent verification:
# Verify temporary staging directory is gone and final directory exists
if [[ -d "$TMP_SET_DIR" ]]; then
    echo "  [FATAL] Post-publication check failed: temporary staging directory '$TMP_SET_DIR' still exists." >&2
    exit 16
fi

if [[ ! -d "$FINAL_BACKUP_SET" || -L "$FINAL_BACKUP_SET" ]]; then
    echo "  [FATAL] Post-publication check failed: destination '$FINAL_BACKUP_SET' is not a valid directory." >&2
    exit 16
fi

# Verify all required artifacts exist and are non-empty regular files
if [[ ! -s "$FINAL_BACKUP_SET/$ARCHIVE_BASENAME" || \
      ! -s "$FINAL_BACKUP_SET/${ARCHIVE_BASENAME}.sha256" || \
      ! -s "$FINAL_BACKUP_SET/${ARCHIVE_BASENAME}.manifest" ]]; then
    echo "  [FATAL] Post-publication check failed: required backup artifacts missing or empty in '$FINAL_BACKUP_SET'." >&2
    exit 16
fi

# Independent cryptographic re-verification in published destination
if ! (cd "$FINAL_BACKUP_SET" && sha256sum -c "${ARCHIVE_BASENAME}.sha256" >/dev/null 2>&1); then
    echo "  [FATAL] Post-publication check failed: SHA-256 checksum verification failed in published location." >&2
    exit 16
fi

# Only after all independent verification checks pass, disarm cleanup for the published directory
TMP_SET_DIR=""

printf "  [DONE] Backup set published atomically: %s\n" "$FINAL_BACKUP_SET"
printf "  [DONE] Archive:  %s (%s, %s bytes)\n" "$ARCHIVE_BASENAME" "$ARCHIVE_SIZE" "$ARCHIVE_BYTES"
printf "  [DONE] SHA-256:  %s\n" "$HASH_VAL"
printf "  [DONE] Manifest: %s.manifest (Schema v2.0.0)\n" "$ARCHIVE_BASENAME"

# ------------------------------------------------------------------------------
# 10. Step 4: Strict Retention Enforcement on Completed Backup Sets
# ------------------------------------------------------------------------------
validate_retention_candidate() {
    local candidate_set="$1"
    local set_name="$2"
    local expected_id="$3"
    local expected_archive="$4"
    local expected_manifest="$5"
    local expected_sha="$6"

    # 1. Artifact existence and non-empty checks
    if [[ ! -f "$candidate_set/$expected_manifest" || ! -s "$candidate_set/$expected_manifest" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest '$expected_manifest' is missing or empty." >&2
        return 1
    fi
    if [[ ! -f "$candidate_set/$expected_archive" || ! -s "$candidate_set/$expected_archive" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': archive '$expected_archive' is missing or empty." >&2
        return 1
    fi
    if [[ ! -f "$candidate_set/$expected_sha" || ! -s "$candidate_set/$expected_sha" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': checksum '$expected_sha' is missing or empty." >&2
        return 1
    fi

    # 2. Extract actual SHA-256 value from the checksum sidecar
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
    sidecar_file="$(echo "$sidecar_file" | tr -d ' \t\r\n*')"
    if [[ -n "$sidecar_file" && "$sidecar_file" != "$expected_archive" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': sidecar '$expected_sha' references unexpected file '$sidecar_file' (expected '$expected_archive')." >&2
        return 1
    fi

    # 3. Obtain actual archive byte size using a reliable file-stat operation
    local actual_archive_bytes
    actual_archive_bytes="$(stat -c "%s" "$candidate_set/$expected_archive" 2>/dev/null || echo "")"
    if [[ -z "$actual_archive_bytes" || ! "$actual_archive_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "  [WARN] Skipping candidate '$set_name': unable to obtain valid archive byte size for '$expected_archive'." >&2
        return 1
    fi

    # 4. Strict line-by-line manifest parsing constrained to exact Schema 2.0.0 format
    # Rejects unsupported YAML constructs (anchors, aliases, inline maps/flows, custom tags)
    local -A SEEN_TOP_KEYS=()
    local -A MANIFEST_SCALARS=()
    local -a PARSED_REQ_CONFIGS=()
    local -a PARSED_REQ_VOLS=()
    local -a PARSED_ARCH_VOLS=()
    local -a PARSED_MISS_VOLS=()
    local -a PARSED_FAIL_VOLS=()
    local -A SEEN_VOL_RESULTS=()
    local -A V_PROP_STATUS=()
    local -A V_PROP_EXISTS=()
    local -A V_PROP_ARCHIVE_VERIFIED=()
    local -A V_PROP_ARCHIVE_BYTES=()
    local -A SEEN_V_PROPS=()
    local -A ARRAY_EXPLICIT_EMPTY=()

    local current_section=""
    local current_sub_vol=""
    local line_num=0
    local seen_notice_content=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        line="${line%$'\r'}"

        if [[ -z "${line// }" ]]; then
            continue
        fi

        # Reject unsupported YAML constructs outside consistency notice
        if [[ "$current_section" != "storage_consistency_notice" ]]; then
            local re_unsupported='[*&{}]'
            local re_yaml_tag='^[[:space:]]*!'
            if [[ "$line" =~ $re_unsupported ]] || [[ "$line" =~ $re_yaml_tag ]]; then
                echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num contains unsupported YAML construct (inline maps, anchors, aliases, or tags are prohibited)." >&2
                return 1
            fi
        fi

        # Check for top-level key: non-indented identifier followed by colon
        if [[ "$line" =~ ^([a-zA-Z0-9_]+):(.*)$ ]]; then
            local tkey="${BASH_REMATCH[1]}"
            local rest="${BASH_REMATCH[2]}"
            local tval
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
                    echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num contains unexpected top-level key '$tkey'." >&2
                    return 1
                    ;;
            esac

            if [[ -n "${SEEN_TOP_KEYS[$tkey]:-}" ]]; then
                echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num contains duplicate top-level key '$tkey'." >&2
                return 1
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
                        echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has malformed list header for '$tkey' ('$tval')." >&2
                        return 1
                    fi
                    ;;
                volume_validation_results|storage_consistency_notice)
                    ;;
            esac
            continue
        fi

        if [[ -z "$current_section" ]]; then
            echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num is an unexpected indented line outside any section." >&2
            return 1
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
                        echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has duplicate '[]' for '$current_section'." >&2
                        return 1
                    fi
                    case "$current_section" in
                        required_config_dirs)
                            if [[ ${#PARSED_REQ_CONFIGS[@]} -gt 0 ]]; then
                                echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has '[]' after items in required_config_dirs." >&2
                                return 1
                            fi
                            ;;
                        required_volumes)
                            if [[ ${#PARSED_REQ_VOLS[@]} -gt 0 ]]; then
                                echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has '[]' after items in required_volumes." >&2
                                return 1
                            fi
                            ;;
                        archived_volumes)
                            if [[ ${#PARSED_ARCH_VOLS[@]} -gt 0 ]]; then
                                echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has '[]' after items in archived_volumes." >&2
                                return 1
                            fi
                            ;;
                        missing_volumes)
                            if [[ ${#PARSED_MISS_VOLS[@]} -gt 0 ]]; then
                                echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has '[]' after items in missing_volumes." >&2
                                return 1
                            fi
                            ;;
                        failed_volumes)
                            if [[ ${#PARSED_FAIL_VOLS[@]} -gt 0 ]]; then
                                echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has '[]' after items in failed_volumes." >&2
                                return 1
                            fi
                            ;;
                    esac
                    ARRAY_EXPLICIT_EMPTY["$current_section"]=1
                    current_section=""
                    continue
                elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"?([^\"]+)\"?[[:space:]]*$ ]]; then
                    local item="${BASH_REMATCH[1]}"
                    case "$current_section" in
                        required_config_dirs)
                            if [[ ${#PARSED_REQ_CONFIGS[@]} -gt 0 ]]; then
                                for existing in "${PARSED_REQ_CONFIGS[@]}"; do
                                    if [[ "$existing" == "$item" ]]; then
                                        echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num contains duplicate directory '$item' in required_config_dirs." >&2
                                        return 1
                                    fi
                                done
                            fi
                            PARSED_REQ_CONFIGS+=("$item")
                            ;;
                        required_volumes)
                            if [[ ${#PARSED_REQ_VOLS[@]} -gt 0 ]]; then
                                for existing in "${PARSED_REQ_VOLS[@]}"; do
                                    if [[ "$existing" == "$item" ]]; then
                                        echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num contains duplicate volume '$item' in required_volumes." >&2
                                        return 1
                                    fi
                                done
                            fi
                            PARSED_REQ_VOLS+=("$item")
                            ;;
                        archived_volumes)
                            if [[ ${#PARSED_ARCH_VOLS[@]} -gt 0 ]]; then
                                for existing in "${PARSED_ARCH_VOLS[@]}"; do
                                    if [[ "$existing" == "$item" ]]; then
                                        echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num contains duplicate volume '$item' in archived_volumes." >&2
                                        return 1
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
                    echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num under '$current_section' has invalid list format." >&2
                    return 1
                fi
                ;;
            volume_validation_results)
                if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z0-9_]+):[[:space:]]*$ ]]; then
                    current_sub_vol="${BASH_REMATCH[1]}"
                    if [[ -n "${SEEN_VOL_RESULTS[$current_sub_vol]:-}" ]]; then
                        echo "  [WARN] Skipping candidate '$set_name': duplicate volume entry '$current_sub_vol' in volume_validation_results." >&2
                        return 1
                    fi
                    SEEN_VOL_RESULTS["$current_sub_vol"]=1
                elif [[ "$line" =~ ^[[:space:]]{4}([a-zA-Z0-9_]+):[[:space:]]*(.*)$ ]]; then
                    if [[ -z "$current_sub_vol" ]]; then
                        echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num has property without preceding volume." >&2
                        return 1
                    fi
                    local vprop="${BASH_REMATCH[1]}"
                    local vpval="${BASH_REMATCH[2]}"
                    vpval="$(echo "$vpval" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                    if [[ "$vpval" =~ ^\"(.*)\"$ ]]; then
                        vpval="${BASH_REMATCH[1]}"
                    fi

                    local prop_key="${current_sub_vol}:${vprop}"
                    if [[ -n "${SEEN_V_PROPS[$prop_key]:-}" ]]; then
                        echo "  [WARN] Skipping candidate '$set_name': duplicate property '$vprop' for volume '$current_sub_vol'." >&2
                        return 1
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
                            echo "  [WARN] Skipping candidate '$set_name': unexpected property '$vprop' in volume_validation_results." >&2
                            return 1
                            ;;
                    esac
                else
                    echo "  [WARN] Skipping candidate '$set_name': manifest line $line_num under volume_validation_results is malformed." >&2
                    return 1
                fi
                ;;
        esac
    done < "$candidate_set/$expected_manifest"

    # 5. Verify all mandatory top-level keys exist (all 23 mandatory keys in Schema 2.0.0)
    local MANDATORY_KEYS=(
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
            echo "  [WARN] Skipping candidate '$set_name': manifest missing mandatory key '$mkey'." >&2
            return 1
        fi
    done

    if [[ "$seen_notice_content" -ne 1 ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest storage_consistency_notice section is empty." >&2
        return 1
    fi

    # 6. Strict Schema Version Enforcement
    local m_schema="${MANIFEST_SCALARS[manifest_schema_version]:-}"
    if [[ "$m_schema" != "2.0.0" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': unsupported manifest schema version '$m_schema' (must be '2.0.0')." >&2
        return 1
    fi

    # 7. Strict Status Enforcement: Only validated SUCCESS backups are eligible for pruning
    local m_status="${MANIFEST_SCALARS[backup_status]:-}"
    if [[ "$m_status" != "SUCCESS" ]]; then
        echo "  [NOTICE] Preserving candidate '$set_name': backup_status is '$m_status' (only validated SUCCESS backups are eligible for pruning)." >&2
        return 1
    fi

    # 8. Identity & Directory Consistency
    local m_id="${MANIFEST_SCALARS[backup_id]:-}"
    if [[ ! "$m_id" =~ ^[0-9]{8}-[0-9]{6}Z-[0-9a-f]{16}$ || "$m_id" != "$expected_id" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest backup_id ('$m_id') is invalid or does not match expected id ('$expected_id')." >&2
        return 1
    fi
    local m_set_dir="${MANIFEST_SCALARS[backup_set_directory]:-}"
    if [[ "$m_set_dir" != "$set_name" || "$m_set_dir" != "backup-set-${expected_id}" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest backup_set_directory ('$m_set_dir') is invalid or does not match '$set_name'." >&2
        return 1
    fi
    local m_archive="${MANIFEST_SCALARS[archive_filename]:-}"
    if [[ "$m_archive" != "$expected_archive" || "$m_archive" != "backup-${expected_id}.tar.gz" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest archive_filename ('$m_archive') is invalid or does not match expected archive ('$expected_archive')." >&2
        return 1
    fi

    # 9. Consistency between Manifest, Sidecar Checksum, and Actual Archive
    local m_sha="${MANIFEST_SCALARS[archive_sha256]:-}"
    m_sha="${m_sha,,}"
    if [[ ! "$m_sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest archive_sha256 has invalid format ('$m_sha')." >&2
        return 1
    fi
    if [[ "$m_sha" != "$sidecar_sha" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest archive_sha256 ('$m_sha') does not match sidecar checksum ('$sidecar_sha')." >&2
        return 1
    fi

    local m_bytes="${MANIFEST_SCALARS[archive_size_bytes]:-}"
    if [[ ! "$m_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest archive_size_bytes has invalid format ('$m_bytes')." >&2
        return 1
    fi
    if [[ "$m_bytes" != "$actual_archive_bytes" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest archive_size_bytes ($m_bytes) does not match actual byte size ($actual_archive_bytes)." >&2
        return 1
    fi

    # 10. Additional Scalar Field Format Validations
    local m_utc="${MANIFEST_SCALARS[created_at_utc]:-}"
    if [[ ! "$m_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest created_at_utc has invalid ISO format ('$m_utc')." >&2
        return 1
    fi
    local m_epoch="${MANIFEST_SCALARS[created_at_epoch]:-}"
    if [[ ! "$m_epoch" =~ ^[1-9][0-9]*$ ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest created_at_epoch has invalid numeric format ('$m_epoch')." >&2
        return 1
    fi
    local m_mode="${MANIFEST_SCALARS[backup_mode]:-}"
    if [[ "$m_mode" != "checkpoint" && "$m_mode" != "routine" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest backup_mode is invalid ('$m_mode')." >&2
        return 1
    fi
    local m_class="${MANIFEST_SCALARS[consistency_classification]:-}"
    if [[ "$m_class" != "LIVE FILE-LEVEL BACKUP — APPLICATION CONSISTENCY AND CRASH CONSISTENCY NOT GUARANTEED" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest consistency_classification is unexpected." >&2
        return 1
    fi
    local m_repo="${MANIFEST_SCALARS[repository_root]:-}"
    if [[ ! "$m_repo" =~ ^/ ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest repository_root is not an absolute path ('$m_repo')." >&2
        return 1
    fi
    local m_pdir="${MANIFEST_SCALARS[permissions_directory]:-}"
    if [[ "$m_pdir" != "0700" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest permissions_directory is not 0700 ('$m_pdir')." >&2
        return 1
    fi
    local m_pfiles="${MANIFEST_SCALARS[permissions_files]:-}"
    if [[ "$m_pfiles" != "0600" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest permissions_files is not 0600 ('$m_pfiles')." >&2
        return 1
    fi
    local m_sec="${MANIFEST_SCALARS[secret_exclusion_policy]:-}"
    if [[ "$m_sec" != "filename_pattern_based (excludes matching .env, keys, certs, credentials; content scanning not performed)" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest secret_exclusion_policy is unexpected." >&2
        return 1
    fi
    local m_human="${MANIFEST_SCALARS[archive_size_human]:-}"
    if [[ -z "$m_human" || ! "$m_human" =~ ^[0-9]+(\.[0-9]+)?[A-Za-z]?$ ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest archive_size_human has invalid format ('$m_human')." >&2
        return 1
    fi
    local actual_du_h=""
    local actual_du_app=""
    actual_du_h="$(du -h "$candidate_set/$expected_archive" 2>/dev/null | cut -f1 | tr -d ' \t\r\n')"
    actual_du_app="$(du -h --apparent-size "$candidate_set/$expected_archive" 2>/dev/null | cut -f1 | tr -d ' \t\r\n')"
    if [[ -z "$actual_du_h" && -z "$actual_du_app" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': unable to obtain disk usage size for '$expected_archive'." >&2
        return 1
    fi
    if [[ "$m_human" != "$actual_du_h" && "$m_human" != "$actual_du_app" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': manifest archive_size_human ('$m_human') does not match actual archive size (disk: '$actual_du_h', apparent: '$actual_du_app')." >&2
        return 1
    fi

    # 11. Configuration Directory Array Validation
    if [[ ${#PARSED_REQ_CONFIGS[@]} -ne ${#REQUIRED_CONFIG_DIRS[@]} ]]; then
        echo "  [WARN] Skipping candidate '$set_name': required_config_dirs count (${#PARSED_REQ_CONFIGS[@]}) does not match expected (${#REQUIRED_CONFIG_DIRS[@]})." >&2
        return 1
    fi
    for req_d in "${REQUIRED_CONFIG_DIRS[@]}"; do
        local found=0
        for pd in "${PARSED_REQ_CONFIGS[@]}"; do
            if [[ "$pd" == "$req_d" ]]; then
                found=1
                break
            fi
        done
        if [[ "$found" -ne 1 ]]; then
            echo "  [WARN] Skipping candidate '$set_name': required_config_dirs missing expected directory '$req_d'." >&2
            return 1
        fi
    done

    # 12. Volume Arrays Validation: Exact sets and equality
    if [[ ${#PARSED_REQ_VOLS[@]} -ne ${#REQUIRED_VOLUMES[@]} ]]; then
        echo "  [WARN] Skipping candidate '$set_name': required_volumes count (${#PARSED_REQ_VOLS[@]}) does not match expected (${#REQUIRED_VOLUMES[@]})." >&2
        return 1
    fi
    for req_v in "${REQUIRED_VOLUMES[@]}"; do
        local found=0
        for pv in "${PARSED_REQ_VOLS[@]}"; do
            if [[ "$pv" == "$req_v" ]]; then
                found=1
                break
            fi
        done
        if [[ "$found" -ne 1 ]]; then
            echo "  [WARN] Skipping candidate '$set_name': required_volumes missing expected volume '$req_v'." >&2
            return 1
        fi
    done

    # In a SUCCESS backup, archived_volumes must exactly equal required_volumes
    if [[ ${#PARSED_ARCH_VOLS[@]} -ne ${#REQUIRED_VOLUMES[@]} ]]; then
        echo "  [WARN] Skipping candidate '$set_name': archived_volumes count (${#PARSED_ARCH_VOLS[@]}) does not match required (${#REQUIRED_VOLUMES[@]})." >&2
        return 1
    fi
    for req_v in "${REQUIRED_VOLUMES[@]}"; do
        local found=0
        for av in "${PARSED_ARCH_VOLS[@]}"; do
            if [[ "$av" == "$req_v" ]]; then
                found=1
                break
            fi
        done
        if [[ "$found" -ne 1 ]]; then
            echo "  [WARN] Skipping candidate '$set_name': archived_volumes does not contain required volume '$req_v'." >&2
            return 1
        fi
    done

    # Check missing_volumes and failed_volumes are strictly empty with explicit '[]' representation
    if [[ ${#PARSED_MISS_VOLS[@]} -ne 0 ]]; then
        echo "  [WARN] Skipping candidate '$set_name': missing_volumes is not empty (${#PARSED_MISS_VOLS[@]} missing volume(s))." >&2
        return 1
    fi
    if [[ -z "${ARRAY_EXPLICIT_EMPTY[missing_volumes]:-}" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': missing_volumes is empty but lacks explicit '[]' representation." >&2
        return 1
    fi

    if [[ ${#PARSED_FAIL_VOLS[@]} -ne 0 ]]; then
        echo "  [WARN] Skipping candidate '$set_name': failed_volumes is not empty (${#PARSED_FAIL_VOLS[@]} failed volume(s))." >&2
        return 1
    fi
    if [[ -z "${ARRAY_EXPLICIT_EMPTY[failed_volumes]:-}" ]]; then
        echo "  [WARN] Skipping candidate '$set_name': failed_volumes is empty but lacks explicit '[]' representation." >&2
        return 1
    fi

    # 13. Volume Validation Results: Exactly one entry per required volume with valid fields
    if [[ ${#SEEN_VOL_RESULTS[@]} -ne ${#REQUIRED_VOLUMES[@]} ]]; then
        echo "  [WARN] Skipping candidate '$set_name': volume_validation_results count (${#SEEN_VOL_RESULTS[@]}) does not match required (${#REQUIRED_VOLUMES[@]})." >&2
        return 1
    fi
    for req_v in "${REQUIRED_VOLUMES[@]}"; do
        if [[ -z "${SEEN_VOL_RESULTS[$req_v]:-}" ]]; then
            echo "  [WARN] Skipping candidate '$set_name': volume '$req_v' missing from volume_validation_results." >&2
            return 1
        fi
        local v_stat="${V_PROP_STATUS[$req_v]:-}"
        local v_exists="${V_PROP_EXISTS[$req_v]:-}"
        local v_ver="${V_PROP_ARCHIVE_VERIFIED[$req_v]:-}"
        local v_bytes="${V_PROP_ARCHIVE_BYTES[$req_v]:-}"

        if [[ "$v_stat" != "PASSED" ]]; then
            echo "  [WARN] Skipping candidate '$set_name': volume '$req_v' status is '$v_stat' (expected 'PASSED')." >&2
            return 1
        fi
        if [[ "$v_exists" != "true" ]]; then
            echo "  [WARN] Skipping candidate '$set_name': volume '$req_v' exists is '$v_exists' (expected 'true')." >&2
            return 1
        fi
        if [[ "$v_ver" != "true" ]]; then
            echo "  [WARN] Skipping candidate '$set_name': volume '$req_v' archive_verified is '$v_ver' (expected 'true')." >&2
            return 1
        fi
        if [[ ! "$v_bytes" =~ ^[1-9][0-9]*$ ]]; then
            echo "  [WARN] Skipping candidate '$set_name': volume '$req_v' archive_bytes is invalid ('$v_bytes')." >&2
            return 1
        fi
    done
    for v_seen in "${!SEEN_VOL_RESULTS[@]}"; do
        local is_req=0
        for req_v in "${REQUIRED_VOLUMES[@]}"; do
            if [[ "$req_v" == "$v_seen" ]]; then
                is_req=1
                break
            fi
        done
        if [[ "$is_req" -ne 1 ]]; then
            echo "  [WARN] Skipping candidate '$set_name': unexpected volume '$v_seen' in volume_validation_results." >&2
            return 1
        fi
    done

    # 14. Cryptographic Checksum Verification via sha256sum -c
    if ! (cd "$candidate_set" && sha256sum -c "$expected_sha" >/dev/null 2>&1); then
        echo "  [WARN] Skipping candidate '$set_name': SHA-256 checksum verification failed." >&2
        return 1
    fi

    # 15. Outer Archive Readability & Robust Table-of-Contents Inspection
    if ! tar -tzf "$candidate_set/$expected_archive" >/dev/null 2>&1; then
        echo "  [WARN] Skipping candidate '$set_name': outer archive '$expected_archive' is corrupt or unreadable." >&2
        return 1
    fi

    # Read detailed table of contents with escaped names to handle unusual filenames, newlines, and spaces safely
    local re_tar_entry='^([-dlhcbp?][rwxstST-]{9})[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}(:[0-9]{2})?)[[:space:]]+(.*)$'
    local re_symlink='^(.*)[[:space:]]->[[:space:]](.*)$'
    local re_hardlink='^(.*)[[:space:]]link[[:space:]]to[[:space:]](.*)$'

    local -a TOC_TYPES=()
    local -a TOC_PATHS=()
    local -a TOC_TARGETS=()
    local -a TOC_SIZES=()

    local toc_line
    while IFS= read -r toc_line || [[ -n "$toc_line" ]]; do
        if [[ -z "${toc_line// }" ]]; then
            continue
        fi
        if [[ "$toc_line" =~ $re_tar_entry ]]; then
            local mode="${BASH_REMATCH[1]}"
            local ftype="${mode:0:1}"
            local size="${BASH_REMATCH[3]}"
            local raw_path="${BASH_REMATCH[6]}"
            local path="$raw_path"
            local target=""

            if [[ "$ftype" == "l" && "$raw_path" =~ $re_symlink ]]; then
                path="${BASH_REMATCH[1]}"
                target="${BASH_REMATCH[2]}"
            elif [[ "$ftype" == "h" && "$raw_path" =~ $re_hardlink ]]; then
                path="${BASH_REMATCH[1]}"
                target="${BASH_REMATCH[2]}"
            fi

            # Check for path traversal or dangerous entries
            if [[ "$path" =~ (^|/)\.\.(/|$) || "$path" =~ ^/ ]]; then
                echo "  [WARN] Skipping candidate '$set_name': outer archive contains dangerous or absolute path ('$path')." >&2
                return 1
            fi

            TOC_TYPES+=("$ftype")
            TOC_PATHS+=("$path")
            TOC_TARGETS+=("$target")
            TOC_SIZES+=("$size")
        else
            echo "  [WARN] Skipping candidate '$set_name': outer archive table of contents contains unparseable or ambiguous entry line." >&2
            return 1
        fi
    done < <(tar -tvzf "$candidate_set/$expected_archive" --quoting-style=escape 2>/dev/null)

    if [[ ${#TOC_PATHS[@]} -eq 0 ]]; then
        echo "  [WARN] Skipping candidate '$set_name': outer archive '$expected_archive' produced empty table of contents." >&2
        return 1
    fi

    # 16. Required Configuration Archive Contents Verification
    # Verifies that every required configuration directory in the manifest is actually present
    # in the outer archive as an actual directory structure (genuine directory entry or valid descendants),
    # while rejecting regular files or symlinks named configs/<required-directory>.
    # No archive contents are extracted to disk, repo, or Docker volumes.
    for cfg_dir in "${REQUIRED_CONFIG_DIRS[@]}"; do
        local dir_entry_found=0
        local descendant_count=0

        local idx
        for ((idx=0; idx<${#TOC_PATHS[@]}; idx++)); do
            local p="${TOC_PATHS[$idx]}"
            local t="${TOC_TYPES[$idx]}"

            # Check for exact name without trailing slash
            if [[ "$p" =~ ^(\./)?configs/${cfg_dir}$ ]]; then
                if [[ "$t" != "d" ]]; then
                    echo "  [WARN] Skipping candidate '$set_name': archive entry 'configs/$cfg_dir' is not a directory (member type: '$t'). Regular files or special files for configuration directories are prohibited." >&2
                    return 1
                fi
                dir_entry_found=1
            # Check for directory entry with trailing slash
            elif [[ "$p" =~ ^(\./)?configs/${cfg_dir}/$ ]]; then
                if [[ "$t" != "d" ]]; then
                    echo "  [WARN] Skipping candidate '$set_name': archive entry 'configs/$cfg_dir/' is not marked as directory (member type: '$t')." >&2
                    return 1
                fi
                dir_entry_found=1
            # Check for descendants inside the directory
            elif [[ "$p" =~ ^(\./)?configs/${cfg_dir}/.+ ]]; then
                descendant_count=$((descendant_count + 1))
            fi
        done

        if [[ "$dir_entry_found" -eq 0 && "$descendant_count" -eq 0 ]]; then
            echo "  [WARN] Skipping candidate '$set_name': required configuration directory '$cfg_dir' has no directory structure or descendants in outer archive." >&2
            return 1
        fi
    done

    # 17. Nested Volume Archive Member Type, Integrity, Size, Count, and Readability
    # For every required volume:
    # - Requires exactly one matching outer archive member
    # - Verifies that the member is a regular file, not a symlink, hardlink, directory, or special entry
    # - Verifies nonzero streamed size against manifest volume_validation_results.<vol>.archive_bytes
    # - Verifies nested tar readability
    # - Preserves set -Eeuo pipefail behavior
    # - Rejects malformed or ambiguous member paths
    # - Does not extract to existing Docker volumes
    for vol in "${REQUIRED_VOLUMES[@]}"; do
        local vol_match_count=0
        local vol_entry_path=""
        local vol_entry_type=""
        local vol_entry_target=""

        local idx
        for ((idx=0; idx<${#TOC_PATHS[@]}; idx++)); do
            local p="${TOC_PATHS[$idx]}"
            local t="${TOC_TYPES[$idx]}"
            local tgt="${TOC_TARGETS[$idx]}"

            # Check for matching volume archive
            # Strict match: must be (^|\./)volumes/<vol>.tar.gz exactly
            if [[ "$p" =~ ^(\./)?volumes/${vol}\.tar\.gz$ ]]; then
                vol_match_count=$((vol_match_count + 1))
                vol_entry_path="$p"
                vol_entry_type="$t"
                vol_entry_target="$tgt"
            # Reject ambiguous or malformed paths starting with this prefix
            elif [[ "$p" =~ ^(\./)?volumes/${vol}\.tar\.gz/ ]] || [[ "$p" =~ ^(\./)?volumes/${vol}\.tar\.gz\..+ ]]; then
                echo "  [WARN] Skipping candidate '$set_name': outer archive contains ambiguous or malformed path for volume '$vol' ('$p')." >&2
                return 1
            fi
        done

        if [[ "$vol_match_count" -eq 0 ]]; then
            echo "  [WARN] Skipping candidate '$set_name': nested volume archive for '$vol' is missing from outer archive." >&2
            return 1
        elif [[ "$vol_match_count" -gt 1 ]]; then
            echo "  [WARN] Skipping candidate '$set_name': outer archive contains duplicate ($vol_match_count) entries for volume '$vol'." >&2
            return 1
        fi

        # Verify that the member is a regular file, not a symlink, hard link, directory, or special entry
        if [[ "$vol_entry_type" != "-" ]]; then
            case "$vol_entry_type" in
                l)
                    echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a symbolic link (target: '$vol_entry_target'). Volume archives must be regular files." >&2
                    ;;
                h)
                    echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a hard link (target: '$vol_entry_target'). Volume archives must be regular files." >&2
                    ;;
                d)
                    echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a directory. Volume archives must be regular files." >&2
                    ;;
                *)
                    echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a special entry (type '$vol_entry_type'). Volume archives must be regular files." >&2
                    ;;
            esac
            return 1
        fi

        # Obtain actual byte size via streaming to wc -c (preserves pipefail)
        local actual_vol_bytes=""
        if ! actual_vol_bytes="$(tar -xzf "$candidate_set/$expected_archive" -O "$vol_entry_path" 2>/dev/null | wc -c)"; then
            echo "  [WARN] Skipping candidate '$set_name': streaming nested volume archive for '$vol' failed." >&2
            return 1
        fi
        actual_vol_bytes="$(echo "$actual_vol_bytes" | tr -d ' \t\r\n')"

        if [[ ! "$actual_vol_bytes" =~ ^[1-9][0-9]*$ ]]; then
            echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is empty or invalid size ('$actual_vol_bytes')." >&2
            return 1
        fi

        local expected_vol_bytes="${V_PROP_ARCHIVE_BYTES[$vol]:-}"
        if [[ "$actual_vol_bytes" != "$expected_vol_bytes" ]]; then
            echo "  [WARN] Skipping candidate '$set_name': nested archive size for '$vol' ($actual_vol_bytes bytes) does not match manifest ($expected_vol_bytes bytes)." >&2
            return 1
        fi

        # Verify nested archive readability (preserves pipefail)
        if ! tar -xzf "$candidate_set/$expected_archive" -O "$vol_entry_path" 2>/dev/null | tar -tzf - >/dev/null 2>&1; then
            echo "  [WARN] Skipping candidate '$set_name': nested volume archive for '$vol' is corrupt, truncated, or unreadable." >&2
            return 1
        fi
    done

    return 0
}

echo ""
echo "[4/4] Evaluating Backup Retention (Retention Window: ${RETENTION_DAYS} days)..."

RETENTION_ERROR=0
if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$RETENTION_DAYS" -lt 1 ]]; then
    echo "  [WARN] Invalid RETENTION_DAYS='$RETENTION_DAYS'. Skipping automated retention pruning." >&2
    RETENTION_ERROR=1
else
    PRUNED_COUNT=0
    # Search strictly for completed backup set directories matching exact pattern
    # Never follow symlinks (-P) and explicitly preserve the newly created backup set
    while IFS= read -r -d '' old_set; do
        if [[ "$old_set" == "$FINAL_BACKUP_SET" ]]; then
            continue
        fi
        if [[ -d "$old_set" && ! -L "$old_set" ]]; then
            set_name="$(basename "$old_set")"
            expected_id="${set_name#backup-set-}"
            expected_archive="backup-${expected_id}.tar.gz"
            expected_manifest="${expected_archive}.manifest"
            expected_sha="${expected_archive}.sha256"

            if ! validate_retention_candidate "$old_set" "$set_name" "$expected_id" "$expected_archive" "$expected_manifest" "$expected_sha"; then
                continue
            fi

            # All checks passed: execute deletion
            if rm -rf "$old_set"; then
                PRUNED_COUNT=$((PRUNED_COUNT + 1))
                echo "  [PRUNED] Verified expired backup set pruned: $set_name"
            else
                echo "  [ERROR] Failed to prune validated expired backup set: $old_set" >&2
                RETENTION_ERROR=1
            fi
        fi
    done < <(find -P "$CANONICAL_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
        -name "backup-set-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]Z-*" \
        -mtime +"$RETENTION_DAYS" -print0)

    # Inspect temporary staging directories safely without automated age-based deletion
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

    if [[ "$RETENTION_ERROR" -eq 0 ]]; then
        printf "  [DONE] Retention enforcement complete (%d expired backup set(s) pruned).\n" "$PRUNED_COUNT"
    else
        echo "  [ERROR] Retention enforcement encountered errors during pruning." >&2
    fi
fi

# ------------------------------------------------------------------------------
# 11. Final Status Determination and Execution Summary
# ------------------------------------------------------------------------------
# Explicitly invoke cleanup before printing the summary so a successful backup
# is never reported if cleanup failed.
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
    if [[ "$RETENTION_ERROR" -ne 0 ]]; then
        echo "  Notice:      Backup set published successfully, but retention pruning encountered errors."
        echo "  Exit Code:   8 (ERR_RETENTION_FAILURE)"
        echo "======================================================================"
        exit 8
    else
        echo "  Exit Code:   0 (SUCCESS)"
        echo "======================================================================"
        exit 0
    fi
elif [[ "$BACKUP_STATUS" == PARTIAL_ROUTINE* ]]; then
    if [[ "$RETENTION_ERROR" -ne 0 ]]; then
        echo "  Notice:      Routine partial backup published, but retention pruning encountered errors."
        echo "  Exit Code:   8 (ERR_RETENTION_FAILURE)"
        echo "======================================================================"
        exit 8
    else
        echo "  Notice:      Routine backup completed with missing volume warnings."
        echo "  Exit Code:   1 (PARTIAL_ROUTINE)"
        echo "======================================================================"
        exit 1
    fi
else
    echo "  Notice:      Backup operation failed."
    echo "  Exit Code:   2 (FAILED)"
    echo "======================================================================"
    exit 2
fi
