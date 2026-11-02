# Automated Self-Healing & Safe Remediation Architecture

**Project:** Linux System Monitoring & Reliability Lab  
**Specification:** Automated Remediation Controller & Safety Engine (Phase 8)  
**Author:** Senior Site Reliability Engineer (Agent 10)  

---

## 1. Architectural Philosophy

Automated remediation in the Linux System Monitoring & Reliability Lab operates under a fundamental principle: **Self-healing must never create a worse incident than the failure it seeks to resolve.**

Off-the-shelf automated scripts frequently lead to secondary outages due to:
1. Infinite restart loops under persistent configuration corruption.
2. Unchecked resource exhaustion caused by rapid flapping.
3. Collateral damage from overly broad commands (e.g. `rm -rf` or `killall`).
4. Blind execution without verifying the post-remediation health state.

Our framework addresses this by implementing a **Guarded Remediation Controller** (`scripts/reliability/remediation/controller.py`) that wraps every recovery action in a formal safety contract.

---

## 2. Guardrail Contract & Architecture

```
                  ┌───────────────────────────────┐
                  │    Alert Firing / Anomaly     │
                  └──────────────┬────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                 SAFE REMEDIATION CONTROLLER                     │
│                                                                 │
│  [Step 1: Human Approval Gate]                                  │
│  • Does target require manual approval?                         │
│    YES ──▶ Is SRE_REMEDIATION_APPROVED=1?                       │
│            NO  ──▶ HALT (APPROVAL_REQUIRED)                    │
│                                                                 │
│  [Step 2: Circuit Breaker Inspection]                           │
│  • Have >= 3 attempts failed in last 10 minutes?                │
│    YES ──▶ HALT (CIRCUIT_OPEN) & Trigger Alert                  │
│                                                                 │
│  [Step 3: Precondition & Idempotency Check]                     │
│  • Is target already healthy?                                   │
│    YES ──▶ NO-OP (ALREADY_HEALTHY)                              │
│  • Do failure preconditions match?                              │
│    NO  ──▶ HALT (PRECONDITION_FAILED)                           │
│                                                                 │
│  [Step 4: Bounded Execution with Timeout]                       │
│  • Execute targeted handler (timeout: 10.0s)                    │
│  • Log audit trail entry                                        │
│                                                                 │
│  [Step 5: Post-Remediation Verification]                        │
│  • Poll health check / assertion                                │
│    PASS ──▶ SUCCESS (Reset failure count)                       │
│    FAIL ──▶ Retry with Backoff (Up to 3x)                       │
│                                                                 │
│  [Step 6: Fallback & Rollback]                                  │
│  • If 3 retries exhausted: Execute registered rollback handler  │
│  • Record trip in circuit breaker state                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. The 8 Safety Pillars

### 3.1 Strict Preconditions
Every remediation handler defines explicit criteria before executing:
- Verifies process identity via recorded PID file.
- Confirms unit failure state via `systemctl is-failed`.
- Asserts that target paths are strictly within sandbox bounds.

### 3.2 Whitelisting & Least Privilege
Handlers can only interact with explicitly whitelisted system assets:
- Approved systemd units: `lab-canary-user.service`, `lab-test-canary.service`.
- Approved ports: `9101` (Python Agent), `9102` (Synthetic Exporter), `8088` (Canary Endpoint).
- Approved storage mounts: `/tmp/lab_test_mount`, `/tmp/lab_test_inode_mount`.
- Unauthorized targets are rejected with `SAFETY VIOLATION`.

### 3.3 Strict Execution Timeouts
Every subprocess execution enforces a strict timeout (`timeout_seconds = 10.0`). If a command hangs (e.g. D-Bus deadlock or frozen network mount), the controller terminates it with `SIGKILL` and marks the attempt failed.

### 3.4 Retry Limits & Exponential Backoff
- Maximum Retries: **3 attempts**.
- Backoff Schedule: Linear backoff between attempts ($1.0\text{s}, 2.0\text{s}$).
- Eliminates CPU and D-Bus thrashing during transient service failures.

### 3.5 Circuit Breaker Pattern
- **Failure Threshold**: 3 consecutive failed remediation attempts.
- **Cooldown Window**: 600 seconds (10 minutes).
- **Behavior**: When tripped, the controller refuses automated execution, writes a `CIRCUIT_TRIPPED` audit entry, and mandates operator intervention.

### 3.6 Strict Idempotency
Running a remediation script against an already healthy service must be completely harmless. Handlers verify service health before executing any modifying action; if healthy, they return immediately with exit code 0.

### 3.7 Rollback Strategies
If all retries are exhausted without achieving healthy verification, the controller executes a registered rollback routine (e.g. unmounting partially attached filesystems or restoring baseline configurations) to avoid leaving the system in an ambiguous state.

### 3.8 Immutable Audit Trail
Every remediation action appends a structured entry to `/tmp/reliability-remediation-audit.log`:
```json
{"timestamp": "2026-10-28T09:48:30Z", "target": "storage_remediation", "action": "START", "details": "Removing bounded payload file /tmp/lab_test_mount/test_fill_payload.dat"}
{"timestamp": "2026-10-28T09:48:30Z", "target": "storage_remediation", "action": "SUCCESS", "details": "Payload removed, capacity restored"}
```

---

## 4. Runbook Catalog

| Runbook Script | Target Subsystem | Remediation Method | Verification Assertion |
|---|---|---|---|
| `remediate_agent.sh` | Custom Agent (:9101) | Releases lingering sockets, purges PID, relaunches via `.venv` | `curl -f http://127.0.0.1:9101/healthz` == 200 OK |
| `remediate_systemd.sh` | systemd Canary Unit | Executes `systemctl reset-failed` followed by `systemctl restart` | `systemctl is-active` == `active` |
| `remediate_filesystem.sh`| Storage Mount | Safely removes specific payload `test_fill_payload.dat` | File removed; free space > 50% |
| `remediate_inodes.sh` | Inode Sandbox | Purges only files matching `test_inode_*.dat` | Inode test file count == 0 |
| `remediate_network.sh` | Canary Endpoint | Restarts container or spawns Python HTTP daemon on port 8088 | `curl -f http://127.0.0.1:8088/` == 200 OK |
| `remediate_exporter.sh` | Synthetic Exporter | Reclaims port 9102 with `allow_reuse_address` and launches exporter | `curl -f http://127.0.0.1:9102/metrics` == 200 OK |

---

## 5. Operator Runbook: Managing the Controller

### Inspecting State
```bash
# View live circuit breaker state
cat /tmp/remediation_controller_state.json

# View live remediation audit trail
tail -n 20 /tmp/reliability-remediation-audit.log
```

### Resetting a Tripped Circuit Breaker
If an incident has been manually investigated and resolved, an operator can reset the circuit breaker:
```python
from scripts.reliability.remediation.controller import RemediationController
ctrl = RemediationController()
ctrl.reset_circuit_breaker("flapping_service")
```
Or simply delete the target entry from `/tmp/remediation_controller_state.json`.
