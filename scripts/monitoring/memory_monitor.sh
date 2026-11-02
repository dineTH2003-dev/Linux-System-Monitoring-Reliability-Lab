#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Memory Monitor
# Purpose: Deep memory capacity, allocation, swap rate, and PSI pressure metrics
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
WARN_MEM=""
CRIT_MEM=""
WARN_SWAP=""
CRIT_SWAP=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Non-destructive Linux Memory monitoring module. Inspects physical memory
allocations, swap utilization, differential paging rates, and memory PSI.

Options:
  -i, --interval SEC      Sampling interval in seconds for paging rate delta (default: 1)
  -w, --warn-mem PCT      Warning threshold for RAM utilization percentage
  -c, --crit-mem PCT      Critical threshold for RAM utilization percentage
  -W, --warn-swap PCT     Warning threshold for Swap utilization percentage
  -C, --crit-swap PCT     Critical threshold for Swap utilization percentage
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interval)
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            -w|--warn-mem)
                WARN_MEM="$2"
                shift 2
                ;;
            -c|--crit-mem)
                CRIT_MEM="$2"
                shift 2
                ;;
            -W|--warn-swap)
                WARN_SWAP="$2"
                shift 2
                ;;
            -C|--crit-swap)
                CRIT_SWAP="$2"
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

    if [[ -n "$WARN_MEM" ]] && (! is_number "$WARN_MEM" || compare_num "$WARN_MEM" "lt" "0" || compare_num "$WARN_MEM" "gt" "100"); then
        log_error "Invalid warn-mem: '$WARN_MEM'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_MEM" ]] && (! is_number "$CRIT_MEM" || compare_num "$CRIT_MEM" "lt" "0" || compare_num "$CRIT_MEM" "gt" "100"); then
        log_error "Invalid crit-mem: '$CRIT_MEM'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_MEM" && -n "$CRIT_MEM" ]] && compare_num "$WARN_MEM" "gt" "$CRIT_MEM"; then
        log_error "warn-mem ($WARN_MEM) cannot be greater than crit-mem ($CRIT_MEM)."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_SWAP" ]] && (! is_number "$WARN_SWAP" || compare_num "$WARN_SWAP" "lt" "0" || compare_num "$WARN_SWAP" "gt" "100"); then
        log_error "Invalid warn-swap: '$WARN_SWAP'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_SWAP" ]] && (! is_number "$CRIT_SWAP" || compare_num "$CRIT_SWAP" "lt" "0" || compare_num "$CRIT_SWAP" "gt" "100"); then
        log_error "Invalid crit-swap: '$CRIT_SWAP'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_SWAP" && -n "$CRIT_SWAP" ]] && compare_num "$WARN_SWAP" "gt" "$CRIT_SWAP"; then
        log_error "warn-swap ($WARN_SWAP) cannot be greater than crit-swap ($CRIT_SWAP)."
        exit "$EXIT_USAGE"
    fi
}

# Collect meminfo fields
collect_meminfo() {
    local meminfo="${PROC_ROOT}/meminfo"
    if [[ ! -r "$meminfo" ]]; then
        log_error "Cannot read $meminfo"
        exit "$EXIT_ERROR"
    fi

    # Read values in kB
    MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' "$meminfo" || echo 0)
    MEM_FREE_KB=$(awk '/^MemFree:/ {print $2}' "$meminfo" || echo 0)
    MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' "$meminfo" || echo 0)
    MEM_BUFFERS_KB=$(awk '/^Buffers:/ {print $2}' "$meminfo" || echo 0)
    MEM_CACHED_KB=$(awk '/^Cached:/ {print $2}' "$meminfo" || echo 0)
    MEM_SHMEM_KB=$(awk '/^Shmem:/ {print $2}' "$meminfo" || echo 0)
    MEM_SRECLAIM_KB=$(awk '/^SReclaimable:/ {print $2}' "$meminfo" || echo 0)
    MEM_DIRTY_KB=$(awk '/^Dirty:/ {print $2}' "$meminfo" || echo 0)

    SWAP_TOTAL_KB=$(awk '/^SwapTotal:/ {print $2}' "$meminfo" || echo 0)
    SWAP_FREE_KB=$(awk '/^SwapFree:/ {print $2}' "$meminfo" || echo 0)

    # Standard Linux memory math: Used = MemTotal - MemAvailable
    if compare_num "$MEM_AVAIL_KB" "gt" "0"; then
        MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
    else
        MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_FREE_KB ))
    fi

    # Buffer/Cache sum (Buffers + Cached + SReclaimable - Shmem)
    MEM_BUFF_CACHE_KB=$(( MEM_BUFFERS_KB + MEM_CACHED_KB + MEM_SRECLAIM_KB ))

    # Swap Used
    SWAP_USED_KB=$(( SWAP_TOTAL_KB - SWAP_FREE_KB ))

    # Percentages
    if [[ "$MEM_TOTAL_KB" -gt 0 ]]; then
        MEM_USED_PCT=$(awk -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" 'BEGIN { printf "%.2f", (u / t) * 100 }')
        MEM_AVAIL_PCT=$(awk -v a="$MEM_AVAIL_KB" -v t="$MEM_TOTAL_KB" 'BEGIN { printf "%.2f", (a / t) * 100 }')
    else
        MEM_USED_PCT="0.00"
        MEM_AVAIL_PCT="0.00"
    fi

    if [[ "$SWAP_TOTAL_KB" -gt 0 ]]; then
        SWAP_USED_PCT=$(awk -v u="$SWAP_USED_KB" -v t="$SWAP_TOTAL_KB" 'BEGIN { printf "%.2f", (u / t) * 100 }')
    else
        SWAP_USED_PCT="0.00"
    fi
}

# Read vmstat counters: pswpin, pswpout, pgmajfault
get_vmstat_counters() {
    local vmstat="${PROC_ROOT}/vmstat"
    if [[ ! -r "$vmstat" ]]; then
        echo "0 0 0"
        return
    fi
    awk '
    /^pswpin/ { in_cnt = $2 }
    /^pswpout/ { out_cnt = $2 }
    /^pgmajfault/ { maj_cnt = $2 }
    END { printf "%d %d %d\n", in_cnt, out_cnt, maj_cnt }
    ' "$vmstat"
}

# Collect Memory PSI
collect_memory_psi() {
    local psi_mem="${PROC_ROOT}/pressure/memory"
    PSI_SOME_10="0.00"
    PSI_SOME_60="0.00"
    PSI_SOME_300="0.00"
    PSI_SOME_TOTAL="0"
    PSI_FULL_10="0.00"
    PSI_FULL_60="0.00"
    PSI_FULL_300="0.00"
    PSI_FULL_TOTAL="0"
    PSI_AVAILABLE=false

    if [[ -r "$psi_mem" ]]; then
        local some_line full_line
        some_line="$(grep '^some ' "$psi_mem" || true)"
        full_line="$(grep '^full ' "$psi_mem" || true)"

        if [[ -n "$some_line" ]]; then
            PSI_AVAILABLE=true
            PSI_SOME_10="$(echo "$some_line" | grep -o 'avg10=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_SOME_60="$(echo "$some_line" | grep -o 'avg60=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_SOME_300="$(echo "$some_line" | grep -o 'avg300=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_SOME_TOTAL="$(echo "$some_line" | grep -o 'total=[0-9]*' | cut -d= -f2 || echo "0")"
        fi

        if [[ -n "$full_line" ]]; then
            PSI_FULL_10="$(echo "$full_line" | grep -o 'avg10=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_FULL_60="$(echo "$full_line" | grep -o 'avg60=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_FULL_300="$(echo "$full_line" | grep -o 'avg300=[0-9.]*' | cut -d= -f2 || echo "0.00")"
            PSI_FULL_TOTAL="$(echo "$full_line" | grep -o 'total=[0-9]*' | cut -d= -f2 || echo "0")"
        fi
    fi
}

main() {
    parse_args "$@"
    validate_inputs

    collect_meminfo

    # Swap rate sampling via differential vmstat
    read -r VMSTAT_IN1 VMSTAT_OUT1 VMSTAT_MAJ1 < <(get_vmstat_counters)

    if compare_num "$SAMPLE_INTERVAL" "gt" "0"; then
        sleep "$SAMPLE_INTERVAL"
        read -r VMSTAT_IN2 VMSTAT_OUT2 VMSTAT_MAJ2 < <(get_vmstat_counters)
    else
        VMSTAT_IN2="$VMSTAT_IN1"
        VMSTAT_OUT2="$VMSTAT_OUT1"
        VMSTAT_MAJ2="$VMSTAT_MAJ1"
    fi

    # Calculate rates (pages/sec and KiB/sec)
    # 1 page in x86_64 = 4096 bytes = 4 KiB
    local delta_sec="$SAMPLE_INTERVAL"
    if compare_num "$delta_sec" "le" "0"; then delta_sec="1"; fi

    SWAP_IN_PAGES_RATE=$(awk -v v1="$VMSTAT_IN1" -v v2="$VMSTAT_IN2" -v dt="$delta_sec" 'BEGIN { printf "%.1f", (v2 - v1) / dt }')
    SWAP_OUT_PAGES_RATE=$(awk -v v1="$VMSTAT_OUT1" -v v2="$VMSTAT_OUT2" -v dt="$delta_sec" 'BEGIN { printf "%.1f", (v2 - v1) / dt }')
    MAJOR_FAULTS_RATE=$(awk -v v1="$VMSTAT_MAJ1" -v v2="$VMSTAT_MAJ2" -v dt="$delta_sec" 'BEGIN { printf "%.1f", (v2 - v1) / dt }')

    SWAP_IN_KIB_RATE=$(awk -v p="$SWAP_IN_PAGES_RATE" 'BEGIN { printf "%.1f", p * 4 }')
    SWAP_OUT_KIB_RATE=$(awk -v p="$SWAP_OUT_PAGES_RATE" 'BEGIN { printf "%.1f", p * 4 }')

    collect_memory_psi

    # Evaluate Thresholds
    local status_mem="$EXIT_SUCCESS"
    local status_swap="$EXIT_SUCCESS"
    local exit_code="$EXIT_SUCCESS"

    if [[ -n "$WARN_MEM" || -n "$CRIT_MEM" ]]; then
        eval_threshold "$MEM_USED_PCT" "$WARN_MEM" "$CRIT_MEM" "upper" || status_mem=$?
    fi

    if [[ -n "$WARN_SWAP" || -n "$CRIT_SWAP" ]]; then
        eval_threshold "$SWAP_USED_PCT" "$WARN_SWAP" "$CRIT_SWAP" "upper" || status_swap=$?
    fi

    exit_code="$(aggregate_status "$exit_code" "$status_mem")"
    exit_code="$(aggregate_status "$exit_code" "$status_swap")"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        local overall_status_str
        overall_status_str="$(status_to_string "$exit_code")"

        cat <<EOF
{
  "timestamp": "$(timestamp_utc)",
  "module": "memory",
  "status": "${overall_status_str}",
  "exit_code": ${exit_code},
  "ram": {
    "total_kb": ${MEM_TOTAL_KB},
    "used_kb": ${MEM_USED_KB},
    "free_kb": ${MEM_FREE_KB},
    "available_kb": ${MEM_AVAIL_KB},
    "buffers_kb": ${MEM_BUFFERS_KB},
    "cached_kb": ${MEM_CACHED_KB},
    "shmem_kb": ${MEM_SHMEM_KB},
    "sreclaimable_kb": ${MEM_SRECLAIM_KB},
    "dirty_kb": ${MEM_DIRTY_KB},
    "used_pct": ${MEM_USED_PCT},
    "available_pct": ${MEM_AVAIL_PCT},
    "status": "$(status_to_string "$status_mem")"
  },
  "swap": {
    "total_kb": ${SWAP_TOTAL_KB},
    "used_kb": ${SWAP_USED_KB},
    "free_kb": ${SWAP_FREE_KB},
    "used_pct": ${SWAP_USED_PCT},
    "status": "$(status_to_string "$status_swap")"
  },
  "swap_activity": {
    "sample_interval_sec": ${SAMPLE_INTERVAL},
    "swap_in_pages_per_sec": ${SWAP_IN_PAGES_RATE},
    "swap_out_pages_per_sec": ${SWAP_OUT_PAGES_RATE},
    "swap_in_kib_per_sec": ${SWAP_IN_KIB_RATE},
    "swap_out_kib_per_sec": ${SWAP_OUT_KIB_RATE},
    "major_faults_per_sec": ${MAJOR_FAULTS_RATE},
    "cumulative_pswpin": ${VMSTAT_IN2},
    "cumulative_pswpout": ${VMSTAT_OUT2},
    "cumulative_pgmajfault": ${VMSTAT_MAJ2}
  },
  "pressure": {
    "supported": ${PSI_AVAILABLE},
    "some": {
      "avg10": ${PSI_SOME_10},
      "avg60": ${PSI_SOME_60},
      "avg300": ${PSI_SOME_300},
      "total_us": ${PSI_SOME_TOTAL}
    },
    "full": {
      "avg10": ${PSI_FULL_10},
      "avg60": ${PSI_FULL_60},
      "avg300": ${PSI_FULL_300},
      "total_us": ${PSI_FULL_TOTAL}
    }
  }
}
EOF
    else
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%sLinux Memory & Swap Subsystem Telemetry Report%s  %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$exit_code")"
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "Timestamp: %s\n" "$(timestamp_utc)"

        printf "\n%s--- Physical RAM Allocation ---%s  %s\n" \
            "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$status_mem")"
        printf "  Total Physical RAM : %10s (%d kB)\n" "$(kb_to_human "$MEM_TOTAL_KB")" "$MEM_TOTAL_KB"
        printf "  Used RAM           : %10s (%d kB, %s%%)\n" "$(kb_to_human "$MEM_USED_KB")" "$MEM_USED_KB" "$MEM_USED_PCT"
        printf "  Available RAM      : %10s (%d kB, %s%%)\n" "$(kb_to_human "$MEM_AVAIL_KB")" "$MEM_AVAIL_KB" "$MEM_AVAIL_PCT"
        printf "  Unallocated Free   : %10s (%d kB)\n" "$(kb_to_human "$MEM_FREE_KB")" "$MEM_FREE_KB"
        printf "  Buffers & PageCache: %10s (%d kB)\n" "$(kb_to_human "$MEM_BUFF_CACHE_KB")" "$MEM_BUFF_CACHE_KB"
        printf "  Shared Memory/tmpfs: %10s (%d kB) | Dirty: %s\n" \
            "$(kb_to_human "$MEM_SHMEM_KB")" "$MEM_SHMEM_KB" "$(kb_to_human "$MEM_DIRTY_KB")"

        printf "\n%s--- Swap Subsystem Capacity ---%s  %s\n" \
            "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$status_swap")"
        printf "  Total Swap Space   : %10s (%d kB)\n" "$(kb_to_human "$SWAP_TOTAL_KB")" "$SWAP_TOTAL_KB"
        printf "  Used Swap Space    : %10s (%d kB, %s%%)\n" "$(kb_to_human "$SWAP_USED_KB")" "$SWAP_USED_KB" "$SWAP_USED_PCT"
        printf "  Free Swap Space    : %10s (%d kB)\n" "$(kb_to_human "$SWAP_FREE_KB")" "$SWAP_FREE_KB"

        printf "\n%s--- Swap Activity & Paging Rates (%ds window) ---%s\n" \
            "${COLOR_BOLD}" "$SAMPLE_INTERVAL" "${COLOR_RESET}"
        printf "  Swap In Rate       : %6.1f pages/s (%s/s)\n" "$SWAP_IN_PAGES_RATE" "$(bytes_to_human "$(( ${SWAP_IN_KIB_RATE%.*} * 1024 ))")"
        printf "  Swap Out Rate      : %6.1f pages/s (%s/s)\n" "$SWAP_OUT_PAGES_RATE" "$(bytes_to_human "$(( ${SWAP_OUT_KIB_RATE%.*} * 1024 ))")"
        printf "  Major Page Faults  : %6.1f faults/s (Disk reads for code/swap)\n" "$MAJOR_FAULTS_RATE"
        printf "  Cumulative History : pswpin=%s pages | pswpout=%s pages | pgmajfault=%s\n" \
            "$VMSTAT_IN2" "$VMSTAT_OUT2" "$VMSTAT_MAJ2"

        printf "\n%s--- Pressure Stall Information (Memory PSI) ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        if [[ "$PSI_AVAILABLE" == "true" ]]; then
            printf "  some: avg10=%s%% avg60=%s%% avg300=%s%% (Total: %s us)\n" \
                "$PSI_SOME_10" "$PSI_SOME_60" "$PSI_SOME_300" "$PSI_SOME_TOTAL"
            printf "  full: avg10=%s%% avg60=%s%% avg300=%s%% (Total: %s us)\n" \
                "$PSI_FULL_10" "$PSI_FULL_60" "$PSI_FULL_300" "$PSI_FULL_TOTAL"
        else
            printf "  Pressure Stall Information: Not enabled or unavailable on host\n"
        fi
        printf "%s---------------------------------------------------------------------%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    fi

    exit "$exit_code"
}

main "$@"
