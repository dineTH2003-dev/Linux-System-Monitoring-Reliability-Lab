#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Safe Automated Remediation: systemd Canary Service
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

UNIT_NAME="${1:-lab-test-canary.service}"
WHITELIST=("lab-test-canary.service" "lab-canary-user.service")

# Safety Assertion: Ensure unit is strictly whitelisted
assert_whitelisted "$UNIT_NAME" "${WHITELIST[@]}"

USE_USER_MODE=0
if systemctl --user status "$UNIT_NAME" >/dev/null 2>&1 || [[ "$UNIT_NAME" == *"user"* ]]; then
    USE_USER_MODE=1
fi

check_active() {
    if [[ "$USE_USER_MODE" -eq 1 ]]; then
        systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1
    else
        systemctl is-active "$UNIT_NAME" >/dev/null 2>&1
    fi
}

main() {
    log_info "Initiating remediation for systemd unit '$UNIT_NAME'..."

    # 1. Precondition / Idempotency Check
    if check_active; then
        log_pass "Unit '$UNIT_NAME' is already active. Idempotent no-op."
        log_audit "systemd_remediation" "ALREADY_ACTIVE" "Unit $UNIT_NAME already running"
        exit 0
    fi

    log_audit "systemd_remediation" "START" "Resetting and restarting failed unit $UNIT_NAME"

    # 2. Reset Failed State & Restart
    if [[ "$USE_USER_MODE" -eq 1 ]]; then
        systemctl --user reset-failed "$UNIT_NAME" || true
        systemctl --user restart "$UNIT_NAME"
    else
        systemctl reset-failed "$UNIT_NAME" || true
        systemctl restart "$UNIT_NAME"
    fi

    # 3. Post-Remediation Verification
    sleep 1
    if check_active; then
        log_pass "Remediation verified: Unit '$UNIT_NAME' successfully restored to active state."
        log_audit "systemd_remediation" "SUCCESS" "Unit $UNIT_NAME restored to active"
        exit 0
    else
        log_fail "Remediation failed: Unit '$UNIT_NAME' failed to enter active state."
        log_audit "systemd_remediation" "FAILED" "Unit $UNIT_NAME still inactive/failed"
        exit 1
    fi
}

main "$@"
