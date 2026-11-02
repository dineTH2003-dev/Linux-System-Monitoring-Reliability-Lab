# Reliability Testing Safety Boundaries & Invariant Contracts

**Project:** Linux System Monitoring & Reliability Lab  
**Specification:** Agent 10 — Safety Invariants & Blast Radius Controls  
**Author:** Senior SRE / Infrastructure Reliability Engineer  

---

## 1. Safety Principles & Operating Environment

All reliability tests execute on an active developer workstation running **Ubuntu 24.04 LTS** on physical hardware (Intel Core i7-1355U, 12 logical cores, 16GB RAM, NVMe SSD). The workstation runs interactive user processes (IDE, desktop shell, background services).

Consequently, the framework enforces a foundational invariant:

> **Fundamental Safety Invariant**: Under no circumstances may a test scenario compromise workstation responsiveness, trigger host Linux Out-Of-Memory (OOM) killing of user processes, exhaust physical storage capacity, alter default network routing, or destabilize core host systemd units.

---

## 2. Blast Radius Matrix & Boundary Guarantees

| Subsystem | Failure Simulation | Blast Radius Guarantee | Enforcement Mechanism |
|---|---|---|---|
| **Storage Capacity** | Space exhaustion simulation | Bounded to a dedicated 50MB loopback image or `/tmp` sandbox. Root filesystem (`/`) and physical NVMe partitions are strictly untouched. | `assert_not_root_mount()` in `common.sh`; rejects `/`, `/boot`, `/etc`, `/usr`, `/var/lib`. |
| **Storage Inodes** | Inode exhaustion simulation | Operates in disposable sandbox directory (`/tmp/lab_test_inode_mount`). Root filesystem has >31 million inodes untouched. | Pre-allocated count ($\le 1000$ files); automated cleanup of `test_inode_*.dat`. |
| **Compute / CPU** | Thread run-queue saturation | Pinned to maximum 2–4 logical cores at lowest CPU priority (`nice +19`). 8–10 host cores remain completely free for desktop tasks. | Kernel scheduler priority `nice -n 19`; hard timeout timer via `timeout` or Python watchdog. |
| **Memory / Swap** | Memory pressure simulation | Allocation capped strictly at 128MB–256MB (max allowed 1024MB). Host has ~7GB available RAM; host OOM killer cannot be invoked. | Bound parameter check; container cgroup `--memory=256m` or in-process bytearray with exit trap. |
| **Disk I/O Latency** | High await latency | Synchronous I/O loop (`O_SYNC` + `fdatasync`) running in a temporary directory throttled to 10–20 writes/sec. Zero impact on NVMe throughput. | Process sleeping between sync writes; watchdog termination after $\le 60\text{s}$. |
| **Networking** | Endpoint failure | Fault targets exclusively a canary server on port `8088`. Host physical NIC (`wlo1`), loopback (`lo`), DNS, and default routes are untouched. | Target validation; no `ip link set down` or global iptables rules. |
| **Observability Agent**| Agent stoppage | Fault targets the custom Python agent process (`agent.main`, `:9101`). Native host Node Exporter (`:9100`) and Prometheus (`:9090`) are preserved. | Targeted PID matching via `/tmp/lab_agent.pid`; `SIGTERM` signal dispatch. |
| **Metrics Exporter** | Exporter down | Targets a dedicated synthetic exporter on port `9102`. Host exporters remain active. | Dedicated test port binding; PID cleanup on exit. |
| **System Services** | Unit failure | Targets a dedicated user-space unit `lab-canary-user.service`. System services (`systemd-journald`, `sshd`, `NetworkManager`) are never touched. | Whitelist assertion `assert_whitelisted()`; user-level unit execution (`systemctl --user`). |

---

## 3. Automated Remediation Safety Guardrails

Automated remediation presents inherent operational risks if unconstrained. To eliminate runaway remediation cascades, the controller enforces 8 mandatory constraints:

1. **Explicit Preconditions**:
   - Before attempting remediation, the controller evaluates preconditions (verifying process state, port binding, and failure mode). Remediation aborts if preconditions are not satisfied.
2. **Strict Whitelisting**:
   - Only explicitly registered lab resources (`lab-canary-user.service`, `lab_agent`, `test_mount`) can be modified. Arbitrary unit restarts or process kills are rejected.
3. **Execution Timeouts**:
   - Every remediation step enforces a strict execution timeout (default: 10.0 seconds). A hung restart command is terminated automatically.
4. **Retry Caps & Exponential Backoff**:
   - The controller permits a maximum of **3 consecutive retry attempts**. Each retry introduces linear/exponential backoff delay ($1\text{s}, 2\text{s}$) to allow state propagation.
5. **Circuit Breaker Protection**:
   - If 3 attempts fail within a 10-minute (600s) cooldown window, the circuit breaker trips to `OPEN`. All further automated remediation for that target is halted, preventing service restart loops.
6. **Strict Idempotency**:
   - If a target passes verification before remediation begins (e.g. service is already healthy), the controller returns `ALREADY_HEALTHY` without executing modifying actions.
7. **Rollback Strategy**:
   - If retries are exhausted without successful verification, the controller executes a registered rollback routine to leave the system in a known safe state.
8. **Human Approval Gate**:
   - High-risk operations require an explicit operator token (`SRE_REMEDIATION_APPROVED=1`). Without this token, execution halts with status `APPROVAL_REQUIRED`.

---

## 4. Prohibited Commands & Anti-Patterns

The following operational actions are strictly forbidden within the repository:
- ❌ Recursive deletion (`rm -rf`) across unvalidated paths or system directories.
- ❌ Arbitrary process termination (`killall -9 python`, `pkill -9 -f systemd`).
- ❌ Unbounded memory stress (`stress-ng --vm 4 --vm-bytes 100%`).
- ❌ Physical interface manipulation (`ip link set wlo1 down`).
- ❌ Writing to physical block devices (`dd of=/dev/nvme0n1`).
- ❌ Infinite service restart loops without retry bounds or circuit breakers.
