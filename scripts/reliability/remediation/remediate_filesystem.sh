#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Safe Automated Remediation: Filesystem Capacity Warning
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

TEST_MOUNT="${1:-/tmp/lab_test_mount}"
PAYLOAD_NAME="test_fill_payload.dat"
TARGET_PAYLOAD="${TEST_MOUNT}/${PAYLOAD_NAME}"

# Strict Safety Boundary Check
assert_not_root_mount "${TEST_MOUNT}"

main() {
    log_info "Initiating safe storage remediation on '${TEST_MOUNT}'..."

    # Precondition: Never use recursive delete. Target only known test payload.
    if [[ ! -f "${TARGET_PAYLOAD}" ]]; then
        log_pass "Test payload file '${TARGET_PAYLOAD}' is not present. Mount is clean (idempotent)."
        log_audit "storage_remediation" "ALREADY_CLEAN" "No payload found at ${TARGET_PAYLOAD}"
        exit 0
    fi

    log_audit "storage_remediation" "START" "Removing bounded payload file ${TARGET_PAYLOAD}"

    # Safe removal of specific known test file
    rm -f "${TARGET_PAYLOAD}"

    # Post-Remediation Verification
    if [[ ! -f "${TARGET_PAYLOAD}" ]]; then
        log_pass "Remediation verified: Bounded payload '${PAYLOAD_NAME}' safely removed."
        log_audit "storage_remediation" "SUCCESS" "Payload removed, capacity restored"
        exit 0
    else
        log_fail "Remediation failed: Payload file still exists."
        log_audit "storage_remediation" "FAILED" "Failed removing ${TARGET_PAYLOAD}"
        exit 1
    fi
}

main "$@"
