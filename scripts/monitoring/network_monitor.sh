#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Network Monitor
# Purpose: Deep network interface status, throughput rates, errors/drops, ports
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
WARN_ERRORS=""
CRIT_ERRORS=""
TARGET_IFACE=""
PORTS_ONLY=false
STATS_ONLY=false
IFACE_DATA=()
PORTS_DATA=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Non-destructive Linux Network monitoring module. Inspects network interfaces,
operational states, RX/TX throughput rates, errors/drops, and listening ports.

Options:
  -I, --interface IFACE   Monitor a specific network interface (e.g. wlo1, lo)
  -i, --interval SEC      Sampling interval in seconds for throughput rates (default: 1)
  -w, --warn-errors NUM   Warning threshold for total RX/TX errors and drops rate
  -c, --crit-errors NUM   Critical threshold for total RX/TX errors and drops rate
  -p, --ports-only        Show only active listening sockets (ports audit)
  -s, --stats-only        Show only interface metrics (skip listening ports)
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
            -I|--interface)
                TARGET_IFACE="$2"
                shift 2
                ;;
            -i|--interval)
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            -w|--warn-errors)
                WARN_ERRORS="$2"
                shift 2
                ;;
            -c|--crit-errors)
                CRIT_ERRORS="$2"
                shift 2
                ;;
            -p|--ports-only)
                PORTS_ONLY=true
                shift
                ;;
            -s|--stats-only)
                STATS_ONLY=true
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
    if ! is_number "$SAMPLE_INTERVAL" || compare_num "$SAMPLE_INTERVAL" "lt" "0"; then
        log_error "Invalid sampling interval: '$SAMPLE_INTERVAL'. Must be a non-negative number."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_ERRORS" ]] && (! is_number "$WARN_ERRORS" || compare_num "$WARN_ERRORS" "lt" "0"); then
        log_error "Invalid warn-errors: '$WARN_ERRORS'. Must be a non-negative number."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$CRIT_ERRORS" ]] && (! is_number "$CRIT_ERRORS" || compare_num "$CRIT_ERRORS" "lt" "0"); then
        log_error "Invalid crit-errors: '$CRIT_ERRORS'. Must be a non-negative number."
        exit "$EXIT_USAGE"
    fi

    if [[ -n "$WARN_ERRORS" && -n "$CRIT_ERRORS" ]] && compare_num "$WARN_ERRORS" "gt" "$CRIT_ERRORS"; then
        log_error "warn-errors ($WARN_ERRORS) cannot be greater than crit-errors ($CRIT_ERRORS)."
        exit "$EXIT_USAGE"
    fi

    if [[ "$PORTS_ONLY" == "true" && "$STATS_ONLY" == "true" ]]; then
        log_error "Cannot specify both --ports-only and --stats-only."
        exit "$EXIT_USAGE"
    fi
}

# Read interface stats snapshot from /proc/net/dev
get_net_dev_snapshot() {
    local net_dev="${PROC_ROOT}/net/dev"
    if [[ ! -r "$net_dev" ]]; then
        return
    fi
    awk -v target="$TARGET_IFACE" '
    NR > 2 {
        if ($0 ~ /:/) {
            split($0, parts, ":")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[1])
            ifname = parts[1]

            if (target != "" && ifname != target) next

            # Split fields in values part
            split(parts[2], val)
            # val[1]: rx_bytes, val[2]: rx_packets, val[3]: rx_errs, val[4]: rx_drop
            # val[9]: tx_bytes, val[10]: tx_packets, val[11]: tx_errs, val[12]: tx_drop
            print ifname, val[1], val[2], val[3], val[4], val[9], val[10], val[11], val[12]
        }
    }' "$net_dev"
}

# Get interface operstate and mtu from /sys/class/net
get_iface_metadata() {
    local ifname="$1"
    local sys_net="${SYS_ROOT}/class/net/${ifname}"
    local operstate="unknown"
    local mtu="unknown"

    if [[ -r "${sys_net}/operstate" ]]; then
        operstate="$(cat "${sys_net}/operstate" 2>/dev/null || echo "unknown")"
    fi
    if [[ -r "${sys_net}/mtu" ]]; then
        mtu="$(cat "${sys_net}/mtu" 2>/dev/null || echo "unknown")"
    fi
    echo "${operstate}|${mtu}"
}

# Collect interface statistics & calculate differential throughput
collect_network_interfaces() {
    IFACE_DATA=()
    local snap1 snap2
    snap1="$(get_net_dev_snapshot)"

    if compare_num "$SAMPLE_INTERVAL" "gt" "0"; then
        sleep "$SAMPLE_INTERVAL"
        snap2="$(get_net_dev_snapshot)"
    else
        snap2="$snap1"
    fi

    local delta_sec="$SAMPLE_INTERVAL"
    if compare_num "$delta_sec" "le" "0"; then delta_sec=1; fi

    while read -r ifname rb2 rp2 re2 rd2 tb2 tp2 te2 td2; do
        [[ -z "$ifname" ]] && continue

        local rb1 rp1 re1 rd1 tb1 tp1 te1 td1
        read -r _ rb1 rp1 re1 rd1 tb1 tp1 te1 td1 < <(echo "$snap1" | awk -v target="$ifname" '$1 == target')
        if [[ -z "$rb1" ]]; then
            rb1="$rb2"; rp1="$rp2"; re1="$re2"; rd1="$rd2"
            tb1="$tb2"; tp1="$tp2"; te1="$te2"; td1="$td2"
        fi

        local rates
        rates="$(awk -v rb1="$rb1" -v rb2="$rb2" -v rp1="$rp1" -v rp2="$rp2" \
                     -v tb1="$tb1" -v tb2="$tb2" -v tp1="$tp1" -v tp2="$tp2" \
                     -v re1="$re1" -v re2="$re2" -v rd1="$rd1" -v rd2="$rd2" \
                     -v te1="$te1" -v te2="$te2" -v td1="$td1" -v td2="$td2" \
                     -v dt="$delta_sec" '
        BEGIN {
            drb = (rb2 >= rb1) ? (rb2 - rb1) : 0
            dtb = (tb2 >= tb1) ? (tb2 - tb1) : 0
            drp = (rp2 >= rp1) ? (rp2 - rp1) : 0
            dtp = (tp2 >= tp1) ? (tp2 - tp1) : 0

            dre = (re2 >= re1) ? (re2 - re1) : 0
            dte = (te2 >= te1) ? (te2 - te1) : 0
            drd = (rd2 >= rd1) ? (rd2 - rd1) : 0
            dtd = (td2 >= td1) ? (td2 - td1) : 0

            rx_kib = (drb / 1024) / dt
            tx_kib = (dtb / 1024) / dt
            rx_pps = drp / dt
            tx_pps = dtp / dt
            err_drop_rate = (dre + dte + drd + dtd) / dt

            printf "%.1f %.1f %.1f %.1f %.1f\n", rx_kib, tx_kib, rx_pps, tx_pps, err_drop_rate
        }')"

        read -r RX_KIB TX_KIB RX_PPS TX_PPS ERR_RATE <<< "$rates"

        local meta operstate mtu
        meta="$(get_iface_metadata "$ifname")"
        operstate="${meta%|*}"
        mtu="${meta#*|}"

        # Record: ifname|operstate|mtu|rx_kib|tx_kib|rx_pps|tx_pps|rb2|tb2|re2|rd2|te2|td2|err_rate
        IFACE_DATA+=("${ifname}|${operstate}|${mtu}|${RX_KIB}|${TX_KIB}|${RX_PPS}|${TX_PPS}|${rb2}|${tb2}|${re2}|${rd2}|${te2}|${td2}|${ERR_RATE}")
    done < <(echo "$snap2")

    if [[ -n "$TARGET_IFACE" && ${#IFACE_DATA[@]} -eq 0 ]]; then
        log_error "Interface '$TARGET_IFACE' not found in active network devices."
        exit "$EXIT_ERROR"
    fi
}

# Collect listening sockets using ss
collect_listening_ports() {
    PORTS_DATA=()
    if ! command -v ss >/dev/null 2>&1; then
        return
    fi

    local ss_output
    ss_output="$(ss -tulnH 2>/dev/null || true)"

    while read -r proto state _ _ local_addr peer_addr; do
        [[ -z "$proto" ]] && continue
        # Extract port (everything after last colon)
        local port="${local_addr##*:}"
        local addr="${local_addr%:*}"

        PORTS_DATA+=("${proto}|${state}|${addr}|${port}|${peer_addr}")
    done < <(echo "$ss_output")
}

main() {
    parse_args "$@"
    validate_inputs

    if [[ "$PORTS_ONLY" == "false" ]]; then
        collect_network_interfaces
    fi

    if [[ "$STATS_ONLY" == "false" ]]; then
        collect_listening_ports
    fi

    # Evaluate Thresholds across interfaces (error/drop rate)
    local max_status="$EXIT_SUCCESS"
    for item in "${IFACE_DATA[@]}"; do
        IFS='|' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ err_rate <<< "$item"
        local status_err="$EXIT_SUCCESS"

        if [[ -n "$WARN_ERRORS" || -n "$CRIT_ERRORS" ]]; then
            eval_threshold "$err_rate" "$WARN_ERRORS" "$CRIT_ERRORS" "upper" || status_err=$?
        fi
        max_status="$(aggregate_status "$max_status" "$status_err")"
    done

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        local overall_status_str
        overall_status_str="$(status_to_string "$max_status")"

        printf "{\n"
        printf "  \"timestamp\": \"%s\",\n" "$(timestamp_utc)"
        printf "  \"module\": \"network\",\n"
        printf "  \"status\": \"%s\",\n" "$overall_status_str"
        printf "  \"exit_code\": %d,\n" "$max_status"
        if [[ ${#IFACE_DATA[@]} -eq 0 ]]; then
            printf "  \"interfaces\": [],\n"
        else
            printf "  \"interfaces\": [\n"
            local first_iface=true
            for item in "${IFACE_DATA[@]}"; do
                IFS='|' read -r ifname operstate mtu rx_kib tx_kib rx_pps tx_pps rx_b tx_b rx_e rx_d tx_e tx_d err_rate <<< "$item"

                local iface_status="$EXIT_SUCCESS"
                if [[ -n "$WARN_ERRORS" || -n "$CRIT_ERRORS" ]]; then
                    eval_threshold "$err_rate" "$WARN_ERRORS" "$CRIT_ERRORS" "upper" || iface_status=$?
                fi

                if [[ "$first_iface" == "false" ]]; then printf ",\n"; fi
                first_iface=false

                cat <<EOF
    {
      "interface": "$(json_escape "$ifname")",
      "operstate": "$(json_escape "$operstate")",
      "mtu": "$(json_escape "$mtu")",
      "throughput": {
        "rx_kib_per_sec": ${rx_kib},
        "tx_kib_per_sec": ${tx_kib},
        "rx_packets_per_sec": ${rx_pps},
        "tx_packets_per_sec": ${tx_pps}
      },
      "cumulative": {
        "rx_bytes": ${rx_b},
        "tx_bytes": ${tx_b},
        "rx_errors": ${rx_e},
        "rx_dropped": ${rx_d},
        "tx_errors": ${tx_e},
        "tx_dropped": ${tx_d}
      },
      "errors_per_sec": ${err_rate},
      "status": "$(status_to_string "$iface_status")"
    }
EOF
            done
            printf "\n  ],\n"
        fi

        if [[ ${#PORTS_DATA[@]} -eq 0 ]]; then
            printf "  \"listening_ports\": []\n"
        else
            printf "  \"listening_ports\": [\n"
            local first_p=true
            for p in "${PORTS_DATA[@]}"; do
                IFS='|' read -r proto state addr port peer <<< "$p"
                if [[ "$first_p" == "false" ]]; then printf ",\n"; fi
                first_p=false

                cat <<EOF
    {
      "protocol": "$(json_escape "$proto")",
      "state": "$(json_escape "$state")",
      "local_address": "$(json_escape "$addr")",
      "port": "$(json_escape "$port")",
      "peer_address": "$(json_escape "$peer")"
    }
EOF
            done
            printf "\n  ]\n"
        fi
        printf "}\n"

    else
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%sLinux Network Subsystem Telemetry Report%s  %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$max_status")"
        printf "%s=====================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "Timestamp: %s\n\n" "$(timestamp_utc)"

        if [[ "$PORTS_ONLY" == "false" ]]; then
            printf "%s--- Active Network Interfaces (%ds sampling window) ---%s\n" \
                "${COLOR_BOLD}" "$SAMPLE_INTERVAL" "${COLOR_RESET}"
            printf "%-10s %-8s %-6s %11s %11s %9s %9s %12s %s\n" \
                "Iface" "State" "MTU" "RX KiB/s" "TX KiB/s" "RX pps" "TX pps" "Err+Drop/s" "Status"
            printf "%s\n" "------------------------------------------------------------------------------------------------"

            for item in "${IFACE_DATA[@]}"; do
                IFS='|' read -r ifname operstate mtu rx_kib tx_kib rx_pps tx_pps rx_b tx_b rx_e rx_d tx_e tx_d err_rate <<< "$item"

                local iface_status="$EXIT_SUCCESS"
                if [[ -n "$WARN_ERRORS" || -n "$CRIT_ERRORS" ]]; then
                    eval_threshold "$err_rate" "$WARN_ERRORS" "$CRIT_ERRORS" "upper" || iface_status=$?
                fi

                printf "%-10s %-8s %-6s %11.1f %11.1f %9.1f %9.1f %12.1f %s\n" \
                    "$ifname" "$operstate" "$mtu" "$rx_kib" "$tx_kib" "$rx_pps" "$tx_pps" "$err_rate" "$(format_status_badge "$iface_status")"
                printf "  └─ Totals: RX: %s (%s errors, %s dropped) | TX: %s (%s errors, %s dropped)\n" \
                    "$(bytes_to_human "$rx_b")" "$rx_e" "$rx_d" \
                    "$(bytes_to_human "$tx_b")" "$tx_e" "$tx_d"
            done
        fi

        if [[ "$STATS_ONLY" == "false" && ${#PORTS_DATA[@]} -gt 0 ]]; then
            printf "\n%s--- Active Listening Sockets (Ports Audit) ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
            printf "%-6s %-9s %-32s %-8s\n" "Proto" "State" "Local Address" "Port"
            printf "%s\n" "------------------------------------------------------------"

            for p in "${PORTS_DATA[@]}"; do
                IFS='|' read -r proto state addr port _ <<< "$p"
                printf "%-6s %-9s %-32s %-8s\n" "$proto" "$state" "$addr" "$port"
            done
        fi
        printf "%s---------------------------------------------------------------------%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    fi

    exit "$max_status"
}

main "$@"
