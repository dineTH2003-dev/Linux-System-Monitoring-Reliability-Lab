#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: scripts/agent.sh
# Purpose: Lifecycle manager for the custom Python host monitoring agent
# Usage: ./scripts/agent.sh {start|stop|restart|status|install-service}
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="/tmp/lab_agent.pid"
LOG_FILE="/tmp/lab_agent.log"
AGENT_PORT="${PYTHON_AGENT_HOST_PORT:-9101}"
HEALTH_URL="http://127.0.0.1:${AGENT_PORT}/healthz"

get_python() {
    if [[ -x "$REPO_ROOT/.venv/bin/python3" ]]; then
        echo "$REPO_ROOT/.venv/bin/python3"
    elif command -v python3 >/dev/null 2>&1; then
        echo "$(command -v python3)"
    else
        echo "Error: Python 3 not found in .venv or PATH." >&2
        exit 1
    fi
}

is_running() {
    if curl -s -m 2 "$HEALTH_URL" >/dev/null 2>&1; then
        return 0
    fi
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

cmd_start() {
    echo "Starting Linux System Monitoring Agent on port ${AGENT_PORT}..."
    if is_running; then
        echo "  [INFO] Agent is already running and responding at ${HEALTH_URL}"
        return 0
    fi

    # Check if systemd user service is available and active
    if systemctl --user is-active --quiet linux-monitoring-agent 2>/dev/null; then
        echo "  [INFO] Agent is active under systemd user manager."
        return 0
    fi

    local python_bin
    python_bin="$(get_python)"

    # Launch daemon process in background
    cd "$REPO_ROOT"
    nohup "$python_bin" -m agent.main --host 127.0.0.1 --port "$AGENT_PORT" --log-level INFO > "$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"

    # Wait up to 5s for readiness
    local ready=0
    for _ in $(seq 1 10); do
        sleep 0.5
        if curl -s -m 2 "$HEALTH_URL" >/dev/null 2>&1; then
            ready=1
            break
        fi
    done

    if [[ "$ready" -eq 1 ]]; then
        echo "  [PASS] Agent started successfully (PID: $new_pid). Responding at ${HEALTH_URL}"
        return 0
    else
        echo "  [FAIL] Agent process started (PID: $new_pid) but did not respond on ${HEALTH_URL} within timeout." >&2
        echo "         Check log file: $LOG_FILE" >&2
        return 1
    fi
}

cmd_stop() {
    echo "Stopping Linux System Monitoring Agent..."
    if systemctl --user is-active --quiet linux-monitoring-agent 2>/dev/null; then
        systemctl --user stop linux-monitoring-agent 2>/dev/null || true
    fi

    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi

    pkill -f "agent\.main" 2>/dev/null || true
    echo "  [PASS] Agent stopped."
}

cmd_status() {
    if is_running; then
        local health_json
        health_json="$(curl -s -m 2 "$HEALTH_URL" || true)"
        echo "Agent Status: [ONLINE] Healthy"
        echo "Endpoint:     $HEALTH_URL"
        if [[ -n "$health_json" ]]; then
            echo "Details:      $health_json"
        fi
        return 0
    else
        echo "Agent Status: [OFFLINE]"
        return 1
    fi
}

case "${1:-}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_stop
        sleep 1
        cmd_start
        ;;
    status)
        cmd_status
        ;;
    install-service)
        bash "$REPO_ROOT/deployment/systemd/install-agent-service.sh"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|install-service}"
        exit 1
        ;;
esac
