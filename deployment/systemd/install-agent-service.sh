#!/usr/bin/env bash
# ==============================================================================
# Linux System Monitoring & Reliability Lab
# Script: deployment/systemd/install-agent-service.sh
# Purpose: Safe installer for the custom Python monitoring agent systemd unit
# Role: Agent 11 — Infrastructure Security & Deployment Engineer
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"
SERVICE_TEMPLATE="$REPO_ROOT/deployment/systemd/linux-monitoring-agent.service"

echo "======================================================================"
echo "  LINUX MONITORING AGENT — SYSTEMD SERVICE INSTALLER"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "======================================================================"

if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "Error: Python virtual environment executable not found at '$VENV_PYTHON'." >&2
    echo "Please initialize the environment first: python3 -m venv .venv && pip install -r requirements.txt" >&2
    exit 1
fi

USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"
TARGET_SERVICE="$USER_SYSTEMD_DIR/linux-monitoring-agent.service"

echo ""
echo "[1/3] Generating tailored systemd unit at $TARGET_SERVICE..."

cat > "$TARGET_SERVICE" << EOF
[Unit]
Description=Linux System Monitoring Agent (Prometheus Exporter)
Documentation=https://github.com/dineth/Linux-System-Monitoring-Reliability-Lab
After=network.target

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
ExecStart=${VENV_PYTHON} -m agent.main -c agent/config.yaml --host 127.0.0.1 --port 9101
Restart=on-failure
RestartSec=5s
KillMode=mixed
TimeoutStopSec=10s

# Linux Sandboxing Directives (User Service Scope)
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes

# Network Restrictions
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Logging Output
StandardOutput=journal
StandardError=journal
SyslogIdentifier=linux-monitoring-agent

[Install]
WantedBy=default.target
EOF

chmod 644 "$TARGET_SERVICE"
printf "  [DONE] Service file generated successfully.\n"

echo ""
echo "[2/3] Reloading user systemd daemon..."
if systemctl --user daemon-reload 2>/dev/null; then
    printf "  [DONE] systemd --user daemon reloaded.\n"
else
    echo "  [WARN] Unable to execute 'systemctl --user daemon-reload' in this environment."
fi

echo ""
echo "[3/3] Installation Instructions:"
echo "  To enable and start the monitoring agent service, run:"
echo "    systemctl --user enable --now linux-monitoring-agent.service"
echo ""
echo "  To inspect service status and logs:"
echo "    systemctl --user status linux-monitoring-agent.service"
echo "    journalctl --user -u linux-monitoring-agent.service -f"
echo ""
echo "======================================================================"
echo "  Installation Complete."
echo "======================================================================"
