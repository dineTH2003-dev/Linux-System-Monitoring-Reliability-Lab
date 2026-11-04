#!/usr/bin/env bash
# ==============================================================================
# Native Grafana Alloy Service Hardening & Installation Script
# Project: Linux System Monitoring & Reliability Lab
# Principle: Least privilege, journal access via group membership, zero capabilities
#
# This installer generates a host-specific Alloy configuration at install time.
# It accepts --host-identity and --loki-url to produce a static River config
# with literal string values, ensuring compatibility across Alloy v1.0.0 and
# v1.21.2+ without relying on env() or sys.env() runtime lookups.
#
# Usage:
#   Central server:
#     sudo ./install-alloy-service.sh --central [--reload]
#
#   Remote host:
#     sudo ./install-alloy-service.sh --host-identity node-02 --loki-url http://192.168.1.10:3100/loki/api/v1/push
#
#   Testing / Dry-run / Staging (non-root):
#     ./install-alloy-service.sh --host-identity node-02 --loki-url http://192.168.1.10:3100/loki/api/v1/push --output /tmp/config-node02.alloy
#     ./install-alloy-service.sh --central --dry-run
#     ./install-alloy-service.sh --central --target-config /tmp/test-alloy/config.alloy --skip-systemd
#
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default values (only used with --central flag)
CENTRAL_HOST_IDENTITY="primary-node"
CENTRAL_LOKI_URL="http://127.0.0.1:3100/loki/api/v1/push"
DEFAULT_RELOAD_ENDPOINT="http://127.0.0.1:12346/-/reload"

HOST_IDENTITY=""
LOKI_URL=""
IS_CENTRAL=false
DRY_RUN=false
OUTPUT_FILE=""
DO_RELOAD=false
RELOAD_ENDPOINT="${DEFAULT_RELOAD_ENDPOINT}"
SKIP_SYSTEMD=false

CONFIG_SOURCE="$REPO_ROOT/alloy/config.alloy"
CONFIG_TARGET="/etc/alloy/config.alloy"

# ==============================================================================
# Argument Parsing
# ==============================================================================
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install and configure the native Grafana Alloy service with a host-specific
identity that aligns Loki host labels with Prometheus instance labels.

Options:
  --central               Install for the central monitoring server.
                          Uses identity: ${CENTRAL_HOST_IDENTITY}
                          Uses Loki URL: ${CENTRAL_LOKI_URL}

  --host-identity NAME    Set the host identity label (e.g. node-02, node-03).
                          Must match [a-zA-Z0-9._-]+ pattern.
                          Required for remote installations.

  --loki-url URL          Set the central Loki push endpoint URL.
                          Must start with http:// or https://.
                          Required for remote installations.

  --reload                Trigger live configuration reload via POST to Alloy's
                          reload endpoint after successful deployment.
                          Automatically rolls back if reload fails.

  --reload-endpoint URL   Override the reload endpoint URL.
                          Default: ${DEFAULT_RELOAD_ENDPOINT}

  --target-config FILE    Override destination config path (default: /etc/alloy/config.alloy).

  --skip-systemd          Skip root checks, user/group modification, and systemd
                          daemon-reload. Ideal for non-root testing with --target-config.

  --output FILE           Render and validate configuration to specified FILE
                          without modifying system services (does not require root).

  --dry-run               Validate inputs and render configuration to a temporary
                          file to check syntax without modifying system services.

  --help|-h               Show this help message.

Examples:
  # Central monitoring server with live reload:
  sudo $0 --central --reload

  # Remote host with explicit identity and Loki endpoint:
  sudo $0 --host-identity node-02 --loki-url http://10.0.0.1:3100/loki/api/v1/push

  # Dry-run validation (non-root):
  $0 --central --dry-run
  $0 --host-identity node-03 --loki-url http://10.0.0.1:3100/loki/api/v1/push --output /tmp/node-03.alloy

EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --central)
            IS_CENTRAL=true
            shift
            ;;
        --host-identity)
            if [[ -z "${2:-}" ]]; then
                echo "[-] Error: --host-identity requires a value." >&2
                exit 1
            fi
            HOST_IDENTITY="$2"
            shift 2
            ;;
        --loki-url)
            if [[ -z "${2:-}" ]]; then
                echo "[-] Error: --loki-url requires a value." >&2
                exit 1
            fi
            LOKI_URL="$2"
            shift 2
            ;;
        --output)
            if [[ -z "${2:-}" ]]; then
                echo "[-] Error: --output requires a file path." >&2
                exit 1
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --target-config)
            if [[ -z "${2:-}" ]]; then
                echo "[-] Error: --target-config requires a file path." >&2
                exit 1
            fi
            CONFIG_TARGET="$2"
            shift 2
            ;;
        --skip-systemd)
            SKIP_SYSTEMD=true
            shift
            ;;
        --reload)
            DO_RELOAD=true
            shift
            ;;
        --reload-endpoint)
            if [[ -z "${2:-}" ]]; then
                echo "[-] Error: --reload-endpoint requires a URL." >&2
                exit 1
            fi
            RELOAD_ENDPOINT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage 0
            ;;
        *)
            echo "[-] Error: Unknown argument: $1" >&2
            usage 1
            ;;
    esac
done

# ==============================================================================
# Input Validation
# ==============================================================================
echo "=== Native Grafana Alloy Service Installer ==="

# Check root/sudo only if performing an actual system installation
if [[ "$DRY_RUN" == false && -z "$OUTPUT_FILE" && "$SKIP_SYSTEMD" == false ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "[-] Error: System installation must be run as root (or via sudo)." >&2
        echo "    Tip: Use --dry-run or --output <file> or --skip-systemd to test without root privileges." >&2
        exit 1
    fi
fi

# Resolve identity and URL
if [[ "$IS_CENTRAL" == true ]]; then
    # --central provides safe defaults; explicit overrides are allowed
    HOST_IDENTITY="${HOST_IDENTITY:-${CENTRAL_HOST_IDENTITY}}"
    LOKI_URL="${LOKI_URL:-${CENTRAL_LOKI_URL}}"
    echo "[+] Central server mode: identity=${HOST_IDENTITY}, loki_url=${LOKI_URL}"
else
    # Remote installations require explicit identity and Loki URL
    if [[ -z "$HOST_IDENTITY" ]]; then
        echo "[-] Error: --host-identity is required for remote installations." >&2
        echo "    Use --central for the primary monitoring server, or provide:" >&2
        echo "    --host-identity <name> --loki-url <url>" >&2
        exit 1
    fi
    if [[ -z "$LOKI_URL" ]]; then
        echo "[-] Error: --loki-url is required for remote installations." >&2
        echo "    Example: --loki-url http://10.0.0.1:3100/loki/api/v1/push" >&2
        exit 1
    fi
    echo "[+] Remote host mode: identity=${HOST_IDENTITY}, loki_url=${LOKI_URL}"
fi

# Validate host identity format (alphanumeric, dots, hyphens, underscores)
if ! [[ "$HOST_IDENTITY" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo "[-] Error: Invalid host identity '${HOST_IDENTITY}'." >&2
    echo "    Must start with alphanumeric and contain only [a-zA-Z0-9._-]." >&2
    exit 1
fi

# Validate Loki URL format
if ! [[ "$LOKI_URL" =~ ^https?:// ]]; then
    echo "[-] Error: Invalid Loki URL '${LOKI_URL}'." >&2
    echo "    Must start with http:// or https://." >&2
    exit 1
fi

# Verify source config exists
if [[ ! -f "$CONFIG_SOURCE" ]]; then
    echo "[-] Error: Repository Alloy config not found at: ${CONFIG_SOURCE}" >&2
    exit 1
fi

# ==============================================================================
# Helper Function: Render Configuration
# ==============================================================================
render_config() {
    local target_file="$1"
    local identity="$2"
    local loki_url="$3"
    local timestamp="$4"

    # Part 1: Header and dynamic components (parameterized)
    cat > "$target_file" <<ALLOY_DYNAMIC
// ==============================================================================
// Grafana Alloy Centralized Logging Pipeline
// Project: Linux System Monitoring & Reliability Lab
// Target Version: Grafana Alloy v1.0.0 / v1.21.2+
// Principles: Cardinality Bounds, Sensitive Data Redaction, Least Privilege
//
// THIS FILE WAS GENERATED by install-alloy-service.sh
// Host Identity: ${identity}
// Loki Endpoint: ${loki_url}
// Generated At:  ${timestamp}
//
// Do not edit manually. Re-run the installer to update.
// ==============================================================================

// ------------------------------------------------------------------------------
// 1. Loki Push Endpoint
// ------------------------------------------------------------------------------
loki.write "default" {
	endpoint {
		url        = "${loki_url}"
		batch_wait = "5s"
		batch_size = "1MiB"
	}
}

// ------------------------------------------------------------------------------
// 2. Linux Host Systemd Journal Collection
// ------------------------------------------------------------------------------
loki.source.journal "systemd" {
	max_age    = "6h"
	path       = "/var/log/journal"
	forward_to = [loki.relabel.journal_filter.receiver]
	labels     = {
		job         = "systemd-journal",
		environment = "lab",
		host        = "${identity}",
	}
}

// Relabel rules for systemd journal: promote low-cardinality metadata and drop noise
loki.relabel "journal_filter" {
	forward_to = [loki.process.journal_sanitization.receiver]

	// Enforce consistent host identity matching Prometheus instance label
	rule {
		source_labels = ["host"]
		regex         = ".*"
		target_label  = "host"
		replacement   = "${identity}"
	}
ALLOY_DYNAMIC

    # Part 2: Static relabeling and privacy scrubbing (quoted heredoc: zero escaping changes)
    cat >> "$target_file" <<'ALLOY_STATIC'

	// Extract standard systemd unit name into 'unit' label
	rule {
		source_labels = ["__journal__systemd_unit"]
		target_label  = "unit"
	}

	// Extract syslog identifier if unit is missing (e.g. linux-monitoring-agent)
	rule {
		source_labels = ["unit", "__journal_syslog_identifier"]
		regex         = ";(.*)"
		target_label  = "unit"
	}

	// Extract syslog priority keyword into standard 'level' label
	rule {
		source_labels = ["__journal_priority_keyword"]
		target_label  = "level"
	}

	// Extract kernel vs userland transport
	rule {
		source_labels = ["__journal__transport"]
		target_label  = "transport"
	}

	// Privacy & Safety: Drop user desktop sessions and desktop utility noise
	rule {
		source_labels = ["unit"]
		regex         = "user@.*\\.service|session-.*\\.scope|conky.*|pipewire.*|gnome-.*|pulseaudio.*"
		action        = "drop"
	}

	// Safety: Ensure bounded label set (drop dynamic unbounded process identifiers)
	rule {
		regex  = "__journal__pid|__journal__uid|__journal__gid|__journal_code_file|__journal_code_line"
		action = "labeldrop"
	}
}

// Sanitization & privacy scrubbing pipeline for systemd journal
loki.process "journal_sanitization" {
	forward_to = [loki.write.default.receiver]

	// Redact cleartext passwords, tokens, API keys, and bearer credentials
	stage.replace {
		expression = "(?i)(password|passwd|pwd|secret|token|api[_-]?key|bearer)\\s*[:=]\\s*([\"']?)([^\\s\"',;]+)([\"']?)"
		replace    = "$1=[REDACTED]"
	}

	// Redact HTTP Authorization headers
	stage.replace {
		expression = "(?i)Authorization:\\s*(Bearer\\s+)?[a-zA-Z0-9_\\-\\.]+"
		replace    = "Authorization: [REDACTED]"
	}

	// Redact sensitive command-line arguments (--password, --token, --api-key)
	stage.replace {
		expression = "(?i)(--password|--token|--api-key|--secret)\\s+([^\\s]+)"
		replace    = "$1 [REDACTED]"
	}

	// Redact session cookies and session tokens
	stage.replace {
		expression = "(?i)(session_id|sessionid|connect\\.sid)=([^\\s;,]+)"
		replace    = "$1=[REDACTED]"
	}

	// Privacy Safeguard: Mask personal user document paths in /home
	stage.replace {
		expression = "/home/[a-zA-Z0-9_-]+"
		replace    = "/home/[REDACTED_USER]"
	}
}
ALLOY_STATIC
}

# ==============================================================================
# Helper Function: Validate Configuration
# ==============================================================================
validate_config() {
    local file_to_validate="$1"
    echo "[+] Validating configuration syntax..."
    if command -v alloy >/dev/null 2>&1; then
        if alloy validate "$file_to_validate" 2>&1; then
            echo "[+] Configuration validation passed via native 'alloy validate'."
            return 0
        else
            echo "[-] Error: Configuration validation failed." >&2
            return 1
        fi
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^lab-alloy$'; then
        if docker exec -i lab-alloy alloy fmt - < "$file_to_validate" >/dev/null 2>&1; then
            echo "[+] Configuration validation passed via containerized 'alloy fmt'."
            return 0
        else
            echo "[-] Error: Configuration validation failed in container." >&2
            return 1
        fi
    else
        echo "[!] Warning: Neither native 'alloy' nor container 'lab-alloy' found. Skipping syntax validation."
        return 0
    fi
}

# ==============================================================================
# Handle Dry-Run or Custom Output File
# ==============================================================================
GENERATED_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    echo "[+] Rendering configuration to: ${OUTPUT_FILE}"
    render_config "$OUTPUT_FILE" "$HOST_IDENTITY" "$LOKI_URL" "$GENERATED_TIMESTAMP"
    validate_config "$OUTPUT_FILE"
    echo "[+] Output file successfully written and validated: ${OUTPUT_FILE}"
    exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
    TMP_DRYRUN="$(mktemp /tmp/alloy_dryrun_XXXXXX.alloy)"
    trap 'rm -f "$TMP_DRYRUN"' EXIT
    echo "[+] Performing dry-run configuration rendering..."
    render_config "$TMP_DRYRUN" "$HOST_IDENTITY" "$LOKI_URL" "$GENERATED_TIMESTAMP"
    validate_config "$TMP_DRYRUN"
    echo "[+] Dry-run completed successfully. Configuration is valid."
    exit 0
fi

# ==============================================================================
# Configuration Deployment
# ==============================================================================

# 1. User/Group Setup (if not skipped)
if [[ "$SKIP_SYSTEMD" == false ]]; then
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
fi

# 2. Backup existing configuration if present
TARGET_DIR="$(dirname "$CONFIG_TARGET")"
mkdir -p "$TARGET_DIR"
BACKUP_PATH=""
if [[ -f "$CONFIG_TARGET" ]]; then
    BACKUP_PATH="${CONFIG_TARGET}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "[+] Backing up existing config to ${BACKUP_PATH}..."
    cp "$CONFIG_TARGET" "$BACKUP_PATH"
    chmod 644 "$BACKUP_PATH"
fi

# 3. Render to temporary file in target directory
CONFIG_TMPFILE="$(mktemp "${CONFIG_TARGET}.XXXXXX")"
trap 'rm -f "$CONFIG_TMPFILE"' EXIT

echo "[+] Generating host-specific Alloy configuration..."
echo "    Host Identity: ${HOST_IDENTITY}"
echo "    Loki URL:      ${LOKI_URL}"
echo "    Target:        ${CONFIG_TARGET}"
render_config "$CONFIG_TMPFILE" "$HOST_IDENTITY" "$LOKI_URL" "$GENERATED_TIMESTAMP"
chmod 644 "$CONFIG_TMPFILE"

# 4. Validate configuration before replacing live file
if ! validate_config "$CONFIG_TMPFILE"; then
    echo "[-] Error: Rendered configuration is invalid. Aborting deployment." >&2
    if [[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]]; then
        echo "[+] Restoring previous configuration from ${BACKUP_PATH}..."
        cp "$BACKUP_PATH" "$CONFIG_TARGET"
    fi
    exit 1
fi

# 5. Atomic move
echo "[+] Deploying configuration to ${CONFIG_TARGET}..."
mv "$CONFIG_TMPFILE" "$CONFIG_TARGET"
trap - EXIT # Clear trap
if [[ "$SKIP_SYSTEMD" == false ]]; then
    chown root:alloy "$CONFIG_TARGET"
fi
chmod 644 "$CONFIG_TARGET"

# 6. Service Hardening & System Configuration (if not skipped)
if [[ "$SKIP_SYSTEMD" == false ]]; then
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
fi

# 7. Live Reload and Automated Rollback
if [[ "$DO_RELOAD" == true ]]; then
    echo "[+] Triggering live configuration reload on Alloy (${RELOAD_ENDPOINT})..."
    RELOAD_HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" -X POST "${RELOAD_ENDPOINT}" || true)"
    if [[ "$RELOAD_HTTP_CODE" == "200" ]]; then
        echo "[+] Alloy service successfully reloaded (HTTP 200)."
    else
        echo "[-] Error: Alloy service reload failed with HTTP ${RELOAD_HTTP_CODE}." >&2
        if [[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]]; then
            echo "[+] Automated Rollback: Restoring previous configuration from ${BACKUP_PATH}..."
            cp "$BACKUP_PATH" "$CONFIG_TARGET"
            echo "[+] Re-triggering reload on restored previous configuration..."
            curl -s -X POST "${RELOAD_ENDPOINT}" || true
            echo "[+] Rollback complete. Previous configuration restored."
        fi
        exit 1
    fi
fi

echo ""
echo "[+] Native Alloy service configuration installed successfully."
echo "    Host Identity: ${HOST_IDENTITY}"
echo "    Loki URL:      ${LOKI_URL}"
echo "    Config:        ${CONFIG_TARGET}"
if [[ -n "$BACKUP_PATH" ]]; then
    echo "    Backup:        ${BACKUP_PATH}"
fi
echo ""
echo "[+] To start:   systemctl start alloy.service"
echo "[+] To verify:  systemctl status alloy.service"
echo "[+] To reload:  curl -s -X POST ${RELOAD_ENDPOINT}"
