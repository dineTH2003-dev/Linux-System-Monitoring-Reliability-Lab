#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Safe Automated Remediation: Custom Python Monitoring Agent
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

PID_FILE="/tmp/lab_agent.pid"
AGENT_PORT="9101"
AGENT_HEALTH_URL="http://127.0.0.1:${AGENT_PORT}/healthz"

check_health() {
    if curl -s -f -m 2 "${AGENT_HEALTH_URL}" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

main() {
    log_info "Initiating remediation for Python Monitoring Agent (:9101)..."

    # 1. Precondition / Idempotency Check
    if check_health; then
        log_pass "Agent is already healthy at ${AGENT_HEALTH_URL}. No remediation needed."
        log_audit "agent_remediation" "ALREADY_HEALTHY" "Port 9101 responding with 200 OK"
        exit 0
    fi

    log_audit "agent_remediation" "START" "Service down, initiating graceful restart"

    # 2. Safe cleanup of stale process if hung
    if [[ -f "${PID_FILE}" ]]; then
        local old_pid
        old_pid="$(cat "${PID_FILE}")"
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log_warn "Stopping stale agent process (PID: $old_pid)..."
            kill -TERM "$old_pid" 2>/dev/null || true
            sleep 1
            if kill -0 "$old_pid" 2>/dev/null; then
                kill -KILL "$old_pid" 2>/dev/null || true
            fi
        fi
        rm -f "${PID_FILE}"
    fi
    pkill -f "agent\.main" 2>/dev/null || true
    fuser -k -n tcp "${AGENT_PORT}" 2>/dev/null || true
    sleep 1

    # 3. Launch Agent within Project Virtual Environment
    local python_bin="${REPO_ROOT}/.venv/bin/python3"
    if [[ ! -x "$python_bin" ]]; then
        python_bin="python3"
    fi

    log_info "Starting agent via ${python_bin} -m agent.main..."
    cd "${REPO_ROOT}"
    nohup "${python_bin}" -m agent.main --host 127.0.0.1 --port "${AGENT_PORT}" --log-level INFO > /tmp/lab_agent.log 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "${PID_FILE}"

    # 4. Post-Remediation Verification
    local verified=0
    for _ in $(seq 1 10); do
        sleep 0.5
        if check_health; then
            verified=1
            break
        fi
    done

    if [[ "$verified" -eq 1 ]]; then
        log_pass "Remediation verified: Agent running at PID ${new_pid}, responding at ${AGENT_HEALTH_URL}"
        log_audit "agent_remediation" "SUCCESS" "Agent recovered at PID ${new_pid}"
        exit 0
    else
        log_fail "Remediation verification failed: Agent did not respond on ${AGENT_HEALTH_URL} within timeout."
        log_audit "agent_remediation" "FAILED" "Agent health check failed post-launch"
        exit 1
    fi
}

main "$@"
