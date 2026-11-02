#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 6: Controlled Network Canary Endpoint Failure
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

CANARY_PORT="${1:-8088}"
PID_FILE="/tmp/lab_canary_${CANARY_PORT}.pid"

main() {
    log_info "Injecting controlled network endpoint failure on port ${CANARY_PORT}..."
    log_audit "network_endpoint_failure" "START" "Target port: ${CANARY_PORT}"

    # Ensure canary endpoint was running first
    if ! curl -s -m 1 "http://127.0.0.1:${CANARY_PORT}" >/dev/null 2>&1; then
        log_info "Launching baseline canary server on port ${CANARY_PORT}..."
        python3 -m http.server "${CANARY_PORT}" --bind 127.0.0.1 >/dev/null 2>&1 &
        echo $! > "${PID_FILE}"
        sleep 1
    fi

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario6_t_inject.txt

    # Inject failure: Terminate the canary endpoint process
    log_warn "Injecting failure: Terminating canary endpoint on port ${CANARY_PORT}..."
    if [[ -f "${PID_FILE}" ]]; then
        local target_pid
        target_pid="$(cat "${PID_FILE}")"
        if kill -0 "$target_pid" 2>/dev/null; then
            kill -KILL "$target_pid" 2>/dev/null || true
        fi
        rm -f "${PID_FILE}"
    fi

    # Also check if any other process is bound to port
    fuser -k -n tcp "${CANARY_PORT}" 2>/dev/null || true

    # Verify failure condition
    if ! curl -s -m 1 "http://127.0.0.1:${CANARY_PORT}" >/dev/null 2>&1; then
        log_pass "Network endpoint failure injected successfully. Port ${CANARY_PORT} is unreachable (Connection Refused)."
        log_audit "network_endpoint_failure" "INJECTED" "Port ${CANARY_PORT} terminated"
        exit 0
    else
        log_fail "Failed to inject endpoint failure; port ${CANARY_PORT} is still responding."
        exit 1
    fi
}

main "$@"
