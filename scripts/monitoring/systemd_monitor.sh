#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: systemd Monitor
# Purpose: Deep systemd service state, failed unit detection, unit inspection
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

# Resolve script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=scripts/lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=scripts/lib/thresholds.sh
source "${LIB_DIR}/thresholds.sh"

setup_traps

# Default configuration parameters
OUTPUT_FORMAT="text"
WARN_FAILED=""
CRIT_FAILED=1
TARGET_SERVICE=""
FAILED_ONLY=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Non-destructive Linux systemd monitoring module. Inspects overall system state,
failed unit services, and specific unit metadata via systemctl interfaces.

Options:
  -s, --service UNIT      Inspect detailed metadata for a specific unit (e.g. ssh.service)
  -f, --failed-only       Report only failed units, skipping system overview
  -w, --warn-failed NUM   Warning threshold for count of failed units
  -c, --crit-failed NUM   Critical threshold for count of failed units (default: 1)
  -j, --json              Output metrics in structured JSON format
  -t, --text              Output metrics in formatted human-readable text (default)
  -h, --help              Display this help message and exit

Exit Codes:
  0 - OK (System running normally, no unexpected failed units)
  1 - Runtime error (Execution failure or unit not found)
  2 - Usage error (Invalid parameters or threshold syntax)
  3 - Warning threshold exceeded
  4 - Critical threshold exceeded
  127 - Required command not found
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                TARGET_SERVICE="$2"
                shift 2
                ;;
            -f|--failed-only)
                FAILED_ONLY=true
                shift
                ;;
            -w|--warn-failed)
                WARN_FAILED="$2"
                shift 2
                ;;
            -c|--crit-failed)
                CRIT_FAILED="$2"
                shift 2
                ;;
            -j|--json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            -t|--text)
                OUTPUT_FORMAT="text"
                shift
                ;;
            -h|--help)
                usage
                exit "$EXIT_SUCCESS"
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit "$EXIT_USAGE"
                ;;
        esac
    done
}

validate_inputs() {
    require_command systemctl
    require_command awk

    if [[ -n "$WARN_FAILED" ]] && ! is_uint "$WARN_FAILED"; then
        log_error "Invalid warn-failed: '$WARN_FAILED'. Must be a non-negative integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_FAILED" ]] && ! is_uint "$CRIT_FAILED"; then
        log_error "Invalid crit-failed: '$CRIT_FAILED'. Must be a non-negative integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_FAILED" && -n "$CRIT_FAILED" ]] && [[ "$WARN_FAILED" -gt "$CRIT_FAILED" ]]; then
        log_error "warn-failed ($WARN_FAILED) cannot be greater than crit-failed ($CRIT_FAILED)."
        exit "$EXIT_USAGE"
    fi
}

# Collect system-level state
collect_system_state() {
    # systemctl is-system-running prints state to stdout and returns non-zero when degraded
    SYSTEM_STATE="$(systemctl is-system-running 2>/dev/null || true)"
    if [[ -z "$SYSTEM_STATE" ]]; then SYSTEM_STATE="degraded"; fi
}

# Collect failed units
collect_failed_units() {
    FAILED_UNITS_DATA=()
    local failed_raw
    failed_raw="$(systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null || true)"

    while read -r unit load active sub desc; do
        [[ -z "$unit" ]] && continue
        # Strip trailing ellipsis or spaces
        FAILED_UNITS_DATA+=("${unit}|${load}|${active}|${sub}|${desc}")
    done < <(echo "$failed_raw")

    FAILED_COUNT=${#FAILED_UNITS_DATA[@]}
}

# Inspect specific service properties
inspect_service() {
    local unit="$1"
    # Ensure .service suffix if no unit type specified
    if [[ "$unit" != *.* ]]; then
        unit="${unit}.service"
    fi

    local show_raw
    show_raw="$(systemctl show "$unit" \
        --property=Id,ActiveState,SubState,UnitFileState,MainPID,ExecMainStatus,NRestarts,Description 2>/dev/null || true)"

    if [[ -z "$show_raw" ]]; then
        log_error "Failed to query unit '$unit'."
        exit "$EXIT_ERROR"
    fi

    SVC_ID="$(echo "$show_raw" | awk -F= '/^Id=/ {print $2}')"
    SVC_ACTIVE_STATE="$(echo "$show_raw" | awk -F= '/^ActiveState=/ {print $2}')"
    SVC_SUB_STATE="$(echo "$show_raw" | awk -F= '/^SubState=/ {print $2}')"
    SVC_FILE_STATE="$(echo "$show_raw" | awk -F= '/^UnitFileState=/ {print $2}')"
    SVC_MAIN_PID="$(echo "$show_raw" | awk -F= '/^MainPID=/ {print $2}')"
    SVC_EXEC_STATUS="$(echo "$show_raw" | awk -F= '/^ExecMainStatus=/ {print $2}')"
    SVC_RESTARTS="$(echo "$show_raw" | awk -F= '/^NRestarts=/ {print $2}')"
    SVC_DESC="$(echo "$show_raw" | awk -F= '/^Description=/ {print $2}')"

    if [[ -z "$SVC_ID" ]]; then
        SVC_ID="$unit"
    fi
    if [[ -z "$SVC_ACTIVE_STATE" ]]; then
        SVC_ACTIVE_STATE="unknown"
    fi
}

main() {
    parse_args "$@"
    validate_inputs

    collect_system_state
    collect_failed_units

    if [[ -n "$TARGET_SERVICE" ]]; then
        inspect_service "$TARGET_SERVICE"
    fi

    # Threshold evaluation
    local status_failed="$EXIT_SUCCESS"
    local status_system="$EXIT_SUCCESS"
    local max_status="$EXIT_SUCCESS"

    if [[ -n "$WARN_FAILED" || -n "$CRIT_FAILED" ]]; then
        eval_threshold "$FAILED_COUNT" "$WARN_FAILED" "$CRIT_FAILED" "upper" || status_failed=$?
    fi

    # If system state is degraded, respect user threshold status
    if [[ "$SYSTEM_STATE" == "degraded" ]]; then
        if [[ "$status_failed" -ne "$EXIT_SUCCESS" ]]; then
            status_system="$status_failed"
        elif [[ -z "$WARN_FAILED" && -z "$CRIT_FAILED" ]]; then
            status_system="$EXIT_CRIT"
        fi
    elif [[ "$SYSTEM_STATE" == "maintenance" || "$SYSTEM_STATE" == "stopping" ]]; then
        status_system="$EXIT_WARN"
    fi

    max_status="$(aggregate_status "$max_status" "$status_failed")"
    max_status="$(aggregate_status "$max_status" "$status_system")"

    # If a specific service was targeted and it is not active, set warning or critical
    if [[ -n "$TARGET_SERVICE" ]]; then
        if [[ "$SVC_ACTIVE_STATE" == "failed" ]]; then
            max_status="$(aggregate_status "$max_status" "$EXIT_CRIT")"
        elif [[ "$SVC_ACTIVE_STATE" != "active" ]]; then
            max_status="$(aggregate_status "$max_status" "$EXIT_WARN")"
        fi
    fi

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        local overall_status_str
        overall_status_str="$(status_to_string "$max_status")"

        printf "{\n"
        printf "  \"timestamp\": \"%s\",\n" "$(timestamp_utc)"
        printf "  \"module\": \"systemd\",\n"
        printf "  \"status\": \"%s\",\n" "$overall_status_str"
        printf "  \"exit_code\": %d,\n" "$max_status"
        printf "  \"system_state\": \"%s\",\n" "$(json_escape "$SYSTEM_STATE")"
        printf "  \"failed_units_count\": %d,\n" "$FAILED_COUNT"
        printf "  \"failed_units\": [\n"

        local first_f=true
        for item in "${FAILED_UNITS_DATA[@]}"; do
            IFS='|' read -r unit load active sub desc <<< "$item"
            if [[ "$first_f" == "false" ]]; then printf ",\n"; fi
            first_f=false

            cat <<EOF
    {
      "unit": "$(json_escape "$unit")",
      "load": "$(json_escape "$load")",
      "active": "$(json_escape "$active")",
      "sub": "$(json_escape "$sub")",
      "description": "$(json_escape "$desc")"
    }
EOF
        done
        printf "\n  ]"

        if [[ -n "$TARGET_SERVICE" ]]; then
            printf ",\n  \"service_inspection\": {\n"
            cat <<EOF
    "unit": "$(json_escape "$SVC_ID")",
    "description": "$(json_escape "$SVC_DESC")",
    "active_state": "$(json_escape "$SVC_ACTIVE_STATE")",
    "sub_state": "$(json_escape "$SVC_SUB_STATE")",
    "unit_file_state": "$(json_escape "$SVC_FILE_STATE")",
    "main_pid": ${SVC_MAIN_PID:-0},
    "exec_main_status": ${SVC_EXEC_STATUS:-0},
    "restarts": ${SVC_RESTARTS:-0}
  }
EOF
        fi
        printf "\n}\n"

    else
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%sLinux systemd Service Subsystem Telemetry Report%s  %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$max_status")"
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "Timestamp: %s\n\n" "$(timestamp_utc)"

        if [[ "$FAILED_ONLY" == "false" ]]; then
            printf "%s--- systemd System Operational State ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
            printf "  Overall System State : %s\n" "${COLOR_BOLD}${SYSTEM_STATE}${COLOR_RESET}"
            printf "  Total Failed Units   : %s %s\n" "${FAILED_COUNT}" "$(format_status_badge "$status_failed")"
        fi

        if [[ ${#FAILED_UNITS_DATA[@]} -gt 0 ]]; then
            printf "\n%s--- Failed Units Detected ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
            printf "%-32s %-8s %-8s %-8s %s\n" "Unit Name" "Load" "Active" "Sub" "Description"
            printf "%s\n" "-------------------------------------------------------------------------------------"
            for item in "${FAILED_UNITS_DATA[@]}"; do
                IFS='|' read -r unit load active sub desc <<< "$item"
                printf "%-32s %-8s %-8s %-8s %s\n" "$unit" "$load" "$active" "$sub" "$desc"
            done
        else
            if [[ "$FAILED_ONLY" == "false" ]]; then
                printf "\n  All systemd units are running cleanly (no failed units detected).\n"
            fi
        fi

        if [[ -n "$TARGET_SERVICE" ]]; then
            printf "\n%s--- Target Service Inspection: %s ---%s\n" "${COLOR_BOLD}" "$SVC_ID" "${COLOR_RESET}"
            printf "  Description     : %s\n" "$SVC_DESC"
            printf "  Active State    : %s (Sub: %s)\n" "$SVC_ACTIVE_STATE" "$SVC_SUB_STATE"
            printf "  Unit File State : %s\n" "$SVC_FILE_STATE"
            printf "  Main PID        : %s\n" "$SVC_MAIN_PID"
            printf "  Exec Main Status: %s\n" "$SVC_EXEC_STATUS"
            printf "  Restart Count   : %s\n" "$SVC_RESTARTS"
        fi
        printf "%s---------------------------------------------------------------------%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    fi

    exit "$max_status"
}

main "$@"
