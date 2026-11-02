# Container Security Profile & Hardening Matrix

**Project:** Linux System Monitoring & Reliability Lab  
**Document Ref:** SEC-02 — Container Security Profile  
**Author:** Agent 11 (Infrastructure Security & Deployment Engineer)  
**Standard:** Alignment with CIS Docker Benchmark Principles & NIST SP 800-190 (Project Hardening Profile)

---

## 1. Executive Overview

Containerized observability systems frequently require deep access to host telemetry, creating substantial security risks if containers are misconfigured with default root privileges or loose runtime capabilities.

This specification documents the container security controls applied across the Docker Compose monitoring stack (`docker-compose.yml`), detailing non-root execution profiles, capability shedding, immutable filesystem boundaries, resource caps, and documented exceptions.

---

## 2. Hardening Matrix Across Lab Containers

| Security Control | Prometheus Server | Grafana Server | Alertmanager | Loki Log Store | Blackbox Exporter | CIS Benchmark Ref |
|---|---|---|---|---|---|---|
| **Image Version Pinning** | `prom/prometheus:v2.51.0` | `grafana/grafana:10.4.1` | `prom/alertmanager:v0.27.0` | `grafana/loki:3.0.0` | `prom/blackbox-exporter:v0.25.0` | CIS 4.4 |
| **Execution User (UID:GID)**| `65534:65534` (`nobody`) | `472:472` (`grafana`) | `65534:65534` (`nobody`) | `10001:10001` (`loki`) | `65534:65534` (`nobody`) | CIS 4.1 |
| **Read-Only Root Filesystem**| `read_only: true` | `read_only: true` | `read_only: true` | `read_only: true` | `read_only: true` | CIS 5.12 |
| **Linux Capabilities** | `cap_drop: [ALL]` | `cap_drop: [ALL]` | `cap_drop: [ALL]` | `cap_drop: [ALL]` | `cap_drop: [ALL]` | CIS 5.3 |
| **No New Privileges** | `true` | `true` | `true` | `true` | `true` | CIS 5.25 |
| **Host Loopback Binding** | `127.0.0.1:9091` | `127.0.0.1:3001` | `127.0.0.1:9093` | `127.0.0.1:3100` | `127.0.0.1:9115` | CIS 5.13 |
| **Memory Limit** | `1024M` (Reservation: 256M)| `512M` (Reservation: 128M)| `256M` (Reservation: 64M) | `512M` (Reservation: 128M)| `128M` (Reservation: 32M) | CIS 5.10 |
| **CPU Limit** | `1.0` core | `1.0` core | `0.5` core | `0.5` core | `0.25` core | CIS 5.11 |
| **Docker Socket Mounted** | **NO** | **NO** | **NO** | **NO** | **NO** | CIS 5.31 |
| **Privileged Mode** | **NO** (`false`) | **NO** (`false`) | **NO** (`false`) | **NO** (`false`) | **NO** (`false`) | CIS 5.4 |
| **Health Check Defined** | Yes (`/-/healthy`) | Yes (`/api/health`) | Yes (`/-/healthy`) | Yes (`/ready`) | Yes (`/-/healthy`) | CIS 4.6 |

---

## 3. Deep-Dive Security Controls

### 3.1 Non-Root User Execution & UID Pinning
Running containers as root (UID 0) within a container exposes the underlying host kernel to privilege escalation vulnerabilities (e.g., Dirty COW, CVE-2024-21626 runc breakout).
- **Prometheus & Alertmanager & Blackbox**: Default to `nobody:nobody` (`65534:65534`), an unprivileged system account possessing zero write permissions on system directories.
- **Grafana**: Defaults to standard service UID `472:472`, with ownership strictly scoped to `/var/lib/grafana`.
- **Loki**: Pinned to UID `10001:10001`, isolating log chunk files from system users.

### 3.2 Linux Capability Shedding (`cap_drop: [ALL]`)
By default, the Docker runtime grants containers a default set of 14 Linux capabilities (such as `CAP_CHOWN`, `CAP_NET_BIND_SERVICE`, `CAP_FOWNER`, `CAP_SETUID`).
In our lab architecture:
- **All capabilities are dropped (`cap_drop: [ALL]`) across all 5 containers.**
- No container requires privileged raw sockets or system configuration rights.
- **Documented Exception — Blackbox ICMP Probing**: If ICMP ping probing (`icmp_ping` module) is enabled in Blackbox Exporter, the Linux kernel requires `CAP_NET_RAW`. In this lab, HTTP and TCP probing are the primary probers (`http_2xx`, `tcp_connect`), which execute completely in user space without capabilities. If ICMP is required in future phases, only `CAP_NET_RAW` should be explicitly added to Blackbox via `cap_add: [NET_RAW]`, keeping all other capabilities dropped.

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
