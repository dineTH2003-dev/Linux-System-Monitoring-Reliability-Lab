# Operational Runbook: Incident Triage & Emergency Response

**Project:** Linux System Monitoring & Reliability Lab  
**Runbook ID:** RB-OPS-03 — Incident Response & Troubleshooting Playbook  
**Severity:** P1/P2/P3 Standard Operating Procedure  

---

## 1. Incident Triage Matrix

| Symptom / Alert | Likely Root Cause | Immediate Diagnostic Command | Remediation Playbook |
|---|---|---|---|
| **Port Binding Conflict (`address already in use`)** | External process bound to port 9091, 3001, 9093, 3100, 9115 | `ss -tulpn \| grep -E ':(9091\|3001\|9093\|3100\|9115)'` | Section 2.1 |
| **Container CrashLoopBackOff / OOMKilled** | Memory limit exceeded or corrupted TSDB index | `docker inspect <container> --format '{{.State.OOMKilled}}'` | Section 2.2 |
| **TargetDown (`python-agent`)** | Python agent process halted or network routing failure | `curl -v http://127.0.0.1:9101/healthz` | Section 2.3 |
| **Filesystem Space Critical (`/` partition >= 90%)** | Unbounded Docker logs or massive TSDB retention | `docker system df && du -sh /var/lib/docker` | Section 2.4 |
| **Permission Denied on Scrape / File Access** | File modes altered by external tool | `./security/audit_permissions.sh` | Section 2.5 |

---

## 2. Emergency Response Procedures

### 2.1 Port Conflict Resolution
If `deployment/deploy.sh up` reports a port binding error:
1. Identify the offending PID:
   ```bash
   ss -tulpn | grep 9091
   ```
2. If it is an orphaned Docker container:
   ```bash
   docker ps -a | grep 9091
   docker stop <container_id> && docker rm <container_id>
   ```
3. Re-run preflight check:
   ```bash
   ./deployment/deploy.sh preflight
   ```

### 2.2 Container Out-of-Memory (OOM) Remediation
If Prometheus or Loki crashes under high metric churn:
1. Check OOM kill status:
   ```bash
   docker inspect lab-prometheus --format 'OOMKilled: {{.State.OOMKilled}}, ExitCode: {{.State.ExitCode}}'
   ```
2. If `OOMKilled: true`:
   - Inspect TSDB retention in `.env`: reduce `PROMETHEUS_RETENTION_TIME` to `7d` or increase memory limit from `1024M` to `2048M` if host RAM permits.
   - Restart stack: `./deployment/deploy.sh restart`.

### 2.3 Python Agent Failure Triage
If Prometheus reports `up{job="python-agent"} == 0`:
1. Check if agent is listening on host:
   ```bash
   ss -tuln | grep 9101
   ```
2. Check systemd service status:
   ```bash
   systemctl --user status linux-monitoring-agent.service --no-pager
   ```
3. Review recent exception traces:
   ```bash
   journalctl --user -u linux-monitoring-agent.service -n 50 --no-pager
   ```
4. Test manual execution in debug mode:
   ```bash
   ./.venv/bin/python3 -m agent.main -c agent/config.yaml --log-level DEBUG
   ```

### 2.4 Disk Space Exhaustion Triage
If host root partition disk usage triggers critical alerts:
1. Check Docker disk utilization:
   ```bash
   docker system df
   ```
2. Remove dangling build caches and unused stopped containers:
   ```bash
   docker container prune -f
   docker image prune -f
   ```
3. Prune old backups:
   ```bash
   find backups/ -name "backup-*.tar.gz" -mtime +3 -delete
   ```

### 2.5 Security & Permission Restoration
If permission errors prevent containers from reading configs:
```bash
./security/harden_permissions.sh
./deployment/deploy.sh restart
```
