# Troubleshooting Runbook: Host Filesystem Remounted Read-Only

## 1. Alert Overview
- **Associated Alert:** `HostFilesystemReadonly`
- **PromQL Trigger:** `node_filesystem_readonly{mountpoint!="/boot/efi"} == 1`
- **Severity:** Critical
- **SLO Impact:** Total outage for any application writing to affected volume. High risk of data loss.

---

## 2. Immediate Triage & Diagnostics
1. **Identify Read-Only Mounts:**
   ```bash
   cat /proc/mounts | grep " ro,"
   ```
2. **Inspect Kernel dmesg for I/O Errors or Ext4/XFS Aborts:**
   ```bash
   sudo dmesg -T | grep -iE "(error|abort|remount|read-only|I/O error|journal commit I/O error)" | tail -n 25
   ```

---

## 3. Resolution Procedures
1. **Attempt Safe Remount (if storage is healthy):**
   ```bash
   sudo mount -o remount,rw <mountpoint>
   ```
2. **If Remount Fails due to Filesystem Corruption:**
   - Take service offline safely.
   - Run appropriate offline filesystem check:
     ```bash
     sudo umount <mountpoint>
     sudo fsck -f -y /dev/<device>
     sudo mount -a
     ```

---

## 4. Recovery Verification
- Confirm mount shows `rw` in `/proc/mounts`.
- Confirm metric `node_filesystem_readonly == 0`.
