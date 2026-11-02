#!/usr/bin/env bash
# ==============================================================================
# Native Grafana Alloy Service Hardening & Installation Script
# Project: Linux System Monitoring & Reliability Lab
# Principle: Least privilege, journal access via group membership, zero capabilities
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Native Grafana Alloy Service Installer ==="

# Check root/sudo
if [[ $EUID -ne 0 ]]; then
    echo "[-] Error: This installation script must be run as root (or via sudo)." >&2
    exit 1
fi

# Ensure alloy user and group exist
if ! getent group alloy >/dev/null 2>&1; then
    echo "[+] Creating system group 'alloy'..."
    groupadd --system alloy
fi

if ! id -u alloy >/dev/null 2>&1; then
    echo "[+] Creating system user 'alloy'..."
    useradd --system --gid alloy --no-create-home --shell /usr/sbin/nologin alloy
fi

# Add alloy user to systemd-journal group for /var/log/journal access
echo "[+] Adding 'alloy' user to 'systemd-journal' and 'adm' groups..."
usermod -a -G systemd-journal,adm alloy

# Ensure /etc/alloy directory exists
mkdir -p /etc/alloy
if [[ -f "$REPO_ROOT/alloy/config.alloy" && ! -f /etc/alloy/config.alloy ]]; then
    echo "[+] Installing config.alloy to /etc/alloy/config.alloy..."
    cp "$REPO_ROOT/alloy/config.alloy" /etc/alloy/config.alloy
    chmod 644 /etc/alloy/config.alloy
fi

# Install /etc/default/alloy
mkdir -p /etc/default
echo "[+] Installing /etc/default/alloy..."
cp "$SCRIPT_DIR/alloy.default" /etc/default/alloy
chmod 644 /etc/default/alloy

# Install systemd drop-in override
OVERRIDE_DIR="/etc/systemd/system/alloy.service.d"
mkdir -p "$OVERRIDE_DIR"
echo "[+] Installing hardened systemd drop-in to $OVERRIDE_DIR/override.conf..."
cp "$SCRIPT_DIR/alloy-override.conf" "$OVERRIDE_DIR/override.conf"
chmod 644 "$OVERRIDE_DIR/override.conf"

# Ensure /var/lib/alloy exists with proper ownership
mkdir -p /var/lib/alloy
chown -R alloy:alloy /var/lib/alloy
chmod 750 /var/lib/alloy

# Reload systemd daemon
echo "[+] Reloading systemd daemon..."
systemctl daemon-reload

echo "[+] Native Alloy service configuration installed successfully."
echo "[+] To start: systemctl start alloy.service"
echo "[+] To verify: systemctl status alloy.service"
