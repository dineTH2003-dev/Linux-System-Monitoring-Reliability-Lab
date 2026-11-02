#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Shared Common Library
# Purpose: Shared utility functions, exit codes, logging, and input validation
# ==============================================================================

# Ensure standard POSIX locale to prevent locale-specific parsing errors
export LC_ALL=C

# Standardized exit codes across all monitoring modules
# shellcheck disable=SC2034
readonly EXIT_SUCCESS=0
# shellcheck disable=SC2034
readonly EXIT_ERROR=1
# shellcheck disable=SC2034
readonly EXIT_USAGE=2
# shellcheck disable=SC2034
readonly EXIT_WARN=3
# shellcheck disable=SC2034
readonly EXIT_CRIT=4
# shellcheck disable=SC2034
readonly EXIT_NOCMD=127

# Configurable interface roots (enables deterministic mock testing)
PROC_ROOT="${PROC_ROOT:-/proc}"
SYS_ROOT="${SYS_ROOT:-/sys}"
DEV_ROOT="${DEV_ROOT:-/dev}"

# Terminal color configuration (auto-disabled if not a TTY or NO_COLOR is set)
if [[ -z "${COLOR_RESET+x}" ]]; then
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
    # shellcheck disable=SC2034
    readonly COLOR_RESET COLOR_BOLD COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_CYAN
fi

# Timestamp generator (ISO 8601 UTC)
timestamp_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Logging functions (outputs to stderr so stdout is reserved for data/json)
log_info() {
    printf "%s [INFO]  %s\n" "$(timestamp_utc)" "$*" >&2
}

log_warn() {
    printf "%s %s[WARN]%s  %s\n" "$(timestamp_utc)" "${COLOR_YELLOW}" "${COLOR_RESET}" "$*" >&2
}

log_error() {
    printf "%s %s[ERROR]%s %s\n" "$(timestamp_utc)" "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
}

log_debug() {
    if [[ "${MONITOR_DEBUG:-0}" == "1" ]]; then
        printf "%s %s[DEBUG]%s %s\n" "$(timestamp_utc)" "${COLOR_BLUE}" "${COLOR_RESET}" "$*" >&2
    fi
}

# Validation: Check if string is an integer (positive, zero, or negative)
is_integer() {
    local val="$1"
    [[ "$val" =~ ^-?[0-9]+$ ]]
}

# Validation: Check if string is a non-negative integer
is_uint() {
    local val="$1"
    [[ "$val" =~ ^[0-9]+$ ]]
}

# Validation: Check if string is a valid floating point or integer number
is_number() {
    local val="$1"
    [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# Validation: Ensure command exists in PATH or exit with EXIT_NOCMD
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command '$cmd' is not installed or not in PATH."
        exit "$EXIT_NOCMD"
    fi
}

# Validation: Check that a file or directory exists and is readable
check_readable() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        log_error "Target '$target' does not exist."
        return 1
    fi
    if [[ ! -r "$target" ]]; then
        log_error "Target '$target' is not readable (permission denied)."
        return 1
    fi
    return 0
}

# Conversion: Format bytes into human-readable format (B, KiB, MiB, GiB, TiB)
bytes_to_human() {
    local bytes="$1"
    if ! is_number "$bytes"; then
        printf "%s" "$bytes"
        return 0
    fi

    awk -v b="$bytes" '
    BEGIN {
        if (b < 1024) {
            printf "%.0f B", b
        } else if (b < 1048576) {
            printf "%.2f KiB", b / 1024
        } else if (b < 1073741824) {
            printf "%.2f MiB", b / 1048576
        } else if (b < 1099511627776) {
            printf "%.2f GiB", b / 1073741824
        } else {
            printf "%.2f TiB", b / 1099511627776
        }
    }'
}

# Conversion: Format kibibytes (kB from /proc/meminfo) into human-readable
kb_to_human() {
    local kb="$1"
    if ! is_number "$kb"; then
        printf "%s" "$kb"
        return 0
    fi
    bytes_to_human "$(( kb * 1024 ))"
}

# JSON string escaper (escapes backslashes, quotes, newlines, tabs)
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    printf "%s" "$str"
}

# Setup safe trap handlers
setup_traps() {
    local script_name
    script_name="$(basename "$0")"
    trap 'log_error "Script $script_name interrupted by signal"; exit 130' SIGINT
    trap 'log_error "Script $script_name terminated by signal"; exit 143' SIGTERM
}
