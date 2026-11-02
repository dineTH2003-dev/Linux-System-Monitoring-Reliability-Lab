# Linux Block Device Architecture & Storage Subsystem

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 1.2.1 — Linux Block Devices, Disks & Partition Architecture (Audited)  
**Author:** Senior Linux Systems Engineer & Site Reliability Engineer  
**Target Host:** Ubuntu 24.04 LTS (`rubi`, Samsung MZVL4512HBLU-00BTW NVMe SSD)  

---

## 1. Fundamentals of Linux Storage Architecture

### 1.1 What is a Block Device?
In the Linux kernel, a **block device** is a hardware or virtual peripheral that provides buffered, random access to data organized in fixed-size chunks called **blocks** (or sectors).

Unlike stream-oriented character devices, block devices support:
1. **Random Seeking**: The storage controller can jump directly to any arbitrary sector using Logical Block Addressing (LBA) without reading preceding data.
2. **Kernel Buffer Cache Integration**: Transfers pass through the kernel page cache and I/O scheduler queues to optimize throughput and coalesce adjacent read/write requests.

### 1.2 Block Devices vs. Character Devices
Linux categorizes all device nodes in `/dev` as either character (`c`) or block (`b`) devices:

| Feature | Block Device (`b`) | Character Device (`c`) |
|---|---|---|
| **Data Transfer Unit** | Fixed blocks (e.g., 512 or 4096 bytes) | Continuous byte stream (unbuffered) |
| **Random Access** | Yes (LBA seeking) | Sequential only (typically no arbitrary seeking) |
| **Kernel Caching** | Yes (integrated with page cache) | No direct page cache buffering |
| **Typical Examples** | NVMe namespaces (`nvme0n1`), SATA disks (`sda`), loop devices | Keyboards, serial consoles, NVMe management controllers (`/dev/nvme0`), `/dev/urandom` |

#### Host Observation & NVMe Architecture:
On the audited host, the NVMe subsystem exposes both device types in `/dev`:
```bash
ls -l /dev/nvme*
```
```
crw------- 1 root root 239,   0 Oct 24 20:34 /dev/nvme0
brw-rw---- 1 root disk 259,   0 Oct 24 20:34 /dev/nvme0n1
brw-rw---- 1 root disk 259,   1 Oct 25 02:28 /dev/nvme0n1p1
brw-rw---- 1 root disk 259,   2 Oct 25 02:28 /dev/nvme0n1p2
```

##### Distinguishing Observed Facts from General Linux Architecture:
- **Directly Observed Evidence on Host**:
  - `/dev/nvme0` is present as a character device node (`crw-------`, Major 239, Minor 0).
  - `/dev/nvme0n1` is present as a block device node (`brw-rw----`, Major 259, Minor 0).
  - `/dev/nvme0n1p1` and `/dev/nvme0n1p2` are child block partitions (`brw-rw----`, Major 259, Minors 1 and 2).
- **General Linux/NVMe Architecture Knowledge**:
  - In the Linux NVMe driver subsystem, character device nodes (`/dev/nvmeX`) represent the physical PCIe NVMe controller. This interface allows user-space management utilities to issue NVMe Admin commands (such as `IDENTIFY`, `GET_LOG_PAGE`, firmware update ioctls, or telemetry extractions) directly to controller registers.
  - In contrast, block device nodes (`/dev/nvmeXnY`) represent storage namespaces that provide addressable block storage holding filesystems and user data.
- **Scope Limitation**:
  - Specific NVMe management ioctls, low-level firmware manipulation, and SMART telemetry commands (e.g. via `nvme-cli` or `smartctl`) were **not executed or tested** during this read-only milestone to adhere to non-privileged safety guardrails.

---

## 2. Block Device Representation & Naming Conventions

### 2.1 Storage Device Hierarchy: Physical Disk vs. Partition vs. Filesystem
In SRE operations, engineers must maintain strict distinctions between storage layers:
1. **Physical Storage Device**: The actual hardware hardware unit (e.g., PCIe M.2 NVMe SSD).
2. **Partition Table**: The structural metadata recorded at the beginning and end of the block device defining logical boundaries (e.g., GUID Partition Table - GPT).
3. **Partition**: A contiguous slice of sectors defined by the partition table acting as an independent block device.
4. **Filesystem**: An on-disk data structure (e.g., ext4, vfat, XFS) formatted into a partition that organizes raw blocks into directories, files, and inodes.
5. **Mount Point**: A directory in the unified Linux VFS (Virtual Filesystem) tree where a formatted filesystem is attached.

```
┌────────────────────────────────────────────────────────────────────────┐
│              Physical NVMe SSD (Samsung MZVL4512HBLU-00BTW)            │
│                       /dev/nvme0n1 (476.9 GiB)                         │
├────────────────────────────────────────────────────────────────────────┤
│                       GPT Partition Table Metadata                     │
├───────────────────────────────────┬────────────────────────────────────┤
│           Partition 1             │            Partition 2             │
│     /dev/nvme0n1p1 (1.0 GiB)      │     /dev/nvme0n1p2 (475.9 GiB)     │
├───────────────────────────────────┼────────────────────────────────────┤
│         vfat Filesystem           │          ext4 Filesystem           │
│      UUID: [SANITIZED_ESP_UUID]   │    UUID: [SANITIZED_ROOT_UUID]     │
├───────────────────────────────────┼───────────────────┬────────────────┤
│           Mount Point             │    Mount Point    │   Swap Store   │
│            /boot/efi              │         /         │   /swap.img    │
└───────────────────────────────────┴───────────────────┴────────────────┘
```

### 2.2 NVMe Naming Conventions
Legacy storage drivers use SCSI emulation (`/dev/sda`, `/dev/sdb`), where drive letters change unpredictably upon hardware bus re-enumeration.

NVMe devices follow the native Non-Volatile Memory Express specification:
$$\text{/dev/nvme} \langle C \rangle \text{n} \langle NS \rangle \text{p} \langle P \rangle$$
- **`C` (Controller Number)**: The PCI controller instance index (e.g., `nvme0` is the first PCIe NVMe controller).
- **`NS` (Namespace ID)**: The virtual or physical storage namespace provided by the controller (typically `n1` for single-namespace consumer/enterprise drives).
- **`P` (Partition Number)**: The partition index defined in the GPT partition table (e.g., `p1`, `p2`).

---

## 3. Block Device Identification & Major/Minor Numbers

### 3.1 Major and Minor Device Numbers
In Linux, the kernel communicates with device nodes using pairs of numbers:
- **Major Number**: Identifies the specific kernel subsystem/device driver responsible for the device.
- **Minor Number**: Handled internally by the driver to distinguish individual physical units, logical namespaces, or partitions.

On the audited host:
| Device Node | Type | Major:Minor | Driver Responsibility |
|---|---|---|---|
| `/dev/nvme0` | Character | `239:0` | NVMe controller character admin interface |
| `/dev/nvme0n1` | Block | `259:0` | Block driver for NVMe Namespace 1 |
| `/dev/nvme0n1p1`| Block | `259:1` | NVMe Partition 1 (`/boot/efi`) |
| `/dev/nvme0n1p2`| Block | `259:2` | NVMe Partition 2 (`/`) |
| `/dev/loop0`..`40` | Block | `7:0`..`7:40` | Linux Loopback driver (virtual block devices) |
| `/dev/mapper/control`| Character | `10:236` | Device Mapper management interface |

### 3.2 Persistent Identification via `/dev/disk/by-*` (Sanitized)
Hardcoding dynamic device names like `/dev/nvme0n1p2` in `/etc/fstab` or automated configurations introduces severe operational risk: hardware enumeration order can change after kernel upgrades, PCIe bus rebalancing, or storage additions.

Linux udev provides persistent deterministic symlinks under `/dev/disk/`:
1. **`/dev/disk/by-uuid/`**: References the **Filesystem UUID** generated when the filesystem was formatted (`mkfs`).
   - Root (`/`): `[SANITIZED_ROOT_UUID] -> ../../nvme0n1p2`
   - ESP (`/boot/efi`): `[SANITIZED_ESP_UUID] -> ../../nvme0n1p1`
2. **`/dev/disk/by-partuuid/`**: References the **GPT Partition UUID** recorded in the partition table, completely independent of what filesystem is formatted inside.
   - Root partition: `[SANITIZED_ROOT_PARTUUID] -> ../../nvme0n1p2`
   - ESP partition: `[SANITIZED_ESP_PARTUUID] -> ../../nvme0n1p1`
3. **`/dev/disk/by-id/`**: References hardware model and serial strings read from drive firmware:
   - `nvme-SAMSUNG_MZVL4512HBLU-00BTW_[SANITIZED_SERIAL] -> ../../nvme0n1`
4. **`/dev/disk/by-path/`**: References the physical PCIe bus hardware routing:
   - `pci-0000:00:0e.0-pci-10000:e1:00.0-nvme-1 -> ../../nvme0n1`

---

## 4. Logical vs. Physical Sector Sizes & Alignment

Modern storage hardware utilizes **Advanced Format** block structures:
- **Logical Block Size**: The smallest addressable unit exposed to the operating system (typically 512 bytes for backward compatibility).
- **Physical Block Size**: The internal physical sector or memory cell page size of the underlying flash media (typically 4096 bytes / 4 KiB).

```bash
# Query sector geometry via sysfs
cat /sys/block/nvme0n1/queue/logical_block_size    # 512
cat /sys/block/nvme0n1/queue/physical_block_size   # 512
```

### 4.1 Partition Alignment Mechanics
Because NAND flash memory is organized into multi-kilobyte pages and megabyte-sized erase blocks, partitions must begin on offsets that are multiples of the physical geometry.

Inspecting `/dev/nvme0n1p2` with `udevadm info`:
- `ID_PART_ENTRY_OFFSET = 2,203,648` sectors.
- Offset in bytes: $2,203,648 \times 512\text{ bytes} = 1,128,267,776\text{ bytes} = 1,076.0\text{ MiB}$.
- Because $1,128,267,776$ is evenly divisible by $4096$ and $1,048,576$ (1 MiB alignment boundary), **the partition is aligned**.

Misaligned partitions cause single I/O requests to straddle two physical flash pages, doubling write amplification and degrading NVMe throughput.

---

## 5. Linux Kernel Block Device Exposure via Sysfs

The Linux kernel exposes block subsystem internals under `/sys/block/`:
```
/sys/block/nvme0n1/
├── queue/
│   ├── scheduler              # I/O scheduler ([none] mq-deadline)
│   ├── logical_block_size     # 512 bytes
│   ├── physical_block_size    # 512 bytes
│   ├── rotational             # 0 (Solid State / NVMe)
│   ├── read_ahead_kb          # 128 kB
│   └── nr_requests            # 1023 hardware queue depth
├── stat                       # 17 kernel raw I/O metric counters
├── nvme0n1p1/                 # Partition 1 sysfs directory
└── nvme0n1p2/                 # Partition 2 sysfs directory
```

### 5.1 The Modern NVMe Multi-Queue Scheduler
Unlike legacy rotating hard drives that required complex elevator algorithms (e.g. `cfq`, `deadline`) to reorder head movements:
```bash
cat /sys/block/nvme0n1/queue/scheduler
# Output: [none] mq-deadline
```
`[none]` indicates that the kernel uses the **blk-mq (Multi-Queue Block Layer)** architecture. I/O requests are dispatched directly from CPU software queues to NVMe hardware submission queues without elevator sorting, minimizing locking contention across the 12 logical CPU threads.

---

## 6. SRE Operational Considerations & Observability Pitfalls

### 6.1 Understanding and Filtering Virtual Loop Devices in Monitoring
On this Ubuntu 24.04 host, **41 virtual loop devices** (`/dev/loop0` through `/dev/loop40`) are actively mounted, backing read-only SquashFS images for Ubuntu Snap packages.

#### Why Loop Devices Produce Misleading Filesystem Alerts:
- Snap packages package applications inside compressed, read-only SquashFS filesystems.
- By design, a SquashFS image is built with zero unallocated blocks ($100\%$ full). `df -h` will consistently report $0\%$ available space.
- Any uncalibrated filesystem capacity alert (e.g. `available / size < 10%`) will fire on every mounted snap image, generating a storm of 40+ false-positive alerts.

#### Distinguishing Filesystem Filtering from Device Filtering:
In Prometheus Node Exporter, storage metrics are segregated into two distinct collectors:
1. **Filesystem Collector (`node_filesystem_*`)**: Reports capacity, free space, and mount points. Filtering is performed on labels such as `fstype` (e.g., `fstype="squashfs"`) or `mountpoint` (e.g., `mountpoint=~"^/snap/.*"`).
2. **Disk I/O Collector (`node_disk_*`)**: Reports sector reads/writes, queue depths, and I/O times. Filtering is performed on the `device` label (e.g., `device=~"^loop[0-9]+"`).

#### Node Exporter Scrape-Time vs. Query-Time Filtering:
- **Scrape-Time Configuration**: Node Exporter includes configuration flags to prevent virtual filesystems from being scraped into TSDB at all:
  - `--collector.filesystem.fs-types-exclude="^(autofs|binfmt_misc|cgroup|fusectl|mqueue|overlay|proc|pstore|squashfs|sysfs|tmpfs|tracefs)$"`
  - `--collector.filesystem.mount-points-exclude="^/(dev|proc|sys|run|snap)($|/)"`
- **Illustrative Query-Time PromQL Patterns**:
  If virtual filesystems are scraped into Prometheus, queries must filter them out. The following are illustrative patterns requiring calibration:
  ```promql
  # Illustrative pattern: filter out virtual filesystems by filesystem type
  node_filesystem_avail_bytes{fstype!~"squashfs|tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"squashfs|tmpfs|overlay"} < 0.10

  # Illustrative pattern: filter disk I/O metrics to physical devices
  rate(node_disk_read_bytes_total{device!~"loop[0-9]+"}[5m])
  ```
- **SRE Guardrail Against Over-Filtering**:
  Monitoring exclusions must be tailored with precision. An overly broad regex (such as filtering out all non-ext4 types or excluding broad mount paths) risks masking genuine storage failures, such as filling a separate XFS partition, a critical persistent volume mount, or a read-only remount condition triggered by filesystem corruption.

### 6.2 Storage Virtualization Status on Host
Auditing the host revealed the following status:
- **LVM (Logical Volume Manager)**: **Not detected** on this host during this assessment (`/dev/mapper` contains only the `control` character node, and no volume groups or logical volumes are present).
- **dm-crypt / LUKS Encryption**: **Not detected** on this host during this assessment (the root filesystem formats directly onto `/dev/nvme0n1p2`).
- **Software RAID (`mdraid`)**: **Not detected** on this host during this assessment (`/proc/mdstat` contains no active arrays).
*(Note: These layers are not impossible or unsupported on Ubuntu 24.04; they were simply not configured on this specific installation).*

### 6.3 Technical Analysis of Swap File I/O Contention
Swap on this host is implemented as a pre-allocated file (`/swap.img`) on `/dev/nvme0n1p2` rather than a dedicated swap partition.

#### SRE Contention Mechanics:
1. **Bypassing Filesystem Journaling**: Once activated with `swapon`, the Linux kernel determines the physical on-disk block extents of the swapfile via `bmap`/`fibmap`. Paging operations issue direct block I/O requests to the underlying block device, completely bypassing ext4 filesystem journaling. Ordinary swap I/O does **not** compete through ext4 journal locks.
2. **Physical Device Queue Contention**: However, because the swapfile resides on the same physical SSD (`nvme0n1`) as the root filesystem, heavy swap paging and regular filesystem I/O target the same underlying flash memory channels and PCIe queues.
3. **Operational Impact**: High swap read/write throughput consumes physical drive IOPS and bandwidth, increases average disk queue length (`aqu-sz`), and elevates read/write wait latencies (`r_await`, `w_await`) for all applications running on the host.
4. **Investigation Methodology**: Storage contention must be evaluated using device-level I/O metrics (`iostat -xz`, `node_disk_*`) and observed application request latency, rather than assuming filesystem-level locking conflicts.
