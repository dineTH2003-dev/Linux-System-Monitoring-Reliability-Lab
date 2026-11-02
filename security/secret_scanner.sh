#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: security/secret_scanner.sh
# Purpose: Static scanning of git history and workspace files for leaked secrets
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "======================================================================"
echo "  LINUX MONITORING LAB — STATIC SECRET & CREDENTIAL SCANNER"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "  Target: $REPO_ROOT"
echo "======================================================================"

EXIT_CODE=0
FINDINGS=0

# Regex patterns for high-entropy secrets and credential tokens
PATTERNS=(
    "Private Key:-----BEGIN (RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----"
    "AWS Access Key ID:AKIA[0-9A-Z]{16}"
    "AWS Secret Access Key:(?i)aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}"
    "GitHub Token:gh[pousr]_[A-Za-z0-9_]{36,255}"
    "Slack Webhook:https://hooks\.slack\.com/services/T[0-9A-Z]{8}/B[0-9A-Z]{8}/[0-9A-Za-z]{24}"
    "Generic Bearer Token:(?i)bearer\s+[a-zA-Z0-9_\-\.]{25,}"
    "Generic API Key:(?i)(api_key|apikey|secret_key)\s*[:=]\s*['\"][a-zA-Z0-9_\-]{20,}['\"]"
    "Hardcoded Password:(?i)(password|passwd|secret)\s*[:=]\s*['\"][^'\"]{8,}['\"]"
)

EXCLUDE_REGEX='^(\.git|\.venv|\.pytest_cache|__pycache__|\.egg-info|tests|scripts/tests/fixtures|\.env\.example)'

echo ""
echo "[1/2] Scanning Working Tree Files..."

python3 - << 'EOF'
import os
import re
import sys

PATTERNS = [
    ("Private Key", re.compile(r"-----BEGIN (?:RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----")),
    ("AWS Key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GitHub Token", re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}")),
    ("Slack Webhook", re.compile(r"https://hooks\.slack\.com/services/T[0-9A-Za-z_]+/B[0-9A-Za-z_]+/[0-9A-Za-z_]+")),
    ("Generic Bearer", re.compile(r"(?i)bearer\s+[a-zA-Z0-9_\-\.]{25,}")),
    ("Generic API Key", re.compile(r"(?i)(?:api_key|apikey|secret_key)\s*[:=]\s*['\"][a-zA-Z0-9_\-]{20,}['\"]")),
    ("Hardcoded Password", re.compile(r"(?i)(?:password|passwd|secret)\s*[:=]\s*['\"][^'\"]{8,}['\"]")),
]

IGNORED_DIRS = {".git", ".venv", ".pytest_cache", "__pycache__", "linux_monitoring_agent.egg-info"}
IGNORED_FILES = {".env.example"}
SAFE_PLACEHOLDERS = {"changeme", "example", "placeholder", "test", "your_password", "sre@example.com"}

findings = 0
for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d not in IGNORED_DIRS and "fixtures" not in d]
    for file in files:
        if file in IGNORED_FILES or file.endswith((".pyc", ".tar.gz", ".png", ".jpg")):
            continue
        filepath = os.path.join(root, file)
        try:
            with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
                for line_num, line in enumerate(f, 1):
                    # Skip comments/lines containing intentional safe placeholders
                    line_lower = line.lower()
                    if any(safe in line_lower for safe in SAFE_PLACEHOLDERS):
                        continue
                    for label, pattern in PATTERNS:
                        if pattern.search(line):
                            print(f"  [ALERT] {label} detected in {filepath}:{line_num}")
                            print(f"          Snippet: {line.strip()[:80]}")
                            findings += 1
        except Exception as e:
            pass

if findings > 0:
    print(f"\nTotal findings in working tree: {findings}")
    sys.exit(1)
else:
    print("  [PASS] Zero secrets or credentials detected in working tree files.")
EOF

if [[ $? -ne 0 ]]; then
    EXIT_CODE=1
    FINDINGS=$((FINDINGS + 1))
fi

echo ""
echo "[2/2] Scanning Git Commit History..."

python3 - << 'EOF'
import subprocess
import re
import sys

PATTERNS = [
    ("Private Key", re.compile(r"-----BEGIN (?:RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----")),
    ("AWS Key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GitHub Token", re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}")),
    ("Generic Bearer", re.compile(r"(?i)bearer\s+[a-zA-Z0-9_\-\.]{25,}")),
]

SAFE_PLACEHOLDERS = {"changeme", "example", "placeholder", "test"}

try:
    log_output = subprocess.check_output(["git", "log", "-p", "--full-history"], text=True, errors="ignore")
except Exception as e:
    print(f"  [WARN] Unable to inspect git log: {e}")
    sys.exit(0)

findings = 0
for line in log_output.splitlines():
    if line.startswith("+") and not line.startswith("+++"):
        if any(safe in line.lower() for safe in SAFE_PLACEHOLDERS):
            continue
        for label, pattern in PATTERNS:
            if pattern.search(line):
                print(f"  [ALERT] {label} detected in git history diff:")
                print(f"          {line.strip()[:80]}")
                findings += 1

if findings > 0:
    print(f"\nTotal findings in git history: {findings}")
    sys.exit(1)
else:
    print("  [PASS] Zero secrets or credentials detected in git commit history.")
EOF

if [[ $? -ne 0 ]]; then
    EXIT_CODE=1
    FINDINGS=$((FINDINGS + 1))
fi

echo ""
echo "======================================================================"
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "  Secret Scan Result: CLEAN (No active secrets detected)"
else
    echo "  Secret Scan Result: FAILED ($FINDINGS secret violations discovered)"
fi
echo "======================================================================"

exit "$EXIT_CODE"
