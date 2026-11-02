#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Test Runner & Assertion Engine
# Purpose: Lightweight TAP-like assertion library and automated test harness
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

TESTS_TOTAL="${TESTS_TOTAL:-0}"
TESTS_PASSED="${TESTS_PASSED:-0}"
TESTS_FAILED="${TESTS_FAILED:-0}"
CURRENT_SUITE=""

# Terminal color configuration
if [[ -z "${COLOR_RESET+x}" ]]; then
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_BOLD=$'\033[1m'
        COLOR_RED=$'\033[0;31m'
        COLOR_GREEN=$'\033[0;32m'
        COLOR_YELLOW=$'\033[0;33m'
        COLOR_BLUE=$'\033[0;34m'
    else
        COLOR_RESET=""
        COLOR_BOLD=""
        COLOR_RED=""
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_BLUE=""
    fi
    # shellcheck disable=SC2034
    readonly COLOR_RESET COLOR_BOLD COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE
fi

describe() {
    CURRENT_SUITE="$*"
    printf "\n%s=== Test Suite: %s ===%s\n" "${COLOR_BOLD}" "$CURRENT_SUITE" "${COLOR_RESET}"
}

it() {
    local desc="$1"
    printf "  • %s ... " "$desc"
}

pass() {
    TESTS_TOTAL=$(( TESTS_TOTAL + 1 ))
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    printf "%sPASS%s\n" "${COLOR_GREEN}" "${COLOR_RESET}"
}

fail() {
    local reason="${1:-Assertion failed}"
    TESTS_TOTAL=$(( TESTS_TOTAL + 1 ))
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    printf "%sFAIL%s\n" "${COLOR_RED}" "${COLOR_RESET}"
    printf "    %s[Error]%s %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$reason"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "Expected: '$expected', Actual: '$actual'. $msg"
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" -eq "$actual" ]]; then
        pass
    else
        fail "Expected exit code: $expected, got: $actual. $msg"
    fi
}

assert_match() {
    local regex="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$actual" =~ $regex ]]; then
        pass
    else
        fail "Pattern '$regex' did not match: '$actual'. $msg"
    fi
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local msg="${3:-}"

    if [[ "$haystack" == *"$needle"* ]]; then
        pass
    else
        fail "Expected substring '$needle' not found. $msg"
    fi
}

summary() {
    printf "\n%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    printf "%sTest Execution Summary%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    printf "Total Assertions : %d\n" "$TESTS_TOTAL"
    printf "Passed           : %s%d%s\n" "${COLOR_GREEN}" "$TESTS_PASSED" "${COLOR_RESET}"
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        printf "Failed           : %s%d%s\n" "${COLOR_RED}" "$TESTS_FAILED" "${COLOR_RESET}"
        return 1
    else
        printf "Failed           : 0\n"
        printf "\n%sAll test suites passed successfully!%s\n" "${COLOR_GREEN}" "${COLOR_RESET}"
        return 0
    fi
}

# If run directly as a script without arguments, discover and execute all test_*.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    start_time="$(date +%s)"
    test_files=("$TESTS_DIR"/test_*.sh)

    for tf in "${test_files[@]}"; do
        if [[ "$(basename "$tf")" == "test_runner.sh" ]]; then continue; fi
        if [[ -x "$tf" || -f "$tf" ]]; then
            # Sourced to accumulate assertion counters
            # shellcheck source=/dev/null
            source "$tf"
        fi
    done

    end_time="$(date +%s)"
    printf "\nExecution completed in %d seconds.\n" "$(( end_time - start_time ))"
    summary
fi
