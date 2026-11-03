# Container Security Profile & Hardening Matrix

**Project:** Linux System Monitoring & Reliability Lab  
**Scope:** Docker Security Controls, CIS Benchmark Principles, Capability Dropping & Filesystem Immutability  

---

## 1. Executive Overview

Containerized observability systems frequently require deep access to host telemetry, creating substantial security risks if containers are misconfigured with default root privileges or loose runtime capabilities.

This specification documents the container security controls applied across the Docker Compose monitoring stack (`docker-compose.yml`), detailing non-root execution profiles, capability shedding, immutable filesystem boundaries, resource caps, and documented exceptions.

---

## 2. Hardening Matrix Across Lab Containers

| Security Control | Prometheus | Grafana | Alertmanager | Loki | Blackbox | Grafana Alloy | CIS Ref |
|---|---|---|---|---|---|---|---|
| **Image Version Pinning** | `prom/prometheus:v2.51.0` | `grafana/grafana:10.4.1` | `prom/alertmanager:v0.27.0` | `grafana/loki:3.0.0` | `prom/blackbox-exporter:v0.25.0` | `grafana/alloy:v1.0.0` | CIS 4.4 |
| **Execution User (UID:GID)**| `65534:65534` (`nobody`) | `472:472` (`grafana`) | `65534:65534` (`nobody`) | `10001:10001` (`loki`) | `65534:65534` (`nobody`) | `0:999` (`root:systemd-journal`) | CIS 4.1 |
| **Read-Only Root Filesystem**| `read_only: true` | `read_only: true` | `read_only: true` | `read_only: true` | `read_only: true` | `read_only: true` | CIS 5.12 |
| **Linux Capabilities** | `cap_drop: [ALL]` | `cap_drop: [ALL]` | `cap_drop: [ALL]` | `cap_drop: [ALL]` | `cap_drop: [ALL]`, `cap_add: [NET_RAW]` | `cap_drop: [ALL]`, `cap_add: [NET_BIND_SERVICE]` | CIS 5.3 |
| **No New Privileges** | `true` | `true` | `true` | `true` | `true` | `true` | CIS 5.25 |
| **Host Loopback Binding** | `127.0.0.1:9091` | `127.0.0.1:3001` | `127.0.0.1:9093` | `127.0.0.1:3100` | `127.0.0.1:9115` | `127.0.0.1:12345` | CIS 5.13 |
| **Memory Limit** | `1024M` (Res: 256M) | `512M` (Res: 128M) | `256M` (Res: 64M) | `512M` (Res: 128M) | `128M` (Res: 32M) | `384M` (Res: 64M) | CIS 5.10 |
| **CPU Limit** | `1.0` core | `1.0` core | `0.5` core | `0.5` core | `0.25` core | `0.5` core | CIS 5.11 |
| **Docker Socket Mounted** | **NO** | **NO** | **NO** | **NO** | **NO** | **NO** | CIS 5.31 |
| **Privileged Mode** | **NO** (`false`) | **NO** (`false`) | **NO** (`false`) | **NO** (`false`) | **NO** (`false`) | **NO** (`false`) | CIS 5.4 |
| **Health Check Defined** | Yes (`/-/healthy`) | Yes (`/api/health`) | Yes (`/-/healthy`) | Yes (`/ready`) | Yes (`/-/healthy`) | Yes (`/-/ready`) | CIS 4.6 |

---

## 3. Deep-Dive Security Controls

### 3.1 Non-Root User Execution & UID Pinning
Running containers as root (UID 0) within a container exposes the host kernel to privilege escalation vulnerabilities.
- **Prometheus & Alertmanager & Blackbox**: Default to `nobody:nobody` (`65534:65534`), an unprivileged system account with no write permissions outside dedicated mounts.
- **Grafana**: Defaults to standard service UID `472:472`, with ownership strictly scoped to `/var/lib/grafana`.
- **Loki**: Pinned to UID `10001:10001`, isolating log chunk files from system users.
- **Grafana Alloy**: Configured with `user: "0:999"`. Primary GID 999 (`systemd-journal`) provides read access to host journal files (`/var/log/journal` mode 0640). Hardening is enforced through dropped capabilities, `no-new-privileges: true`, and read-only host mounts.

### 3.2 Linux Capability Shedding (`cap_drop: [ALL]`)
By default, Docker grants containers 14 default Linux capabilities. In our lab:
- All containers drop all capabilities (`cap_drop: [ALL]`).
- **Blackbox Exporter**: Explicitly adds `cap_add: [NET_RAW]` to permit ICMP ping probes without requiring root privileges.
- **Grafana Alloy**: Explicitly adds `cap_add: [NET_BIND_SERVICE]` for its internal HTTP server. All other capabilities remain dropped.

### 3.3 Immutable Runtimes (`read_only: true`)
A key defense against container persistence and runtime file tampering is mounting the container's root filesystem as read-only.
- Attackers cannot download malware, modify binaries in `/bin` or `/usr/bin`, or alter `/etc/resolv.conf`.
- **Documented Writable Exceptions**:
  1. **Prometheus**: Requires write access for TSDB chunks and WAL. Mounted to named volume `lab_prometheus_data` on `/prometheus`. Temporary scratch space provided via in-memory `tmpfs` at `/tmp:noexec,nosuid,size=64M`.
  2. **Grafana**: Requires database and plugin cache writes. Mounted to named volume `lab_grafana_data` on `/var/lib/grafana`. Temporary files and logging scratch space mounted via `tmpfs` at `/tmp` (64M) and `/var/log/grafana` (32M).
  3. **Alertmanager**: Requires alert silence and notification state writes. Mounted to named volume `lab_alertmanager_data` on `/alertmanager`. `tmpfs` at `/tmp` (32M).
  4. **Loki**: Requires TSDB index and chunk writes. Mounted to named volume `lab_loki_data` on `/loki`. `tmpfs` at `/tmp` (128M).
  5. **Blackbox**: Completely stateless prober. Requires only in-memory `tmpfs` at `/tmp:noexec,nosuid,size=16M`.

### 3.4 Host Loopback Isolation & Network Security
- **Wildcard Port Elimination**: Under standard Docker Compose setups, port mappings like `9091:9090` bind to `0.0.0.0:9091`, exposing the container to all connected network adapters (including the host's Wi-Fi interface `wlo1`).
- **Enforced Loopback**: Every port mapping in `docker-compose.yml` strictly prefixes the host IP: `"${HOST_BIND_IP:-127.0.0.1}:${PORT}:${CONTAINER_PORT}"`.
- **Custom Isolated Bridge**: Services communicate internally over `lab-monitoring-net` (`172.28.0.0/16`), segregated from default Docker bridges and external containers.

### 3.5 Bounded Resource Allocations
To eliminate Denial of Service (DoS) risks stemming from runaway TSDB scrapes or log flooding, hard memory and CPU quotas are enforced via `deploy.resources.limits`:
- Total Stack CPU Allocation Cap: `3.25` logical cores (Host capacity: 12 logical processors).
- Total Stack RAM Allocation Cap: `2.44` GiB (Host capacity: 15 GiB physical RAM).
- Memory reservations guarantee that baseline services cannot be starved by transient spikes.

---

## 4. Verification and Compliance Tooling

Automated verification of this security profile is executed via:
```bash
./security/container_audit.sh
```
This utility parses `docker compose config` and asserts 42 project-defined container hardening checks across all 6 services (verifying non-root execution, dropped capabilities, no-new-privileges, read-only root filesystems, loopback port bindings, resource bounds, and healthcheck configurations), failing with a non-zero exit code if any check is violated.
