# Phase 1.2.2 Assessment Report: Linux Filesystems, Mounting & /etc/fstab

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 1.2.2 — Linux Filesystems, Mounting & /etc/fstab  
**Author:** Senior Linux Systems Engineer, Filesystem Engineer & Site Reliability Engineer  
**Date:** October 2026  
**Status:** Completed & Empirically Verified  
**Target Host:** Ubuntu 24.04.5 LTS (`rubi`, Linux 7.0.0-38-generic)  

---

## 1. Executive Summary

This report documents the empirical investigation of the Linux filesystem subsystem, VFS mount hierarchy, and persistent `/etc/fstab` configuration of the Ubuntu 24.04.5 LTS host.

### Key Empirical Findings:
1. **Physical Filesystem Layout**:
   - The primary root filesystem (`/`) is hosted on `/dev/nvme0n1p2`, formatted as **ext4** with a 4096-byte block size, totaling $122,512,118$ blocks ($467.35\text{ GiB}$) and $31,195,136$ inodes.
   - The EFI System Partition (`/boot/efi`) is hosted on `/dev/nvme0n1p1`, formatted as **FAT32 (vfat)** ($1.1\text{ GiB}$ capacity). Because FAT32 organizes files via directory entries and cluster chains rather than Unix inodes, `df -i` and `statfs(2)` report zero inodes. This report is an artifact of the filesystem reporting model rather than an indication of an empty filesystem.
   - Swap is configured as a 4.0 GiB swap file at `/swap.img` with active priority `-2`.
2. **Crash Consistency & Mount Lifecycle**:
   - The root ext4 filesystem was initialized in **`data=ordered`** journaling mode during early boot (`EXT4-fs (nvme0n1p2): mounted filesystem [SANITIZED_ROOT_UUID] ro with ordered data mode`), ordering data block dispatch before metadata commit. This reflects filesystem driver transaction ordering, not an immediate hardware guarantee of persistence to flash cells (which depends on SSD controller caches and barrier/flush commands).
   - **Boot Lifecycle Progression**: The early boot log captures an initial read-only (`ro`) mount, followed by a subsequent read-write remount (`EXT4-fs (nvme0n1p2): re-mounted [SANITIZED_ROOT_UUID] r/w`), leading to the current steady-state read-write (`rw`) operational mount verified by `findmnt`. This sequence illustrates the standard early-boot/initramfs and systemd remount lifecycle (`systemd-remount-fs.service`).
   - **Filesystem Telemetry**: The inspected sysfs error counter (`/sys/fs/ext4/nvme0n1p2/errors_count`) currently reports **`0`**, while cumulative logical filesystem writes report $4.76\text{ TiB}$ ($4,993,517,728\text{ KiB}$). A current error counter of zero indicates no active kernel-recorded filesystem errors, but does not prove that the filesystem has never experienced errors in its history, that unread structures are completely free of corruption, or that the physical SSD is healthy.
3. **Mount Architecture & systemd Generation**:
   - `/etc/fstab` persistently mounts `/` and `/boot/efi` by unique filesystem UUIDs (`/dev/disk/by-uuid/...`).
   - Early boot generator `systemd-fstab-generator` automatically compiles `/etc/fstab` into native systemd units (`/run/systemd/generator/-.mount` and `/run/systemd/generator/boot-efi.mount`), wiring them into `local-fs.target` with automated `systemd-fsck` verification.
4. **Virtual & Loop Density**:
   - The host maintains 41 SquashFS read-only loopback mounts supporting Ubuntu Snap packages, requiring explicit filtering in Prometheus `node_exporter` to prevent metric bloat and false-positive disk alerts.

---

## 2. Empirical Host Storage & Filesystem Inventory

The following table summarizes all distinct filesystem classes identified during the read-only audit:

| Mount Point | Backing Source | Filesystem Type | Size / Inodes | Mount Options | Operational Classification |
|---|---|---|---|---|---|
| `/` | `/dev/nvme0n1p2` | `ext4` | 468 GiB / 31.2M inodes | `rw,relatime` | Persistent Physical Storage |
| `/boot/efi` | `/dev/nvme0n1p1` | `vfat` | 1.1 GiB / 0 inodes | `rw,relatime,fmask=0022,dmask=0022` | Persistent Physical Storage (EFI) |
| `/proc` | `proc` | `proc` | Ephemeral (RAM) | `rw,nosuid,nodev,noexec,relatime` | Kernel Pseudo-Filesystem |
| `/sys` | `sysfs` | `sysfs` | Ephemeral (RAM) | `rw,nosuid,nodev,noexec,relatime` | Kernel Pseudo-Filesystem |
| `/dev` | `udev` | `devtmpfs` | 6.7 GiB / 1.75M inodes | `rw,nosuid,relatime,size=7028400k` | Kernel Device Pseudo-FS |
| `/run` | `tmpfs` | `tmpfs` | 1.5 GiB / 401K inodes | `rw,nosuid,nodev,noexec,relatime` | Memory-Backed Runtime FS |
| `/dev/shm` | `tmpfs` | `tmpfs` | 7.3 GiB | `rw,nosuid,nodev,inode64` | Memory-Backed POSIX IPC |
| `/run/lock` | `tmpfs` | `tmpfs` | 5.0 MiB | `rw,nosuid,nodev,noexec,relatime` | Memory-Backed Lock Files |
| `/run/user/1000` | `tmpfs` | `tmpfs` | 1.5 GiB / 401K inodes | `rw,nosuid,nodev,relatime,mode=700` | User Session Memory FS |
| `/snap/*` (41 mounts)| `/dev/loop0`–`/dev/loop40` | `squashfs` | Read-only packages (100% full) | `ro,nodev,relatime,errors=continue` | Compressed Loopback Mounts |

---

## 3. ext4 Filesystem Technical Analysis

### 3.1 Block Geometry & Virtual Memory Alignment
Using the `stat -f /` system call interface, the following filesystem geometry was captured:
- **Block Size**: 4096 bytes ($4\text{ KiB}$).
- **Fundamental Block Size**: 4096 bytes ($4\text{ KiB}$).
- **Total Blocks**: $122,512,118$ ($122,512,118 \times 4096\text{ bytes} \approx 467.35\text{ GiB}$).
- **Free Blocks**: $88,713,028$ ($338.41\text{ GiB}$).
- **Available Blocks (Non-Root)**: $83,518,185$ ($318.60\text{ GiB}$).

#### SRE Architectural Insight:
The 4096-byte ext4 block size perfectly matches the architecture's memory page size (`getconf PAGESIZE = 4096`). When the Linux kernel transfers pages between system RAM and the NVMe controller, every memory page maps directly to exactly one disk block, eliminating partial-page translation overhead and write amplification.

---

### 3.2 Inode Capacity & Consumption Analysis
Using `df -i` and `stat -f`:
- **Total Inodes**: $31,195,136$
- **Used Inodes**: $1,326,625$ ($\approx 4.25\%$)
- **Free Inodes**: $29,868,511$ ($\approx 95.75\%$)

#### Comparative Analysis: ext4 vs FAT32 (`vfat`)
A fundamental architectural contrast was observed between the root and boot filesystems:
- **ext4 (`/`)**: Maintains a strict table of $31.2\text{ million}$ index nodes. File creation consumes one inode regardless of file size.
- **FAT32 (`/boot/efi`)**: Reports `0` inodes (`Inodes: 0, IUsed: 0, IFree: 0`). FAT32 does not provide a native Unix inode architecture; files and directories are organized via 32-byte directory records and cluster chains in the File Allocation Table. Consequently, `statfs(2)` sets total and free inodes to zero. This does not indicate an absence of files (boot files such as `grubx64.efi` reside here) or a lack of file creation capacity, but it renders inode-based capacity monitoring metrics (`node_filesystem_files_*`) inapplicable to FAT32 mounts.

---

### 3.3 Root Block Reservation (`CAP_SYS_RESOURCE`)
- Total Blocks: $122,512,118$
- Free Blocks: $88,713,028$
- Available Blocks for non-root users: $83,518,185$
- **Root Reserved Blocks**: $88,713,028 - 83,518,185 = 5,194,843\text{ blocks}$.
- **Storage Unit Conversion**:
  - Exact Bytes: $5,194,843 \times 4,096\text{ bytes} = 21,278,076,928\text{ bytes}$
  - Decimal GB ($10^9\text{ bytes}$): $\frac{21,278,076,928}{1,000,000,000} \approx 21.28\text{ GB}$
  - Binary GiB ($2^{30} = 1,073,741,824\text{ bytes}$): $\frac{21,278,076,928}{1,073,741,824} \approx 19.82\text{ GiB}$
  - Effective Reserve Percentage: $\frac{5,194,843}{122,512,118} \times 100 \approx 4.24\%$.

This reserve protects the host against system-wide lockouts if user-space applications fill the disk, ensuring that root-level monitoring agents, SSH daemons, and system journals continue operating uninterrupted.

---

### 3.4 Live Kernel Health Telemetry (`/sys/fs/ext4/nvme0n1p2`)
The kernel's `sysfs` interface provided direct insights into the operational health of the primary filesystem:
- **`errors_count: 0`**: The inspected ext4 error counter currently reports zero kernel-detected errors for this filesystem. This indicates that the ext4 kernel driver has not recorded an active filesystem error through this interface during operation so far. This observed zero does not prove that the filesystem has never experienced any error in its history, that unread data/metadata blocks are entirely free of corruption, or that the physical SSD is healthy.
- **`lifetime_write_kbytes: 4993517728`**: $4,993,517,728\text{ KiB} \approx 4.76\text{ TiB}$ of cumulative logical writes passed into the ext4 writeback layer. (Does not represent physical NAND flash writes, SSD write amplification, or direct drive wear/SMART metrics).
- **`session_write_kbytes: 136856592`**: $130.52\text{ GiB}$ of logical writes during the current mount session.
- **`delayed_allocation_blocks`**: Dynamic buffer tracking dirty allocations prior to flushing.

---

## 4. `/etc/fstab` Audit & systemd Generator Verification

### 4.1 Live `/etc/fstab` Configuration
The static filesystem table (`/etc/fstab`) on the host was audited (sanitizing sensitive machine UUIDs):

```fstab
# /etc/fstab: static file system information.
# <file system>                           <mount point> <type> <options> <dump> <pass>
/dev/disk/by-uuid/[SANITIZED_ROOT_UUID]   /             ext4   defaults  0      1
/dev/disk/by-uuid/[SANITIZED_ESP_UUID]    /boot/efi     vfat   defaults  0      1
/swap.img                                 none          swap   sw        0      0
```

#### Engineering Best Practices Validated:
1. **Persistent Device Addressing**: Both physical partitions are addressed via persistent `/dev/disk/by-uuid/` paths rather than volatile kernel names (`/dev/nvme0n1p2`), guaranteeing boot resilience against PCIe bus renumbering.
2. **Fsck Sequencing**: The root filesystem sets `<pass>` to `1` (ensuring it is verified first), while `/boot/efi` sets `1` and `/swap.img` sets `0` (bypassing fsck).

---

### 4.2 systemd Generator Correlation
Modern Linux distributions do not invoke `/bin/mount -a` during boot. Instead, `systemd-fstab-generator` transforms `/etc/fstab` into transient mount units during early boot:

```ini
# /run/systemd/generator/-.mount
[Unit]
Documentation=man:fstab(5) man:systemd-fstab-generator(8)
SourcePath=/etc/fstab
Before=local-fs.target
After=blockdev@dev-disk-by\x2duuid-[SANITIZED_ROOT_UUID].target

[Mount]
What=/dev/disk/by-uuid/[SANITIZED_ROOT_UUID]
Where=/
Type=ext4

# /run/systemd/generator/boot-efi.mount
[Unit]
Documentation=man:fstab(5) man:systemd-fstab-generator(8)
SourcePath=/etc/fstab
Before=local-fs.target
Requires=systemd-fsck@dev-disk-by\x2duuid-[SANITIZED_ESP_UUID].service
After=systemd-fsck@dev-disk-by\x2duuid-[SANITIZED_ESP_UUID].service
After=blockdev@dev-disk-by\x2duuid-[SANITIZED_ESP_UUID].target

[Mount]
What=/dev/disk/by-uuid/[SANITIZED_ESP_UUID]
Where=/boot/efi
Type=vfat
```

#### Verified Dependency Chain & Target Wiring:
Read-only inspection of `/run/systemd/generator/` and `systemctl show -p Requires,Wants,After,Before -- -.mount boot-efi.mount` verifies:
1. **Directives Written into Generated Mount Units**:
   - `-.mount`: Contains `Before=local-fs.target` and `After=blockdev@dev-disk-by\x2duuid-[SANITIZED_ROOT_UUID].target`.
   - `boot-efi.mount`: Contains `Before=local-fs.target`, `Requires=systemd-fsck@dev-disk-by\x2duuid-[SANITIZED_ESP_UUID].service`, `After=systemd-fsck@dev-disk-by\x2duuid-[SANITIZED_ESP_UUID].service`, and `After=blockdev@dev-disk-by\x2duuid-[SANITIZED_ESP_UUID].target`.
   - *Note on `blockdev@...target`*: This directive is generated explicitly by `systemd-fstab-generator` on Ubuntu 24.04 (systemd v255) to coordinate with udev block device target units.
2. **Generator Directory Link Wiring (`/run/systemd/generator/`)**:
   - `local-fs.target.requires/`: Symlinks to `-.mount` and `boot-efi.mount`.
   - `local-fs.target.wants/`: Symlinks to `systemd-fsck-root.service` and `systemd-remount-fs.service`.
3. **Runtime Dependency Machinery (`systemctl show`)**:
   - Runtime inspection reports additional dependencies, such as `Requires=-.slice` for root, and `Requires=dev-nvme0n1p1.device ... -.mount system.slice` for boot-efi.
   - *Architectural Qualification*: These runtime dependencies reflect systemd's broader unit resolution machinery (e.g. tracking active udev device units, ordering child mounts after parent mounts, and assigning default target/slice relationships) rather than directives emitted by `systemd-fstab-generator` alone.

---

## 5. Security & SRE Observability Recommendations

### 5.1 Illustrative Prometheus Metric Exclusions for Production Monitoring
Ubuntu's default environment mounts 41 read-only SquashFS packages for Snap applications. Because SquashFS images are 100% full by definition, standard disk space alerts will trigger false alerts unless appropriately filtered.

#### Illustrative `node_exporter` Systemd Arguments (Reference Pattern):
```bash
# Illustrative configuration for future exporter deployment (not applied in Phase 1.2.2)
--collector.filesystem.mount-points-exclude="^/(dev|proc|sys|snap)($|/)" \
--collector.filesystem.fs-types-exclude="^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
```

#### SRE Monitoring Best Practices:
1. **Separate Subsystems**: Maintain strict separation between filesystem metrics (`node_filesystem_*`) and block-device metrics (`node_disk_*`).
2. **Avoid Overbroad Exclusions**: Broadly excluding entire directory paths like `^/run($|/)` risks hiding legitimate transient storage or container filesystems mounted under `/run` or `/var/run`. Favor explicit pseudo-filesystem type exclusions (`fs-types-exclude`) over aggressive mount-point masking.
3. **Validate Metric Labels**: Monitoring policies and alert rules must be validated against actual metric labels emitted by the installed Node Exporter version.
4. **Out-of-Scope Reminder**: In Phase 1.2.2, Prometheus and Node Exporter services are neither installed nor modified.

### 5.2 Illustrative SRE Alerts to Implement in Phase 4:
1. **`HostFilesystemSpaceFillingUp`**: Alert when available bytes on physical filesystems drop below 10%.
2. **`HostFilesystemInodeExhaustion`**: Alert when available inodes drop below 10% on filesystems with meaningful inode accounting.
   - *Scope Note*: The label filter `fstype=~"ext4|xfs"` in the monitoring reference is an illustrative example of a restricted monitoring scope targeting conventional block filesystems with fixed inode tables, not a universal allowlist. SREs must assess whether inode statistics are meaningful for each active filesystem and validate exported metrics.
3. **`HostFilesystemReadOnly`**: Critical alert if any writable filesystem remounts as read-only (`node_filesystem_readonly == 1`).
4. **`Ext4ErrorsDetected`**: Alert if `/sys/fs/ext4/*/errors_count > 0`.

---

## 6. Safety & Non-Destructive Verification
- All investigative commands executed during this audit (`findmnt`, `cat /etc/fstab`, `stat -f`, `systemctl cat`, `/proc/self/mountinfo`, `/sys/fs/ext4/*`) were strictly read-only.
- No filesystems were mounted, unmounted, or reformatted.
- No modifications were made to `/etc/fstab` or system storage parameters.
- Machine-specific UUIDs and hardware serials have been fully sanitized.
