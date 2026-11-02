#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Test Suite: Memory Monitor Unit & Deterministic Fixture Tests
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${TESTS_DIR}/fixtures"
MONITOR_DIR="${TESTS_DIR}/../monitoring"

# shellcheck source=scripts/tests/test_runner.sh
source "${TESTS_DIR}/test_runner.sh"

describe "Memory Monitor: Capacity, Swap Math & PSI Verification"

export PROC_ROOT="${FIXTURES_DIR}/proc"
export SYS_ROOT="${FIXTURES_DIR}/sys"

out="$(bash "${MONITOR_DIR}/memory_monitor.sh" -i 0 --json)"

it "calculates MemTotal correctly from fixture (16,000,000 kB)"
assert_contains '"total_kb": 16000000' "$out" "MemTotal matches"

it "calculates Used Memory as MemTotal - MemAvailable (8,000,000 kB = 50.00%)"
assert_contains '"used_kb": 8000000' "$out" "Used kB matches"
assert_contains '"used_pct": 50.00' "$out" "Used percentage matches"

it "calculates Swap Used and percentage (1,000,000 kB / 4,000,000 kB = 25.00%)"
assert_contains '"used_kb": 1000000' "$out" "Swap used kB matches"
assert_contains '"used_pct": 25.00' "$out" "Swap used percentage matches"

it "reads cumulative vmstat counters from fixture"
assert_contains '"cumulative_pswpin": 10000' "$out" "pswpin matches"
assert_contains '"cumulative_pswpout": 25000' "$out" "pswpout matches"

it "reads Memory PSI metrics (some avg10=0.10, full avg10=0.00)"
assert_contains '"avg10": 0.10' "$out" "some avg10 matches"

it "exits with code 0 when within thresholds"
code=0
bash "${MONITOR_DIR}/memory_monitor.sh" -i 0 --warn-mem 60 --crit-mem 80 >/dev/null 2>&1 || code=$?
assert_exit_code 0 "$code" "Should exit 0 when below thresholds"

it "exits with code 3 [WARN] when RAM usage exceeds warn threshold (50% >= 40%)"
code=0
bash "${MONITOR_DIR}/memory_monitor.sh" -i 0 --warn-mem 40 --crit-mem 80 >/dev/null 2>&1 || code=$?
assert_exit_code 3 "$code" "Should exit 3 on RAM warning"

it "exits with code 4 [CRIT] when Swap usage exceeds critical threshold (25% >= 20%)"
code=0
bash "${MONITOR_DIR}/memory_monitor.sh" -i 0 --warn-swap 10 --crit-swap 20 >/dev/null 2>&1 || code=$?
assert_exit_code 4 "$code" "Should exit 4 on Swap critical"
