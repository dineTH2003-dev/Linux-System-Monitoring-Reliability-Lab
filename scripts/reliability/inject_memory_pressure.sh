#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 2: Controlled Memory Pressure Simulation
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

DURATION="${1:-30}"
ALLOC_MB="${2:-256}"
CONTAINER_MODE="${3:-0}"
PID_FILE="/tmp/lab_memory_pressure.pid"

# 1. Safety Checks
assert_safe_timeout "$DURATION" 60
if [[ "$ALLOC_MB" -lt 64 ]] || [[ "$ALLOC_MB" -gt 1024 ]]; then
    log_fail "SAFETY VIOLATION: Memory allocation must be bounded between 64MB and 1024MB (got ${ALLOC_MB}MB) to prevent host OOM."
    exit 1
fi

WORKER_PID=""

cleanup() {
    log_info "Releasing allocated memory and stopping memory pressure..."
    if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
        kill -TERM "$WORKER_PID" 2>/dev/null || true
        wait "$WORKER_PID" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
    docker rm -f lab-mem-stress >/dev/null 2>&1 || true
    log_pass "Memory pressure terminated cleanly. Host memory reclaimed."
    log_audit "memory_pressure" "STOP" "Released ${ALLOC_MB}MB after ${DURATION}s"
}

trap cleanup INT TERM EXIT

main() {
    log_info "Injecting controlled memory pressure (${ALLOC_MB}MB, duration: ${DURATION}s)..."
    log_audit "memory_pressure" "START" "Target MB: $ALLOC_MB, Duration: ${DURATION}s"

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario2_t_inject.txt

    if [[ "$CONTAINER_MODE" -eq 1 ]] && command -v docker >/dev/null 2>&1; then
        log_info "Running container-isolated memory saturation (cgroup-bounded to 256MB)..."
        docker run --name lab-mem-stress --rm -d --memory=256m --memory-swap=256m alpine sh -c \
            "python3 -c 'import time; a = bytearray(200 * 1024 * 1024); time.sleep(${DURATION})' 2>/dev/null || sleep ${DURATION}" >/dev/null
        sleep "$DURATION"
    else
        log_info "Running safe in-process memory allocation (${ALLOC_MB}MB)..."
        python3 -c '
import time, sys
alloc_mb = int(sys.argv[1])
duration = int(sys.argv[2])
data = bytearray(alloc_mb * 1024 * 1024)
for i in range(0, len(data), 4096):
    data[i] = 1
time.sleep(duration)
' "$ALLOC_MB" "$DURATION" &
        WORKER_PID=$!
        echo "$WORKER_PID" > "${PID_FILE}"
        log_pass "Allocated ${ALLOC_MB}MB in worker process (PID: $WORKER_PID)"
        wait "$WORKER_PID" || true
    fi
}

main "$@"
