#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 1: Controlled CPU Contention Simulation
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

DURATION="${1:-30}"
CORES="${2:-2}"
PID_FILE="/tmp/lab_cpu_contention.pid"

# 1. Safety Checks
assert_safe_timeout "$DURATION" 60
if [[ "$CORES" -lt 1 ]] || [[ "$CORES" -gt 4 ]]; then
    log_fail "SAFETY VIOLATION: Cores to stress must be between 1 and 4 (got $CORES). Workstation stability must be preserved."
    exit 1
fi

PIDS=()

cleanup() {
    log_info "Stopping CPU contention workers..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    rm -f "${PID_FILE}"
    wait 2>/dev/null || true
    log_pass "CPU contention injection terminated cleanly. Host CPU restored."
    log_audit "cpu_contention" "STOP" "Stopped $CORES workers after duration ${DURATION}s"
}

trap cleanup INT TERM EXIT

main() {
    log_info "Injecting controlled CPU contention: $CORES cores, $DURATION seconds (nice +19)..."
    log_audit "cpu_contention" "START" "Cores: $CORES, Duration: ${DURATION}s"

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario1_t_inject.txt

    for i in $(seq 1 "$CORES"); do
        # Execute synthetic mathematical loop with lowest scheduling priority
        nice -n 19 python3 -c '
import time, math
end = time.time() + '"$DURATION"'
while time.time() < end:
    _ = [math.sqrt(x) for x in range(1000)]
' &
        PIDS+=($!)
    done

    printf "%s\n" "${PIDS[@]}" > "${PID_FILE}"

    log_pass "Spawned $CORES CPU worker processes: [${PIDS[*]}]"
    log_info "Waiting $DURATION seconds for controlled contention duration..."
    sleep "$DURATION"
}

main "$@"
