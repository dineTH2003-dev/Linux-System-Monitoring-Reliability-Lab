#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 4: Controlled Inode Pressure in Disposable Test Filesystem
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

TEST_MOUNT="${1:-/tmp/lab_test_inode_mount}"
COUNT="${2:-500}"
PRESERVE="${3:-0}"
IMG_FILE="/tmp/lab_test_inode.img"

# Strict Safety Assertions
assert_not_root_mount "${TEST_MOUNT}"

cleanup() {
    if [[ "$PRESERVE" -eq 1 ]]; then
        log_info "Preserving test inode files for automated remediation testing."
        return
    fi
    log_info "Cleaning up temporary inode test artifacts..."
    find "${TEST_MOUNT}" -maxdepth 1 -name "test_inode_*.dat" -delete 2>/dev/null || true
    if mountpoint -q "${TEST_MOUNT}" 2>/dev/null; then
        umount "${TEST_MOUNT}" 2>/dev/null || true
    fi
    rm -f "${IMG_FILE}"
    rm -rf "${TEST_MOUNT}"
    log_pass "Inode test artifacts purged. Zero residual files."
    log_audit "inode_pressure" "CLEANUP" "Purged test files in ${TEST_MOUNT}"
}

trap cleanup INT TERM

main() {
    log_info "Initializing disposable inode pressure test on '${TEST_MOUNT}' (Count: $COUNT)..."
    log_audit "inode_pressure" "START" "Target: ${TEST_MOUNT}, File Count: $COUNT"

    mkdir -p "${TEST_MOUNT}"

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario4_t_inject.txt

    # If running with mount privileges, format ext4 with strict inode ceiling (-N 600)
    if command -v mkfs.ext4 >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        dd if=/dev/zero of="${IMG_FILE}" bs=1M count=20 status=none
        mkfs.ext4 -q -F -N 600 "${IMG_FILE}" >/dev/null 2>&1
        sudo mount -o loop "${IMG_FILE}" "${TEST_MOUNT}"
        sudo chown -R "$(id -u):$(id -g)" "${TEST_MOUNT}"
    fi

    log_info "Generating $COUNT zero-byte test inode files in '${TEST_MOUNT}'..."
    for i in $(seq 1 "$COUNT"); do
        touch "${TEST_MOUNT}/test_inode_${i}.dat"
    done

    local inode_info
    inode_info="$(python3 -c '
import os, sys
path = sys.argv[1]
try:
    st = os.statvfs(path)
    free = st.f_favail
    total = st.f_files
    print(f"Total: {total}, Free: {free}, Used: {total - free}")
except Exception as e:
    print("UNKNOWN")
' "${TEST_MOUNT}")"

    log_pass "Injected inode pressure: Created $COUNT files in ${TEST_MOUNT} ($inode_info)"
    log_audit "inode_pressure" "INJECTED" "Created $COUNT files in ${TEST_MOUNT}"

    if [[ "$PRESERVE" -eq 0 ]]; then
        sleep 5
        cleanup
    fi
}

main "$@"
