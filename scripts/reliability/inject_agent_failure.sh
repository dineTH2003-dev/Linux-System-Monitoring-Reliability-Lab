#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 7: Controlled Custom Monitoring Agent Failure
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

PID_FILE="/tmp/lab_agent.pid"
AGENT_PORT="9101"

main() {
    log_info "Injecting controlled monitoring agent failure (Port :${AGENT_PORT})..."
    log_audit "agent_failure" "START" "Target: Python Agent on port ${AGENT_PORT}"

    # Verify agent was running before injection; if not, launch it first so failure is real
    if ! curl -s -m 1 "http://127.0.0.1:${AGENT_PORT}/healthz" >/dev/null 2>&1; then
        log_info "Agent not running; starting agent first to establish baseline..."
        bash "${REPO_ROOT}/scripts/reliability/remediation/remediate_agent.sh" >/dev/null 2>&1
        sleep 1
    fi

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario7_t_inject.txt

    # Inject failure: send SIGTERM to agent PID
    local terminated=0
    if [[ -f "${PID_FILE}" ]]; then
        local agent_pid
        agent_pid="$(cat "${PID_FILE}")"
        if kill -0 "$agent_pid" 2>/dev/null; then
            log_warn "Sending SIGTERM to Agent (PID: $agent_pid)..."
            kill -TERM "$agent_pid"
            terminated=1
        fi
        rm -f "${PID_FILE}"
    fi

    # Fallback to pkill specifically for agent.main if PID file was missing
    if [[ "$terminated" -eq 0 ]]; then
        pkill -f "agent\.main" || true
    fi

    sleep 1

    # Verify agent is down
    if ! curl -s -m 1 "http://127.0.0.1:${AGENT_PORT}/healthz" >/dev/null 2>&1; then
        log_pass "Monitoring agent failure injected successfully. Agent (:9101) is down."
        log_audit "agent_failure" "INJECTED" "Agent (:9101) stopped successfully"
        exit 0
    else
        log_fail "Failed to stop monitoring agent; port ${AGENT_PORT} is still responding."
        exit 1
    fi
}

main "$@"
