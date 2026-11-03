# Troubleshooting Runbook: Filesystem Space Utilization & Fill Rate Extrapolation

## 1. Alert Overview
- **Associated Alerts:** `HostFilesystemSpaceWarning`, `HostFilesystemSpaceCritical`, `HostFilesystemFillRatePredict`
- **PromQL Triggers:**
  - `(1 - (node_filesystem_avail_bytes / node_filesystem_size_bytes)) * 100 > 80` (Warning: 80% for 10m)
  - `(1 - (node_filesystem_avail_bytes / node_filesystem_size_bytes)) * 100 > 90` (Critical: 90% for 5m)
  - `predict_linear(node_filesystem_free_bytes[1h], 86400 * 2) < 0` (Predictive: disk full in < 48h)
- **Severity:** Warning / Critical
- **SLO Impact:** Impending storage exhaustion causes filesystem write lockouts, database crashes, and kernel errors.

---

## 2. Immediate Triage & Diagnostics
1. **Check Mount Space & Avail:**
   ```bash
   df -hT -x tmpfs -x devtmpfs -x overlay
   bash scripts/monitoring/monitor_storage.sh --capacity
   ```
2. **Find Largest Space Consumers in `/var/log` or `/tmp`:**
   ```bash
   sudo du -xh / | sort -rh | head -n 20
   sudo du -sh /var/log/* | sort -rh | head -n 10
   ```
3. **Detect Deleted But Open File Leaks (Unlinked Open Handles):**
   ```bash
   sudo lsof +L1
   ```

---

## 3. Resolution Procedures
1. **Clean Archived System Logs:**
   ```bash
   sudo journalctl --vacuum-time=3d
   sudo journalctl --vacuum-size=200M
   ```
2. **Clean Docker Build Caches & Unused Images:**
   ```bash
   docker image prune -f
   docker builder prune -f
   ```
3. **Execute Lab Storage Remediation Controller:**
   ```bash
   python3 scripts/remediation/remediate_storage.py --mode dry-run
   python3 scripts/remediation/remediate_storage.py --mode execute
   ```

---

## 4. Recovery Verification
- Verify filesystem usage drops below 75% on affected mount:
  ```bash
  df -h <mountpoint>
  ```
