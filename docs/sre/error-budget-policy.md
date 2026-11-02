# SRE Operational Policy: Error Budget Governance & Escalation

**Project:** Linux System Monitoring & Reliability Lab  
**Document Ref:** SRE-POL-002  
**Author:** Senior Site Reliability Engineer (Agent 9 — SLI/SLO Specialist)  
**Host Target:** Ubuntu 24.04 LTS (`rubi`, Linux Kernel `7.0.0-38-generic`)  
**Status:** Approved & Enforced  

---

## 1. Purpose & Core Principles

An Error Budget is not merely an observational metric displayed on a dashboard; it is an **operational contract** between systems engineering, platform development, and service operations.

The purpose of this Error Budget Policy is to provide an objective, data-driven mechanism to balance **feature velocity** (new collectors, experimental kernel scrapers, dashboard additions) with **service reliability** (telemetry freshness, continuous monitoring, and alerting integrity).

### Core Principles
1. **Reliability is a Feature**: A monitoring system that is crashing or dropping metrics provides negative utility. Reliability takes priority when the error budget is compromised.
2. **Zero-Blame Accountability**: Error budget depletion is not punished; it is treated as an engineering signal that the system has absorbed too much operational risk.
3. **Automated Governance**: Operational consequences (such as release freezes or mandatory reliability refactoring) are triggered deterministically based on empirical error budget consumption, removing subjective debate.
4. **Shared Responsibility**: Product enhancements and stability are co-owned by the Monitoring Agent Developers and the SRE team.

---

## 2. Error Budget Measurement Framework

### 2.1 Formal Calculations

All service objectives are evaluated across a rolling 30-day window ($720\text{ hours} = 2,592,000\text{ seconds}$):

$$\text{Error Budget Fraction} = 1 - \text{SLO}$$

$$\text{Allowed Downtime (Seconds)} = T_{\text{window}} \times (1 - \text{SLO})$$

$$\text{Observed Downtime (Seconds)} = \int_{0}^{T} (1 - \text{SLI}_t) \, dt$$

$$\text{Remaining Error Budget } (\%) = 100 \times \left(1 - \frac{\text{Observed Downtime}}{\text{Allowed Downtime}}\right)$$

$$\text{Consumed Error Budget } (\%) = \left(\frac{\text{Observed Downtime}}{\text{Allowed Downtime}}\right) \times 100\%$$

$$\text{Burn Rate} = \frac{\text{Observed Error Rate}}{1 - \text{SLO}} = \frac{1 - \text{SLI}}{1 - \text{SLO}}$$

---

### 2.2 Error Budget Reference Table (30-Day Rolling Window)

| Service Tier / Target | SLO | Monthly Budget ($1 - \text{SLO}$) | Max Allowed Downtime | Max Allowed Scrape Drops ($15\text{s}$ interval) |
|---|---|---|---|---|
| **Node Exporter Host Telemetry** *(Optional)* | **99.5%** | **0.5% (0.005)** | **3.6 hours (216 min)** | **864 scrapes** |
| **Custom Python Agent** *(Core Target)* | **99.0%** | **1.0% (0.010)** | **7.2 hours (432 min)** | **1,728 scrapes** |
| **Agent Collector Execution** | **99.9%** | **0.1% (0.001)** | **43.2 minutes** | **172 collector cycles** |
| **Rule Engine Pipeline** | **99.9%** | **0.1% (0.001)** | **43.2 minutes** | **172 rule iterations** |

> **Operational Telemetry Clarification**:
> The native host `prometheus-node-exporter` is an **optional telemetry source**. The platform's authoritative system telemetry availability SLO is anchored on the **Custom Python Monitoring Agent** (`127.0.0.1:9101`). An offline host Node Exporter produces an intentional telemetry down signal for multi-window burn-rate training, but does not indicate that the core observability platform is unavailable.

---

### 2.3 Mathematical Derivation: 200x Burn Rate (Controlled Target-Outage Example)

During failure injection scenarios or when the optional Node Exporter is stopped on the host, Prometheus evaluates:
$$\text{instance:node_exporter_burn_rate:1h} = 200.0$$

#### Step-by-Step Derivation
1. **Target SLO & Error Budget**:
   - SLO Target: $99.5\%$ ($0.995$).
   - Error Budget ($\epsilon$): $\epsilon = 1.0 - 0.995 = 0.005$ ($0.5\%$).
2. **Outage Error Rate**:
   - During a complete 100% outage of the target over the evaluation window, $up = 0$ for all samples.
   - Observed Error Rate: $1.0 - 0.0 = 1.0$ ($100\%$).
3. **Burn-Rate Ratio**:
   $$\text{Burn Rate} = \frac{\text{Observed Error Rate}}{\text{Allowed Error Budget}} = \frac{1.0}{0.005} = 200.0$$

#### SRE Burn-Rate vs. Budget Exhaustion Distinction
- **Instantaneous Consumption Rate**: A 1-hour burn rate of $200.0\times$ means the budget is burning 200 times faster than the budgeted monthly rate during that window.
- **Budget Consumed in 1 Hour**: Over a 1-hour total outage, a 200x burn rate consumes:
  $$\frac{1\text{ hour} \times 200}{720\text{ hours in 30 days}} = \frac{200}{720} \approx 27.78\% \text{ of the monthly budget}.$$
- **Exhaustion Threshold**: To completely exhaust ($100\%$) the 30-day error budget, the 100% outage must persist for:
  $$T_{\text{exhaust}} = \frac{720\text{ hours}}{200} = 3.6\text{ consecutive hours}.$$
- **Operational Principle**: Observing a 200x burn rate over 1 hour trips the P1 alert (`HostTelemetryErrorBudgetBurnCritical`) to prompt rapid response, but it does **not** prove that the full 30-day error budget has already been exhausted.

---

## 3. Error Budget Consumption States & Action Matrix

The operational state of each monitored component is categorized into four discrete zones based on remaining error budget margin:

```
Error Budget Zones & Engineering Consequence Matrix
┌────────────────────────────────────────────────────────────────────────┐
│ HEALTHY (100% – 50% Remaining)                                         │
│ • Full release velocity permitted. Experimental collectors active.     │
├────────────────────────────────────────────────────────────────────────┤
│ CAUTION (50% – 20% Remaining)                                          │
│ • Heightened monitoring. Reliability prioritized in sprint backlog.    │
├────────────────────────────────────────────────────────────────────────┤
│ CRITICAL (20% – 0% Remaining)                                          │
│ • Non-critical changes frozen. SRE review required for deployments.   │
├────────────────────────────────────────────────────────────────────────┤
│ EXHAUSTED (< 0% Remaining / Breached)                                  │
│ • COMPLETE FEATURE MORATORIUM. 100% engineering effort on reliability. │
└────────────────────────────────────────────────────────────────────────┘
```

---

### 3.1 Detailed Consequence Matrix

| Zone | Remaining Budget | Operational Condition | Engineering & Deployment Policy | Escalation & Reporting |
|---|---|---|---|---|
| **Zone 1: Healthy** | **100% – 50%** | System operating within planned reliability limits. | - Unrestricted code deployments for Python agent.<br>- New collectors and kernel scrapers welcomed.<br>- Chaos engineering and load simulations permitted. | Standard bi-weekly operational review. |
| **Zone 2: Caution** | **49% – 20%** | Significant budget consumed due to outages or scrape instability. | - Development continues, but **30% of engineering bandwidth** in the next sprint must be dedicated to reliability bugs.<br>- Peer review mandatory for all agent configuration changes. | Weekly SRE sync; root causes highlighted in lab status report. |
| **Zone 3: Critical** | **19% – 0%** | Risk of imminent SLO breach within the rolling window. | - **Feature Freeze**: No new collector types or exploratory features may be deployed.<br>- Only bug fixes, stability patches, and documentation updates are allowed.<br>- All changes require explicit approval from the Senior SRE. | Daily operational triage; immediate incident notification to Platform Lead. |
| **Zone 4: Exhausted** | **< 0% (Breached)** | Service has failed its commitment to observability consumers. | - **MANDATORY MORATORIUM**: Total freeze on all code changes unrelated to reliability.<br>- **100% of engineering focus** redirected to telemetry stability, memory leak remediation, or daemon hardening.<br>- Formal Post-Mortem required within 48 hours. | Executive incident report; bi-daily updates until budget recovers into Zone 2. |

---

## 4. Multi-Window Burn-Rate Alerting & Triage

When error budget is burning rapidly, engineers cannot wait for the monthly rolling average to decay. The monitoring harness enforces multi-window burn-rate alerts to detect acute degradation immediately:

```
Incident Triage Escalation Pathway
┌────────────────────────────────────────────────────────────┐
│ Multi-Window Alert Fires                                   │
│ (e.g. 14.4x Burn Rate over 1h AND 5m)                      │
└─────────────────────────────┬──────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────┐
│ STEP 1: Immediate Triage (< 5 Minutes)                     │
│ • Verify host responsiveness: ping rubi, ssh               │
│ • Check target status: curl localhost:9091/api/v1/targets  │
│ • Inspect systemd units: systemctl status node_exporter    │
└─────────────────────────────┬──────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────┐
│ STEP 2: Containment & Rollback (< 15 Minutes)              │
│ • If recent agent commit deployed: git revert / rollback   │
│ • If process hung: restart service under systemd           │
│ • If memory exhaustion (OOM): clear slab or allocate swap  │
└─────────────────────────────┬──────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────┐
│ STEP 3: Post-Incident Recovery & Budget Audit              │
│ • Audit consumed seconds: PromQL remaining budget query    │
│ • Log incident in docs/reports/                            │
│ • Conduct Blameless Post-Mortem if > 10% budget consumed   │
└────────────────────────────────────────────────────────────┘
```

### Alerting Rules Matrix
1. **Critical Page ($14.4\times$ Burn Rate)**:
   - **Trigger**: Burns $2\%$ of budget in 1 hour; exhausts entire budget in 50 hours.
   - **Action**: Immediate on-call engineer page; operator must log in and begin triage within 10 minutes.
2. **High Page ($6.0\times$ Burn Rate)**:
   - **Trigger**: Burns $5\%$ of budget in 6 hours; exhausts budget in 5 days.
   - **Action**: High-priority alert; response required within 30 minutes.
3. **Low Ticket ($1.0\times$ Burn Rate)**:
   - **Trigger**: Sustained consumption over 3 days that would deplete the entire budget at month end.
   - **Action**: Automatically creates a GitHub issue/ticket; reviewed in next sprint planning.

---

## 5. Post-Mortem Triggers & Standards

A formal **Blameless Root Cause Analysis (RCA) Post-Mortem** is mandatory under any of the following conditions:
1. **Single Incident Impact**: Any single operational event that consumes **$\ge 10\%$ of the monthly error budget** in under 6 hours.
2. **SLO Breach**: Any event that results in Error Budget Exhaustion (Zone 4).
3. **Data Loss Incident**: Any corruption of the Prometheus TSDB Write-Ahead Log (WAL) resulting in permanent metric time-series loss.

### Post-Mortem Guidelines
- **Timeline**: Drafted within 24 hours of incident resolution; finalized within 48 hours.
- **Blameless Culture**: Focus exclusively on systemic vulnerabilities, missing telemetry, fragile configuration formats, or missing integration tests—never on human error.
- **Action Items**: Every RCA must produce at least two distinct preventive action items:
  - One **detection improvement** (e.g., tighter alert threshold or new synthetic probe).
  - One **architectural resilience improvement** (e.g., systemd restart limits, watchdog timeout, memory limit).

---

## 6. Emergency Waiver & Exception Process

In critical circumstances, an exception to the Feature Moratorium may be requested:

### Criteria for Emergency Waiver
- **P1 Security Vulnerability**: Remediating a critical CVE or active security vulnerability.
- **Critical Data Integrity Bug**: Correcting a severe kernel or filesystem bug causing storage corruption.
- **Observability Restoral**: Deploying code specifically engineered to fix a broken monitoring collector.

### Approval Chain
An Emergency Waiver requires documented sign-off from:
1. **The Senior Site Reliability Engineer** (Agent 9).
2. **The Lead Systems Architect**.

The waiver document must state:
- The exact patch commit SHA.
- The quantified risk of deployment.
- The rollback plan if the patch causes further error budget depletion.
