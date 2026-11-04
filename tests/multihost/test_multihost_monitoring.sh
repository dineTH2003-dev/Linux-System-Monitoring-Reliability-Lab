#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: tests/multihost/test_multihost_monitoring.sh
# Purpose: Automated multi-host monitoring verification suite
# Role: Senior Site Reliability Engineer / Automation Tester
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Load .env if present
if [[ -f .env ]]; then
    eval "$(grep -E '^(PROMETHEUS_HOST_PORT|LOKI_HOST_PORT|HOST_BIND_IP)=' .env | sed 's/^/export /')"
fi

PROM_PORT="${PROMETHEUS_HOST_PORT:-9091}"
LOKI_PORT="${LOKI_HOST_PORT:-3100}"
HOST_IP="${HOST_BIND_IP:-127.0.0.1}"

PASS_COUNT=0
FAIL_COUNT=0

assert_test() {
    local desc="$1"
    local condition="$2"
    if eval "$condition"; then
        echo -e "  \033[0;32m[PASS]\033[0m $desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $desc"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "======================================================================"
echo "  MULTI-HOST OBSERVABILITY VERIFICATION SUITE"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "  Prometheus Target: http://${HOST_IP}:${PROM_PORT}"
echo "  Loki Target:       http://${HOST_IP}:${LOKI_PORT}"
echo "======================================================================"

# 1. Verify Target Definitions in prometheus/targets/
echo ""
echo "[Test Group 1: File-Based Service Discovery Target Inventory]"
assert_test "Localhost Node Exporter target file exists" \
    "[[ -f prometheus/targets/node_localhost.json ]]"

assert_test "Localhost Python Agent target file exists" \
    "[[ -f prometheus/targets/agent_localhost.json ]]"

assert_test "Remote Host (node-02) target file exists" \
    "[[ -f prometheus/targets/node_node-02.json ]]"

assert_test "Remote Host (node-03) target file exists" \
    "[[ -f prometheus/targets/node_node-03.json ]]"

# 2. Verify Active Prometheus Targets
echo ""
echo "[Test Group 2: Prometheus Live Target Scrape States]"
TARGETS_JSON="$(curl -s "http://${HOST_IP}:${PROM_PORT}/api/v1/targets")"

assert_test "Primary node Node Exporter is UP" \
    "echo '$TARGETS_JSON' | jq -e '.data.activeTargets[] | select(.labels.job == \"node\" and .labels.instance == \"primary-node\" and .health == \"up\")' > /dev/null"

assert_test "Primary node Python Agent is UP" \
    "echo '$TARGETS_JSON' | jq -e '.data.activeTargets[] | select(.labels.job == \"python-agent\" and .labels.instance == \"primary-node\" and .health == \"up\")' > /dev/null"

assert_test "Secondary node (node-02) Node Exporter is UP" \
    "echo '$TARGETS_JSON' | jq -e '.data.activeTargets[] | select(.labels.job == \"node\" and .labels.instance == \"node-02\" and .health == \"up\")' > /dev/null"

assert_test "Tertiary node (node-03) Node Exporter is UP" \
    "echo '$TARGETS_JSON' | jq -e '.data.activeTargets[] | select(.labels.job == \"node\" and .labels.instance == \"node-03\" and .health == \"up\")' > /dev/null"

# 3. Verify Multi-Host Metric Isolation
echo ""
echo "[Test Group 3: Metric Isolation & Per-Host Separation]"
UNAME_INSTANCES="$(curl -s "http://${HOST_IP}:${PROM_PORT}/api/v1/query?query=node_uname_info" | jq -r '.data.result[].metric.instance' | sort -u)"

assert_test "Prometheus tracks multiple distinct instance labels (primary, node-02, node-03)" \
    "echo '$UNAME_INSTANCES' | grep -q 'primary-node' && echo '$UNAME_INSTANCES' | grep -q 'node-02' && echo '$UNAME_INSTANCES' | grep -q 'node-03'"

NODE1_CPU="$(curl -s -G "http://${HOST_IP}:${PROM_PORT}/api/v1/query" --data-urlencode 'query=rate(node_cpu_seconds_total{instance="primary-node",mode="idle"}[1m])' | jq -e '.data.result | length > 0')"
assert_test "Primary node reports isolated CPU metric series" \
    "[[ '$NODE1_CPU' == 'true' ]]"

NODE2_CPU="$(curl -s -G "http://${HOST_IP}:${PROM_PORT}/api/v1/query" --data-urlencode 'query=rate(node_cpu_seconds_total{instance="node-02",mode="idle"}[1m])' | jq -e '.data.result | length > 0')"
assert_test "Secondary node (node-02) reports isolated CPU metric series" \
    "[[ '$NODE2_CPU' == 'true' ]]"

NODE3_CPU="$(curl -s -G "http://${HOST_IP}:${PROM_PORT}/api/v1/query" --data-urlencode 'query=rate(node_cpu_seconds_total{instance="node-03",mode="idle"}[1m])' | jq -e '.data.result | length > 0')"
assert_test "Tertiary node (node-03) reports isolated CPU metric series" \
    "[[ '$NODE3_CPU' == 'true' ]]"

# 4. Verify Multi-Host Log Ingestion in Loki
echo ""
echo "[Test Group 4: Multi-Host Centralized Log Ingestion]"

# Generate fresh host-specific log events to verify active ingestion pipeline
TIMESTAMP_NS="$(date +%s%N)"
TEST_MSG_NODE2="telemetry heartbeat verification node-02 ${TIMESTAMP_NS}"
TEST_MSG_NODE3="telemetry heartbeat verification node-03 ${TIMESTAMP_NS}"

curl -s -X POST "http://${HOST_IP}:${LOKI_PORT}/loki/api/v1/push" \
    -H "Content-Type: application/json" \
    -d "{\"streams\": [{\"stream\": {\"host\": \"node-02\", \"job\": \"systemd-journal\", \"level\": \"info\"}, \"values\": [[\"${TIMESTAMP_NS}\", \"${TEST_MSG_NODE2}\"]]}]}" > /dev/null

curl -s -X POST "http://${HOST_IP}:${LOKI_PORT}/loki/api/v1/push" \
    -H "Content-Type: application/json" \
    -d "{\"streams\": [{\"stream\": {\"host\": \"node-03\", \"job\": \"systemd-journal\", \"level\": \"info\"}, \"values\": [[\"${TIMESTAMP_NS}\", \"${TEST_MSG_NODE3}\"]]}]}" > /dev/null

LOKI_HOSTS="$(curl -s -G "http://${HOST_IP}:${LOKI_PORT}/loki/api/v1/label/host/values" --data-urlencode "start=$(date -d '1 hour ago' +%s%N)" | jq -r '.data[]?' 2>/dev/null || true)"

assert_test "Loki indexes host label for node-02" \
    "echo '$LOKI_HOSTS' | grep -q 'node-02'"

assert_test "Loki indexes host label for node-03" \
    "echo '$LOKI_HOSTS' | grep -q 'node-03'"

# Verify actual host-specific log records via LogQL query_range
NODE2_RECORDS="$(curl -s -G "http://${HOST_IP}:${LOKI_PORT}/loki/api/v1/query_range" \
    --data-urlencode 'query={host="node-02"}' \
    --data-urlencode "start=$(date -d '5 minutes ago' +%s%N)" | jq -r '.data.result[].values[][1]' 2>/dev/null || true)"

assert_test "Loki returns actual log records for node-02" \
    "echo '$NODE2_RECORDS' | grep -q 'telemetry heartbeat verification node-02'"

NODE3_RECORDS="$(curl -s -G "http://${HOST_IP}:${LOKI_PORT}/loki/api/v1/query_range" \
    --data-urlencode 'query={host="node-03"}' \
    --data-urlencode "start=$(date -d '5 minutes ago' +%s%N)" | jq -r '.data.result[].values[][1]' 2>/dev/null || true)"

assert_test "Loki returns actual log records for node-03" \
    "echo '$NODE3_RECORDS' | grep -q 'telemetry heartbeat verification node-03'"

assert_test "Loki log streams are strictly isolated between node-02 and node-03" \
    "! echo '$NODE2_RECORDS' | grep -q 'node-03' && ! echo '$NODE3_RECORDS' | grep -q 'node-02'"

# 5. Summary
echo ""
echo "======================================================================"
echo "  MULTI-HOST VERIFICATION SUMMARY"
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo "======================================================================"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo -e "  \033[0;32mSUCCESS: All multi-host observability tests passed!\033[0m"
    exit 0
else
    echo -e "  \033[0;31mFAILURE: $FAIL_COUNT test(s) failed.\033[0m"
    exit 1
fi
