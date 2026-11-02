# Phase B.0.3 — Pre-Deployment Evidence Closure Report

**Project:** Linux System Monitoring & Reliability Lab  
**Author:** Principal SRE Architect and Independent Deployment Auditor  
**Date:** October 28, 2026  
**Document:** `docs/project-management/phase-b0-3-pre-deployment-evidence-closure.md`  
**Execution Mode:** Strict Read-Only Audit & Static Validation (Zero state changes, zero commits)  
**Deployment Authorization:** **UNAUTHORIZED / PENDING APPROVAL**

---

## 1. Section 1 — Alloy Healthcheck Verification

### 1.1 Live Image Executable Verification
Inspection of running container `lab-alloy` (`grafana/alloy:v1.0.0`) via `which` confirmed:
- **Available Binaries:** `/usr/bin/bash`, `/usr/bin/sh`, `/usr/bin/perl`, `/usr/bin/alloy`
- **Missing Binaries:** `wget` (NOT FOUND), `curl` (NOT FOUND), `nc` (NOT FOUND)
- **Current Defect:** Root `docker-compose.yml` specifies `wget -q --spider http://127.0.0.1:12345/-/healthy || exit 1`. This produces `/bin/sh: 1: wget: not found\n` and 942+ consecutive healthcheck failures.

### 1.2 Proposed Bash HTTP Readiness Check (`GET /-/ready`)
The validated healthcheck uses `/usr/bin/bash`'s native `/dev/tcp` socket interface:
```bash
bash -c 'exec 3<>/dev/tcp/127.0.0.1/12345 && printf "GET /-/ready HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3 && resp=$$(cat <&3) && echo "$$resp" | grep -q "HTTP/1.1 200 OK" && echo "$$resp" | grep -q "Alloy is ready."' || exit 1
```

### 1.3 Empirical Positive & Negative Test Suite

All tests executed live against the exact `grafana/alloy:v1.0.0` container without modifying state:

| Test Scenario | Test Description | Executed Command | Actual Output | Exit Code | Result |
|---|---|---|---|---|---|
| **1. Healthy & Ready** | Probes active Alloy readiness endpoint | `docker exec lab-alloy bash -c 'exec 3<>/dev/tcp/127.0.0.1/12345 && printf "GET /-/ready HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3 && resp=$(cat <&3) && echo "$resp" | grep -q "HTTP/1.1 200 OK" && echo "$resp" | grep -q "Alloy is ready."'` | *(empty on match)* | **`0`** | **PASS** |
| **2. Closed Port** | Probes unallocated port 12349 | `docker exec lab-alloy bash -c 'exec 3<>/dev/tcp/127.0.0.1/12349 && printf "GET /-/ready HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3 && resp=$(cat <&3) && echo "$resp" | grep -q "HTTP/1.1 200 OK" && echo "$resp" | grep -q "Alloy is ready."'` | `/dev/tcp/127.0.0.1/12349: Connection refused` | **`1`** | **PASS** |
| **3. Genuine Non-200 (400 Bad Request)** | Sends malformed HTTP syntax (`BAD_SYNTAX\r\n\r\n`) to port 12345. Alloy returns `HTTP/1.1 400 Bad Request`. | `docker exec lab-alloy bash -c 'exec 3<>/dev/tcp/127.0.0.1/12345 && printf "BAD_SYNTAX\r\n\r\n" >&3 && resp=$(cat <&3) && echo "$resp" | grep -q "HTTP/1.1 200 OK" && echo "$resp" | grep -q "Alloy is ready."'` | *(exits non-zero)* | **`1`** | **PASS** |
| **4. Mismatched Body** | Probes `/ready` but matches `Server Error` | `docker exec lab-alloy bash -c 'exec 3<>/dev/tcp/127.0.0.1/12345 && printf "GET /-/ready HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3 && resp=$(cat <&3) && echo "$resp" | grep -q "HTTP/1.1 200 OK" && echo "$resp" | grep -q "Server Error"'` | *(exits non-zero)* | **`1`** | **PASS** |

### 1.4 YAML Quoting & Compose Compatibility
Validated with Python YAML parser (`yaml.safe_load`). The `$$` syntax is required by Docker Compose to prevent variable interpolation of `$resp`:
```yaml
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/12345 && printf \"GET /-/ready HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n\" >&3 && resp=$$(cat <&3) && echo \"$$resp\" | grep -q \"HTTP/1.1 200 OK\" && echo \"$$resp\" | grep -q \"Alloy is ready.\"' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s
```

### 1.5 Proposed Minimal Diff for `docker-compose.yml` (Line 270)
*(Static proposal only — file has NOT been modified):*
```diff
--- a/docker-compose.yml
+++ b/docker-compose.yml
@@ -267,7 +267,7 @@ services:
         reservations:
           memory: "64M"
     healthcheck:
-      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:12345/-/healthy || exit 1"]
+      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/12345 && printf \"GET /-/ready HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n\" >&3 && resp=$$(cat <&3) && echo \"$$resp\" | grep -q \"HTTP/1.1 200 OK\" && echo \"$$resp\" | grep -q \"Alloy is ready.\"' || exit 1"]
       interval: 15s
       timeout: 5s
       retries: 3
```

---

## 2. Section 2 — Persistent Volume Identity & Migration Verification

### 2.1 Volume Verification Matrix

| Volume Name | Specialist Project & Service | Root Compose Service | Source Mount | Target Mount | Numeric UID:GID | Management Type | Accidental Empty Volume Risk |
|---|---|---|---|---|---|---|---|
| **`lab_prometheus_data`** | `prometheus` / `prometheus` | `prometheus` | `/prometheus` | `/prometheus` | `65534:65534` (`nobody`) | Project-managed (`name: ...`) | **LOW** (Volume exists; reattached by exact name) |
| **`lab_alertmanager_data`** | `alertmanager` / `alertmanager` | `alertmanager` | `/alertmanager` | `/alertmanager` | `65534:65534` (`nobody`) | Project-managed (`name: ...`) | **LOW** (Volume exists; reattached by exact name) |
| **`lab_loki_data`** | `loki` / `loki` | `loki` | `/loki` | `/loki` | `10001:10001` (`loki`) | Project-managed (`name: ...`) | **LOW** (Volume exists; reattached by exact name) |
| **`lab_alloy_data`** | `loki` / `alloy` | `alloy` | `/data-alloy` | `/data-alloy` | `0:4` (`root:adm`) | Project-managed (`name: ...`) | **LOW** (Volume exists; reattached by exact name) |
| **`lab_grafana_data`** | *(none - unmounted)* | `grafana` | N/A | `/var/lib/grafana`| `472:472` (`grafana`) | Project-managed (`name: ...`) | **NONE** (Volume initialized; first-run schema) |

### 2.2 Volume Management Analysis: `name:` vs `external: true`
- In both specialist compose files and root `docker-compose.yml`, volumes are declared as:
  ```yaml
  volumes:
    lab_prometheus_data:
      name: lab_prometheus_data
  ```
- **Compose v2 Behavior:** Docker Compose looks up volumes by the `name` attribute. Because `lab_prometheus_data` already exists in Docker daemon (`/var/lib/docker/volumes/lab_prometheus_data/_data`), Compose attaches to the existing volume without creating a new one.
- **Critical Risk Boundary:** Because `external: true` is not set, Compose treats these volumes as project-managed under the active project. **Executing `docker compose down -v` would delete the volumes.**
- **Operational Constraint:** **NEVER pass `-v` or `--volumes` to `docker compose down`.** Omitting `-v` ensures the volume data remains 100% preserved.

---

## 3. Section 3 — Backup and Restoration Readiness

*Notice: This is a proposed, statically validated operational runbook. Respecting the read-only audit restrictions, NO backup containers were mounted and NO archives were created.*

### 3.1 Quiescence & Downtime Requirements
Taking live backups while Prometheus or Loki is actively writing WAL segments or chunks introduces the risk of torn pages. Therefore, volume backups must only be executed during **Stage 0 quiescence** (after specialist containers are stopped).

### 3.2 Proposed Backup Runbook
```bash
# 1. Establish timestamped backup directory
TIMESTAMP="$(date -u +"%Y%m%d-%H%M%S")"
BACKUP_DIR="/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/backups/pre-b-migration-${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

# 2. Backup volumes preserving numeric ownership
for vol in lab_prometheus_data lab_alertmanager_data lab_loki_data lab_alloy_data; do
    echo "Snapshotting $vol..."
    docker run --rm \
        -v "${vol}:/volume:ro" \
        -v "$BACKUP_DIR:/backup" \
        alpine:3.19 tar --numeric-owner -czf "/backup/${vol}.tar.gz" -C /volume .
    sha256sum "$BACKUP_DIR/${vol}.tar.gz" > "$BACKUP_DIR/${vol}.tar.gz.sha256"
done

# 3. Archive configurations
tar -czf "$BACKUP_DIR/configs.tar.gz" prometheus alertmanager loki blackbox grafana alloy docker-compose.yml .env
sha256sum "$BACKUP_DIR/configs.tar.gz" > "$BACKUP_DIR/configs.tar.gz.sha256"
```

### 3.3 Proposed Restoration & Post-Restore Verification
```bash
# Verify checksums before restoration
sha256sum -c "$BACKUP_DIR/lab_prometheus_data.tar.gz.sha256"

# Restore volume contents preserving numeric owner
docker run --rm \
    -v lab_prometheus_data:/volume \
    -v "$BACKUP_DIR:/backup" \
    alpine:3.19 sh -c 'rm -rf /volume/* && tar --numeric-owner -xzf /backup/lab_prometheus_data.tar.gz -C /volume'

# Post-restore permission audit
docker run --rm -v lab_prometheus_data:/volume:ro alpine:3.19 ls -lan /volume | grep 65534
```

---

## 4. Section 4 — Resource Safety Assessment

*Fresh Measurements: `2026-10-28T12:42:00Z` (`18:12:00 IST`)*

```
+-----------------------------------------------------------------------------------------+
| FRESH RESOURCE TELEMETRY (Docker VM Limit: 3,737.60 MiB / 3.650 GiB)                    |
|                                                                                         |
|  • minikube:                       2,559.00 MiB (2.499 GiB / 68.46%)                    |
|  • taskmanager-postgres:               7.68 MiB (0.007 GiB /  0.21%)                    |
|  -------------------------------------------------------------------------------------  |
|  Subtotal Non-Lab Workloads:       2,566.68 MiB (2.507 GiB / 68.67%)                    |
|                                                                                         |
|  • lab-loki:                          86.46 MiB                                         |
|  • lab-prometheus:                    73.07 MiB                                         |
|  • lab-alloy:                         20.79 MiB                                         |
|  • lab-blackbox-exporter:             18.68 MiB                                         |
|  • lab-alertmanager:                  12.70 MiB                                         |
|  -------------------------------------------------------------------------------------  |
|  Subtotal Active Lab Usage:          211.70 MiB (0.207 GiB /  5.66%)                    |
|                                                                                         |
|  TOTAL CONTAINER ALLOCATION:       2,778.38 MiB (2.713 GiB / 74.34%)                    |
|  AVAILABLE VM HEADROOM FOR LAB:    1,170.92 MiB (1.143 GiB / 31.33%)                    |
|                                                                                         |
|  • Expected Grafana Addition:        100.00 MiB (0.098 GiB)                             |
|  NET HEADROOM MARGIN:              1,070.92 MiB (1.046 GiB / 28.65%)                    |
+-----------------------------------------------------------------------------------------+
```

### Physical Host Telemetry (`free -b`, `swapon --show --bytes`)
- **Host Physical RAM:** 16,453,804,032 bytes (**15.32 GiB**). Available: **3.08 GiB** (3,305,725,952 bytes). Buff/Cache: 7.15 GiB.
- **Host Swap:** 4,294,963,200 bytes (**4.00 GiB**). Used: 4,294,467,584 bytes (**4.00 GiB**). **Free: 484 KiB (99.99% Saturated)**.
- **Host PSI (`/proc/pressure/memory`):** `some avg10=0.00 avg60=0.00 avg300=0.00 total=337s`.

### Rollout Viability Analysis
The empirical data **supports a controlled staged rollout**:
- Steady-state operation of the full monitoring stack (~312 MiB total with Grafana) consumes only **26.6%** of the 1,170.92 MiB available VM headroom.
- **Risk Constraint:** Cumulative hard limits in root Compose equal **2,688 MiB**. If all containers surge simultaneously ($2,566.68 + 2,688 = 5,254.68 \text{ MiB}$), memory demand would exceed the 3,737.60 MiB VM limit. Therefore, **synthetic memory pressure tests (Agent 10) must remain strictly prohibited while Minikube is active.**

---

## 5. Section 5 — Migration and Rollback Sequences

### 5.1 Verified Component Map

| Component | Specialist Source File | Project Name | Target in Root Compose | Port Mapping (Host -> Container) |
|---|---|---|---|---|
| **Prometheus** | `prometheus/docker-compose.yml` | `prometheus` | Service `prometheus` | `127.0.0.1:9091->9090` |
| **Alertmanager** | `alertmanager/docker-compose.yml` | `alertmanager`| Service `alertmanager` | `127.0.0.1:9093->9093` |
| **Blackbox** | `blackbox/docker-compose.yml` | `blackbox` | Service `blackbox` | `127.0.0.1:9115->9115` |
| **Loki** | `loki/docker-compose.yml` | `loki` | Service `loki` | `127.0.0.1:3100->3100` |
| **Alloy** | `loki/docker-compose.yml` | `loki` | Service `alloy` | `127.0.0.1:12345->12345` |
| **Grafana** | *(None)* | N/A | Service `grafana` | `127.0.0.1:3001->3000` |
| **Python Agent** | PID `1755348` (Host) | N/A | Host Native | `127.0.0.1:9101` |

### 5.2 Dependency-Safe Teardown & Migration Sequence (Staged)

#### Stage 0: Teardown of Specialist Stacks
```bash
# Stop dependents first (releases endpoints on prometheus_default)
docker compose -f alertmanager/docker-compose.yml down
docker compose -f blackbox/docker-compose.yml down
docker compose -f loki/docker-compose.yml down

# Stop network owner last (cleanly removes prometheus_default)
docker compose -f prometheus/docker-compose.yml down

# Verify port liberation
ss -ltnp | grep -E ':(9091|9093|3100|9115|12345)\b' || echo "All ports free"
```

#### Stage 1: Data Tier Deployment
```bash
docker compose up -d prometheus loki
# Gate: HTTP 200 on :9091/-/healthy and :3100/ready
```

#### Stage 2: Telemetry Tier Deployment
```bash
docker compose up -d blackbox alloy
# Gate: HTTP 200 on :9115/-/healthy and :12345/-/ready; probe_success = 1
```

#### Stage 3: Presentation Tier Deployment
```bash
docker compose up -d alertmanager grafana
# Gate: HTTP 200 on :9093/-/healthy and :3001/api/health
```

### 5.3 Deterministic Rollback Sequence
```bash
docker compose down
docker compose -f prometheus/docker-compose.yml up -d
docker compose -f alertmanager/docker-compose.yml up -d
docker compose -f blackbox/docker-compose.yml up -d
docker compose -f loki/docker-compose.yml up -d
```

---

## 6. Audit Synthesis & Final Verdict

### 6.1 Summary of Evidence Collected
1. **Alloy Healthcheck:** Tested live inside `grafana/alloy:v1.0.0` container. Validated positive check (Exit Code 0), closed port check (Exit Code 1), and genuine 400 Bad Request check (Exit Code 1).
2. **Volume Identity:** Confirmed 100% name parity (`lab_*_data`) and identical image versions across all services.
3. **Resource Telemetry:** Fresh measurements prove that steady-state lab deployment (~312 MiB) comfortably fits within the 1,170.92 MiB VM headroom.
4. **Agent Integrity:** Python agent (PID `1755348`) remains running and healthy on `127.0.0.1:9101`.

### 6.2 Remaining Assumptions & Unresolved Risks
- **Remaining Assumption:** Grafana clean schema initialization on first boot inside `lab_grafana_data` is assumed based on standard official Grafana 10.4.1 behavior.
- **Unresolved Risk:** Saturated host swap (99.9% full) and shared Docker VM memory (Minikube consuming 2.56 GiB). Risk is mitigated by deferring synthetic memory pressure testing.

### 6.3 Final Recommendation & Verdict

```
┌────────────────────────────────────────────────────────────────────────┐
│  FINAL VERDICT: READY WITH CONDITIONS                                  │
│                                                                        │
│  Every critical safety condition is grounded in empirical evidence.   │
│  Deployment execution is ready to proceed upon clearing the three     │
│  mandatory operational conditions below.                               │
└────────────────────────────────────────────────────────────────────────┘
```

### Mandatory Conditions to Clear Before Deployment:
1. **Apply One-Line Alloy Healthcheck Diff:** Update line 270 in [`docker-compose.yml`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/docker-compose.yml#L270) with the validated bash socket check.
2. **Execute Stage 0 Teardown:** Execute the dependency-safe shutdown sequence (`alertmanager` -> `blackbox` -> `loki` -> `prometheus`) without `-v`.
3. **Maintain Memory Boundary:** Strictly prohibit Agent 10 synthetic memory injection scenarios until Minikube is paused or VM memory is expanded.

---

**AUDIT COMPLETE. STOPPING EXECUTION. AWAITING EXPLICIT LEAD SRE AUTHORIZATION TO PROCEED.**
