#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Scenario 8: Controlled Exporter Failure Simulation
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

EXPORTER_PORT="${1:-9102}"
PID_FILE="/tmp/lab_test_exporter_${EXPORTER_PORT}.pid"

main() {
    log_info "Injecting controlled exporter failure (Port :${EXPORTER_PORT})..."
    log_audit "exporter_failure" "START" "Target exporter port: ${EXPORTER_PORT}"

    # 1. Establish running exporter if not present
    if ! curl -s -m 1 "http://127.0.0.1:${EXPORTER_PORT}/metrics" >/dev/null 2>&1; then
        log_info "Starting synthetic Prometheus exporter on :${EXPORTER_PORT}..."
        python3 -c '
from http.server import HTTPServer, BaseHTTPRequestHandler
import sys

class MetricHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(b"# HELP test_exporter_up Synthetic test metric\n# TYPE test_exporter_up gauge\ntest_exporter_up 1\n")
    def log_message(self, format, *args):
        return

port = int(sys.argv[1])
server = HTTPServer(("127.0.0.1", port), MetricHandler)
server.serve_forever()
' "${EXPORTER_PORT}" >/dev/null 2>&1 &
        echo $! > "${PID_FILE}"
        sleep 1
    fi

    local t_inject
    t_inject="$(timestamp_epoch)"
    printf "%s" "$t_inject" > /tmp/sre_scenario8_t_inject.txt

    # 2. Inject failure: Terminate the exporter process
    log_warn "Injecting failure: Terminating synthetic exporter on port ${EXPORTER_PORT}..."
    if [[ -f "${PID_FILE}" ]]; then
        local exp_pid
        exp_pid="$(cat "${PID_FILE}")"
        if kill -0 "$exp_pid" 2>/dev/null; then
            kill -KILL "$exp_pid" 2>/dev/null || true
        fi
        rm -f "${PID_FILE}"
    fi

    fuser -k -n tcp "${EXPORTER_PORT}" 2>/dev/null || true
    sleep 0.5

    # 3. Verify failure condition
    if ! curl -s -m 1 "http://127.0.0.1:${EXPORTER_PORT}/metrics" >/dev/null 2>&1; then
        log_pass "Exporter failure injected successfully. Port ${EXPORTER_PORT} is unresponsive."
        log_audit "exporter_failure" "INJECTED" "Exporter (:9102) terminated"
        exit 0
    else
        log_fail "Failed to stop exporter; port ${EXPORTER_PORT} still responding."
        exit 1
    fi
}

main "$@"
