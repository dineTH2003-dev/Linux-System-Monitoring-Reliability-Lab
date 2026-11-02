#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Reliability Engineering Common Library & Safety Harness
# Specification: Agent 10 — Reliability Testing & Recovery Framework
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

# Audit Log Location
AUDIT_LOG="${AUDIT_LOG:-/tmp/reliability-lab-audit.log}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9091}"
AGENT_URL="${AGENT_URL:-http://127.0.0.1:9101}"

# Terminal color configuration
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_RED=$'\033[0;31m'
    COLOR_GREEN=$'\033[0;32m'
    COLOR_YELLOW=$'\033[0;33m'
    COLOR_BLUE=$'\033[0;34m'
    COLOR_CYAN=$'\033[0;36m'
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_CYAN=""
fi
readonly COLOR_RESET COLOR_BOLD COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_CYAN

# Timestamp generator (ISO 8601 UTC)
timestamp_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Timestamp generator (Epoch seconds with millisecond precision)
timestamp_epoch() {
    date +%s.%3N
}

# Logging functions
log_info() {
    printf "%s[INFO]%s [%s] %s\n" "${COLOR_BLUE}" "${COLOR_RESET}" "$(timestamp_iso)" "$*" >&2
}

log_pass() {
    printf "%s[PASS]%s [%s] %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$(timestamp_iso)" "$*" >&2
}

log_warn() {
    printf "%s[WARN]%s [%s] %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$(timestamp_iso)" "$*" >&2
}

log_fail() {
    printf "%s[FAIL]%s [%s] %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$(timestamp_iso)" "$*" >&2
}

log_audit() {
    local scenario="$1"
    local event="$2"
    local details="$3"
    local ts
    ts="$(timestamp_iso)"

    # Append human-readable log
    printf "[AUDIT] [%s] scenario=%s event=%s details=%s\n" "$ts" "$scenario" "$event" "$details" >> "${AUDIT_LOG}"
}

# Safety Invariants & Boundary Guards
assert_not_root_mount() {
    local target="$1"
    if [[ -z "$target" ]]; then
        log_fail "assert_not_root_mount: Target mount cannot be empty."
        return 1
    fi

    # Normalize path
    local clean_target
    clean_target="$(realpath -m "$target")"

    if [[ "$clean_target" == "/" ]]; then
        log_fail "SAFETY VIOLATION: Refusing to target root filesystem ('/')!"
        return 1
    fi

    if [[ "$clean_target" == "/boot"* ]] || [[ "$clean_target" == "/etc"* ]] || [[ "$clean_target" == "/usr"* ]] || [[ "$clean_target" == "/var/lib"* ]]; then
        log_fail "SAFETY VIOLATION: Refusing to target critical OS directory ('$clean_target')!"
        return 1
    fi

    return 0
}

assert_safe_timeout() {
    local timeout_val="${1:-}"
    local max_allowed="${2:-300}"

    if [[ ! "$timeout_val" =~ ^[0-9]+$ ]]; then
        log_fail "assert_safe_timeout: Timeout must be an integer, got '$timeout_val'."
        return 1
    fi

    if [[ "$timeout_val" -le 0 ]] || [[ "$timeout_val" -gt "$max_allowed" ]]; then
        log_fail "SAFETY VIOLATION: Timeout $timeout_val out of safe range (1-$max_allowed seconds)."
        return 1
    fi

    return 0
}

assert_whitelisted() {
    local item="$1"
    shift
    local whitelist=("$@")

    for valid in "${whitelist[@]}"; do
        if [[ "$item" == "$valid" ]]; then
            return 0
        fi
    done

    log_fail "SAFETY VIOLATION: Item '$item' is not in whitelist: [${whitelist[*]}]"
    return 1
}

# Prometheus Query Helper
query_prometheus() {
    local query="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s -G "${PROMETHEUS_URL}/api/v1/query" --data-urlencode "query=${query}" || echo '{"status":"error"}'
    else
        log_fail "curl command not found"
        return 1
    fi
}

query_prometheus_alerts() {
    if command -v curl >/dev/null 2>&1; then
        curl -s "${PROMETHEUS_URL}/api/v1/alerts" || echo '{"status":"error"}'
    else
        log_fail "curl command not found"
        return 1
    fi
}

# Metric Calculations (Floating-point safe via awk)
calculate_mttd() {
    local t_inject="$1"
    local t_detect="$2"
    awk -v i="$t_inject" -v d="$t_detect" 'BEGIN { printf "%.3f", (d - i > 0 ? d - i : 0) }'
}

calculate_mttr() {
    local t_recover_start="$1"
    local t_restored="$2"
    awk -v r="$t_recover_start" -v e="$t_restored" 'BEGIN { printf "%.3f", (e - r > 0 ? e - r : 0) }'
}

calculate_total_duration() {
    local t_inject="$1"
    local t_restored="$2"
    awk -v i="$t_inject" -v e="$t_restored" 'BEGIN { printf "%.3f", (e - i > 0 ? e - i : 0) }'
}

calculate_mtbf() {
    local total_uptime="$1"
    local failure_count="$2"
    if [[ "$failure_count" -le 0 ]]; then
        echo "N/A (no failures observed)"
    else
        if command -v awk >/dev/null 2>&1; then
            awk "BEGIN {printf \"%.2f\", $total_uptime / $failure_count}"
        else
            echo $(( total_uptime / failure_count ))
        fi
    fi
}
