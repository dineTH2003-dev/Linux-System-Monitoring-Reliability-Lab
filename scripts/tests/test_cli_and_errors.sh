#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Test Suite: CLI Orchestrator, Error Handling & Safety Invariant Tests
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="${TESTS_DIR}/../monitoring"
LIB_DIR="${TESTS_DIR}/../lib"

# shellcheck source=scripts/tests/test_runner.sh
source "${TESTS_DIR}/test_runner.sh"
# shellcheck source=scripts/lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=scripts/lib/thresholds.sh
source "${LIB_DIR}/thresholds.sh"

describe "CLI Orchestrator, Error Handling & Safety Invariants"

it "displays CLI help message on --help (exit code 0)"
code=0
out="$(bash "${MONITOR_DIR}/system_monitor.sh" --help)" || code=$?
assert_exit_code 0 "$code" "Should exit 0 on --help"
assert_contains "Unified Linux System Monitoring" "$out" "Help message banner present"

it "displays version string on --version"
code=0
out="$(bash "${MONITOR_DIR}/system_monitor.sh" --version)" || code=$?
assert_exit_code 0 "$code" "Should exit 0 on --version"
assert_contains "Toolkit v1.0.0" "$out" "Version string matches"

it "fails with exit code 2 on unknown command"
code=0
bash "${MONITOR_DIR}/system_monitor.sh" invalid_command_foo >/dev/null 2>&1 || code=$?
assert_exit_code 2 "$code" "Should exit 2 on unknown command"

it "fails with exit code 2 when no command is provided"
code=0
bash "${MONITOR_DIR}/system_monitor.sh" >/dev/null 2>&1 || code=$?
assert_exit_code 2 "$code" "Should exit 2 when no command provided"

it "verifies require_command exits with 127 when tool is missing"
code=0
( require_command "command_that_definitely_does_not_exist_xyz123" >/dev/null 2>&1 ) || code=$?
assert_exit_code 127 "$code" "require_command returns 127 on missing tool"

it "verifies check_readable returns 1 on nonexistent file"
code=0
check_readable "/tmp/file_that_does_not_exist_abc987.txt" >/dev/null 2>&1 || code=$?
assert_exit_code 1 "$code" "check_readable returns 1 on missing file"

it "verifies numeric comparison helper handles floats and integers correctly"
code=0
compare_num "85.5" "gt" "80" || code=$?
assert_exit_code 0 "$code" "85.5 > 80 is true"

code=0
compare_num "70.2" "ge" "70.2" || code=$?
assert_exit_code 0 "$code" "70.2 >= 70.2 is true"

code=0
compare_num "50" "lt" "40" || code=$?
assert_exit_code 1 "$code" "50 < 40 is false"

it "verifies threshold status aggregator selects maximum severity"
s="$(aggregate_status 0 3)"
assert_equals "3" "$s" "OK + WARN -> WARN"
s="$(aggregate_status 3 4)"
assert_equals "4" "$s" "WARN + CRIT -> CRIT"
s="$(aggregate_status 0 0)"
assert_equals "0" "$s" "OK + OK -> OK"

it "verifies JSON string escaper safely escapes special characters"
escaped="$(json_escape $'Hello "World"\nNew line\tTab')"
assert_contains 'Hello \"World\"' "$escaped" "Escapes double quotes"
assert_contains '\nNew line' "$escaped" "Escapes newlines"
assert_contains '\tTab' "$escaped" "Escapes tabs"

it "verifies human byte formatting accurately converts magnitudes"
h1="$(bytes_to_human 512)"
assert_equals "512 B" "$h1" "512 B"
h2="$(bytes_to_human 1048576)"
assert_equals "1.00 MiB" "$h2" "1 MiB"
h3="$(bytes_to_human 1073741824)"
assert_equals "1.00 GiB" "$h3" "1 GiB"
