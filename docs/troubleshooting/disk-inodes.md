# Troubleshooting Runbook: Filesystem Inode Exhaustion

## 1. Alert Overview
- **Associated Alerts:** `HostInodeExhaustionWarning`, `HostInodeExhaustionCritical`
- **PromQL Triggers:**
  - `(1 - (node_filesystem_files_free / node_filesystem_files)) * 100 > 80` (Warning: 80% for 10m)
  - `(1 - (node_filesystem_files_free / node_filesystem_files)) * 100 > 90` (Critical: 90% for 5m)
- **Severity:** Warning / Critical
- **SLO Impact:** Inode exhaustion prevents creating new files even when disk space is available, causing total service write failure.

---

## 2. Immediate Triage & Diagnostics
1. **Check Inode Usage by Mountpoint:**
   ```bash
   df -i -x tmpfs -x devtmpfs -x overlay
   ```
2. **Find Directories with Massive File Counts:**
   ```bash
   sudo find /var/spool /var/log /tmp -xdev -printf '%h\n' | sort | uniq -c | sort -k1 -n | tail -n 20
   ```

---

## 3. Resolution Procedures
1. **Purge Excessive Small Files / Temporary Caches:**
   ```bash
   # Clean temp directories
   sudo find /tmp -type f -atime +3 -delete
   ```
2. **Execute Inode Remediation Script:**
   ```bash
   python3 scripts/remediation/remediate_inodes.py --mode execute
   ```

---

## 4. Recovery Verification
- Confirm inode usage drops below 70%:
  ```bash
  df -i <mountpoint>
  ```
