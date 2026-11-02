#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Process Monitor
# Purpose: Deep process state counts, top CPU/Memory consumers, PID inspection
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
TOP_COUNT=5
OUTPUT_FORMAT="text"
WARN_ZOMBIES=""
CRIT_ZOMBIES=""
WARN_DISK_SLEEP=""
CRIT_DISK_SLEEP=""
TARGET_PID=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Non-destructive Linux Process monitoring module. Inspects process counts,
kernel scheduling states (R/S/D/Z/T), top resource consumers, and PID details.

Options:
  -n, --top NUM           Number of top processes to report (default: 5)
  -p, --pid PID           Inspect detailed attributes for a specific process ID
  -z, --warn-zombies NUM  Warning threshold for zombie (Z) process count
  -Z, --crit-zombies NUM  Critical threshold for zombie (Z) process count
  -d, --warn-dstate NUM   Warning threshold for uninterruptible disk sleep (D) count
  -D, --crit-dstate NUM   Critical threshold for uninterruptible disk sleep (D) count
  -j, --json              Output metrics in structured JSON format
  -t, --text              Output metrics in formatted human-readable text (default)
  -h, --help              Display this help message and exit

Exit Codes:
  0 - OK (All metrics within normal thresholds)
  1 - Runtime error (Missing files, process not found)
  2 - Usage error (Invalid parameters or threshold syntax)
  3 - Warning threshold exceeded
  4 - Critical threshold exceeded
  127 - Required command not found
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--top)
                TOP_COUNT="$2"
                shift 2
                ;;
            -p|--pid)
                TARGET_PID="$2"
                shift 2
                ;;
            -z|--warn-zombies)
                WARN_ZOMBIES="$2"
                shift 2
                ;;
            -Z|--crit-zombies)
                CRIT_ZOMBIES="$2"
                shift 2
                ;;
            -d|--warn-dstate)
                WARN_DISK_SLEEP="$2"
                shift 2
                ;;
            -D|--crit-dstate)
                CRIT_DISK_SLEEP="$2"
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
    require_command ps
    require_command awk

    if ! is_uint "$TOP_COUNT" || [[ "$TOP_COUNT" -le 0 ]]; then
        log_error "Invalid top count: '$TOP_COUNT'. Must be a positive integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$TARGET_PID" ]] && ! is_uint "$TARGET_PID"; then
        log_error "Invalid target PID: '$TARGET_PID'. Must be an integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_ZOMBIES" ]] && ! is_uint "$WARN_ZOMBIES"; then
        log_error "Invalid warn-zombies: '$WARN_ZOMBIES'. Must be a non-negative integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_ZOMBIES" ]] && ! is_uint "$CRIT_ZOMBIES"; then
        log_error "Invalid crit-zombies: '$CRIT_ZOMBIES'. Must be a non-negative integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_ZOMBIES" && -n "$CRIT_ZOMBIES" ]] && [[ "$WARN_ZOMBIES" -gt "$CRIT_ZOMBIES" ]]; then
        log_error "warn-zombies ($WARN_ZOMBIES) cannot be greater than crit-zombies ($CRIT_ZOMBIES)."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_DISK_SLEEP" ]] && ! is_uint "$WARN_DISK_SLEEP"; then
        log_error "Invalid warn-dstate: '$WARN_DISK_SLEEP'. Must be a non-negative integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_DISK_SLEEP" ]] && ! is_uint "$CRIT_DISK_SLEEP"; then
        log_error "Invalid crit-dstate: '$CRIT_DISK_SLEEP'. Must be a non-negative integer."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_DISK_SLEEP" && -n "$CRIT_DISK_SLEEP" ]] && [[ "$WARN_DISK_SLEEP" -gt "$CRIT_DISK_SLEEP" ]]; then
        log_error "warn-dstate ($WARN_DISK_SLEEP) cannot be greater than crit-dstate ($CRIT_DISK_SLEEP)."
        exit "$EXIT_USAGE"
    fi
}

# Collect global process states and thread counts
collect_process_states() {
    local ps_output
    ps_output="$(ps -eo stat --no-headers 2>/dev/null || true)"

    read -r TOTAL_PROCS PROCS_R PROCS_S PROCS_D PROCS_Z PROCS_T PROCS_I _ < <(echo "$ps_output" | awk '
    {
        s = substr($1, 1, 1)
        if (s == "R") r++
        else if (s == "S") s_int++
        else if (s == "D") d++
        else if (s == "Z") z++
        else if (s == "T" || s == "t") t++
        else if (s == "I") i++
        else other++
        total++
    } END {
        printf "%d %d %d %d %d %d %d %d\n", total, r, s_int, d, z, t, i, other
    }')

    # Count total threads across all processes
    TOTAL_THREADS="$(ps -eLf --no-headers 2>/dev/null | wc -l || echo "$TOTAL_PROCS")"
}

# Collect top CPU consumers
collect_top_cpu() {
    TOP_CPU_DATA=()
    local top_raw
    top_raw="$(ps -eo pid,ppid,user,%cpu,%mem,stat,comm --sort=-%cpu 2>/dev/null | tail -n +2 | head -n "$TOP_COUNT" || true)"

    while read -r pid ppid user cpu mem stat comm; do
        [[ -z "$pid" ]] && continue
        TOP_CPU_DATA+=("${pid}|${ppid}|${user}|${cpu}|${mem}|${stat}|${comm}")
    done < <(echo "$top_raw")
}

# Collect top Memory consumers
collect_top_memory() {
    TOP_MEM_DATA=()
    local top_raw
    top_raw="$(ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,stat,comm --sort=-rss 2>/dev/null | tail -n +2 | head -n "$TOP_COUNT" || true)"

    while read -r pid ppid user cpu mem rss vsz stat comm; do
        [[ -z "$pid" ]] && continue
        TOP_MEM_DATA+=("${pid}|${ppid}|${user}|${cpu}|${mem}|${rss}|${vsz}|${stat}|${comm}")
    done < <(echo "$top_raw")
}

# Collect details for a specific PID
inspect_pid() {
    local pid="$1"
    local pid_dir="${PROC_ROOT}/${pid}"

    if [[ ! -d "$pid_dir" ]]; then
        log_error "Process ID $pid not found or terminated."
        exit "$EXIT_ERROR"
    fi

    PID_COMM="Unknown"
    PID_STATE="Unknown"
    PID_PPID=0
    PID_THREADS=1
    PID_RSS_KB=0
    PID_VSZ_KB=0
    PID_CMDLINE=""

    if [[ -r "${pid_dir}/status" ]]; then
        PID_COMM="$(awk -F':\t*' '/^Name:/ {print $2}' "${pid_dir}/status" || echo "Unknown")"
        PID_STATE="$(awk -F':\t*' '/^State:/ {print $2}' "${pid_dir}/status" || echo "Unknown")"
        PID_PPID="$(awk -F':\t*' '/^PPid:/ {print $2}' "${pid_dir}/status" || echo 0)"
        PID_THREADS="$(awk -F':\t*' '/^Threads:/ {print $2}' "${pid_dir}/status" || echo 1)"
        PID_RSS_KB="$(awk '/^VmRSS:/ {print $2}' "${pid_dir}/status" || echo 0)"
        PID_VSZ_KB="$(awk '/^VmSize:/ {print $2}' "${pid_dir}/status" || echo 0)"
    fi

    if [[ -r "${pid_dir}/cmdline" ]]; then
        PID_CMDLINE="$(tr '\0' ' ' < "${pid_dir}/cmdline" || echo "")"
    fi
}

main() {
    parse_args "$@"
    validate_inputs

    collect_process_states

    if [[ -n "$TARGET_PID" ]]; then
        inspect_pid "$TARGET_PID"
    else
        collect_top_cpu
        collect_top_memory
    fi

    # Evaluate Thresholds (Zombies & D-state)
    local status_z="$EXIT_SUCCESS"
    local status_d="$EXIT_SUCCESS"
    local max_status="$EXIT_SUCCESS"

    if [[ -n "$WARN_ZOMBIES" || -n "$CRIT_ZOMBIES" ]]; then
        eval_threshold "$PROCS_Z" "$WARN_ZOMBIES" "$CRIT_ZOMBIES" "upper" || status_z=$?
    fi

    if [[ -n "$WARN_DISK_SLEEP" || -n "$CRIT_DISK_SLEEP" ]]; then
        eval_threshold "$PROCS_D" "$WARN_DISK_SLEEP" "$CRIT_DISK_SLEEP" "upper" || status_d=$?
    fi

    max_status="$(aggregate_status "$max_status" "$status_z")"
    max_status="$(aggregate_status "$max_status" "$status_d")"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        local overall_status_str
        overall_status_str="$(status_to_string "$max_status")"

        printf "{\n"
        printf "  \"timestamp\": \"%s\",\n" "$(timestamp_utc)"
        printf "  \"module\": \"process\",\n"
        printf "  \"status\": \"%s\",\n" "$overall_status_str"
        printf "  \"exit_code\": %d,\n" "$max_status"
        printf "  \"counts\": {\n"
        printf "    \"total_processes\": %d,\n" "$TOTAL_PROCS"
        printf "    \"total_threads\": %d,\n" "$TOTAL_THREADS"
        printf "    \"running\": %d,\n" "$PROCS_R"
        printf "    \"sleeping_interruptible\": %d,\n" "$PROCS_S"
        printf "    \"uninterruptible_disk_sleep\": %d,\n" "$PROCS_D"
        printf "    \"zombie\": %d,\n" "$PROCS_Z"
        printf "    \"stopped\": %d,\n" "$PROCS_T"
        printf "    \"idle_kernel\": %d\n" "$PROCS_I"
        printf "  },\n"

        if [[ -n "$TARGET_PID" ]]; then
            cat <<EOF
  "target_pid": {
    "pid": ${TARGET_PID},
    "ppid": ${PID_PPID},
    "command": "$(json_escape "$PID_COMM")",
    "state": "$(json_escape "$PID_STATE")",
    "threads": ${PID_THREADS},
    "rss_kb": ${PID_RSS_KB},
    "vsz_kb": ${PID_VSZ_KB},
    "cmdline": "$(json_escape "$PID_CMDLINE")"
  }
}
EOF
        else
            printf "  \"top_cpu\": [\n"
            local first_cpu=true
            for item in "${TOP_CPU_DATA[@]}"; do
                IFS='|' read -r pid ppid user cpu mem stat comm <<< "$item"
                if [[ "$first_cpu" == "false" ]]; then printf ",\n"; fi
                first_cpu=false

                cat <<EOF
    {
      "pid": ${pid},
      "ppid": ${ppid},
      "user": "$(json_escape "$user")",
      "cpu_pct": ${cpu},
      "mem_pct": ${mem},
      "stat": "$(json_escape "$stat")",
      "command": "$(json_escape "$comm")"
    }
EOF
            done
            printf "\n  ],\n"

            printf "  \"top_memory\": [\n"
            local first_mem=true
            for item in "${TOP_MEM_DATA[@]}"; do
                IFS='|' read -r pid ppid user cpu mem rss vsz stat comm <<< "$item"
                if [[ "$first_mem" == "false" ]]; then printf ",\n"; fi
                first_mem=false

                cat <<EOF
    {
      "pid": ${pid},
      "ppid": ${ppid},
      "user": "$(json_escape "$user")",
      "cpu_pct": ${cpu},
      "mem_pct": ${mem},
      "rss_kb": ${rss},
      "vsz_kb": ${vsz},
      "stat": "$(json_escape "$stat")",
      "command": "$(json_escape "$comm")"
    }
EOF
            done
            printf "\n  ]\n"
            printf "}\n"
        fi

    else
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%sLinux Process Subsystem Telemetry Report%s  %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$max_status")"
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "Timestamp: %s\n\n" "$(timestamp_utc)"

        printf "%s--- Global Process Scheduling States ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "  Total Process Tasks: %-6d | Total Kernel Threads: %d\n" "$TOTAL_PROCS" "$TOTAL_THREADS"
        printf "  ├─ Running (R)      : %-5d ├─ Zombie Defunct (Z) : %-5d %s\n" \
            "$PROCS_R" "$PROCS_Z" "$(format_status_badge "$status_z")"
        printf "  ├─ Sleep Interrupt  : %-5d ├─ Disk Sleep (D)     : %-5d %s\n" \
            "$PROCS_S" "$PROCS_D" "$(format_status_badge "$status_d")"
        printf "  └─ Stopped / Traced : %-5d └─ Kernel Idle (I)    : %-5d\n" \
            "$PROCS_T" "$PROCS_I"

        if [[ -n "$TARGET_PID" ]]; then
            printf "\n%s--- Target Process Details (PID: %s) ---%s\n" "${COLOR_BOLD}" "$TARGET_PID" "${COLOR_RESET}"
            printf "  Command Name : %s\n" "$PID_COMM"
            printf "  State        : %s\n" "$PID_STATE"
            printf "  Parent PID   : %s\n" "$PID_PPID"
            printf "  Thread Count : %s\n" "$PID_THREADS"
            printf "  Resident RSS : %s (%s kB)\n" "$(kb_to_human "$PID_RSS_KB")" "$PID_RSS_KB"
            printf "  Virtual Size : %s (%s kB)\n" "$(kb_to_human "$PID_VSZ_KB")" "$PID_VSZ_KB"
            printf "  Full Cmdline : %s\n" "$PID_CMDLINE"
        else
            printf "\n%s--- Top %d CPU Consuming Processes ---%s\n" "${COLOR_BOLD}" "$TOP_COUNT" "${COLOR_RESET}"
            printf "%-8s %-8s %-12s %6s %6s %-6s %s\n" "PID" "PPID" "USER" "%CPU" "%MEM" "STAT" "COMMAND"
            printf "%s\n" "---------------------------------------------------------------------"
            for item in "${TOP_CPU_DATA[@]}"; do
                IFS='|' read -r pid ppid user cpu mem stat comm <<< "$item"
                printf "%-8s %-8s %-12s %6s %6s %-6s %s\n" \
                    "$pid" "$ppid" "${user:0:12}" "$cpu" "$mem" "$stat" "$comm"
            done

            printf "\n%s--- Top %d Memory Consuming Processes (by RSS) ---%s\n" "${COLOR_BOLD}" "$TOP_COUNT" "${COLOR_RESET}"
            printf "%-8s %-8s %-12s %10s %6s %-6s %s\n" "PID" "PPID" "USER" "RSS" "%MEM" "STAT" "COMMAND"
            printf "%s\n" "---------------------------------------------------------------------"
            for item in "${TOP_MEM_DATA[@]}"; do
                IFS='|' read -r pid ppid user _ mem rss _ stat comm <<< "$item"
                printf "%-8s %-8s %-12s %10s %6s %-6s %s\n" \
                    "$pid" "$ppid" "${user:0:12}" "$(kb_to_human "$rss")" "$mem" "$stat" "$comm"
            done
        fi
        printf "%s---------------------------------------------------------------------%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    fi

    exit "$max_status"
}

main "$@"
