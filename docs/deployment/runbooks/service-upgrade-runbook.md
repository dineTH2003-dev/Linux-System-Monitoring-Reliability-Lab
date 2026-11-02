# Operational Runbook: Component & Dependency Upgrades

**Project:** Linux System Monitoring & Reliability Lab  
**Runbook ID:** RB-OPS-02 — Safe Upgrade Procedures  
**Severity:** P2 / Maintenance Standard  
**Components Covered:** Docker Container Images, Python Dependencies, Bash Tooling  

---

## 1. Principles of Zero-Downtime / Low-Impact Upgrades

1. **Exact Version Pinning**: Never use the `:latest` tag in production compose configurations. All container images must be pinned to immutable semantic version tags.
2. **Pre-Upgrade Backup**: Always trigger `./deployment/backup.sh` immediately prior to any component version bump.
3. **Canary Validation**: Pull and validate new container images locally using `docker compose config` and syntax checkers before restarting running services.
4. **Native Service Invariance**: Never upgrade host systemd packages (`apt upgrade prometheus`) without dedicated host engineering review.

---

## 2. Docker Container Upgrade Procedure

### Step 1: Pre-Upgrade State Capture
```bash
cd /home/dineth/dev/Linux-System-Monitoring-Reliability-Lab
./deployment/backup.sh
./deployment/healthcheck.sh > /tmp/pre-upgrade-health.log
```

### Step 2: Update Image Version in `docker-compose.yml`
Locate the target service in `docker-compose.yml` (e.g. updating Prometheus from `v2.51.0` to `v2.52.0`):
```yaml
services:
  prometheus:
    image: prom/prometheus:v2.52.0
```

### Step 3: Pull New Image & Validate Configuration
```bash
docker pull prom/prometheus:v2.52.0
docker compose config
```

### Step 4: Apply Rolling Restart
```bash
# Docker Compose updates only the modified container:
docker compose up -d prometheus

# Verify container status
docker compose ps prometheus
```

### Step 5: Post-Upgrade Healthcheck
```bash
./deployment/healthcheck.sh
./security/container_audit.sh
```

### Rollback Procedure (If Upgrade Fails):
1. Revert image tag in `docker-compose.yml` back to `v2.51.0`.
2. Re-run `docker compose up -d prometheus`.
3. If database migration failure occurred, restore volume from pre-upgrade backup:
   ```bash
   ./deployment/deploy.sh down
   ./deployment/restore.sh backups/pre-upgrade-backup.tar.gz
   ./deployment/deploy.sh up
   ```

---

## 3. Python Monitoring Agent Upgrade Procedure

### Step 1: Audit Outdated Dependencies
```bash
./.venv/bin/pip list --outdated
```

### Step 2: Test in Isolation
```bash
# Run existing regression test suite
./.venv/bin/pytest tests/

# If bumping psutil or pyyaml, update pyproject.toml and requirements.txt:
./.venv/bin/pip install --upgrade -r requirements.txt
./.venv/bin/pytest tests/
```

### Step 3: Restart Agent Service
```bash
# If running via systemd user service:
systemctl --user restart linux-monitoring-agent.service
systemctl --user status linux-monitoring-agent.service

# Verify /metrics endpoint
curl -s http://127.0.0.1:9101/metrics | head -n 20
```
