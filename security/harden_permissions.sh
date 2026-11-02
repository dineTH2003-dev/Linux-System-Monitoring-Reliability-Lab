#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: security/harden_permissions.sh
# Purpose: Idempotent permission enforcement applying least-privilege modes
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "======================================================================"
echo "  LINUX MONITORING LAB — LEAST-PRIVILEGE PERMISSION HARDENING"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "  Target: $REPO_ROOT"
echo "======================================================================"

echo ""
echo "[1/4] Enforcing Directory Permissions (0755: rwxr-xr-x)..."
find . -not -path '*/.*' -type d -exec chmod 755 {} +
printf "  [DONE] All non-hidden directories hardened to 0755.\n"

echo ""
echo "[2/4] Enforcing Shell Script Permissions (0755: rwxr-xr-x)..."
find scripts security deployment -type f -name "*.sh" -exec chmod 755 {} +
printf "  [DONE] All operational and test shell scripts set to 0755 executable.\n"

echo ""
echo "[3/4] Enforcing Configuration and Documentation Modes (0644: rw-r--r--)..."
find agent prometheus grafana alertmanager loki blackbox docs \
    -type f \( -name "*.py" -o -name "*.yml" -o -name "*.yaml" -o -name "*.json" -o -name "*.md" -o -name "*.toml" -o -name "*.txt" \) \
    -exec chmod 644 {} +
chmod 644 README.md pyproject.toml requirements.txt requirements-dev.txt .env.example docker-compose.yml 2>/dev/null || true
printf "  [DONE] Configurations, Python modules, and documentation restricted to 0644.\n"

echo ""
echo "[4/4] Enforcing Secret & Environment File Least Privilege (0600: rw-------)..."
if [[ -f .env ]]; then
    chmod 600 .env
    printf "  [DONE] Active .env file restricted to 0600 (owner read/write only).\n"
fi
find . -maxdepth 2 -name ".env.*" ! -name ".env.example" -exec chmod 600 {} + 2>/dev/null || true

echo ""
echo "======================================================================"
echo "  Permission Hardening Complete. Validating with audit_permissions.sh..."
echo "======================================================================"
bash security/audit_permissions.sh
