#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Safe Automated Remediation: Network Canary Endpoint
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

CANARY_PORT="${1:-8088}"
CANARY_URL="http://127.0.0.1:${CANARY_PORT}"
PID_FILE="/tmp/lab_canary_${CANARY_PORT}.pid"

check_endpoint() {
    curl -s -f -m 2 "${CANARY_URL}" >/dev/null 2>&1
}

main() {
    log_info "Initiating remediation for network canary endpoint (${CANARY_URL})..."

    # 1. Precondition / Idempotency Check
    if check_endpoint; then
        log_pass "Endpoint ${CANARY_URL} is already healthy. Idempotent no-op."
        log_audit "network_remediation" "ALREADY_HEALTHY" "Port ${CANARY_PORT} reachable"
        exit 0
    fi

    log_audit "network_remediation" "START" "Restarting canary endpoint on port ${CANARY_PORT}"

    # 2. Check if docker container exists for canary
    if docker ps -a --format '{{.Names}}' | grep -q "^lab-canary-endpoint$"; then
        docker start lab-canary-endpoint >/dev/null 2>&1 || true
    else
        # Start local lightweight Python HTTP canary
        nohup python3 -m http.server "${CANARY_PORT}" --bind 127.0.0.1 > /dev/null 2>&1 &
        echo $! > "${PID_FILE}"
    fi

    # 3. Post-Remediation Verification
    local verified=0
    for _ in $(seq 1 10); do
        sleep 0.5
        if check_endpoint; then
            verified=1
            break
        fi
    done

    if [[ "$verified" -eq 1 ]]; then
        log_pass "Remediation verified: Canary endpoint restored at ${CANARY_URL}"
        log_audit "network_remediation" "SUCCESS" "Port ${CANARY_PORT} restored and verified"
        exit 0
    else
        log_fail "Remediation failed: Canary endpoint still unresponsive."
        log_audit "network_remediation" "FAILED" "Port ${CANARY_PORT} failed health check"
        exit 1
    fi
}

main "$@"
