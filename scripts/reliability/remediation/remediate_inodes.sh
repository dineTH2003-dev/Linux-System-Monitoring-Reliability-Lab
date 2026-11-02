#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Safe Automated Remediation: Inode Exhaustion
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

TEST_MOUNT="${1:-/tmp/lab_test_inode_mount}"

# Strict Safety Boundary Check
assert_not_root_mount "${TEST_MOUNT}"

main() {
    log_info "Initiating safe inode remediation on '${TEST_MOUNT}'..."

    # Check for test inode files
    local match_count
    match_count="$(find "${TEST_MOUNT}" -maxdepth 1 -name "test_inode_*.dat" 2>/dev/null | wc -l || echo 0)"

    if [[ "$match_count" -eq 0 ]]; then
        log_pass "Zero test inode files found in '${TEST_MOUNT}'. Idempotent no-op."
        log_audit "inode_remediation" "ALREADY_CLEAN" "No inode test files found"
        exit 0
    fi

    log_audit "inode_remediation" "START" "Safely removing $match_count test inode files"

    # Targeted deletion of simulation-created files only
    find "${TEST_MOUNT}" -maxdepth 1 -name "test_inode_*.dat" -delete

    # Post-Remediation Verification
    local remaining
    remaining="$(find "${TEST_MOUNT}" -maxdepth 1 -name "test_inode_*.dat" 2>/dev/null | wc -l || echo 0)"

    if [[ "$remaining" -eq 0 ]]; then
        log_pass "Remediation verified: All $match_count test inode files purged. Inodes restored."
        log_audit "inode_remediation" "SUCCESS" "Purged $match_count test inode files"
        exit 0
    else
        log_fail "Remediation failed: $remaining test files still remain."
        log_audit "inode_remediation" "FAILED" "$remaining files failed deletion"
        exit 1
    fi
}

main "$@"
