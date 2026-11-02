#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Test Suite: systemd Monitor Unit Tests
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="${TESTS_DIR}/../monitoring"

# shellcheck source=scripts/tests/test_runner.sh
source "${TESTS_DIR}/test_runner.sh"

describe "systemd Monitor: Service State & Unit Failure Verification"

it "collects overall system state and failed units count"
out="$(bash "${MONITOR_DIR}/systemd_monitor.sh" --json || true)"
assert_contains '"system_state":' "$out" "system_state present"
assert_contains '"failed_units_count":' "$out" "failed_units_count present"
assert_contains '"failed_units": [' "$out" "failed_units array present"

it "inspects service metadata for cron.service"
out_svc="$(bash "${MONITOR_DIR}/systemd_monitor.sh" --service cron.service --crit-failed 100 --json || true)"
assert_contains '"unit": "cron.service"' "$out_svc" "cron.service unit name"
assert_contains '"active_state": "active"' "$out_svc" "cron.service active state"

it "exits with code 0 when failed units count is below configured threshold"
code=0
bash "${MONITOR_DIR}/systemd_monitor.sh" --crit-failed 100 >/dev/null 2>&1 || code=$?
assert_exit_code 0 "$code" "Should exit 0 when failed units below high threshold"

it "exits with code 4 [CRIT] when failed units count meets or exceeds critical threshold (e.g. -c 1)"
code=0
bash "${MONITOR_DIR}/systemd_monitor.sh" -c 1 >/dev/null 2>&1 || code=$?
# Since host currently has failed units (apport, openipmi), -c 1 triggers exit 4
assert_exit_code 4 "$code" "Should exit 4 when failed units >= crit threshold"

it "exits with code 2 on invalid threshold input"
code=0
bash "${MONITOR_DIR}/systemd_monitor.sh" -c -5 >/dev/null 2>&1 || code=$?
assert_exit_code 2 "$code" "Should exit 2 on negative threshold"
