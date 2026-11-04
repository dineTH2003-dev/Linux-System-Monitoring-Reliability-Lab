# Site Reliability Engineering (SRE) Framework: SLI & SLO Specification

**Project:** Linux System Monitoring & Reliability Lab  
**Scope:** Service Level Indicators (SLIs), Service Level Objectives (SLOs) & Mathematical Models  

---

## 1. Reliability Foundations & Core Model

In production Site Reliability Engineering, reliability is defined from the perspective of the system’s consumers, rather than raw internal infrastructure utilization. For the **Linux System Monitoring & Reliability Lab**, the primary consumers are:
1. **Site Reliability Engineers & System Operators** relying on fresh, continuous telemetry for diagnostics and capacity planning.
2. **Prometheus Alerting Engine & Alertmanager** evaluating symptom and saturation alerts to protect system stability.
3. **Grafana Visualization Dashboards** rendering executive and deep-dive telemetry.
4. **Automated Remediation Daemons** executing corrective workflows based on metric state changes.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        UBUNTU 24.04 LINUX HOST                         │
│                                                                        │
│   Kernel Telemetry Sources:                                            │
│   • /proc/stat, /proc/meminfo, /proc/diskstats, /proc/net/dev          │
│   • systemd D-Bus, Linux PSI (Pressure Stall Information)              │
│                                 │                                      │
│                ┌────────────────┴───────────────┐                      │
│                ▼                                ▼                      │
│     ┌──────────────────────┐        ┌──────────────────────┐           │
│     │ Node Exporter (:9100)│        │ Custom Agent (:9101) │           │
│     │ [Host Telemetry SLI] │        │ [Custom Agent SLI]   │           │
│     └──────────┬───────────┘        └───────────┬──────────┘           │
│                │                                │                      │
│                │ HTTP Metrics Scrape            │ HTTP Metrics Scrape  │
│                └────────────────┬───────────────┘                      │
│                                 ▼                                      │
│     ┌────────────────────────────────────────────────────────────┐     │
│     │               PROMETHEUS MONITORING CORE                   │     │
│     │                                                            │     │
│     │  ┌──────────────────────────────────────────────────────┐  │     │
│     │  │ Scrape Engine: Target Health & Scrape Latency SLIs   │  │     │
│     │  └──────────────────────────┬───────────────────────────┘  │     │
│     │                             ▼                              │     │
│     │  ┌──────────────────────────────────────────────────────┐  │     │
│     │  │ TSDB & Storage: Append, Compaction & WAL Integrity   │  │     │
│     │  └──────────────────────────┬───────────────────────────┘  │     │
│     │                             ▼                              │     │
│     │  ┌──────────────────────────────────────────────────────┐  │     │
│     │  │ Rule Engine: Pipeline Recording & Alert Eval SLIs    │  │     │
│     │  └──────────────────────────────────────────────────────┘  │     │
│     └────────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────┘
```

---

### 1.1 Core SRE Taxonomy: SLI, SLO, and SLA

Reliability management requires strict separation of measurement, internal engineering objectives, and contractual business agreements:

| Concept | Formal Definition | Organizational Role | Consequence of Breach |
|---|---|---|---|
| **Service Level Indicator (SLI)** | A carefully chosen quantitative measure of some aspect of the level of service that is provided. Expressed as: <br>$$\text{SLI} = \frac{\text{Good Events}}{\text{Total Events}} \times 100\% \quad \text{or} \quad \frac{\text{Good Time}}{\text{Total Time}} \times 100\%$$ | Measurement baseline grounded in raw telemetry. | None directly; SLIs measure reality. |
| **Service Level Objective (SLO)** | A target value or range of values for a service level that is measured by an SLI, bound to a specific rolling window (e.g., $99.5\%$ over 30 days). | Internal engineering target balancing feature velocity against reliability. | Error budget burn; engineering pauses new feature deployments to focus on stability. |
| **Service Level Agreement (SLA)** | An explicit or implicit contractual commitment made to external customers or business stakeholders regarding service reliability. | Legal, financial, or formal contractual obligation. | Financial penalties, customer service credits, contractual termination, or regulatory fines. |

#### Contractual SLA Distinction
An SLA is fundamentally a **contractual and business concept**, whereas an SLO is an **internal engineering tool**:
- **Tighter Targets**: SLOs are always set **stricter** than SLAs (e.g., Internal SLO $= 99.5\%$, External SLA $= 99.0\%$).
- **Safety Margin**: The gap between the internal SLO and external SLA provides engineering with an operational safety buffer. When the internal SLO is breached, the error budget is depleted and engineering halts risky changes, yet the external SLA remains unviolated—preventing financial penalties or contractual liability.
- **Scope**: SLAs typically include legal clauses, scheduled maintenance exemptions, force majeure terms, formal breach notification procedures, and credit calculation matrices. In this lab, all targets defined are internal engineering **SLOs**; external contractual SLAs are intentionally decoupled.

---

### 1.2 Error Budgets & Consumption Dynamics

An **Error Budget** is the allowable fraction of unreliability that a service may experience over an observation window while still satisfying the SLO:

$$\text{Error Budget} = 1 - \text{SLO}$$

For example, an SLO of $99.5\%$ ($0.995$) over a 30-day window yields an Error Budget of:

$$\text{Error Budget} = 1 - 0.995 = 0.005 \quad (0.5\%)$$

#### Mathematical Formulas
1. **Allowed Failures ($F_{\text{allowed}}$)**:
   - *Time-based (seconds)*:
     $$F_{\text{allowed}} = T_{\text{window}} \times (1 - \text{SLO})$$
     For a 30-day window ($2,592,000\text{ seconds}$):
     $$F_{\text{allowed}} = 2,592,000 \times 0.005 = 12,960\text{ seconds } (216\text{ minutes} = 3.6\text{ hours})$$
   - *Event-based (scrapes/evaluations)*:
     $$F_{\text{allowed}} = N_{\text{total}} \times (1 - \text{SLO})$$
     For a 15-second scrape interval ($172,800\text{ scrapes}$ per 30 days):
     $$F_{\text{allowed}} = 172,800 \times 0.005 = 864\text{ failed scrapes}$$

2. **Observed Failures ($F_{\text{observed}}$)**:
   - Sum of bad events or outage seconds recorded by the SLI over the time window:
     $$F_{\text{observed}} = \sum_{t=0}^{T} (1 - \text{SLI}_t)$$

3. **Remaining Error Budget ($\text{EB}_{\text{remaining}}$)**:
   $$\text{EB}_{\text{remaining}} \% = 100 \times \left(1 - \frac{F_{\text{observed}}}{F_{\text{allowed}}}\right)$$

4. **Error Budget Consumption ($\text{EB}_{\text{consumed}}$)**:
   $$\text{EB}_{\text{consumed}} \% = \frac{F_{\text{observed}}}{F_{\text{allowed}}} \times 100\% = \frac{1 - \text{SLI}}{1 - \text{SLO}} \times 100\%$$

---

### 1.3 Burn Rates & Multi-Window Alerting

The **Burn Rate** is the acceleration at which the error budget is being consumed relative to the rate that would exhaust exactly 100% of the budget over the entire SLO window:

$$\text{Burn Rate} = \frac{\text{Observed Error Rate}}{\text{Allowed Error Rate}} = \frac{1 - \text{SLI}}{1 - \text{SLO}}$$

- **$\text{Burn Rate} = 1.0$**: The error budget will be exactly exhausted ($100\%$ consumed) at the end of the 30-day window.
- **$\text{Burn Rate} = 2.0$**: The error budget will be exhausted in 15 days.
- **$\text{Burn Rate} = 14.4$**: $2\%$ of the 30-day error budget is consumed in just **1 hour**. The entire budget would be depleted in **50 hours** (~2 days).
- **$\text{Burn Rate} = 6.0$**: $5\%$ of the budget is consumed in **6 hours**.

```
Error Budget Consumption over 30 Days
100% ┌───────────────────────────────────────────────────────────┐
     │                                                           │
     │  Fast Burn (14.4x) ──┐                                    │
     │                      ▼                                    │
 50% │                 (Depleted in ~2 days)                     │
     │                                     Sustainable (1.0x)    │
     │                                            ┌──────────────┤
  0% └────────────────────────────────────────────┴──────────────┘
     Day 0                       Day 15                    Day 30
```

#### Why Multi-Window Multi-Burn-Rate Alerting is Essential
Traditional single-threshold alerts (e.g. `up == 0 for 5m`) suffer from severe operational pathologies:
1. **Alert Fatigue (Low Precision)**: Brief transient network glitches cause an alert to fire, waking up an engineer even though less than $0.05\%$ of the budget was consumed.
2. **Delayed Detection (High Reset Latency)**: Long window alerts (e.g. 24 hours) continue firing long after the outage has been resolved because the historical average remains depressed, leading to operator cynicism.
3. **Flapping**: Oscillating errors cause repeated alert notifications and ticket churning.

**The Google SRE Multi-Window Multi-Burn-Rate Solution**:  
An alert fires **only** when both conditions are simultaneously met:
- **Condition 1 (Long Window)**: The burn rate over the long window exceeds the threshold, proving sufficient budget impact.
- **Condition 2 (Short Window)**: The burn rate over the short window ($1/12$th of long window) exceeds the threshold, proving that the incident is **actively ongoing**.

Once the outage is resolved, the short window immediately drops to $0.0$, causing the alert to clear within minutes, even while the long window recovers.

---

### 1.4 Availability Windows & Trade-offs

The framework evaluates SLIs over two distinct window models:

1. **Rolling Availability Window (Standard: 30 Days)**:
   - Continuously evaluates the preceding 30 days ($720\text{ hours}$).
   - **Advantage**: Smooths transient variance; prevents arbitrary end-of-month "budget resets" where systems get a clean slate on the 1st of the month despite chronic instability.
   - **Trade-off**: Requires time-series historical retention of at least 30 days.

2. **Tactical Operational Windows (1 Hour, 6 Hours, 24 Hours)**:
   - Used specifically for burn-rate calculation and immediate operational triage.
   - 1-hour window captures acute, catastrophic degradation.
   - 24-hour window captures persistent, low-grade attrition.

---

### 1.5 Latency Objectives & Tail Distribution Analysis

Measuring system latency via the arithmetic mean ($\mu$) is fundamentally flawed in systems engineering. In computing, latency distributions are **multimodal, non-normal, and heavy-tailed**:
- A single garbage-collection pause or disk I/O stall can cause a 10-second delay for one request while 99 requests complete in 5 milliseconds. The mean would report $104.95\text{ ms}$, hiding the fact that 99% of requests were blazing fast while 1% experienced total failure.
- **Percentiles ($p50, p90, p95, p99$)**:
  - $p50$ (Median): Typical operator experience.
  - $p95$: Standard SLA threshold for healthy performance.
  - $p99$ (Tail Latency): Edge-case performance under scheduling contention, memory paging, or I/O lockup.
- **Scrape Latency SLI**: Evaluated using PromQL quantile functions over `scrape_duration_seconds` to enforce that 95% of scrapes finish under $1.0\text{s}$ and 99% under $2.5\text{s}$.

---

### 1.6 Monitoring Coverage & Telemetry Boundaries

Monitoring coverage defines the proportion of mission-critical services, endpoints, and kernel subsystems instrumented by the observability harness.

```
Monitoring Coverage Scope
├── Covered by Node Exporter (:9100)
│   ├── Host CPU & Scheduler Pressure (PSI)
│   ├── Host Memory, Slab & Swap Paging
│   ├── Block Device I/O Throughput & IOPS
│   ├── Filesystem Capacity & Inodes
│   └── Host Network Interface Drops/Errors
├── Covered by Custom Agent (:9101)
│   ├── Process-level Resource Consumption
│   ├── Microsecond Collector Execution Latency
│   └── Subsystem Collector Fault Isolation
├── Covered by Prometheus TSDB (:9090 / :9091)
│   ├── Scrape Engine Target Availability
│   ├── Rule Evaluation Scheduling & Latency
│   └── TSDB Head Series, WAL & Compaction
└── Known Coverage Gaps (Identified for Phase 4/5)
    ├── External Network Path Validation (Blackbox Exporter pending)
    └── Downstream Notification Sinks (Alertmanager delivery receipts)
```

---

### 1.7 Infrastructure Health vs. User-Visible Service Reliability

A foundational tenet of SRE is the strict distinction between **infrastructure saturation** and **service unreliability**:

| Dimension | Infrastructure Health (Resource State) | User-Visible Service Reliability (SLI State) |
|---|---|---|
| **What it measures** | Utilization, saturation, queue depth, temperature, capacity headroom. | Availability, correctness, timeliness, data integrity. |
| **Example metric** | Host CPU utilization $= 96\%$, Memory available $= 8\%$, Load average $= 14.2$. | Node Exporter scrape $= \text{SUCCESS } (up=1)$, Scrape duration $= 0.28\text{s}$, Rule eval $= \text{ON-TIME}$. |
| **SRE Interpretation** | The host is operating at high efficiency under heavy computational load. | **The service is 100% reliable.** No user impact has occurred; no error budget is consumed. |
| **Counter-example** | Host CPU utilization $= 3\%$, Memory available $= 85\%$, Load average $= 0.1$. | Node Exporter crashed (`connection refused`), Scrapes failing, Telemetry lost. |
| **SRE Interpretation** | The host hardware appears pristine and completely idle. | **Catastrophic 100% outage.** Zero telemetry is received; the error budget is rapidly burning. |

Alerting on high CPU alone produces false alarms and noise. Alerts must fire on **symptoms affecting consumers** (SLI degradation and rapid error budget burn), while infrastructure health metrics provide the secondary diagnostic context to identify root causes.

---

## 2. Measurable Service Level Indicators (SLI Design)

All indicators are designed strictly from existing, verified metrics in the lab repository. No uncollected service traffic or imaginary synthetic user queries are referenced.

---

### SLI 1: Host Exporter Availability SLI

- **Description**: The proportion of time that the native Node Exporter daemon is reachable, healthy, and successfully returning host kernel telemetry.
- **Operational Scope**: The native `prometheus-node-exporter` on port `9100` is an **optional host telemetry provider** in this lab environment. The lab's primary, required host observability pipeline is the Custom Python Monitoring Agent (`linux-monitoring-agent` on `127.0.0.1:9101`). While SLI 1 and its multi-window burn-rate rules are computed for multi-exporter operational drills, an offline host Node Exporter does not degrade the core platform's custom agent availability.
- **SLI Formula**:
  $$\text{SLI}_{\text{node\_avail}} = \frac{\text{Scrapes where } up\{job="node"\} == 1}{\text{Total scheduled scrapes of } job="node"}$$
- **Numerator**: Scrapes returning `up{job="node"} == 1`.
- **Denominator**: Total scrapes attempted (`count_over_time(up{job="node"}[T])`).
- **PromQL Representation**:
  ```promql
  avg_over_time(up{job="node",instance="primary-node"}[30d]) * 100
  ```
- **Measurement Source**: Prometheus server internal scrape harness (`up`).
- **Evaluation Interval**: 15 seconds.
- **Time Window**: Rolling 30 days ($720\text{h}$) for compliance; 1 hour / 5 minutes for burn-rate monitoring.
- **Critical SRE Metric Distinction (`up == 0` vs. Absent Series)**:
  - **`up == 0` (Scrape Failure)**: Prometheus contacted (or attempted to contact) the configured endpoint and received connection refused, timeout, or invalid HTTP response. The time series exists in TSDB with value `0`. `avg_over_time` evaluates this as $0.0$, registering an error and burning budget.
  - **Absent Series (Missing Telemetry)**: If the scrape job is removed, renamed, or Prometheus cannot schedule the target, no `up` time series is written to TSDB. In PromQL, `avg_over_time(absent_metric[1h])` evaluates to an **empty vector (no result)** rather than zero.
  - **Protection Against Silent Telemetry Loss**: Formulas like `1 - avg_over_time(up[1h])` will NOT yield $1.0$ if the series is absent; they produce no output. Companion alert rules (such as `absent()` assertions or target down alerts) must be maintained to prevent missing metrics from silently hiding outages.
- **Exclusions**: Scheduled host operating system reboot cycles explicitly registered in the maintenance window schedule.
- **Limitations**: Sampling resolution is bounded by the 15-second scrape interval; micro-outages lasting $<15\text{s}$ occurring between scrape ticks are not captured.

---

### SLI 2: Custom Monitoring Agent Availability SLI

- **Description**: The proportion of time that the custom Python monitoring agent is reachable on port `9101` and successfully returning extended telemetry.
- **SLI Formula**:
  $$\text{SLI}_{\text{agent\_avail}} = \frac{\text{Scrapes where } up\{job="python-agent"\} == 1}{\text{Total scheduled scrapes of } job="python-agent"}$$
- **Numerator**: Scrapes returning `up{job="python-agent"} == 1`.
- **Denominator**: Total scrapes attempted (`count_over_time(up{job="python-agent"}[T])`).
- **PromQL Representation**:
  ```promql
  avg_over_time(up{job="python-agent",instance="primary-node"}[30d]) * 100
  ```
- **Measurement Source**: Prometheus server scrape engine (`up`).
- **Evaluation Interval**: 15 seconds.
- **Time Window**: Rolling 30 days ($720\text{h}$) for compliance; 1 hour / 5 minutes for burn-rate monitoring.
- **Exclusions**: Local agent unit test runs, explicit operator-initiated configuration restarts via CLI.
- **Limitations**: If the Python process hangs due to a GIL deadlock or blocking system call, the scrape will fail only after the 10-second scrape timeout expires.

---

### SLI 3: Prometheus Scrape Success SLI

- **Description**: The aggregate reliability of Prometheus metric extraction across all registered monitoring scrape pools.
- **SLI Formula**:
  $$\text{SLI}_{\text{scrape\_success}} = \frac{\sum_{\text{jobs}} \text{Successful Scrapes } (up == 1)}{\sum_{\text{jobs}} \text{Total Scheduled Scrapes}}$$
- **Numerator**: Sum of successful scrapes across all active targets:
  ```promql
  sum(sum_over_time((up == 1)[30d]))
  ```
- **Denominator**: Sum of all attempted scrapes across all active targets:
  ```promql
  sum(count_over_time(up[30d]))
  ```
- **PromQL Representation**:
  ```promql
  sum(sum_over_time((up{job=~"node|python-agent|prometheus"} == 1)[30d]))
  / sum(count_over_time(up{job=~"node|python-agent|prometheus"}[30d])) * 100
  ```
- **Measurement Source**: Prometheus target metadata and `up` metric vector.
- **Evaluation Interval**: 15 seconds.
- **Time Window**: Rolling 30 days.
- **Exclusions**: Intentionally decommissioned or dynamically dropped scrape targets.
- **Limitations**: Aggregates all targets into an unweighted pool; a single failing peripheral exporter could dilute overall perceived scrape health if not inspected per target job.

---

### SLI 4: Monitoring Endpoint Availability SLI

- **Description**: The ability of the monitoring endpoints (`/metrics`, `/healthz`) to service HTTP requests with status `200 OK` within an acceptable response latency threshold ($< 1.0\text{s}$).
- **SLI Formula**:
  $$\text{SLI}_{\text{endpoint}} = \frac{\text{Probes returning HTTP 200 with latency } < 1.0\text{s}}{\text{Total endpoint probe attempts}}$$
- **Numerator**: Scrapes where `up == 1` AND `scrape_duration_seconds < 1.0`.
- **Denominator**: Total scrapes attempted.
- **PromQL Representation**:
  ```promql
  avg_over_time(((up{job=~"node|python-agent"} == 1) and (scrape_duration_seconds < 1.0))[30d]) * 100
  ```
- **Measurement Source**: Prometheus `scrape_duration_seconds` and target HTTP response status.
- **Evaluation Interval**: 15 seconds.
- **Time Window**: Rolling 30 days.
- **Exclusions**: Telemetry scraped during initial TCP handshake re-negotiation.
- **Limitations**: Evaluates the endpoint as observed from the local container network gateway (`host.docker.internal`); does not evaluate physical external network interface routing.

---

### SLI 5: Metric Collection Success SLI (Collector Health)

- **Description**: The internal execution reliability of the custom Python monitoring agent's nine subsystem collectors (`cpu`, `memory`, `swap`, `filesystem`, `inode`, `disk_io`, `network`, `process`, `systemd`). Ensures that even if the HTTP daemon is up, the collectors are not silently failing to read `/proc` and `/sys`.
- **SLI Formula**:
  $$\text{SLI}_{\text{collectors}} = \frac{\sum_{\text{collectors}} \text{Successful Collector Executions}}{\sum_{\text{collectors}} \text{Total Collector Executions}}$$
- **Numerator**: Sum of successful collector iterations where `linux_agent_collector_success == 1`.
- **Denominator**: Total collector collection attempts across all registered collectors.
- **PromQL Representation**:
  ```promql
  avg_over_time(linux_agent_collector_success[30d]) * 100
  ```
- **Measurement Source**: Custom agent internal telemetry `linux_agent_collector_success{collector="..."}`.
- **Evaluation Interval**: 15 seconds (on each incoming scrape).
- **Time Window**: Rolling 30 days.
- **Exclusions**: Subsystem collectors intentionally disabled in `agent/config.yaml` (e.g. experimental collectors toggled off).
- **Limitations**: Measures whether the collector encountered an unhandled exception or returned an error status; does not perform semantic validation of individual counter values (e.g. detects if `/proc/diskstats` failed to open, but does not verify whether the disk actually processed I/O).

---

### SLI 6: Monitoring Pipeline Reliability SLI (Rule Engine Integrity)

- **Description**: The reliability of the Prometheus rule engine in evaluating recording and alerting rule groups on schedule without missed iterations or evaluation crashes.
- **SLI Formula**:
  $$\text{SLI}_{\text{pipeline}} = \frac{\text{Completed Rule Group Iterations} - \text{Missed Iterations}}{\text{Total Scheduled Rule Group Iterations}} \times 100\%$$
- **Numerator**: Executed rule iterations without timing misses:
  $$\Delta \text{prometheus\_rule\_group\_iterations\_total} - \Delta \text{prometheus\_rule\_group\_iterations\_missed\_total}$$
- **Denominator**: Total scheduled rule group iterations:
  $$\Delta \text{prometheus\_rule\_group\_iterations\_total}$$
- **PromQL Representation**:
  ```promql
  clamp_max(
    (1 - (
      sum(increase(prometheus_rule_group_iterations_missed_total[30d]))
      / clamp_min(sum(increase(prometheus_rule_group_iterations_total[30d])), 1)
    )) * 100,
    100
  )
  ```
- **Measurement Source**: Prometheus server internal time-series metrics (`prometheus_rule_group_iterations_total`, `prometheus_rule_group_iterations_missed_total`, `prometheus_rule_evaluation_failures_total`).
- **Evaluation Interval**: 15 seconds (rule group evaluation cadence).
- **Time Window**: Rolling 30 days.
- **Exclusions**: Server startup duration and initial TSDB WAL replay period.
- **Limitations**: Reflects the internal health of Prometheus TSDB rule evaluation; does not confirm downstream receipt by Alertmanager or webhook endpoints.

---

### SLI 7: Scrape Latency Performance SLI

- **Description**: The proportion of metric scrapes completed within bounded duration limits, preventing metric staleness and scrape queue congestion.
- **SLI Formula**:
  $$\text{SLI}_{\text{latency}} = \frac{\text{Scrapes with duration } \le 1.0\text{ second}}{\text{Total completed scrapes}} \times 100\%$$
- **Numerator**: Scrapes completing in $\le 1.0\text{s}$.
- **Denominator**: Total completed scrapes.
- **PromQL Representation**:
  ```promql
  (count_over_time((scrape_duration_seconds{job="node"} <= 1.0)[30d])
  / count_over_time(scrape_duration_seconds{job="node"}[30d])) * 100
  ```
- **Measurement Source**: Prometheus scrape duration metric `scrape_duration_seconds{job="..."}`.
- **Evaluation Interval**: 15 seconds.
- **Time Window**: Rolling 30 days.
- **Exclusions**: Network interface re-negotiations during system wake/sleep.
- **Limitations**: Scrapes exceeding the 10-second timeout abort completely and register as scrape errors (`up=0`) rather than slow scrapes.

---

## 3. Service Level Objectives (SLO Design)

### 3.1 Realistic Objective Calibration

In SRE, choosing arbitrary "five nines" ($99.999\%$) targets on unclustered, single-node infrastructure is an anti-pattern that destroys engineering credibility:
- On a single workstation or standalone Linux server, an SLO of $99.999\%$ permits only **26 seconds** of downtime per month. A single standard Linux kernel update and reboot requires 30 to 60 seconds, which would instantly breach the SLO and exhaust 200% of the monthly error budget.
- Objectives must reflect real architectural constraints: single physical host, local storage, non-HA daemon processes, and scheduled developer reboot cycles.

```
SLO Target Hierarchy
┌────────────────────────────────────────────────────────────────────────┐
│ Core Pipeline & Rule Evaluation: 99.9% (Allowable: 43.2 min / month)   │
├────────────────────────────────────────────────────────────────────────┤
│ Production Host Exporter Telemetry: 99.5% (Allowable: 3.6 hours / month│
├────────────────────────────────────────────────────────────────────────┤
│ Custom Python Agent (Experimental Lab): 99.0% (Allowable: 7.2 hours)   │
└────────────────────────────────────────────────────────────────────────┘
```

---

### 3.2 Target Specifications Matrix

| Target Name | Target Value | Category | Allowable 30-Day Failure Budget | Rationale & Measurement Method |
|---|---|---|---|---|
| **Host Exporter Availability** | **99.5%** | Production (Host) | $216\text{ minutes } (3.6\text{ hours})$ | Node Exporter is a compiled, mature Go daemon running under systemd. $99.5\%$ provides sufficient headroom for scheduled kernel reboots, package upgrades, and Docker Desktop engine restarts while maintaining strict host visibility. Measured via `avg_over_time(up{job="node"}[30d])`. |
| **Custom Python Agent Availability** | **99.0%** | Experimental (Lab) | $432\text{ minutes } (7.2\text{ hours})$ | The Python agent is under active development and experimentation. A $99.0\%$ target permits iterative collector development, configuration reloads, and testing without triggering unwarranted code freeze policies. Measured via `avg_over_time(up{job="python-agent"}[30d])`. |
| **Collector Internal Execution** | **99.9%** | Production (Agent) | $43.2\text{ minutes } (0.1\%)$ | While the agent process is executing, the internal reading of Linux `/proc` and `/sys` must be nearly deterministic. Collector exceptions indicate unhandled kernel format changes or parsing bugs that require immediate remediation. Measured via `avg_over_time(linux_agent_collector_success[30d])`. |
| **Pipeline Rule Evaluation** | **99.9%** | Production (Pipeline) | $43.2\text{ minutes } (0.1\%)$ | The Prometheus TSDB rule engine executes entirely in-memory. Missed iterations indicate CPU starvation or TSDB compaction lockups that jeopardize alerting integrity. Measured via `prometheus_rule_group_iterations_missed_total`. |
| **Scrape Latency Performance** | **95.0% < 1.0s** | Performance | $5.0\%$ of scrapes | Empirically, Node Exporter scrapes complete in $0.25\text{s}$–$0.30\text{s}$, and Prometheus internal scrapes complete in $0.02\text{s}$–$0.05\text{s}$. A $1.0\text{s}$ threshold allows a $3\times$ safety margin for transient I/O contention. Measured via `scrape_duration_seconds`. |

---

## 4. Error Budget Models & Mathematical Derivations

### 4.1 Error Budget Calculations for 30-Day Window

All calculations assume a standard 30-day rolling evaluation window:
- $T_{\text{window}} = 30 \times 24 \times 3600\text{ seconds} = 2,592,000\text{ seconds}$.
- At a 15-second scrape cadence:
  $$N_{\text{scrapes}} = \frac{2,592,000}{15} = 172,800\text{ scrapes per target}$$

| SLO Target | Error Budget Fraction ($1 - \text{SLO}$) | Allowed Downtime (Seconds) | Allowed Downtime (Hours/Minutes) | Allowed Failed Scrapes ($N_{\text{failed}}$) |
|---|---|---|---|---|
| **99.9%** | $0.001 \quad (0.1\%)$ | $2,592\text{ s}$ | **43.2 minutes** | **172 scrapes** |
| **99.5%** | $0.005 \quad (0.5\%)$ | $12,960\text{ s}$ | **3.6 hours (216 min)** | **864 scrapes** |
| **99.0%** | $0.010 \quad (1.0\%)$ | $25,920\text{ s}$ | **7.2 hours (432 min)** | **1,728 scrapes** |
| **95.0%** | $0.050 \quad (5.0\%)$ | $129,600\text{ s}$ | **36.0 hours** | **8,640 scrapes** |

---

### 4.2 Multi-Window Multi-Burn-Rate Alerting Architecture

To achieve zero alert flapping, rapid detection of catastrophic outages, and instant alert reset upon remediation, the monitoring core implements Google SRE multi-window multi-burn-rate alerting:

| Alert Name | Severity | Burn Rate | % Budget Consumed | Long Window ($L$) | Short Window ($S$) | Time to 100% Depletion | Pager Target / Channel |
|---|---|---|---|---|---|---|---|
| **`HostTelemetryErrorBudgetBurnCritical`** | **Critical (Page)** | **$14.4\times$** | **$2\%$** | **1 hour** | **5 minutes** | **50 hours (~2 days)** | On-Call SRE Pager / Urgent Notification |
| **`HostTelemetryErrorBudgetBurnHigh`** | **Critical (Page)** | **$6.0\times$** | **$5\%$** | **6 hours** | **30 minutes** | **120 hours (5 days)** | On-Call SRE Pager / Urgent Notification |
| **`HostTelemetryErrorBudgetBurnWarning`** | **Warning (Ticket)**| **$1.0\times$** | **$10\%$** | **3 days (72h)**| **6 hours** | **30 days** | Next Business Day Ticket / Team Backlog |

```
Multi-Window Dual Condition Logic
┌────────────────────────────────────────────────────────────┐
│                    INCIDENT DETECTION                      │
│                                                            │
│   ┌──────────────────────────┐                             │
│   │ Long Window (e.g. 1h)    │ ───▶ Burn Rate > 14.4?      │
│   │ [Proves Budget Impact]   │                             │
│   └──────────────────────────┘                             │
│                AND                                         │
│   ┌──────────────────────────┐                             │
│   │ Short Window (e.g. 5m)   │ ───▶ Burn Rate > 14.4?      │
│   │ [Proves Active Incident] │                             │
│   └──────────────────────────┘                             │
│                │                                           │
│                ▼ BOTH TRUE                                 │
│   ┌──────────────────────────┐                             │
│   │   FIRE CRITICAL ALERT    │                             │
│   └──────────────────────────┘                             │
│                │                                           │
│                ▼ Remediated (Short window drops to 0)      │
│   ┌──────────────────────────┐                             │
│   │  INSTANT ALERT CLEARING  │ (No waiting for 1h window)  │
│   └──────────────────────────┘                             │
└────────────────────────────────────────────────────────────┘
```

#### Production PromQL Multi-Window Expressions
1. **Critical 1-Hour Burn Rate Alert ($14.4\times$)**:
   ```promql
   (
     (1 - avg_over_time(up{job="node"}[1h])) / (1 - 0.995) > 14.4
   )
   and
   (
     (1 - avg_over_time(up{job="node"}[5m])) / (1 - 0.995) > 14.4
   )
   ```

2. **High 6-Hour Burn Rate Alert ($6.0\times$)**:
   ```promql
   (
     (1 - avg_over_time(up{job="node"}[6h])) / (1 - 0.995) > 6.0
   )
   and
   (
     (1 - avg_over_time(up{job="node"}[30m])) / (1 - 0.995) > 6.0
   )
   ```

3. **Warning 3-Day Burn Rate Alert ($1.0\times$)**:
   ```promql
   (
     (1 - avg_over_time(up{job="node"}[3d])) / (1 - 0.995) > 1.0
   )
   and
   (
     (1 - avg_over_time(up{job="node"}[6h])) / (1 - 0.995) > 1.0
   )
   ```

---

## 5. Implementation & Companion Assets

To ensure absolute safety and non-interference with other engineering agents, all SRE rules and test specifications are managed in standalone companion files:
- **Rule Definitions**: `prometheus/rules/sre_rules.yml`
- **Synthetic Unit Verification**: `prometheus/tests/sre_rule_tests.yml`

This architecture allows the Prometheus Engineer (Agent 5) to include `rules/sre_rules.yml` in `prometheus.yml` at their discretion, without modifying their existing rule files.
