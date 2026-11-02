#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Storage Monitor
# Purpose: Deep filesystem capacity, inode utilization, disk I/O, mount options
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
WARN_DISK=""
CRIT_DISK=""
WARN_INODE=""
CRIT_INODE=""
TARGET_MOUNT=""
INCLUDE_VIRTUAL=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Non-destructive Linux Storage monitoring module. Inspects filesystem capacity,
inode allocation, mount options, and differential disk I/O statistics.

Options:
  -m, --mount PATH        Inspect specific mount point (e.g. /, /boot/efi)
  -i, --interval SEC      Sampling interval in seconds for disk I/O rates (default: 1)
  -w, --warn-disk PCT     Warning threshold for filesystem capacity usage percentage
  -c, --crit-disk PCT     Critical threshold for filesystem capacity usage percentage
  -W, --warn-inode PCT    Warning threshold for inode usage percentage
  -C, --crit-inode PCT    Critical threshold for inode usage percentage
  -v, --include-virtual   Include virtual/pseudo filesystems (tmpfs, devtmpfs, squashfs)
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
            -m|--mount)
                TARGET_MOUNT="$2"
                shift 2
                ;;
            -i|--interval)
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            -w|--warn-disk)
                WARN_DISK="$2"
                shift 2
                ;;
            -c|--crit-disk)
                CRIT_DISK="$2"
                shift 2
                ;;
            -W|--warn-inode)
                WARN_INODE="$2"
                shift 2
                ;;
            -C|--crit-inode)
                CRIT_INODE="$2"
                shift 2
                ;;
            -v|--include-virtual)
                INCLUDE_VIRTUAL=true
                shift
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
    require_command df
    require_command awk

    if ! is_number "$SAMPLE_INTERVAL" || compare_num "$SAMPLE_INTERVAL" "lt" "0"; then
        log_error "Invalid sampling interval: '$SAMPLE_INTERVAL'. Must be a non-negative number."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_DISK" ]] && (! is_number "$WARN_DISK" || compare_num "$WARN_DISK" "lt" "0" || compare_num "$WARN_DISK" "gt" "100"); then
        log_error "Invalid warn-disk: '$WARN_DISK'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_DISK" ]] && (! is_number "$CRIT_DISK" || compare_num "$CRIT_DISK" "lt" "0" || compare_num "$CRIT_DISK" "gt" "100"); then
        log_error "Invalid crit-disk: '$CRIT_DISK'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_DISK" && -n "$CRIT_DISK" ]] && compare_num "$WARN_DISK" "gt" "$CRIT_DISK"; then
        log_error "warn-disk ($WARN_DISK) cannot be greater than crit-disk ($CRIT_DISK)."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_INODE" ]] && (! is_number "$WARN_INODE" || compare_num "$WARN_INODE" "lt" "0" || compare_num "$WARN_INODE" "gt" "100"); then
        log_error "Invalid warn-inode: '$WARN_INODE'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_INODE" ]] && (! is_number "$CRIT_INODE" || compare_num "$CRIT_INODE" "lt" "0" || compare_num "$CRIT_INODE" "gt" "100"); then
        log_error "Invalid crit-inode: '$CRIT_INODE'. Must be between 0 and 100."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_INODE" && -n "$CRIT_INODE" ]] && compare_num "$WARN_INODE" "gt" "$CRIT_INODE"; then
        log_error "warn-inode ($WARN_INODE) cannot be greater than crit-inode ($CRIT_INODE)."
        exit "$EXIT_USAGE"
    fi
}

# Collect mount options from /proc/mounts
# Associates mount_point -> mount_options
get_mount_opts() {
    local mounts_file="${PROC_ROOT}/mounts"
    local mnt="$1"
    if [[ -r "$mounts_file" ]]; then
        awk -v target="$mnt" '$2 == target { print $4; exit }' "$mounts_file"
    else
        echo "unknown"
    fi
}

# Collect Filesystem & Inode capacity
# Populates global array FS_RECORDS
collect_filesystems() {
    local df_cmd=(df -PTk)
    local df_i_cmd=(df -PTi)

    if [[ "$INCLUDE_VIRTUAL" == "false" ]]; then
        df_cmd+=(-x squashfs -x tmpfs -x devtmpfs -x efivarfs)
        df_i_cmd+=(-x squashfs -x tmpfs -x devtmpfs -x efivarfs)
    fi

    local df_output df_i_output
    df_output="$("${df_cmd[@]}" 2>/dev/null || true)"
    df_i_output="$("${df_i_cmd[@]}" 2>/dev/null || true)"

    FS_DATA=()

    # Parse and combine block capacity and inode capacity
    while read -r fs type total_kb used_kb avail_kb cap_str mnt; do
        [[ "$fs" == "Filesystem" ]] && continue
        [[ -z "$fs" ]] && continue

        if [[ -n "$TARGET_MOUNT" && "$mnt" != "$TARGET_MOUNT" ]]; then
            continue
        fi

        local cap_pct="${cap_str%\%}"
        if ! is_number "$cap_pct"; then cap_pct=0; fi

        # Look up corresponding inode info
        local inodes iused ifree icap_pct
        read -r _ _ inodes iused ifree icap_str _ < <(echo "$df_i_output" | awk -v target="$mnt" '$7 == target {print $1, $2, $3, $4, $5, $6, $7}')

        local icap_pct="${icap_str%\%}"
        if ! is_number "$icap_pct"; then icap_pct=0; fi
        if [[ -z "$inodes" || "$inodes" == "-" ]]; then inodes=0; iused=0; ifree=0; icap_pct=0; fi

        local opts
        opts="$(get_mount_opts "$mnt")"
        if [[ -z "$opts" ]]; then opts="rw"; fi

        # Record format: fs|type|total_kb|used_kb|avail_kb|cap_pct|inodes|iused|ifree|icap_pct|mnt|opts
        FS_DATA+=("${fs}|${type}|${total_kb}|${used_kb}|${avail_kb}|${cap_pct}|${inodes}|${iused}|${ifree}|${icap_pct}|${mnt}|${opts}")
    done < <(echo "$df_output")

    if [[ -n "$TARGET_MOUNT" && ${#FS_DATA[@]} -eq 0 ]]; then
        log_error "Target mount point '$TARGET_MOUNT' not found in active mounts."
        exit "$EXIT_ERROR"
    fi
}

# Read snapshot of /proc/diskstats (ignoring loop devices by default)
get_diskstats_snapshot() {
    local diskstats_file="${PROC_ROOT}/diskstats"
    if [[ ! -r "$diskstats_file" ]]; then
        return
    fi
    awk '
    {
        dev = $3
        # Exclude loop, ram, and dm virtual devices unless specified
        if (dev ~ /^loop[0-9]/ || dev ~ /^ram[0-9]/) next
        # Print: dev reads_completed sectors_read time_reading writes_completed sectors_written time_writing io_in_progress time_io
        print dev, $4, $6, $7, $8, $10, $11, $12, $13
    }' "$diskstats_file"
}

# Calculate differential disk I/O rates
collect_disk_io() {
    DISK_IO_DATA=()
    local snap1 snap2
    snap1="$(get_diskstats_snapshot)"

    if compare_num "$SAMPLE_INTERVAL" "gt" "0"; then
        sleep "$SAMPLE_INTERVAL"
        snap2="$(get_diskstats_snapshot)"
    else
        snap2="$snap1"
    fi

    local delta_sec="$SAMPLE_INTERVAL"
    if compare_num "$delta_sec" "le" "0"; then delta_sec=1; fi

    while read -r dev r2 s_r2 _ w2 s_w2 _ cur2 time_io2; do
        [[ -z "$dev" ]] && continue
        # Find matching dev in snap1
        local r1 s_r1 w1 s_w1 time_io1
        read -r _ r1 s_r1 _ w1 s_w1 _ _ time_io1 < <(echo "$snap1" | awk -v target="$dev" '$1 == target')

        if [[ -z "$r1" ]]; then continue; fi

        # Math:
        # read_iops = (r2 - r1) / dt
        # read_kib = (s_r2 - s_r1) * 512 / (1024 * dt)
        # write_iops = (w2 - w1) / dt
        # write_kib = (s_w2 - s_w1) * 512 / (1024 * dt)
        # util_pct = (time_io2 - time_io1) / (10 * dt)
        local stats
        stats="$(awk -v r1="$r1" -v r2="$r2" -v sr1="$s_r1" -v sr2="$s_r2" \
                     -v w1="$w1" -v w2="$w2" -v sw1="$s_w1" -v sw2="$s_w2" \
                     -v t1="$time_io1" -v t2="$time_io2" -v dt="$delta_sec" '
        BEGIN {
            dr = (r2 >= r1) ? (r2 - r1) : 0
            dw = (w2 >= w1) ? (w2 - w1) : 0
            dsr = (sr2 >= sr1) ? (sr2 - sr1) : 0
            dsw = (sw2 >= sw1) ? (sw2 - sw1) : 0
            dtio = (t2 >= t1) ? (t2 - t1) : 0

            read_iops = dr / dt
            write_iops = dw / dt
            read_kib = (dsr * 512) / (1024 * dt)
            write_kib = (dsw * 512) / (1024 * dt)
            io_util = dtio / (10 * dt)
            if (io_util > 100) io_util = 100

            printf "%.1f %.1f %.1f %.1f %.1f\n", read_iops, write_iops, read_kib, write_kib, io_util
        }')"

        read -r R_IOPS W_IOPS R_KIB W_KIB IO_UTIL <<< "$stats"
        DISK_IO_DATA+=("${dev}|${R_IOPS}|${W_IOPS}|${R_KIB}|${W_KIB}|${cur2}|${IO_UTIL}")
    done < <(echo "$snap2")
}

main() {
    parse_args "$@"
    validate_inputs

    collect_filesystems
    collect_disk_io

    # Evaluate Thresholds across filesystems
    local max_status="$EXIT_SUCCESS"
    for item in "${FS_DATA[@]}"; do
        IFS='|' read -r _ _ _ _ _ cap_pct _ _ _ icap_pct _ _ <<< "$item"
        local status_disk="$EXIT_SUCCESS"
        local status_inode="$EXIT_SUCCESS"

        if [[ -n "$WARN_DISK" || -n "$CRIT_DISK" ]]; then
            eval_threshold "$cap_pct" "$WARN_DISK" "$CRIT_DISK" "upper" || status_disk=$?
        fi

        if [[ -n "$WARN_INODE" || -n "$CRIT_INODE" ]]; then
            eval_threshold "$icap_pct" "$WARN_INODE" "$CRIT_INODE" "upper" || status_inode=$?
        fi

        max_status="$(aggregate_status "$max_status" "$status_disk")"
        max_status="$(aggregate_status "$max_status" "$status_inode")"
    done

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        local overall_status_str
        overall_status_str="$(status_to_string "$max_status")"

        printf "{\n"
        printf "  \"timestamp\": \"%s\",\n" "$(timestamp_utc)"
        printf "  \"module\": \"storage\",\n"
        printf "  \"status\": \"%s\",\n" "$overall_status_str"
        printf "  \"exit_code\": %d,\n" "$max_status"
        printf "  \"filesystems\": [\n"

        local first_fs=true
        for item in "${FS_DATA[@]}"; do
            IFS='|' read -r fs type total_kb used_kb avail_kb cap_pct inodes iused ifree icap_pct mnt opts <<< "$item"

            local fs_status="$EXIT_SUCCESS"
            if [[ -n "$WARN_DISK" || -n "$CRIT_DISK" ]]; then
                eval_threshold "$cap_pct" "$WARN_DISK" "$CRIT_DISK" "upper" || fs_status=$?
            fi

            if [[ "$first_fs" == "false" ]]; then printf ",\n"; fi
            first_fs=false

            cat <<EOF
    {
      "filesystem": "$(json_escape "$fs")",
      "type": "$(json_escape "$type")",
      "mount_point": "$(json_escape "$mnt")",
      "mount_options": "$(json_escape "$opts")",
      "total_kb": ${total_kb},
      "used_kb": ${used_kb},
      "available_kb": ${avail_kb},
      "used_pct": ${cap_pct},
      "inodes_total": ${inodes},
      "inodes_used": ${iused},
      "inodes_free": ${ifree},
      "inodes_used_pct": ${icap_pct},
      "status": "$(status_to_string "$fs_status")"
    }
EOF
        done
        printf "\n  ],\n"
        printf "  \"disk_io\": [\n"

        local first_io=true
        for io in "${DISK_IO_DATA[@]}"; do
            IFS='|' read -r dev r_iops w_iops r_kib w_kib in_prog util_pct <<< "$io"
            if [[ "$first_io" == "false" ]]; then printf ",\n"; fi
            first_io=false

            cat <<EOF
    {
      "device": "$(json_escape "$dev")",
      "read_iops": ${r_iops},
      "write_iops": ${w_iops},
      "read_kib_per_sec": ${r_kib},
      "write_kib_per_sec": ${w_kib},
      "io_in_progress": ${in_prog},
      "io_utilization_pct": ${util_pct}
    }
EOF
        done
        printf "\n  ]\n"
        printf "}\n"

    else
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%sLinux Storage Subsystem Telemetry Report%s  %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$max_status")"
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "Timestamp: %s\n\n" "$(timestamp_utc)"

        printf "%s--- Active Filesystem Capacity & Inodes ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%-22s %-7s %10s %10s %10s %6s %7s %-16s %s\n" \
            "Filesystem" "Type" "Size" "Used" "Avail" "Use%" "Inodes%" "Mount Point" "Status"
        printf "%s\n" "------------------------------------------------------------------------------------------------------"

        for item in "${FS_DATA[@]}"; do
            IFS='|' read -r fs type total_kb used_kb avail_kb cap_pct _ _ _ icap_pct mnt opts <<< "$item"

            local fs_status="$EXIT_SUCCESS"
            if [[ -n "$WARN_DISK" || -n "$CRIT_DISK" ]]; then
                eval_threshold "$cap_pct" "$WARN_DISK" "$CRIT_DISK" "upper" || fs_status=$?
            fi

            printf "%-22s %-7s %10s %10s %10s %5.1f%% %6.1f%% %-16s %s\n" \
                "${fs:0:22}" "$type" \
                "$(kb_to_human "$total_kb")" \
                "$(kb_to_human "$used_kb")" \
                "$(kb_to_human "$avail_kb")" \
                "$cap_pct" "$icap_pct" "${mnt:0:16}" "$(format_status_badge "$fs_status")"
            printf "  └─ Options: %s\n" "$opts"
        done

        if [[ ${#DISK_IO_DATA[@]} -gt 0 ]]; then
            printf "\n%s--- Physical Block Device I/O Rates (%ds window) ---%s\n" \
                "${COLOR_BOLD}" "$SAMPLE_INTERVAL" "${COLOR_RESET}"
            printf "%-14s %10s %10s %12s %12s %10s %8s\n" \
                "Device" "Read r/s" "Write w/s" "Read KiB/s" "Write KiB/s" "In-Flight" "%util"
            printf "%s\n" "----------------------------------------------------------------------------------"

            for io in "${DISK_IO_DATA[@]}"; do
                IFS='|' read -r dev r_iops w_iops r_kib w_kib in_prog util_pct <<< "$io"
                printf "%-14s %10.1f %10.1f %12.1f %12.1f %10d %7.1f%%\n" \
                    "$dev" "$r_iops" "$w_iops" "$r_kib" "$w_kib" "$in_prog" "$util_pct"
            done
        fi
        printf "%s---------------------------------------------------------------------%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    fi

    exit "$max_status"
}

main "$@"
