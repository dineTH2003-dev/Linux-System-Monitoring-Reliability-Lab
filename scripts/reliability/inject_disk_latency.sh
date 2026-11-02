#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 5: Controlled Disk I/O Latency Simulation in Isolated Environment
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

DURATION="${1:-20}"
TEST_DIR="${2:-/tmp/lab_io_latency_test}"
PID_FILE="/tmp/lab_disk_latency.pid"

# Safety assertions
assert_safe_timeout "$DURATION" 60
assert_not_root_mount "$TEST_DIR"

WORKER_PID=""

cleanup() {
    log_info "Stopping disk I/O latency simulation workers..."
    if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
        kill -TERM "$WORKER_PID" 2>/dev/null || true
        wait "$WORKER_PID" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
    rm -rf "${TEST_DIR}"
    log_pass "Disk I/O latency simulation cleaned up."
    log_audit "disk_latency" "STOP" "Simulation terminated after ${DURATION}s"
}

trap cleanup INT TERM EXIT

main() {
    log_info "Injecting controlled disk I/O latency simulation (${DURATION}s, dir: ${TEST_DIR})..."
    log_audit "disk_latency" "START" "Target dir: ${TEST_DIR}, Duration: ${DURATION}s"

    mkdir -p "${TEST_DIR}"

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario5_t_inject.txt

    # Run synchronous direct I/O write loop with fdatasync to simulate high await latency
    python3 -c '
import os, time, sys

test_file = sys.argv[1] + "/sync_payload.dat"
duration = float(sys.argv[2])
end_time = time.time() + duration

fd = os.open(test_file, os.O_CREAT | os.O_WRONLY | os.O_SYNC)
payload = b"X" * 4096

writes = 0
total_latency = 0.0

try:
    while time.time() < end_time:
        t0 = time.perf_counter()
        os.write(fd, payload)
        os.fdatasync(fd)
        t1 = time.perf_counter()
        latency_ms = (t1 - t0) * 1000
        total_latency += latency_ms
        writes += 1
        time.sleep(0.01)
finally:
    os.close(fd)
    if writes > 0:
        avg_latency = total_latency / writes
        print(f"Executed {writes} synchronous writes. Average await latency: {avg_latency:.2f} ms")
' "${TEST_DIR}" "${DURATION}" &
    WORKER_PID=$!
    echo "$WORKER_PID" > "${PID_FILE}"

    log_pass "Started synchronous I/O latency worker (PID: $WORKER_PID)"
    wait "$WORKER_PID" || true
}

main "$@"
