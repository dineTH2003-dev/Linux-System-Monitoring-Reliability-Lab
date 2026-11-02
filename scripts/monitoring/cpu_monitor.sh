#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: CPU Monitor
# Purpose: Deep CPU utilization, load average, hardware info, and PSI metrics
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
SAMPLE_INTERVAL=1
OUTPUT_FORMAT="text"
WARN_UTIL=""
CRIT_UTIL=""
WARN_LOAD=""
CRIT_LOAD=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Non-destructive Linux CPU monitoring module. Collects differential CPU
utilization, load average, core topology, and Pressure Stall Information (PSI).

Options:
  -i, --interval SEC      Sampling interval in seconds for differential utilization (default: 1)
  -w, --warn-util PCT     Warning threshold for total CPU utilization percentage
  -c, --crit-util PCT     Critical threshold for total CPU utilization percentage
  -W, --warn-load NUM     Warning threshold for 1-minute per-core normalized load
  -C, --crit-load NUM     Critical threshold for 1-minute per-core normalized load
  -j, --json              Output metrics in structured JSON format
  -t, --text              Output metrics in formatted human-readable text (default)
  -h, --help              Display this help message and exit

Exit Codes:
  0 - OK (All metrics within normal thresholds)
  1 - Runtime error (Missing files, unreadable pseudo-fs)
  2 - Usage error (Invalid parameters or threshold syntax)
  3 - Warning threshold exceeded
  4 - Critical threshold exceeded
  127 - Required command not found
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interval)
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            -w|--warn-util)
                WARN_UTIL="$2"
                shift 2
                ;;
            -c|--crit-util)
                CRIT_UTIL="$2"
                shift 2
                ;;
            -W|--warn-load)
                WARN_LOAD="$2"
                shift 2
                ;;
            -C|--crit-load)
                CRIT_LOAD="$2"
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
    if ! is_number "$SAMPLE_INTERVAL" || compare_num "$SAMPLE_INTERVAL" "lt" "0"; then
        log_error "Invalid sampling interval: '$SAMPLE_INTERVAL'. Must be a non-negative number."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_UTIL" ]] && (! is_number "$WARN_UTIL" || compare_num "$WARN_UTIL" "lt" "0" || compare_num "$WARN_UTIL" "gt" "100"); then
        log_error "Invalid warn-util: '$WARN_UTIL'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_UTIL" ]] && (! is_number "$CRIT_UTIL" || compare_num "$CRIT_UTIL" "lt" "0" || compare_num "$CRIT_UTIL" "gt" "100"); then
        log_error "Invalid crit-util: '$CRIT_UTIL'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_UTIL" && -n "$CRIT_UTIL" ]] && compare_num "$WARN_UTIL" "gt" "$CRIT_UTIL"; then
        log_error "warn-util ($WARN_UTIL) cannot be greater than crit-util ($CRIT_UTIL)."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_LOAD" ]] && (! is_number "$WARN_LOAD" || compare_num "$WARN_LOAD" "lt" "0"); then
        log_error "Invalid warn-load: '$WARN_LOAD'. Must be a positive number."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_LOAD" ]] && (! is_number "$CRIT_LOAD" || compare_num "$CRIT_LOAD" "lt" "0"); then
        log_error "Invalid crit-load: '$CRIT_LOAD'. Must be a positive number."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_LOAD" && -n "$CRIT_LOAD" ]] && compare_num "$WARN_LOAD" "gt" "$CRIT_LOAD"; then
        log_error "warn-load ($WARN_LOAD) cannot be greater than crit-load ($CRIT_LOAD)."
        exit "$EXIT_USAGE"
    fi
}

# Read single row of cpu ticks from /proc/stat
# Returns line starting with "cpu "
get_stat_cpu_line() {
    local stat_file="${PROC_ROOT}/stat"
    if [[ ! -r "$stat_file" ]]; then
        log_error "Cannot read $stat_file"
        return 1
    fi
    grep '^cpu ' "$stat_file" || true
}

# Calculate differential CPU utilization
# Takes: line1 line2
calculate_utilization() {
    local line1="$1"
    local line2="$2"

    awk -v s1="$line1" -v s2="$line2" '
    BEGIN {
        split(s1, a)
        split(s2, b)

        # Fields: 1:cpu 2:user 3:nice 4:system 5:idle 6:iowait 7:irq 8:softirq 9:steal 10:guest 11:guest_nice
        # Note: Linux kernel accounts guest inside user, and guest_nice inside nice.
        # To avoid double-counting:
        # pure_user = user - guest
        # pure_nice = nice - guest_nice

        u1 = a[2]; n1 = a[3]; sys1 = a[4]; idl1 = a[5]; io1 = a[6]; irq1 = a[7]; sirq1 = a[8]; st1 = a[9]; g1 = (a[10] != "" ? a[10] : 0); gn1 = (a[11] != "" ? a[11] : 0)
        u2 = b[2]; n2 = b[3]; sys2 = b[4]; idl2 = b[5]; io2 = b[6]; irq2 = b[7]; sirq2 = b[8]; st2 = b[9]; g2 = (b[10] != "" ? b[10] : 0); gn2 = (b[11] != "" ? b[11] : 0)

        du = u2 - u1
        dn = n2 - n1
        dsys = sys2 - sys1
        didl = idl2 - idl1
        dio = io2 - io1
        dirq = irq2 - irq1
        dsirq = sirq2 - sirq1
        dst = st2 - st1
        dg = g2 - g1
        dgn = gn2 - gn1

        # Adjust for double counting
        dpure_u = (du >= dg) ? (du - dg) : 0
        dpure_n = (dn >= dgn) ? (dn - dgn) : 0

        active_ticks = dpure_u + dpure_n + dsys + dirq + dsirq + dst + dg + dgn
        total_ticks = active_ticks + didl + dio

        if (total_ticks <= 0) total_ticks = 1

        util_pct = (active_ticks / total_ticks) * 100
        user_pct = (dpure_u / total_ticks) * 100
        nice_pct = (dpure_n / total_ticks) * 100
        sys_pct = (dsys / total_ticks) * 100
        idle_pct = (didl / total_ticks) * 100
        iowait_pct = (dio / total_ticks) * 100
        irq_pct = ((dirq + dsirq) / total_ticks) * 100
        steal_pct = (dst / total_ticks) * 100
        guest_pct = ((dg + dgn) / total_ticks) * 100

        printf "%.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f %d %d\n",
            util_pct, user_pct, nice_pct, sys_pct, idle_pct, iowait_pct, irq_pct, steal_pct, guest_pct, active_ticks, total_ticks
    }'
}

# Collect CPU hardware info
collect_cpu_info() {
    local cpuinfo="${PROC_ROOT}/cpuinfo"
    CPU_MODEL="Unknown"
    CPU_SOCKETS=1
    CPU_LOGICAL=0
    CPU_PHYSICAL=0
    CPU_MHZ="0"

    if [[ -r "$cpuinfo" ]]; then
        CPU_MODEL="$(grep -m1 '^model name' "$cpuinfo" | cut -d: -f2- | sed 's/^[ \t]*//' || echo "Unknown")"
        CPU_LOGICAL="$(grep -c '^processor' "$cpuinfo" || echo 1)"
        if [[ "$CPU_LOGICAL" -eq 0 ]]; then CPU_LOGICAL=1; fi

        # Physical core count calculation
        local phys_ids
        phys_ids="$(grep '^physical id' "$cpuinfo" | sort -u | wc -l || echo 1)"
        if [[ "$phys_ids" -gt 0 ]]; then CPU_SOCKETS="$phys_ids"; fi

        local core_ids
        core_ids="$(grep '^core id' "$cpuinfo" | sort -u | wc -l || echo 0)"
        if [[ "$core_ids" -gt 0 ]]; then
            CPU_PHYSICAL=$(( core_ids * CPU_SOCKETS ))
        else
            CPU_PHYSICAL="$CPU_LOGICAL"
        fi

        CPU_MHZ="$(grep -m1 '^cpu MHz' "$cpuinfo" | awk '{printf "%.1f", $4}' || echo "0")"
    else
        CPU_LOGICAL=1
        CPU_PHYSICAL=1
    fi
}

# Collect Load Average
collect_loadavg() {
    local loadavg_file="${PROC_ROOT}/loadavg"
    LOAD_1M="0.00"
    LOAD_5M="0.00"
    LOAD_15M="0.00"
    LOAD_RUNNABLE=0
    LOAD_TOTAL_ENTITIES=0
    LOAD_LAST_PID=0
    LOAD_1M_PER_CORE="0.00"

    if [[ -r "$loadavg_file" ]]; then
        read -r LOAD_1M LOAD_5M LOAD_15M proc_entities LOAD_LAST_PID < "$loadavg_file" || true
        LOAD_RUNNABLE="$(echo "$proc_entities" | cut -d/ -f1)"
        LOAD_TOTAL_ENTITIES="$(echo "$proc_entities" | cut -d/ -f2)"

        if [[ "$CPU_LOGICAL" -gt 0 ]]; then
            LOAD_1M_PER_CORE="$(awk -v l="$LOAD_1M" -v c="$CPU_LOGICAL" 'BEGIN { printf "%.2f", l / c }')"
        fi
    fi
}

# Collect Pressure Stall Information (PSI)
collect_psi() {
    local psi_cpu="${PROC_ROOT}/pressure/cpu"
    PSI_SOME_10="0.00"
    PSI_SOME_60="0.00"
    PSI_SOME_300="0.00"
    PSI_SOME_TOTAL="0"
    PSI_AVAILABLE=false

    if [[ -r "$psi_cpu" ]]; then
        local some_line
        some_line="$(grep '^some ' "$psi_cpu" || true)"
        if [[ -n "$some_line" ]]; then
            PSI_AVAILABLE=true
            PSI_SOME_10="$(echo "$some_line" | grep -o 'avg10=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_SOME_60="$(echo "$some_line" | grep -o 'avg60=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_SOME_300="$(echo "$some_line" | grep -o 'avg300=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_SOME_TOTAL="$(echo "$some_line" | grep -o 'total=[0-9]*' | cut -d= -f2 || echo "0")"
        fi
    fi
}

main() {
    parse_args "$@"
    validate_inputs

    # Collect CPU hardware info first (needed for logical core normalization)
    collect_cpu_info

    # Collect Utilization via differential sampling
    local stat_line1 stat_line2
    stat_line1="$(get_stat_cpu_line)"

    if compare_num "$SAMPLE_INTERVAL" "gt" "0"; then
        sleep "$SAMPLE_INTERVAL"
        stat_line2="$(get_stat_cpu_line)"
    else
        # Zero-delay: duplicate line to produce 0% delta or read again immediately
        stat_line2="$(get_stat_cpu_line)"
    fi

    local util_result
    util_result="$(calculate_utilization "$stat_line1" "$stat_line2")"

    read -r UTIL_TOTAL UTIL_USER UTIL_NICE UTIL_SYS UTIL_IDLE UTIL_IOWAIT UTIL_IRQ UTIL_STEAL UTIL_GUEST _ _ <<< "$util_result"

    # Collect Load Average and PSI
    collect_loadavg
    collect_psi

    # Evaluate Thresholds
    local status_util="$EXIT_SUCCESS"
    local status_load="$EXIT_SUCCESS"
    local exit_code="$EXIT_SUCCESS"

    if [[ -n "$WARN_UTIL" || -n "$CRIT_UTIL" ]]; then
        eval_threshold "$UTIL_TOTAL" "$WARN_UTIL" "$CRIT_UTIL" "upper" || status_util=$?
    fi

    if [[ -n "$WARN_LOAD" || -n "$CRIT_LOAD" ]]; then
        eval_threshold "$LOAD_1M_PER_CORE" "$WARN_LOAD" "$CRIT_LOAD" "upper" || status_load=$?
    fi

    exit_code="$(aggregate_status "$exit_code" "$status_util")"
    exit_code="$(aggregate_status "$exit_code" "$status_load")"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        local overall_status_str
        overall_status_str="$(status_to_string "$exit_code")"

        cat <<EOF
{
  "timestamp": "$(timestamp_utc)",
  "module": "cpu",
  "status": "${overall_status_str}",
  "exit_code": ${exit_code},
  "hardware": {
    "model": "$(json_escape "$CPU_MODEL")",
    "sockets": ${CPU_SOCKETS},
    "physical_cores": ${CPU_PHYSICAL},
    "logical_processors": ${CPU_LOGICAL},
    "frequency_mhz": ${CPU_MHZ}
  },
  "utilization": {
    "total_pct": ${UTIL_TOTAL},
    "user_pct": ${UTIL_USER},
    "nice_pct": ${UTIL_NICE},
    "system_pct": ${UTIL_SYS},
    "idle_pct": ${UTIL_IDLE},
    "iowait_pct": ${UTIL_IOWAIT},
    "irq_pct": ${UTIL_IRQ},
    "steal_pct": ${UTIL_STEAL},
    "guest_pct": ${UTIL_GUEST},
    "status": "$(status_to_string "$status_util")"
  },
  "load_average": {
    "load_1m": ${LOAD_1M},
    "load_5m": ${LOAD_5M},
    "load_15m": ${LOAD_15M},
    "load_1m_per_core": ${LOAD_1M_PER_CORE},
    "runnable_entities": ${LOAD_RUNNABLE},
    "total_entities": ${LOAD_TOTAL_ENTITIES},
    "status": "$(status_to_string "$status_load")"
  },
  "pressure": {
    "supported": ${PSI_AVAILABLE},
    "some_avg10": ${PSI_SOME_10},
    "some_avg60": ${PSI_SOME_60},
    "some_avg300": ${PSI_SOME_300},
    "total_stalled_us": ${PSI_SOME_TOTAL}
  }
}
EOF
    else
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%sLinux CPU Subsystem Telemetry Report%s  %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$exit_code")"
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "Timestamp: %s | Model: %s\n" "$(timestamp_utc)" "$CPU_MODEL"
        printf "Topology : %d Socket(s) | %d Physical Core(s) | %d Logical Processor(s) (%.1f MHz)\n" \
            "$CPU_SOCKETS" "$CPU_PHYSICAL" "$CPU_LOGICAL" "$CPU_MHZ"
        printf "\n%s--- Differential CPU Utilization (%ds window) ---%s  %s\n" \
            "${COLOR_BOLD}" "$SAMPLE_INTERVAL" "${COLOR_RESET}" "$(format_status_badge "$status_util")"
        printf "  Total Active Utilization : %s%%%s\n" "${COLOR_BOLD}${UTIL_TOTAL}" "${COLOR_RESET}"
        printf "  ├─ Pure User Space       : %6.2f%%   ├─ Pure Idle Task : %6.2f%%\n" "$UTIL_USER" "$UTIL_IDLE"
        printf "  ├─ Kernel System Space   : %6.2f%%   ├─ Disk I/O Wait  : %6.2f%%\n" "$UTIL_SYS" "$UTIL_IOWAIT"
        printf "  ├─ Virtual Guest (KVM)   : %6.2f%%   ├─ IRQ / SoftIRQ  : %6.2f%%\n" "$UTIL_GUEST" "$UTIL_IRQ"
        printf "  └─ Nice Priority         : %6.2f%%   └─ Hypervisor Stl : %6.2f%%\n" "$UTIL_NICE" "$UTIL_STEAL"

        printf "\n%s--- System Load Average ---%s  %s\n" \
            "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$status_load")"
        printf "  1-Min Load: %s (Normalized: %s/core) | 5-Min: %s | 15-Min: %s\n" \
            "$LOAD_1M" "$LOAD_1M_PER_CORE" "$LOAD_5M" "$LOAD_15M"
        printf "  Scheduling Entities: %s runnable / %s total | Last PID: %s\n" \
            "$LOAD_RUNNABLE" "$LOAD_TOTAL_ENTITIES" "$LOAD_LAST_PID"

        printf "\n%s--- Pressure Stall Information (CPU PSI) ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        if [[ "$PSI_AVAILABLE" == "true" ]]; then
            printf "  some avg10=%s%% avg60=%s%% avg300=%s%% | Total Stalled Time: %s us\n" \
                "$PSI_SOME_10" "$PSI_SOME_60" "$PSI_SOME_300" "$PSI_SOME_TOTAL"
        else
            printf "  Pressure Stall Information: Not enabled or unavailable on host\n"
        fi
        printf "%s---------------------------------------------------------------------%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    fi

    exit "$exit_code"
}

main "$@"
