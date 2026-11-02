#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Safe Automated Remediation: Synthetic Prometheus Exporter
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/reliability/common.sh
source "${REPO_ROOT}/scripts/reliability/common.sh"

EXPORTER_PORT="${1:-9102}"
PID_FILE="/tmp/lab_test_exporter_${EXPORTER_PORT}.pid"

check_health() {
    curl -s -f -m 1 "http://127.0.0.1:${EXPORTER_PORT}/metrics" >/dev/null 2>&1
}

main() {
    log_info "Initiating remediation for exporter on port ${EXPORTER_PORT}..."

    # Idempotency check
    if check_health; then
        log_pass "Exporter is already responding on port ${EXPORTER_PORT}."
        exit 0
    fi

    # Release any lingering socket
    fuser -k -n tcp "${EXPORTER_PORT}" 2>/dev/null || true
    sleep 0.5

    # Launch python exporter daemon
    python3 -c '
from http.server import HTTPServer, BaseHTTPRequestHandler
import sys

class ReusableServer(HTTPServer):
    allow_reuse_address = True

class MetricHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(b"# HELP test_exporter_up Synthetic test metric\n# TYPE test_exporter_up gauge\ntest_exporter_up 1\n")
    def log_message(self, format, *args):
        return

port = int(sys.argv[1])
server = ReusableServer(("127.0.0.1", port), MetricHandler)
server.serve_forever()
' "${EXPORTER_PORT}" >/dev/null 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "${PID_FILE}"

    # Verification
    local verified=0
    for _ in $(seq 1 10); do
        sleep 0.5
        if check_health; then
            verified=1
            break
        fi
    done

    if [[ "$verified" -eq 1 ]]; then
        log_pass "Remediation verified: Exporter recovered at PID ${new_pid} on port ${EXPORTER_PORT}."
        exit 0
    else
        log_fail "Remediation failed: Exporter did not respond on port ${EXPORTER_PORT}."
        exit 1
    fi
}

main "$@"
