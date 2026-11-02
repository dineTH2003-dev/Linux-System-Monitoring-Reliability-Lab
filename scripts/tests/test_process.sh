#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Test Suite: Process Monitor Unit & Deterministic Fixture Tests
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${TESTS_DIR}/fixtures"
MONITOR_DIR="${TESTS_DIR}/../monitoring"

# shellcheck source=scripts/tests/test_runner.sh
source "${TESTS_DIR}/test_runner.sh"

describe "Process Monitor: States, Top Resources & PID Inspection"

export PROC_ROOT="${FIXTURES_DIR}/proc"
export SYS_ROOT="${FIXTURES_DIR}/sys"

it "counts and categorizes process states"
out="$(bash "${MONITOR_DIR}/process_monitor.sh" -n 3 --json)"
assert_contains '"total_processes":' "$out" "total processes field present"
assert_contains '"running":' "$out" "running procs field present"
assert_contains '"zombie":' "$out" "zombie procs field present"

it "reports top CPU and top memory consumer arrays"
assert_contains '"top_cpu": [' "$out" "top_cpu list present"
assert_contains '"top_memory": [' "$out" "top_memory list present"

it "inspects PID 1 accurately from fixture /proc/1/status"
out_pid="$(bash "${MONITOR_DIR}/process_monitor.sh" --pid 1 --json)"
assert_contains '"command": "systemd"' "$out_pid" "PID 1 command is systemd"
assert_contains '"ppid": 0' "$out_pid" "PID 1 PPID is 0"
assert_contains '"threads": 1' "$out_pid" "PID 1 thread count is 1"
assert_contains '"rss_kb": 12000' "$out_pid" "PID 1 RSS matches fixture"

it "exits with code 0 when zombie threshold is not exceeded"
code=0
bash "${MONITOR_DIR}/process_monitor.sh" --warn-zombies 5 --crit-zombies 10 >/dev/null 2>&1 || code=$?
assert_exit_code 0 "$code" "Should exit 0 when zombies below threshold"

it "exits with code 1 when targeted PID does not exist"
code=0
bash "${MONITOR_DIR}/process_monitor.sh" --pid 9999999 >/dev/null 2>&1 || code=$?
assert_exit_code 1 "$code" "Should exit 1 on nonexistent PID"

it "exits with code 2 on invalid PID argument"
code=0
bash "${MONITOR_DIR}/process_monitor.sh" --pid "not_a_number" >/dev/null 2>&1 || code=$?
assert_exit_code 2 "$code" "Should exit 2 on invalid PID"
