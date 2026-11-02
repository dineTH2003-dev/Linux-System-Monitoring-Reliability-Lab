#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Module: Unified System Health Monitor & CLI Orchestrator
# Purpose: Master CLI entrypoint for individual and consolidated health reports
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

VERSION="1.0.0"
OUTPUT_FORMAT="text"
SUMMARY_ONLY=false
WARN_ONLY=false

usage() {
    cat <<EOF
Usage: $(basename "$0") <COMMAND> [OPTIONS]

Unified Linux System Monitoring & Diagnostic Toolkit.
Orchestrates deep kernel observability across compute, storage, networking,
processes, and service managers.

Commands:
  all, report       Execute full consolidated system health assessment
  cpu               Run CPU subsystem monitor
  memory            Run Memory and swap subsystem monitor
  storage           Run Storage, filesystem, and disk I/O monitor
  network           Run Network interfaces and listening sockets monitor
  process           Run Process states and top consumers monitor
  systemd           Run systemd unit failure and service inspection monitor
  help              Display this help message
  version           Display toolkit version information

Global Options (applicable to 'all' / 'report'):
  -j, --json        Output consolidated report in structured JSON format
  -t, --text        Output report in formatted human-readable text (default)
  -s, --summary     Display high-level executive summary table only
  -w, --warn-only   Display only subsystems in WARN or CRIT status
  -h, --help        Display command usage and options

Subcommand Passthrough:
  Any arguments passed after a specific subcommand are forwarded directly
  to that module. For example:
    $(basename "$0") cpu --warn-util 80 --crit-util 90
    $(basename "$0") memory --json
    $(basename "$0") storage --mount /
    $(basename "$0") process --top 10
    $(basename "$0") systemd --service ssh.service

Exit Codes:
  0 - OK (All monitored subsystems healthy)
  1 - Runtime error
  2 - Usage or syntax error
  3 - Warning threshold breached in one or more subsystems
  4 - Critical threshold breached in one or more subsystems
  127 - Required command not found
EOF
}

# Run a single child module in JSON mode and capture exit code + output
# Args: module_name module_script [extra_args...]
run_module_json() {
    local mod_script="$1"
    shift
    local out code=0

    out="$("${mod_script}" --json "$@" 2>/dev/null)" || code=$?
    printf "%s\n__MODULE_EXIT_CODE__:%d" "$out" "$code"
}

# Run consolidated report across all modules
run_full_report() {
    local cpu_script="${SCRIPT_DIR}/cpu_monitor.sh"
    local mem_script="${SCRIPT_DIR}/memory_monitor.sh"
    local stor_script="${SCRIPT_DIR}/storage_monitor.sh"
    local net_script="${SCRIPT_DIR}/network_monitor.sh"
    local proc_script="${SCRIPT_DIR}/process_monitor.sh"
    local sysd_script="${SCRIPT_DIR}/systemd_monitor.sh"

    local cpu_raw mem_raw stor_raw net_raw proc_raw sysd_raw
    local cpu_json mem_json stor_json net_json proc_json sysd_json
    local cpu_code mem_code stor_code net_code proc_code sysd_code

    # Execute all modules (fast, non-destructive read-only sampling)
    cpu_raw="$(run_module_json "$cpu_script")"
    cpu_code="${cpu_raw##*__MODULE_EXIT_CODE__:}"
    cpu_json="${cpu_raw%__MODULE_EXIT_CODE__:*}"

    mem_raw="$(run_module_json "$mem_script")"
    mem_code="${mem_raw##*__MODULE_EXIT_CODE__:}"
    mem_json="${mem_raw%__MODULE_EXIT_CODE__:*}"

    stor_raw="$(run_module_json "$stor_script")"
    stor_code="${stor_raw##*__MODULE_EXIT_CODE__:}"
    stor_json="${stor_raw%__MODULE_EXIT_CODE__:*}"

    net_raw="$(run_module_json "$net_script")"
    net_code="${net_raw##*__MODULE_EXIT_CODE__:}"
    net_json="${net_raw%__MODULE_EXIT_CODE__:*}"

    proc_raw="$(run_module_json "$proc_script")"
    proc_code="${proc_raw##*__MODULE_EXIT_CODE__:}"
    proc_json="${proc_raw%__MODULE_EXIT_CODE__:*}"

    sysd_raw="$(run_module_json "$sysd_script")"
    sysd_code="${sysd_raw##*__MODULE_EXIT_CODE__:}"
    sysd_json="${sysd_raw%__MODULE_EXIT_CODE__:*}"

    # Determine master aggregate status
    local master_status="$EXIT_SUCCESS"
    master_status="$(aggregate_status "$master_status" "$cpu_code")"
    master_status="$(aggregate_status "$master_status" "$mem_code")"
    master_status="$(aggregate_status "$master_status" "$stor_code")"
    master_status="$(aggregate_status "$master_status" "$net_code")"
    master_status="$(aggregate_status "$master_status" "$proc_code")"
    master_status="$(aggregate_status "$master_status" "$sysd_code")"

    local host_name
    host_name="$(hostname 2>/dev/null || echo "localhost")"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        cat <<EOF
{
  "timestamp": "$(timestamp_utc)",
  "hostname": "$(json_escape "$host_name")",
  "version": "${VERSION}",
  "status": "$(status_to_string "$master_status")",
  "exit_code": ${master_status},
  "subsystems": {
    "cpu": ${cpu_json:-null},
    "memory": ${mem_json:-null},
    "storage": ${stor_json:-null},
    "network": ${net_json:-null},
    "process": ${proc_json:-null},
    "systemd": ${sysd_json:-null}
  }
}
EOF
    else
        printf "%s========================================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%sLinux Reliability & Monitoring Lab — Consolidated System Health Report%s  %s\n" \
            "${COLOR_BOLD}" "${COLOR_RESET}" "$(format_status_badge "$master_status")"
        printf "%s========================================================================================%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "Host Target: %s | Timestamp: %s | Toolkit Version: %s\n\n" \
            "$host_name" "$(timestamp_utc)" "$VERSION"

        # Executive Summary Table
        printf "%s--- Subsystem Health Summary ---%s\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        printf "%-18s %-12s %-12s %s\n" "Subsystem" "Status" "Exit Code" "Core Telemetry Highlights"
        printf "%s\n" "----------------------------------------------------------------------------------------"

        # Parse highlights from JSON outputs using awk
        local cpu_hl mem_hl stor_hl net_hl proc_hl sysd_hl
        cpu_hl="$(echo "$cpu_json" | awk '
            /"total_pct":/ { sub(/.*"total_pct": */, ""); sub(/,.*/, ""); util = $0 }
            /"load_1m":/ { sub(/.*"load_1m": */, ""); sub(/,.*/, ""); load = $0 }
            END { printf "Util: %s%% | 1m Load: %s", util, load }
        ')"

        mem_hl="$(echo "$mem_json" | awk '
            /"used_pct":/ { if (ram == "") { sub(/.*"used_pct": */, ""); sub(/,.*/, ""); ram = $0 } else if (swap == "") { sub(/.*"used_pct": */, ""); sub(/,.*/, ""); swap = $0 } }
            END { printf "RAM Used: %s%% | Swap Used: %s%%", ram, swap }
        ')"

        stor_hl="$(echo "$stor_json" | awk '
            /"used_pct":/ { sub(/.*"used_pct": */, ""); sub(/,.*/, ""); if (root == "") root = $0 }
            END { printf "Root FS: %s%% used", root }
        ')"

        net_hl="$(echo "$net_json" | awk '
            /"rx_kib_per_sec":/ { sub(/.*"rx_kib_per_sec": */, ""); sub(/,.*/, ""); rx = $0 }
            /"tx_kib_per_sec":/ { sub(/.*"tx_kib_per_sec": */, ""); sub(/,.*/, ""); tx = $0 }
            END { printf "RX: %s KiB/s | TX: %s KiB/s", rx, tx }
        ')"

        proc_hl="$(echo "$proc_json" | awk '
            /"total_processes":/ { sub(/.*"total_processes": */, ""); sub(/,.*/, ""); tot = $0 }
            /"zombie":/ { sub(/.*"zombie": */, ""); sub(/,.*/, ""); z = $0 }
            END { printf "Procs: %s | Zombies: %s", tot, z }
        ')"

        sysd_hl="$(echo "$sysd_json" | awk '
            /"system_state":/ {
                if (match($0, /"system_state": *"([^"]+)"/, m)) st = m[1]
            }
            /"failed_units_count":/ {
                if (match($0, /"failed_units_count": *([0-9]+)/, m)) fc = m[1]
            }
            END { printf "State: %s | Failed Units: %s", st, fc }
        ')"

        printf "%-18s %-12s %-12d %s\n" "CPU Compute" "$(format_status_badge "$cpu_code")" "$cpu_code" "$cpu_hl"
        printf "%-18s %-12s %-12d %s\n" "Memory & Swap" "$(format_status_badge "$mem_code")" "$mem_code" "$mem_hl"
        printf "%-18s %-12s %-12d %s\n" "Storage & Inodes" "$(format_status_badge "$stor_code")" "$stor_code" "$stor_hl"
        printf "%-18s %-12s %-12d %s\n" "Network & Ports" "$(format_status_badge "$net_code")" "$net_code" "$net_hl"
        printf "%-18s %-12s %-12d %s\n" "Process States" "$(format_status_badge "$proc_code")" "$proc_code" "$proc_hl"
        printf "%-18s %-12s %-12d %s\n" "systemd Services" "$(format_status_badge "$sysd_code")" "$sysd_code" "$sysd_hl"
        printf "%s\n" "----------------------------------------------------------------------------------------"

        if [[ "$SUMMARY_ONLY" == "false" ]]; then
            # Print detailed sections if not filtered by warn-only
            if [[ "$WARN_ONLY" == "false" || "$cpu_code" -ne "$EXIT_SUCCESS" ]]; then
                printf "\n"
                "${cpu_script}" --text
            fi

            if [[ "$WARN_ONLY" == "false" || "$mem_code" -ne "$EXIT_SUCCESS" ]]; then
                printf "\n"
                "${mem_script}" --text
            fi

            if [[ "$WARN_ONLY" == "false" || "$stor_code" -ne "$EXIT_SUCCESS" ]]; then
                printf "\n"
                "${stor_script}" --text
            fi

            if [[ "$WARN_ONLY" == "false" || "$net_code" -ne "$EXIT_SUCCESS" ]]; then
                printf "\n"
                "${net_script}" --text
            fi

            if [[ "$WARN_ONLY" == "false" || "$proc_code" -ne "$EXIT_SUCCESS" ]]; then
                printf "\n"
                "${proc_script}" --text
            fi

            if [[ "$WARN_ONLY" == "false" || "$sysd_code" -ne "$EXIT_SUCCESS" ]]; then
                printf "\n"
                "${sysd_script}" --text
            fi
        fi

        printf "\n%sOverall Diagnostic Result: %s (Exit Code: %d)%s\n" \
            "${COLOR_BOLD}" "$(format_status_badge "$master_status")" "$master_status" "${COLOR_RESET}"
    fi

    exit "$master_status"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit "$EXIT_USAGE"
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        all|report)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -j|--json)
                        OUTPUT_FORMAT="json"
                        shift
                        ;;
                    -t|--text)
                        OUTPUT_FORMAT="text"
                        shift
                        ;;
                    -s|--summary)
                        SUMMARY_ONLY=true
                        shift
                        ;;
                    -w|--warn-only)
                        WARN_ONLY=true
                        shift
                        ;;
                    -h|--help)
                        usage
                        exit "$EXIT_SUCCESS"
                        ;;
                    *)
                        log_error "Unknown option for 'all': $1"
                        usage >&2
                        exit "$EXIT_USAGE"
                        ;;
                esac
            done
            run_full_report
            ;;
        cpu)
            exec "${SCRIPT_DIR}/cpu_monitor.sh" "$@"
            ;;
        memory|mem)
            exec "${SCRIPT_DIR}/memory_monitor.sh" "$@"
            ;;
        storage|disk)
            exec "${SCRIPT_DIR}/storage_monitor.sh" "$@"
            ;;
        network|net)
            exec "${SCRIPT_DIR}/network_monitor.sh" "$@"
            ;;
        process|proc)
            exec "${SCRIPT_DIR}/process_monitor.sh" "$@"
            ;;
        systemd|service|svc)
            exec "${SCRIPT_DIR}/systemd_monitor.sh" "$@"
            ;;
        version|-v|--version)
            echo "Linux Reliability Lab Monitoring Toolkit v${VERSION}"
            exit "$EXIT_SUCCESS"
            ;;
        help|-h|--help)
            usage
            exit "$EXIT_SUCCESS"
            ;;
        *)
            log_error "Unknown command: $cmd"
            usage >&2
            exit "$EXIT_USAGE"
            ;;
    esac
}

main "$@"
