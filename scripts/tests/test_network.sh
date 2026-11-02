#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Test Suite: Network Monitor Unit & Deterministic Fixture Tests
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${TESTS_DIR}/fixtures"
MONITOR_DIR="${TESTS_DIR}/../monitoring"

# shellcheck source=scripts/tests/test_runner.sh
source "${TESTS_DIR}/test_runner.sh"

describe "Network Monitor: Interfaces, Error Counters & Socket Verification"

export PROC_ROOT="${FIXTURES_DIR}/proc"
export SYS_ROOT="${FIXTURES_DIR}/sys"

out="$(bash "${MONITOR_DIR}/network_monitor.sh" -i 0 --json)"

it "parses interface names from /proc/net/dev fixture (eth0, lo)"
assert_contains '"interface": "eth0"' "$out" "eth0 detected"
assert_contains '"interface": "lo"' "$out" "lo detected"

it "parses operstate and MTU from sysfs fixture (up, 1500)"
assert_contains '"operstate": "up"' "$out" "operstate is up"
assert_contains '"mtu": "1500"' "$out" "mtu is 1500"

it "reads cumulative bytes and error/drop counters from fixture"
assert_contains '"rx_bytes": 50000000' "$out" "rx_bytes matches"
assert_contains '"tx_bytes": 30000000' "$out" "tx_bytes matches"
assert_contains '"rx_errors": 5' "$out" "rx_errors matches"
assert_contains '"rx_dropped": 10' "$out" "rx_dropped matches"

it "supports single interface filtering (--interface eth0)"
out_eth0="$(bash "${MONITOR_DIR}/network_monitor.sh" -i 0 -I eth0 --json)"
assert_contains '"interface": "eth0"' "$out_eth0" "eth0 present"
assert_contains false "$(echo "$out_eth0" | grep -q '"interface": "lo"' && echo true || echo false)" "lo excluded"

it "exits with code 0 when error rates are within thresholds"
code=0
bash "${MONITOR_DIR}/network_monitor.sh" -i 0 -I eth0 --warn-errors 100 --crit-errors 200 >/dev/null 2>&1 || code=$?
assert_exit_code 0 "$code" "Should exit 0 when below thresholds"

it "fails with exit code 1 when target interface does not exist"
code=0
bash "${MONITOR_DIR}/network_monitor.sh" -i 0 -I nonexistent_eth99 >/dev/null 2>&1 || code=$?
assert_exit_code 1 "$code" "Should exit 1 on nonexistent interface"

it "supports --ports-only mode and captures listening sockets"
out_ports="$(bash "${MONITOR_DIR}/network_monitor.sh" -i 0 --ports-only --json)"
assert_contains '"listening_ports": [' "$out_ports" "listening_ports list present"
assert_contains '"interfaces": []' "$out_ports" "interfaces list empty in ports-only mode"
