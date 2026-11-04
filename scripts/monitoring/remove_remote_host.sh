#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: scripts/monitoring/remove_remote_host.sh
# Purpose: Unregister a remote Linux host from Prometheus File-SD
# Usage: ./scripts/monitoring/remove_remote_host.sh <hostname>
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGETS_DIR="$REPO_ROOT/prometheus/targets"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hostname>"
    exit 1
fi

HOST_NAME="$1"
NODE_TARGET_FILE="$TARGETS_DIR/node_${HOST_NAME}.json"
AGENT_TARGET_FILE="$TARGETS_DIR/agent_${HOST_NAME}.json"

REMOVED=0

if [[ -f "$NODE_TARGET_FILE" ]]; then
    rm -f "$NODE_TARGET_FILE"
    echo "Removed Node Exporter target: $NODE_TARGET_FILE"
    REMOVED=1
fi

if [[ -f "$AGENT_TARGET_FILE" ]]; then
    rm -f "$AGENT_TARGET_FILE"
    echo "Removed Python Agent target: $AGENT_TARGET_FILE"
    REMOVED=1
fi

if [[ $REMOVED -eq 0 ]]; then
    echo "Warning: No target files found for host '$HOST_NAME' in $TARGETS_DIR"
else
    echo "Host '$HOST_NAME' successfully removed. Prometheus File-SD will update within 30 seconds."
fi
