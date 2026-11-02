#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: security/audit_permissions.sh
# Purpose: Comprehensive audit of file modes, execute bits, and ownership
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "======================================================================"
echo "  LINUX MONITORING LAB — FILE PERMISSION & PRIVILEGE AUDIT"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "  Target: $REPO_ROOT"
echo "======================================================================"

EXIT_CODE=0
WARNINGS=0
ERRORS=0

report_pass() {
    printf "  [PASS] %s\n" "$1"
}

report_warn() {
    printf "  [WARN] %s\n" "$1"
    WARNINGS=$((WARNINGS + 1))
}

report_fail() {
    printf "  [FAIL] %s\n" "$1"
    ERRORS=$((ERRORS + 1))
    EXIT_CODE=1
}

echo ""
echo "[1/6] Auditing for World-Writable Files and Directories..."
WORLD_WRITABLE=$(find . -not -path '*/.*' -perm -0002 2>/dev/null || true)
if [[ -z "$WORLD_WRITABLE" ]]; then
    report_pass "No world-writable files or directories detected in repository."
else
    report_fail "World-writable items detected:"
    echo "$WORLD_WRITABLE" | sed 's/^/         /'
fi

echo ""
echo "[2/6] Auditing for Unexpected SUID / SGID Executables..."
SUID_SGID=$(find . -not -path '*/.*' -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null || true)
if [[ -z "$SUID_SGID" ]]; then
    report_pass "Zero SUID/SGID binaries present in repository tree."
else
    report_fail "SUID/SGID binaries discovered:"
    echo "$SUID_SGID" | sed 's/^/         /'
fi

echo ""
echo "[3/6] Auditing Script Execution Bits (*.sh)..."
NON_EXEC_SCRIPTS=$(find scripts security deployment -type f -name "*.sh" ! -perm -0111 2>/dev/null || true)
if [[ -z "$NON_EXEC_SCRIPTS" ]]; then
    report_pass "All Shell utility scripts are correctly marked executable."
else
    report_warn "Shell scripts missing executable permissions:"
    echo "$NON_EXEC_SCRIPTS" | sed 's/^/         /'
fi

echo ""
echo "[4/6] Auditing Documentation & Configuration Over-Permissioning..."
EXEC_CONFIGS=$(find prometheus grafana alertmanager loki blackbox docs \
    -type f \( -name "*.yml" -o -name "*.yaml" -o -name "*.json" -o -name "*.md" \) \
    -perm -0111 2>/dev/null || true)
if [[ -z "$EXEC_CONFIGS" ]]; then
    report_pass "All YAML, JSON, and Markdown files have non-executable permissions."
else
    report_warn "Configuration or documentation files incorrectly marked executable:"
    echo "$EXEC_CONFIGS" | sed 's/^/         /'
fi

echo ""
echo "[5/6] Auditing Environment & Secret File Permissions..."
if [[ -f .env ]]; then
    ENV_PERM=$(stat -c "%a" .env)
    if [[ "$ENV_PERM" =~ ^[46]00$ ]]; then
        report_pass ".env file is protected with least-privilege mode ($ENV_PERM)."
    else
        report_fail ".env file has loose permissions: $ENV_PERM (expected 600 or 400)."
    fi
else
    report_pass ".env file does not exist on disk (clean state; .env.example present)."
fi

echo ""
echo "[6/6] Auditing Docker Socket & Host Sockets Exposure..."
if [[ -e /var/run/docker.sock ]]; then
    SOCK_PERM=$(stat -c "%a %U:%G" /var/run/docker.sock 2>/dev/null || true)
    report_pass "/var/run/docker.sock permissions: $SOCK_PERM (Docker daemon socket)."
    # Verify docker socket is not bind-mounted in compose
    if grep -q "/var/run/docker.sock" docker-compose.yml 2>/dev/null; then
        report_fail "CRITICAL: docker-compose.yml mounts /var/run/docker.sock (Container breakout risk!)."
    else
        report_pass "docker-compose.yml does NOT mount /var/run/docker.sock."
    fi
else
    report_pass "/var/run/docker.sock not present directly in host path."
fi

echo ""
echo "======================================================================"
echo "  Audit Summary: $ERRORS Errors, $WARNINGS Warnings"
echo "======================================================================"

exit "$EXIT_CODE"
