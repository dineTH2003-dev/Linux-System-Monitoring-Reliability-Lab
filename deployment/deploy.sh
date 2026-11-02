#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: deployment/deploy.sh
# Purpose: Master deployment orchestrator with preflight validation and lifecycle controls
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
ENV_EXAMPLE="${ENV_EXAMPLE:-$REPO_ROOT/.env.example}"

# Required ports for the lab monitoring stack (must be free on 127.0.0.1)
LAB_PORTS=(9091 3001 9093 3100 9115 12345)

usage() {
    cat << EOF
Usage: $(basename "$0") <COMMAND>

Master Deployment & Lifecycle Orchestrator for the Monitoring Lab.

Commands:
  preflight     Run environment readiness, resource, and port conflict checks
  up            Launch hardened monitoring stack in detached mode with healthcheck
  down          Gracefully stop and tear down containers (preserves volume data)
  restart       Perform graceful restart of the monitoring stack
  status        Display container runtime status and resource consumption
  logs [svc]    Stream structured container logs (optional service name)
  health        Execute multi-service endpoint health validation
  config        Validate compose syntax and show rendered configuration
  help          Display this help message

EOF
    exit 0
}

log_info() {
    printf "%s [INFO]  %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

log_warn() {
    printf "%s [WARN]  %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2
}

log_error() {
    printf "%s [ERROR] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2
}

cmd_preflight() {
    log_info "Executing deployment preflight verification..."
    local errors=0

    # 1. Verify Docker Engine availability
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH."
        errors=$((errors + 1))
    elif ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running or current user lacks docker group access."
        errors=$((errors + 1))
    else
        log_info "Docker Engine is operational."
    fi

    # 2. Verify Docker Compose plugin
    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose (v2 plugin) is missing."
        errors=$((errors + 1))
    else
        local compose_ver
        compose_ver="$(docker compose version --short 2>/dev/null || docker compose version)"
        log_info "Docker Compose is available ($compose_ver)."
    fi

    # 3. Environment configuration (.env)
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "Missing .env configuration file! Copy from .env.example, configure credentials, and set mode 0600 prior to deployment."
        errors=$((errors + 1))
    else
        local perm
        perm=$(stat -c "%a" "$ENV_FILE" 2>/dev/null || stat -f "%Lp" "$ENV_FILE" 2>/dev/null)
        if [[ "$perm" != "600" && "$perm" != "0600" ]]; then
            log_error "Invalid permissions on .env (mode $perm). Required: exactly 0600 (read/write by owner only). Run: chmod 600 .env"
            errors=$((errors + 1))
        else
            log_info "Active .env permissions verified (mode $perm)."
        fi

        # Check for known insecure default placeholder password
        if grep -Eq '^[[:space:]]*GF_SECURITY_ADMIN_PASSWORD[[:space:]]*=[[:space:]]*["'"'"']?CHANGEME_SECURE_GRAFANA_ADMIN_PASSWORD_MIN_16_CHARS["'"'"']?[[:space:]]*$' "$ENV_FILE"; then
            log_error "Insecure placeholder password detected in .env: GF_SECURITY_ADMIN_PASSWORD must be changed from default placeholder before deployment."
            errors=$((errors + 1))
        elif ! grep -Eq '^[[:space:]]*GF_SECURITY_ADMIN_PASSWORD[[:space:]]*=' "$ENV_FILE"; then
            log_error "Missing required variable GF_SECURITY_ADMIN_PASSWORD in .env configuration."
            errors=$((errors + 1))
        else
            log_info "Grafana admin credential configuration verified (placeholder check passed)."
        fi
    fi

    # 4. Storage capacity check (require >= 3GB available on root partition)
    local avail_kb
    avail_kb=$(df -k "$REPO_ROOT" | awk 'NR==2 {print $4}')
    if [[ "$avail_kb" -lt 3145728 ]]; then
        log_warn "Low root disk space: $((avail_kb / 1024)) MiB available (recommended >= 3072 MiB)."
    else
        log_info "Filesystem capacity adequate: $((avail_kb / 1024 / 1024)) GiB available."
    fi

    # 5. Host port conflict check
    log_info "Checking port availability for lab bindings (127.0.0.1)..."
    for port in "${LAB_PORTS[@]}"; do
        if ss -tuln | grep -q "127.0.0.1:${port}\b"; then
            # Verify if it is already our lab container
            if docker ps --format '{{.Ports}}' | grep -q "127.0.0.1:${port}->"; then
                log_info "Port $port is currently bound by an existing lab container (safe to restart/update)."
            else
                log_error "Port $port is already in use by an external process!"
                errors=$((errors + 1))
            fi
        else
            log_info "Port $port is available."
        fi
    done

    # 6. Verify native host services are untouched
    log_info "Verifying native host monitoring services..."
    for srv in prometheus prometheus-node-exporter grafana-server; do
        if systemctl is-active --quiet "$srv" 2>/dev/null; then
            log_info "Native host service '$srv' is running normally."
        fi
    done

    if [[ "$errors" -gt 0 ]]; then
        log_error "Preflight checks failed with $errors error(s). Resolve issues before deployment."
        return 1
    fi

    log_info "Preflight checks completed successfully."
    return 0
}

cmd_up() {
    if ! cmd_preflight; then
        log_error "Deployment preflight verification failed! Aborting deployment."
        return 1
    fi
    log_info "Enforcing least privilege permissions across configs and scripts..."
    bash "$REPO_ROOT/security/harden_permissions.sh" >/dev/null 2>&1 || true

    log_info "Launching hardened monitoring stack via Docker Compose..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

    log_info "Waiting for service initialization (10s)..."
    sleep 10

    log_info "Validating container health..."
    bash "$REPO_ROOT/deployment/healthcheck.sh"
}

cmd_down() {
    log_info "Stopping monitoring stack gracefully (preserving persistent TSDB and database volumes)..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down
    log_info "Stack stopped."
}

cmd_restart() {
    if ! cmd_preflight; then
        log_error "Restart preflight verification failed! Aborting restart without stopping or tearing down running services."
        return 1
    fi
    log_info "Restarting monitoring stack..."
    cmd_down
    cmd_up
}

cmd_status() {
    echo "======================================================================"
    echo "  CONTAINER STATUS & RUNTIME HEALTH"
    echo "======================================================================"
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
    echo ""
    echo "======================================================================"
    echo "  CONTAINER RESOURCE UTILIZATION (CPU / MEMORY / I/O)"
    echo "======================================================================"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}" \
        $(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps -q 2>/dev/null) 2>/dev/null || echo "No active containers."
}

cmd_logs() {
    local svc="${1:-}"
    if [[ -n "$svc" ]]; then
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f --tail=100 "$svc"
    else
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f --tail=50
    fi
}

cmd_health() {
    bash "$REPO_ROOT/deployment/healthcheck.sh"
}

cmd_config() {
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config
}

# Main entrypoint
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    preflight)  cmd_preflight ;;
    up)         cmd_up ;;
    down)       cmd_down ;;
    restart)    cmd_restart ;;
    status)     cmd_status ;;
    logs)       cmd_logs "${1:-}" ;;
    health)     cmd_health ;;
    config)     cmd_config ;;
    help|--help|-h) usage ;;
    *)
        log_error "Unknown command: '$COMMAND'"
        usage
        ;;
esac
