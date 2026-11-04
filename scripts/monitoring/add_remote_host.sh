#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: scripts/monitoring/add_remote_host.sh
# Purpose: Dynamically register a remote Linux host into Prometheus File-SD
# Usage: ./scripts/monitoring/add_remote_host.sh <hostname> <ip_or_fqdn> [node_port] [agent_port]
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGETS_DIR="$REPO_ROOT/prometheus/targets"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <hostname> <ip_or_fqdn> [node_exporter_port] [python_agent_port]"
    echo ""
    echo "Examples:"
    echo "  $0 node-02 192.168.1.50"
    echo "  $0 worker-1 10.0.0.12 9100 9101"
    exit 1
fi

HOST_NAME="$1"
TARGET_HOST="$2"
NODE_PORT="${3:-9100}"
AGENT_PORT="${4:-}"

# Sanitize hostname
if ! [[ "$HOST_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Invalid hostname '$HOST_NAME'. Only alphanumeric, '.', '_', and '-' allowed."
    exit 1
fi

mkdir -p "$TARGETS_DIR"

# Write Node Exporter target definition
NODE_TARGET_FILE="$TARGETS_DIR/node_${HOST_NAME}.json"
cat << JSON_EOF > "$NODE_TARGET_FILE"
[
  {
    "targets": ["${TARGET_HOST}:${NODE_PORT}"],
    "labels": {
      "instance": "${HOST_NAME}",
      "collector_type": "node_exporter",
      "role": "remote_host_telemetry"
    }
  }
]
JSON_EOF

echo "Registered Node Exporter for '${HOST_NAME}' -> ${NODE_TARGET_FILE}"

# Optionally write Python Agent target definition
if [[ -n "$AGENT_PORT" ]]; then
    AGENT_TARGET_FILE="$TARGETS_DIR/agent_${HOST_NAME}.json"
    cat << JSON_EOF > "$AGENT_TARGET_FILE"
[
  {
    "targets": ["${TARGET_HOST}:${AGENT_PORT}"],
    "labels": {
      "instance": "${HOST_NAME}",
      "collector_type": "python_agent",
      "role": "custom_telemetry"
    }
  }
]
JSON_EOF
    echo "Registered Python Agent for '${HOST_NAME}' -> ${AGENT_TARGET_FILE}"
fi

echo "Prometheus File-SD will automatically discover this host within 30 seconds."
echo "To view status: curl -s http://127.0.0.1:\${PROMETHEUS_HOST_PORT:-9091}/api/v1/targets | jq ."
