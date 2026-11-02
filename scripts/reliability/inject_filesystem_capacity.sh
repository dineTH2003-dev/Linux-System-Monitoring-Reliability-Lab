#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 3: Controlled Filesystem Capacity Warning Simulation
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

TEST_MOUNT="${1:-/tmp/lab_test_mount}"
PRESERVE="${2:-0}"
IMG_FILE="/tmp/lab_test_fs.img"
PAYLOAD_FILE="${TEST_MOUNT}/test_fill_payload.dat"

# Strict Safety Assertions
assert_not_root_mount "${TEST_MOUNT}"

cleanup() {
    if [[ "$PRESERVE" -eq 1 ]]; then
        log_info "Preserving test payload for automated remediation testing."
        return
    fi
    log_info "Cleaning up temporary filesystem capacity test artifacts..."
    rm -f "${PAYLOAD_FILE}" "${IMG_FILE}"
    if mountpoint -q "${TEST_MOUNT}" 2>/dev/null; then
        umount "${TEST_MOUNT}" 2>/dev/null || true
    fi
    rm -rf "${TEST_MOUNT}"
    log_pass "Filesystem capacity artifacts purged. Zero residual storage."
    log_audit "filesystem_capacity" "CLEANUP" "Removed ${IMG_FILE} and ${TEST_MOUNT}"
}

trap cleanup INT TERM

main() {
    log_info "Initializing disposable filesystem capacity test on '${TEST_MOUNT}'..."
    log_audit "filesystem_capacity" "START" "Target mount: ${TEST_MOUNT}"

    mkdir -p "${TEST_MOUNT}"

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario3_t_inject.txt

    # Create bounded 50MB image file
    log_info "Allocating 50MB disposable test image..."
    dd if=/dev/zero of="${IMG_FILE}" bs=1M count=50 status=none

    # If running with mount privileges, mount as ext4 loopback
    if command -v mkfs.ext4 >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        mkfs.ext4 -q -F "${IMG_FILE}" >/dev/null 2>&1
        sudo mount -o loop "${IMG_FILE}" "${TEST_MOUNT}"
        sudo chown -R "$(id -u):$(id -g)" "${TEST_MOUNT}"
        # Fill 45MB of 50MB (90% capacity, leaving 10% available, breaching the 15% warning threshold)
        log_info "Writing 45MB payload to cross 85% capacity threshold (<15% available)..."
        dd if=/dev/zero of="${PAYLOAD_FILE}" bs=1M count=45 status=none
    else
        # Non-root fallback: generate payload directly in isolated test directory
        log_info "Generating bounded 45MB test payload in sandbox directory '${TEST_MOUNT}'..."
        dd if=/dev/zero of="${PAYLOAD_FILE}" bs=1M count=45 status=none
    fi

    local avail_ratio
    avail_ratio="$(python3 -c '
import os, sys
path = sys.argv[1]
try:
    st = os.statvfs(path)
    free = st.f_bavail * st.f_frsize
    total = st.f_blocks * st.f_frsize
    print(f"{(free/total)*100:.2f}%")
except Exception as e:
    print("UNKNOWN")
' "${TEST_MOUNT}")"

    log_pass "Injected filesystem capacity condition: Payload generated at ${PAYLOAD_FILE} (Capacity: ${avail_ratio})"
    log_audit "filesystem_capacity" "INJECTED" "Payload at ${PAYLOAD_FILE}"

    if [[ "$PRESERVE" -eq 0 ]]; then
        sleep 5
        cleanup
    fi
}

main "$@"
