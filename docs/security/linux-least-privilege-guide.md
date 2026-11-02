# Linux Host Security & Least Privilege Engineering Guide

**Project:** Linux System Monitoring & Reliability Lab  
**Document Ref:** SEC-04 — Host Security & Systemd Sandboxing  
**Author:** Agent 11 (Infrastructure Security & Deployment Engineer)  

---

## 1. Operating System Least-Privilege Principles

Security on modern Linux systems requires defense-in-depth across the filesystem hierarchy, kernel interfaces (`/proc`, `/sys`), process execution environments, and service managers (`systemd`).

In this project:
1. **Zero Root Processes for Monitoring**: Neither the Python custom monitoring agent nor the containerized monitoring services execute as root (UID 0).
2. **Explicit Filesystem Modes**: Permissions are deterministically enforced across code, configuration, scripts, and sensitive assets.
3. **Kernel Namespace & Directives Sandboxing**: Systemd services utilize modern kernel isolation directives to minimize attack surfaces.
4. **Log Privacy & Data Scrubbing**: Telemetry collectors scrub process arguments and memory maps to prevent credential leakage.

---

## 2. Filesystem Permissions Standard

The project implements a deterministic permissions hierarchy enforced via `security/harden_permissions.sh`:

| Asset Class | Target Paths | Permissions | Symbolic Mode | Rationale |
|---|---|---|---|---|
| **Operational & Test Scripts** | `scripts/**/*.sh`, `security/*.sh`, `deployment/*.sh` | `0755` | `rwxr-xr-x` | Executable by owner/group; non-writable by unprivileged users. |
| **Python Code Modules** | `agent/**/*.py`, `tests/**/*.py` | `0644` | `rw-r--r--` | Read/write by owner; non-executable preventing direct binary execution tricks. |
| **Declarative Configurations** | `prometheus/**/*.yml`, `grafana/**/*.json`, `loki/*.yml` | `0644` | `rw-r--r--` | Readable by container unprivileged UIDs; tamper-proof. |
| **Environment Configuration** | `.env` | `0600` | `rw-------` | Strictly restricted to owner; zero group/other read permissions. |
| **Public Templates & Docs** | `.env.example`, `docs/**/*.md`, `README.md` | `0644` | `rw-r--r--` | Standard public documentation modes. |
| **Repository Directories** | All non-hidden directories | `0755` | `rwxr-xr-x` | Traversal and listing enabled for operational users. |

### Automated Enforcement:
```bash
./security/harden_permissions.sh
```
This utility walks the repository and idempotently restores baseline permissions, eliminating accidental over-permissioning or world-writable bits (`0777`).

---

## 3. Python Monitoring Agent Hardening & Systemd Sandboxing

The custom Python monitoring agent (`linux-monitoring-agent`) executes on the bare-metal Linux host to access `/proc`, `/sys`, and systemd D-Bus telemetry.

To prevent this service from becoming an escalation vector, it is defined under `deployment/systemd/linux-monitoring-agent.service` with an exhaustive set of Linux kernel sandboxing directives:

### 3.1 Sandboxing Directives Explained:

| Directive | Configured Value | Security Protection Provided |
|---|---|---|
| `NoNewPrivileges` | `yes` | Ensures that child processes cannot acquire new privileges via `setuid` or `setgid` binaries (e.g. `sudo`, `passwd`). |
| `ProtectSystem` | `strict` | Mounts the entire host filesystem (`/usr`, `/boot`, `/etc`) as read-only for the service. |
| `ProtectHome` | `read-only` | Prevents the agent from writing to `/home`, `/root`, and `/run/user`. |
| `PrivateTmp` | `yes` | Mounts an isolated, private `/tmp` and `/var/tmp` namespace, preventing cross-process tmpfile tampering. |
| `ProtectKernelTunables` | `yes` | Prohibits access to `/proc/sys`, `/sys`, `/proc/sysrq-trigger`, preventing kernel reconfiguration. |
| `ProtectControlGroups` | `yes` | Prohibits modification of host cgroup hierarchies. |
| `ProtectKernelModules` | `yes` | Prohibits loading or unloading Linux kernel modules. |
| `ProtectClock` | `yes` | Prevents changes to the hardware clock or system time. |
| `ProtectHostname` | `yes` | Isolates UTS namespace, preventing hostname alteration. |
| `LockPersonality` | `yes` | Locks the execution domain to prevent personality switching (e.g., 32-bit emulation exploits). |
| `MemoryDenyWriteExecute` | `yes` | Prohibits memory allocations that are simultaneously writable and executable (`W^X`), preventing runtime shellcode injection. |
| `RestrictRealtime` | `yes` | Prohibits real-time process scheduling (preventing CPU starvation attacks). |
| `RestrictSUIDSGID` | `yes` | Prohibits creating or executing SUID/SGID files. |
| `RestrictNamespaces` | `yes` | Prohibits the creation of new namespaces. |
| `CapabilityBoundingSet` | *(empty)* | Completely strips all Linux kernel capabilities. |
| `RestrictAddressFamilies`| `AF_INET AF_INET6 AF_UNIX` | Restricts network sockets to IPv4, IPv6, and local UNIX sockets; blocks packet sockets and raw networking. |

---

## 4. Log Privacy & Telemetry Redaction

Observability tools that sample process states or kernel telemetry risk harvesting credentials passed via command-line arguments or environment variables.

### Applied Protections:
1. **Process Name Sanitization**:
   In `agent/collector/process.py`, the collector parses process names using regex `re.compile(r"[^a-zA-Z0-9_\-\.:]")` and strips all command-line arguments. Process paths are reduced to their binary basename (e.g., `/usr/bin/python3 -s -m app --password secret` becomes simply `python3`).
2. **Structured Log Redaction**:
   All monitoring scripts in `scripts/monitoring/` write data and error logs to stderr, reserving stdout strictly for valid JSON data structures. Sensitive environment variables are never echoed into log streams.
3. **Filesystem Filters**:
   The Python agent configuration (`agent/config.yaml`) explicitly ignores virtual, pseudo, and sensitive filesystems (`autofs`, `bpf`, `cgroup`, `securityfs`, `tracefs`, `/run`, `/snap`, `/sys`), avoiding unintentional metadata harvesting.
