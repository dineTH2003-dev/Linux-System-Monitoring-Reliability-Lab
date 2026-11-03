# Automated Self-Healing & Safe Remediation Architecture

**Project:** Linux System Monitoring & Reliability Lab  
**Scope:** Guarded Remediation Controller, Circuit Breakers, Rollback Strategies & Incident Lifecycle Math  

---

## 1. Architectural Philosophy

Automated remediation in the Linux System Monitoring & Reliability Lab operates under a fundamental principle: **Self-healing must never create a worse incident than the failure it seeks to resolve.**

Off-the-shelf automated scripts frequently lead to secondary outages due to:
1. Infinite restart loops under persistent configuration corruption.
2. Unchecked resource exhaustion caused by rapid flapping.
3. Collateral damage from overly broad commands (e.g. `killall` or unconstrained directory cleanup).
4. Blind execution without verifying post-remediation health state.

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

### Safety Invariants
1. **Explicit Preconditions**: Before attempting remediation, the controller evaluates preconditions (verifying process state, port binding, and failure mode). Remediation aborts if preconditions are not satisfied.
2. **Strict Whitelisting**: Only explicitly registered lab resources (`lab-canary-user.service`, `lab_agent`, `test_mount`) can be modified. Arbitrary unit restarts or process kills are rejected.
3. **Execution Timeouts**: Every remediation step enforces a strict execution timeout (default: 10.0 seconds). A hung restart command is terminated automatically.
4. **Retry Caps & Exponential Backoff**: The controller permits a maximum of **3 consecutive retry attempts**. Each retry introduces linear/exponential backoff delay ($1\text{s}, 2\text{s}$) to allow state propagation.
5. **Circuit Breaker Protection**: If 3 attempts fail within a 10-minute (600s) cooldown window, the circuit breaker trips to `OPEN`. All further automated remediation for that target is halted, preventing service restart loops.
6. **Strict Idempotency**: If a target passes verification before remediation begins (e.g. service is already healthy), the controller returns `ALREADY_HEALTHY` without executing modifying actions.
7. **Rollback Strategy**: If retries are exhausted without successful verification, the controller executes a registered rollback routine to leave the system in a known safe state.
8. **Human Approval Gate**: High-risk operations require an explicit operator token (`SRE_REMEDIATION_APPROVED=1`). Without this token, execution halts with status `APPROVAL_REQUIRED`.

---

## 3. Remediation Handlers Inventory

The platform provides dedicated self-healing runbook handlers in `scripts/reliability/remediation/`:

| Handler Script | Target Subsystem | Remediation Mechanism | Verification Assertion |
|---|---|---|---|
| `runbook_remediate_cpu_contention.sh` | CPU | Dispatches bounded `SIGTERM` to runaway test worker PID. | Validates CPU load drops below warning threshold. |
| `runbook_remediate_memory_leak.sh` | Memory | Drops temporary allocations and terminates leaking test process. | Asserts available memory $> 40\%$. |
| `runbook_remediate_disk_space.sh` | Storage Space | Safely purges temporary test files in test mount. | Asserts filesystem usage $< 80\%$. |
| `runbook_remediate_inodes.sh` | Storage Inodes | Unlinks orphaned test directory entries in test mount. | Asserts free inodes $> 30\%$. |
| `runbook_remediate_network_endpoint.sh` | Networking | Restarts canary HTTP listener on `127.0.0.1:8088`. | Asserts HTTP 200 from canary endpoint. |
| `runbook_remediate_agent_failure.sh` | Agent Daemon | Restarts Python monitoring agent process in `.venv`. | Asserts HTTP 200 from `127.0.0.1:9101/healthz`. |
| `runbook_remediate_systemd_service.sh` | System Services | Restarts user-space service `lab-canary-user.service`. | Asserts `systemctl --user is-active` returns `active`. |

---

## 4. Incident Lifecycle & Quantitative SRE Formulations

The reliability testing framework models the end-to-end incident lifecycle using 6 explicit milestones:

```
[Fault Injected]
       │
       │ T_inject (System enters anomalous state)
       ▼
[Anomaly Detected] ◀── MTTD (T_detect - T_inject)
       │
       │ T_detect (Monitoring probe or assertion notices degradation)
       ▼
[Alert Delivered] ◀── Alert Latency (T_alert - T_detect)
       │
       │ T_alert (Prometheus alert moves PENDING -> FIRING)
       ▼
[Triage Started]
       │
       │ T_investigate (Automated diagnostic controller inspects telemetry)
       ▼
[Remediation Started]
       │
       │ T_recover_start (Self-healing runbook begins execution)
       ▼
[Service Restored] ◀── MTTR (T_restored - T_recover_start)
       │
       │ T_restored (Post-remediation verification assertions pass 100%)
       ▼
[Incident Resolved] ◀── Total Duration (T_restored - T_inject)
```

### Mathematical Definitions
- **Mean Time to Detect (MTTD)**:
  $$\text{MTTD} = T_{\text{detect}} - T_{\text{inject}}$$
  The elapsed time between fault injection and initial detection by monitoring probes.
- **Alert Delivery Latency**:
  $$\text{Latency}_{\text{alert}} = T_{\text{alert}} - T_{\text{detect}}$$
  The duration required for metric condition breach to transition through Prometheus pending thresholds (`for:` duration gating).
- **Mean Time to Restore / Remediate (MTTR)**:
  $$\text{MTTR} = T_{\text{restored}} - T_{\text{recover\_start}}$$
  The elapsed time from remediation trigger to confirmed service restoration.
- **Mean Time Between Failures (MTBF)**:
  $$\text{MTBF} = \frac{T_{\text{operational\_uptime}}}{\text{Number of Incidents}}$$
  Quantifies systemic stability across observation periods.
