#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 9: Controlled systemd Service Failure in Disposable Test Service
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

UNIT_NAME="${1:-lab-canary-user.service}"
WHITELIST=("lab-test-canary.service" "lab-canary-user.service")

# Safety Assertion: Strict Whitelist Guard
assert_whitelisted "$UNIT_NAME" "${WHITELIST[@]}"

USER_SERVICE_DIR="${HOME}/.config/systemd/user"
UNIT_PATH="${USER_SERVICE_DIR}/${UNIT_NAME}"

setup_canary_unit() {
    mkdir -p "${USER_SERVICE_DIR}"
    cat <<EOF > "${UNIT_PATH}"
[Unit]
Description=Disposable SRE Reliability Lab Canary Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'sleep 3600'
Restart=no

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user start "${UNIT_NAME}"
    sleep 0.5
}

main() {
    log_info "Injecting controlled systemd service failure into disposable unit '${UNIT_NAME}'..."
    log_audit "systemd_failure" "START" "Target unit: ${UNIT_NAME}"

    # 1. Ensure canary unit exists and is running
    if ! systemctl --user is-active "${UNIT_NAME}" >/dev/null 2>&1; then
        log_info "Deploying and starting disposable canary unit '${UNIT_NAME}'..."
        setup_canary_unit
    fi

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario9_t_inject.txt

    # 2. Inject failure: Kill the unit process with SIGKILL to simulate fatal crash
    log_warn "Injecting crash: Sending SIGKILL to unit '${UNIT_NAME}'..."
    systemctl --user kill --signal=SIGKILL "${UNIT_NAME}" 2>/dev/null || true
    sleep 1

    # 3. Verify failure state
    local state
    state="$(systemctl --user is-failed "${UNIT_NAME}" 2>/dev/null || echo "not-failed")"

    if [[ "$state" == "failed" ]]; then
        log_pass "systemd unit failure injected successfully: Unit '${UNIT_NAME}' is in 'failed' state."
        log_audit "systemd_failure" "INJECTED" "Unit ${UNIT_NAME} entered failed state"
        exit 0
    else
        log_fail "Failed to inject unit failure; state is '${state}' (expected 'failed')."
        exit 1
    fi
}

main "$@"
