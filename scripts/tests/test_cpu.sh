#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Test Suite: CPU Monitor Unit & Deterministic Fixture Tests
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${TESTS_DIR}/fixtures"
MONITOR_DIR="${TESTS_DIR}/../monitoring"

# shellcheck source=scripts/tests/test_runner.sh
source "${TESTS_DIR}/test_runner.sh"

describe "CPU Monitor: Deterministic Parsing & Threshold Verification"

# Setup fixture environment overrides
export PROC_ROOT="${FIXTURES_DIR}/proc"
export SYS_ROOT="${FIXTURES_DIR}/sys"

it "parses CPU model and core topology accurately from fixtures"
out="$(bash "${MONITOR_DIR}/cpu_monitor.sh" -i 0 --json)"
assert_contains "Intel(R) Core(TM) i7-TestModel" "$out" "Model name matches fixture"

it "counts logical processors correctly from fixture (4 processors)"
assert_contains '"logical_processors": 4' "$out" "Logical cores equal 4"

it "reads and normalizes load average from fixture (0.75 / 4 = 0.19 per core)"
assert_contains '"load_1m": 0.75' "$out" "1m loadavg matches"
assert_contains '"load_1m_per_core": 0.19' "$out" "Normalized load matches"

it "extracts Pressure Stall Information (PSI) correctly from fixture"
assert_contains '"some_avg10": 1.50' "$out" "PSI some avg10 matches"
assert_contains '"some_avg60": 2.00' "$out" "PSI some avg60 matches"

it "exits with code 0 [OK] when all metrics are within thresholds"
code=0
bash "${MONITOR_DIR}/cpu_monitor.sh" -i 0 --warn-util 90 --crit-util 95 >/dev/null 2>&1 || code=$?
assert_exit_code 0 "$code" "Should exit 0 when below thresholds"

it "exits with code 3 [WARN] when warning load threshold is exceeded"
code=0
bash "${MONITOR_DIR}/cpu_monitor.sh" -i 0 --warn-load 0.10 >/dev/null 2>&1 || code=$?
assert_exit_code 3 "$code" "Should exit 3 on warn threshold"

it "exits with code 4 [CRIT] when critical load threshold is exceeded"
code=0
bash "${MONITOR_DIR}/cpu_monitor.sh" -i 0 --warn-load 0.10 --crit-load 0.15 >/dev/null 2>&1 || code=$?
assert_exit_code 4 "$code" "Should exit 4 on crit threshold"

it "validates that warn threshold cannot be greater than crit threshold (exit 2)"
code=0
bash "${MONITOR_DIR}/cpu_monitor.sh" -i 0 --warn-util 90 --crit-util 80 >/dev/null 2>&1 || code=$?
assert_exit_code 2 "$code" "Should exit 2 on invalid threshold syntax"
