# Phase 1.2.1: Linux Block Device & Storage Assessment Report

**Execution Timestamp:** 2026-10-28 12:30:00 IST (Audited: 12:42:00 IST)  
**Assessment Team:** Senior Linux Systems Engineer / Site Reliability Engineer  
**Host Target:** `rubi` (Ubuntu 24.04.5 LTS, Kernel `7.0.0-38-generic`, Samsung MZVL4512HBLU-00BTW NVMe SSD)  
**Milestone:** Phase 1.2.1 — Linux Block Devices, Disks & Partition Architecture (Technical Audit)  

---

## 1. Executive Summary

This report documents the audited empirical findings from direct kernel-level inspection of the storage and block device architecture on the monitored Ubuntu host.

All telemetry was gathered using non-destructive, read-only utilities (`lsblk`, `udevadm`, `findmnt`, `sysfs`, and `/proc/partitions`). No storage modifications, partition changes, mounting, or unmounting operations were performed.

### Key Architectural Discoveries:
1. **Primary Physical Drive**: A single **Samsung MZVL4512HBLU-00BTW** (PM9B1 512 GB M.2 PCIe 4.0 x4 NVMe SSD) is installed.
2. **Partition Scheme**: Configured with a modern **GUID Partition Table (GPT)** (`ID_PART_TABLE_TYPE=gpt`), containing two primary partitions aligned to 1 MiB boundaries.
3. **Partition & Mount Layout**:
   - `nvme0n1p1`: $1.0\text{ GiB}$ FAT32 EFI System Partition (`/boot/efi`).
   - `nvme0n1p2`: $475.9\text{ GiB}$ ext4 Linux root partition (`/`).
4. **Intermediate Storage Abstractions Status**:
   - **LVM**: **Not detected** on this host during this assessment.
   - **dm-crypt / LUKS Encryption**: **Not detected** on this host during this assessment.
   - **Software RAID (`mdraid`)**: **Not detected** on this host during this assessment.
   - The filesystem interfaces directly with the bare-metal NVMe partition block device.
5. **Virtual Block Devices**: **41 virtual loopback devices** (`/dev/loop0` through `/dev/loop40`, Major 7) are active, backing read-only SquashFS snap application packages.
6. **Swap Architecture**: Swap is configured as a pre-allocated file (`/swap.img`, 4.0 GiB) on the root `ext4` filesystem rather than a dedicated block partition.

---

## 2. Block Device Inventory & Topology

### 2.1 The Host Storage Hierarchy
```
┌────────────────────────────────────────────────────────────────────────┐
│               Samsung MZVL4512HBLU-00BTW NVMe SSD                      │
│                  /dev/nvme0n1 (MAJ:MIN 259:0)                          │
│                     476.9 GiB (512,110,190,592 bytes)                  │
├────────────────────────────────────────────────────────────────────────┤
│                      GUID Partition Table (GPT)                        │
├───────────────────────────────────┬────────────────────────────────────┤
│           Partition 1             │            Partition 2             │
│    /dev/nvme0n1p1 (MAJ:MIN 259:1) │   /dev/nvme0n1p2 (MAJ:MIN 259:2)   │
│         1.0 GiB (2,201,600 sectors)│     475.9 GiB (998,008,832 sectors)│
├───────────────────────────────────┼────────────────────────────────────┤
│         vfat (FAT32)              │               ext4                 │
│     UUID: [SANITIZED_ESP_UUID]    │    UUID: [SANITIZED_ROOT_UUID]     │
├───────────────────────────────────┼──────────────────┬─────────────────┤
│          Mount Point              │   Mount Point    │   Swap File     │
│           /boot/efi               │        /         │   /swap.img     │
└───────────────────────────────────┴──────────────────┴─────────────────┘
```

### 2.2 Device Node Attributes Table (Sanitized)
| Device Node | Device Type | Major:Minor | Size | Filesystem | Mount Point | Persistent UUID / Identifier |
|---|---|---|---|---|---|---|
| `/dev/nvme0` | Character (`c`) | `239:0` | - | - | - | Controller Admin Node |
| `/dev/nvme0n1` | Block (`b`) | `259:0` | 476.9 GiB | GPT Table | - | `nvme-SAMSUNG_MZVL4512HBLU-00BTW_[SANITIZED_SERIAL]` |
| `/dev/nvme0n1p1`| Block (`b`) | `259:1` | 1.0 GiB | `vfat` (FAT32) | `/boot/efi` | `UUID=[SANITIZED_ESP_UUID]` |
| `/dev/nvme0n1p2`| Block (`b`) | `259:2` | 475.9 GiB | `ext4` | `/` | `UUID=[SANITIZED_ROOT_UUID]` |
| `/dev/loop0`..`40`| Block (`b`) | `7:0`..`7:40` | 1 MB - 600 MB | `squashfs` | `/snap/*` | Read-only snap image hashes |

---

## 3. Physical Geometry & Sector Alignment Audit

Inspected via `sysfs` and `udevadm`:

| Parameter | Observed Value | SRE Significance |
|---|---|---|
| **Logical Sector Size** | 512 bytes | Smallest addressable unit exposed to the OS |
| **Physical Sector Size** | 512 bytes | Controller reporting geometry |
| **Partition 1 Offset** | 2,048 sectors ($1,048,576\text{ bytes} = 1\text{ MiB}$) | Standard 1 MiB alignment boundary |
| **Partition 2 Offset** | 2,203,648 sectors ($1,128,267,776\text{ bytes}$) | Exactly divisible by 1 MiB ($1,076.0\text{ MiB}$) |
| **Partition Alignment Status** | **ALIGNED** | Zero write amplification from misaligned sector boundaries |
| **I/O Scheduler** | `[none] mq-deadline` | Multi-queue raw hardware dispatching (blk-mq) |
| **Rotational Indicator** | `0` | Confirms non-rotational solid-state media |

---

## 4. Persistent Block Device Identification Verification (Sanitized)

Audited via `/dev/disk/` symlinks and `/etc/fstab`:
- **Filesystem UUID Mounting**: `/etc/fstab` exclusively uses persistent UUIDs:
  - `/` is mounted via `/dev/disk/by-uuid/[SANITIZED_ROOT_UUID]`
  - `/boot/efi` is mounted via `/dev/disk/by-uuid/[SANITIZED_ESP_UUID]`
- **GPT Partition Identifiers**:
  - `nvme0n1p1` has PARTUUID `[SANITIZED_ESP_PARTUUID]` (Type: `c12a7328-f81f-11d2-ba4b-00a0c93ec93b` - EFI System Partition).
  - `nvme0n1p2` has PARTUUID `[SANITIZED_ROOT_PARTUUID]` (Type: `0fc63daf-8483-4772-8e79-3d69d8477de4` - Linux filesystem data).
- **PCIe Hardware Path**:
  - `pci-0000:00:0e.0-pci-10000:e1:00.0-nvme-1 -> ../../nvme0n1`

---

## 5. SRE Operational Insights & Monitoring Guardrails

### 5.1 Virtual Loop Device Monitoring & Alert Calibration
- **Root Cause of Potential False Alerts**: Ubuntu Snaps mount 41 read-only SquashFS images on `/dev/loop0` through `/dev/loop40`. By design, read-only SquashFS filesystems contain zero free blocks ($100\%$ full). Standard filesystem utilization alerts will fire immediately for all 41 loop devices unless properly handled.
- **Distinguishing Filesystem vs. Device Filtering**:
  - Filesystem metrics (`node_filesystem_*`) should be filtered by `fstype` (e.g. excluding `squashfs`) or `mountpoint` (excluding `/snap/.*`).
  - Disk I/O metrics (`node_disk_*`) should be filtered by `device` (e.g. excluding `loop[0-9]+`).
- **Scrape Configuration vs. Query Filtering**:
  - Node Exporter flags (`--collector.filesystem.fs-types-exclude` and `--collector.filesystem.mount-points-exclude`) are typically configured to omit virtual mounts at scrape time.
  - In PromQL, expressions such as `node_filesystem_avail_bytes{fstype!~"squashfs|tmpfs|overlay"}` represent illustrative query patterns that must be validated against actual metric labels in Phase 4/5.
- **Guardrail**: Monitoring filters must be precise to avoid accidentally masking real physical partitions or valid storage alert conditions.

### 5.2 Technical Reality of Swap File I/O Contention
Because swap is implemented as a file (`/swap.img`) inside `/dev/nvme0n1p2`:
- Once activated with `swapon`, swap I/O operates on mapped physical block extents and **bypasses ext4 filesystem journaling**. It does not compete directly through ext4 journal locks.
- However, swap and regular filesystem traffic share the same physical PCIe bus, NVMe controller, and flash channels on `/dev/nvme0n1`.
- Heavy swap activity increases physical disk queue depth (`aqu-sz`), consumes available IOPS and bandwidth, and elevates disk I/O wait times (`await`, `r_await`, `w_await`) for all applications on the host.
- Contention should be diagnosed using device-level I/O metrics (`iostat -xz`, `node_disk_*`) and observed application latency.

---

## 6. Safety Statement

**Confirmation**: All investigation commands were strictly read-only (`lsblk`, `findmnt`, `sysfs`, `udevadm`, `cat`). No filesystems were mounted or unmounted, no partition tables were altered, `/etc/fstab` was not modified, and no disk blocks were written.
