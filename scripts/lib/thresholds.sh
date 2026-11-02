#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Threshold Evaluation Library
# Purpose: Threshold validation, numeric comparison, status aggregation
# ==============================================================================

# Ensure common library is loaded if not already loaded
if [[ -z "${EXIT_SUCCESS:-}" ]]; then
    # shellcheck source=scripts/lib/common.sh
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# Compare two numbers using awk (handles both integer and floating point)
# Returns 0 if cond is true, 1 otherwise
compare_num() {
    local n1="$1"
    local op="$2"
    local n2="$3"

    awk -v a="$n1" -v b="$n2" -v op="$op" '
    BEGIN {
        res = 0
        if (op == "gt") res = (a > b)
        else if (op == "ge") res = (a >= b)
        else if (op == "lt") res = (a < b)
        else if (op == "le") res = (a <= b)
        else if (op == "eq") res = (a == b)
        else if (op == "ne") res = (a != b)
        exit (res ? 0 : 1)
    }'
}

# Evaluate a value against warning and critical thresholds
# Usage: eval_threshold <value> <warn_thresh> <crit_thresh> [direction: upper|lower]
# upper: triggers when value >= threshold (e.g. CPU util, memory used %, error count)
# lower: triggers when value <= threshold (e.g. free disk space, free memory %)
eval_threshold() {
    local val="$1"
    local warn="$2"
    local crit="$3"
    local dir="${4:-upper}"

    if ! is_number "$val"; then
        log_error "eval_threshold: value '$val' is not numeric."
        return "$EXIT_ERROR"
    fi

    if [[ "$dir" == "upper" ]]; then
        if [[ -n "$crit" ]] && is_number "$crit" && compare_num "$val" "ge" "$crit"; then
            return "$EXIT_CRIT"
        fi
        if [[ -n "$warn" ]] && is_number "$warn" && compare_num "$val" "ge" "$warn"; then
            return "$EXIT_WARN"
        fi
    elif [[ "$dir" == "lower" ]]; then
        if [[ -n "$crit" ]] && is_number "$crit" && compare_num "$val" "le" "$crit"; then
            return "$EXIT_CRIT"
        fi
        if [[ -n "$warn" ]] && is_number "$warn" && compare_num "$val" "le" "$warn"; then
            return "$EXIT_WARN"
        fi
    else
        log_error "eval_threshold: unknown direction '$dir'. Use 'upper' or 'lower'."
        return "$EXIT_ERROR"
    fi

    return "$EXIT_SUCCESS"
}

# Format status badge with ANSI coloring
format_status_badge() {
    local status="$1"
    case "$status" in
        0|"$EXIT_SUCCESS")
            printf "%s[OK]%s" "${COLOR_GREEN}" "${COLOR_RESET}"
            ;;
        3|"$EXIT_WARN")
            printf "%s[WARN]%s" "${COLOR_YELLOW}" "${COLOR_RESET}"
            ;;
        4|"$EXIT_CRIT")
            printf "%s[CRIT]%s" "${COLOR_RED}" "${COLOR_RESET}"
            ;;
        *)
            printf "%s[ERR:%s]%s" "${COLOR_RED}" "$status" "${COLOR_RESET}"
            ;;
    esac
}

# Return textual representation of status (for JSON output)
status_to_string() {
    local status="$1"
    case "$status" in
        0|"$EXIT_SUCCESS") echo "OK" ;;
        3|"$EXIT_WARN")    echo "WARNING" ;;
        4|"$EXIT_CRIT")    echo "CRITICAL" ;;
        *)                 echo "ERROR" ;;
    esac
}

# Aggregate two statuses: returns the more severe status
# CRIT (4) > WARN (3) > ERROR (1) > OK (0)
aggregate_status() {
    local current="$1"
    local new="$2"

    if [[ "$current" -eq "$EXIT_CRIT" || "$new" -eq "$EXIT_CRIT" ]]; then
        echo "$EXIT_CRIT"
    elif [[ "$current" -eq "$EXIT_WARN" || "$new" -eq "$EXIT_WARN" ]]; then
        echo "$EXIT_WARN"
    elif [[ "$current" -eq "$EXIT_ERROR" || "$new" -eq "$EXIT_ERROR" ]]; then
        echo "$EXIT_ERROR"
    else
        echo "$EXIT_SUCCESS"
    fi
}
