# Environment Assessment & Host Baseline Report

**Execution Date:** 2026-10-28  
**Auditor:** Senior Site Reliability Engineer / Linux Infrastructure Engineer  
**Target Environment:** Local Ubuntu 24.04 LTS Workstation  
**Project:** Linux System Monitoring & Reliability Lab  

---

## 1. Operating System & Kernel Specifications

The host environment was audited using native Linux diagnostic tools (`/etc/os-release`, `uname`, `hostnamectl`, `uptime`).

| Parameter | Observed Value | Command Source |
|---|---|---|
| **Distribution** | Ubuntu 24.04.5 LTS (Noble Numbat) | `cat /etc/os-release` |
| **Kernel Release** | `7.0.0-38-generic` | `uname -r` |
| **Kernel Build** | `Linux version 7.0.0-38-generic (buildd@lcy02-amd64-077)` | `cat /proc/version` |
| **System Architecture**| `x86_64` (AMD64 / Intel 64) | `uname -m` |
| **Static Hostname** | `rubi` | `hostname` |
| **Chassis & Hardware** | MSI Modern 15 B13M Laptop | `hostnamectl` |
| **Firmware Date** | Tue 2023-05-09 (BIOS E15H1IMS.307) | `hostnamectl` |
| **System Uptime** | 3 days, 15 hours | `uptime -p` |
| **System Load Average**| `4.97, 3.75, 2.99` (1m, 5m, 15m) | `uptime` |

---

## 2. CPU Architecture & Compute Resources

Hardware inspection was executed via `lscpu` and `/proc/cpuinfo`.

| Parameter | Specification | Details |
|---|---|---|
| **Processor Model** | 13th Gen Intel(R) Core(TM) i7-1355U | Modern hybrid performance/efficiency mobile architecture |
| **Architecture** | `x86_64` | 64-bit |
| **Physical Sockets** | 1 | Single-socket mobile BGA |
| **Physical Cores** | 10 | 2 Performance Cores (P-cores) + 8 Efficient Cores (E-cores) |
| **Logical Processors** | 12 | P-cores hyperthreaded (2 x 2) + 8 E-cores (8 x 1) |
| **Threads per Core** | 2 (P-cores) / 1 (E-cores) | Averaged as 2 by `lscpu` |
| **NUMA Nodes** | 1 (Node 0: CPUs 0-11) | Unified memory access |
| **Virtualization** | Intel VT-x (`vmx`) | Hardware-assisted virtualization verified active in `/proc/cpuinfo` |

---

## 3. Memory & Swap Configuration

Evaluated using `free -h`, `/proc/meminfo`, and `swapon --show`.

| Metric | Capacity | Utilization / Details |
|---|---|---|
| **Total Physical RAM** | 15 GiB (15,691,568 kB) | Raw physical memory installed |
| **Used RAM** | 8.3 GiB | Active applications and system services |
| **Free RAM** | 4.1 GiB | Completely unallocated memory |
| **Buffer / Page Cache**| 4.5 GiB | Kernel disk page caches and buffers |
| **Available RAM** | 7.0 GiB | Memory available for new workloads without swapping |
| **Swap Space Total** | 4.0 GiB (4,194,300 kB) | File-backed swap at `/swap.img` (priority -1) |
| **Swap Space Used** | 642.1 MiB (15.7%) | Normal minor paging under interactive usage |

---

## 4. Storage Subsystem & Filesystems

Inspected via `lsblk -f`, `df -h`, and `df -i`.

### 4.1 Block Devices & Partition Layout
- **Physical Device**: `nvme0n1` (NVMe SSD, 476.9 GiB)
  - `nvme0n1p1`: EFI System Partition (vfat), 1.0 GiB mounted at `/boot/efi`
  - `nvme0n1p2`: Linux root filesystem (ext4), 468 GiB mounted at `/`

### 4.2 Filesystem Capacity & Inodes
| Filesystem | Mount Point | Size | Used | Available | Use % | Total Inodes | Inodes Used | Inode % |
|---|---|---|---|---|---|---|---|---|
| `/dev/nvme0n1p2` | `/` (root) | 468 GiB | 124 GiB | 320 GiB | **28%** | 31,195,136 | 1,325,436 | **5%** |
| `/dev/nvme0n1p1` | `/boot/efi` | 1.1 GiB | 6.2 MiB | 1.1 GiB | **1%** | 0 | 0 | - |
| `tmpfs` | `/run` | 1.6 GiB | 3.2 MiB | 1.6 GiB | 1% | 2,008,521 | 1,751 | 1% |
| `tmpfs` | `/dev/shm` | 7.7 GiB | 86 MiB | 7.6 GiB | 2% | 2,008,521 | 139 | 1% |

**SRE Safety Assessment**: Root storage has 320 GiB available and 95% free inodes. Controlled failure experiments will have ample capacity, but must strictly use bounded temporary mounts rather than filling `/`.

---

## 5. Networking Configuration & Port Allocation

Audited using `ip addr`, `ip route`, `resolvectl status`, and `ss -tuln`.

### 5.1 Interfaces & IP Addressing
- **`lo` (Loopback)**: `127.0.0.1/8`, `::1/128`
- **`wlo1` (Wireless Network)**: State `UP`, IP: `10.10.x.x/19` (DHCP), Default Gateway: `10.10.x.254`
- **DNS Resolution**: `systemd-resolved` local stub at `127.0.0.53:53` / `127.0.0.54:53`. Upstream DNS configured via DHCP (Domain: internal).

### 5.2 Listening Ports Audit & Conflict Analysis
A crucial audit finding is that **standard monitoring ports are already occupied by host-level native systemd services**:

| Port | Protocol | Binding | Process / Service | Conflict Significance |
|---|---|---|---|---|
| **9090** | TCP | `0.0.0.0:9090` | `/usr/bin/prometheus` (systemd: `prometheus.service`) | **CRITICAL**: Standard Prometheus port occupied on host |
| **9100** | TCP | `0.0.0.0:9100` | `/usr/bin/prometheus-node-exporter` (systemd) | **CRITICAL**: Standard Node Exporter port occupied on host |
| **3000** | TCP | `0.0.0.0:3000` | `/usr/share/grafana/bin/grafana` (systemd) | **CRITICAL**: Standard Grafana port occupied on host |
| **22** | TCP | `0.0.0.0:22` | `systemd` (`ssh.socket` OpenSSH server) | Normal remote administration port |
| **5432** | TCP | `127.0.0.1:5432` | Local PostgreSQL instance | Development service |
| **5433** | TCP | `0.0.0.0:5433` | Docker container `taskmanager-postgres` | Container service |
| **3306** | TCP | `127.0.0.1:3306` | Local MySQL instance | Development service |

---

## 6. System Services & systemd Health

Audited via `systemctl is-system-running`, `systemctl list-units`.

- **systemd State**: `degraded`
- **Failed Units**:
  1. `apport-autoreport.service`: Automatic error crash reporting service failure.
  2. `openipmi.service`: IPMI driver initialization failure (expected on consumer mobile hardware lacking IPMI baseboard management controllers).
- **Core System Services**:
  - `NetworkManager`: **Active** (running)
  - `systemd-resolved`: **Active** (running)
  - `systemd-journald`: **Active** (running)
  - `ufw` (Uncomplicated Firewall): **Active** (running)
  - `ssh.socket`: **Active** (ssh.service triggers on demand)
  - `prometheus.service`: **Active** (running natively)
  - `prometheus-node-exporter.service`: **Active** (running natively)
  - `grafana-server.service`: **Active** (running natively)

---

## 7. Development Tools & Tooling Audit

| Tool | Status | Version / Path | Purpose in Lab |
|---|---|---|---|
| **Git** | ✅ Installed | `2.43.0` (`/usr/bin/git`) | Monorepo version control |
| **Python 3** | ✅ Installed | `3.12.3` (`/usr/bin/python3`) | Custom agent and log parser |
| **pip / pip3** | ✅ Installed | `26.1.1` (`~/.local/bin/pip`) | Python package management |
| **venv** | ✅ Available | Python standard library `venv` | Isolated agent virtual environment |
| **psutil** | ✅ Available | Python module in user site-packages | Kernel & process sampling library |
| **pyyaml** | ✅ Available | Python module | Agent configuration parser |
| **Docker** | ✅ Installed | `29.9.1` (`/usr/local/bin/docker`) | Containerized monitoring services |
| **Docker Compose**| ✅ Installed | `v5.1.4` (plugin `docker compose`) | Multi-service orchestration |
| **curl** | ✅ Installed | `8.5.0` (`/usr/bin/curl`) | HTTP probing and API queries |
| **wget** | ✅ Installed | `1.21.4` (`/usr/bin/wget`) | File downloading |
| **jq** | ✅ Installed | `1.7` (`/usr/bin/jq`) | JSON CLI parser for API responses |
| **htop** | ✅ Installed | `3.3.0` (`/usr/bin/htop`) | Interactive terminal process viewer |
| **sysstat** | ✅ Installed | `sar` 12.6.1, `iostat` 12.6.1 | Host performance measurement suite |
| **stress-ng** | ❌ **Missing** | Not found in `$PATH` | Required for Phase 5 & 8 stress experiments |
| **shellcheck** | ❌ **Missing** | Not found in `$PATH` | Required for static analysis of Bash scripts |
| **pytest** | ⚠️ In venv | Missing globally, will reside in project `.venv` | Agent unit testing |

---

## 8. Docker Architecture Discovery

The Docker daemon is provided by **Docker Desktop for Linux** (`/opt/docker-desktop/`), operating through an accelerated QEMU LinuxKit virtual machine (`/usr/bin/qemu-system-x86_64 -accel kvm ... -m 3922`).

**SRE Implications**:
1. Containers run inside the virtualized LinuxKit kernel, not directly on the host's Linux 7.0 kernel.
2. In Docker Compose, bridging to the host's native Node Exporter on `:9100` cannot use `localhost:9100` (which would point inside the container); it must route via `host.docker.internal:9100` or host network mode.
3. The existing native Node Exporter running on port 9100 directly monitors the physical Ubuntu host, which is the intended architecture.

---

## 9. Environment Readiness Assessment

### **Classification: Partially Ready**

### Identified Issues & Technical Risks:
1. **Prerequisite Gaps**:
   - `stress-ng` is missing; required to execute CPU, memory, and disk stress experiments.
   - `shellcheck` is missing; required to validate Bash scripts in Phase 2.
2. **Port Binding Conflicts with Existing Native Services**:
   - `prometheus` is already running natively on port 9090.
   - `prometheus-node-exporter` is already running natively on port 9100.
   - `grafana-server` is already running natively on port 3000.
   - *Risk*: Running `docker compose up` with standard mappings `9090:9090` and `3000:3000` will fail with `bind: address already in use`.
3. **Docker Desktop Network Routing**:
   - Docker containers do not share the physical host network namespace by default.

---

## 10. SRE Recommendations & Action Plan

1. **Package Installation**:
   Install missing testing and linting tools via apt:
   ```bash
   sudo apt update && sudo apt install -y stress-ng shellcheck
   ```
2. **Service Strategy for Prometheus & Grafana**:
   We have two production-sound options:
   - **Option A (Integrated Hybrid)**: Utilize the existing native Node Exporter (:9100) on the host, and stop/disable the native Prometheus (:9090) and Grafana (:3000) services so our reproducible Docker Compose monitoring stack has full control of ports 9090 and 3000.
   - **Option B (Port Isolated)**: Map the Docker Compose monitoring stack to dedicated lab ports (e.g., Prometheus `:9091`, Grafana `:3001`, Alertmanager `:9093`, Custom Agent `:9101`) to avoid touching existing host services.
   - *Recommendation*: Option A provides the most authentic production layout once user approval is granted, or Option B if the user has production workloads on the existing Grafana/Prometheus.
3. **Python Virtual Environment**:
   Initialize a dedicated virtual environment in `./.venv` for Phase 2 to manage `pytest`, `psutil`, and `pyyaml` cleanly without contaminating host Python.
