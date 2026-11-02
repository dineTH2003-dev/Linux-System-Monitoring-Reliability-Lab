"""Shared fixtures and synthetic procfs/sysfs test environments."""

import os
import tempfile
from collections import namedtuple
from typing import Generator
import pytest

# Synthetic /proc/stat
PROC_STAT_SAMPLE = """cpu  23699739 4306 6022439 101041738 147273 0 102450 0 20000 500
cpu0 2100000 400 500000 8000000 12000 0 10000 0 1500 50
cpu1 1900000 350 480000 8100000 11000 0 9500 0 1400 40
intr 123456789
ctxt 987654321
btime 1700000000
processes 54321
procs_running 2
procs_blocked 0
"""

# Synthetic /proc/loadavg
PROC_LOADAVG_SAMPLE = "1.25 2.50 3.75 2/1024 45678\n"

# Synthetic /proc/meminfo
PROC_MEMINFO_SAMPLE = """MemTotal:       16068168 kB
MemFree:         1363636 kB
MemAvailable:    4028776 kB
Buffers:           63896 kB
Cached:          7612652 kB
SwapCached:        12340 kB
Active:          4567890 kB
Inactive:        3456780 kB
SwapTotal:       4194300 kB
SwapFree:        3552200 kB
Shmem:           5030888 kB
SReclaimable:     450364 kB
"""

# Synthetic /proc/vmstat
PROC_VMSTAT_SAMPLE = """nr_free_pages 340909
nr_inactive_anon 123456
pswpin 989217
pswpout 2369821
pgpgin 8765432
pgpgout 1234567
"""

# Synthetic /proc/pressure/cpu
PROC_PRESSURE_CPU_SAMPLE = """some avg10=2.50 avg60=1.75 avg300=0.85 total=12345678
"""

# Synthetic /proc/pressure/memory
PROC_PRESSURE_MEMORY_SAMPLE = """some avg10=0.50 avg60=0.25 avg300=0.10 total=4567890
full avg10=0.10 avg60=0.05 avg300=0.01 total=123456
"""

# Synthetic /proc/mounts
PROC_MOUNTS_SAMPLE = """/dev/nvme0n1p2 / ext4 rw,relatime,errors=remount-ro 0 0
/dev/nvme0n1p1 /boot/efi vfat rw,relatime,fmask=0022,dmask=0022 0 0
/dev/loop1 /snap/core22/1621 squashfs ro,nodev,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev,noexec,relatime,size=1606820k,mode=755 0 0
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
"""

# Synthetic /proc/diskstats
PROC_DISKSTATS_SAMPLE = """   8       0 sda 1000 100 20000 5000 2000 200 40000 10000 0 15000 20000
 259       0 nvme0n1 50000 500 1000000 25000 75000 1000 2500000 45000 2 60000 80000
   7       0 loop0 500 0 1000 100 0 0 0 0 0 100 100
"""

# Synthetic /proc/net/dev
PROC_NET_DEV_SAMPLE = (
    "Inter-|   Receive                                                |  Transmit\n"
    " face |bytes    packets errs drop fifo frame compressed multicast|"
    "bytes    packets errs drop fifo colls carrier compressed\n"
    "    lo: 10000000    50000    0    0    0     0          0         0 "
    "10000000    50000    0    0    0     0       0          0\n"
    "  eth0: 50000000   100000   10    5    0     0          0         0 "
    "30000000    75000    2    1    0     0       0          0\n"
)

# Mock StatVFS Result
StatVFS = namedtuple(
    "StatVFS",
    [
        "f_bsize",
        "f_frsize",
        "f_blocks",
        "f_bfree",
        "f_bavail",
        "f_files",
        "f_ffree",
        "f_favail",
        "f_flag",
        "f_namemax",
    ],
)


@pytest.fixture
def mock_proc_dir() -> Generator[str, None, None]:
    """Create a temporary proc directory populated with synthetic test data."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create proc structure
        os.makedirs(os.path.join(tmpdir, "pressure"), exist_ok=True)
        os.makedirs(os.path.join(tmpdir, "net"), exist_ok=True)

        with open(os.path.join(tmpdir, "stat"), "w") as f:
            f.write(PROC_STAT_SAMPLE)
        with open(os.path.join(tmpdir, "loadavg"), "w") as f:
            f.write(PROC_LOADAVG_SAMPLE)
        with open(os.path.join(tmpdir, "meminfo"), "w") as f:
            f.write(PROC_MEMINFO_SAMPLE)
        with open(os.path.join(tmpdir, "vmstat"), "w") as f:
            f.write(PROC_VMSTAT_SAMPLE)
        with open(os.path.join(tmpdir, "pressure", "cpu"), "w") as f:
            f.write(PROC_PRESSURE_CPU_SAMPLE)
        with open(os.path.join(tmpdir, "pressure", "memory"), "w") as f:
            f.write(PROC_PRESSURE_MEMORY_SAMPLE)
        with open(os.path.join(tmpdir, "mounts"), "w") as f:
            f.write(PROC_MOUNTS_SAMPLE)
        with open(os.path.join(tmpdir, "diskstats"), "w") as f:
            f.write(PROC_DISKSTATS_SAMPLE)
        with open(os.path.join(tmpdir, "net", "dev"), "w") as f:
            f.write(PROC_NET_DEV_SAMPLE)

        # Create synthetic processes
        # PID 101: systemd (sleeping)
        os.makedirs(os.path.join(tmpdir, "101"), exist_ok=True)
        pid101_stat = (
            "101 (systemd) S 0 1 1 0 -1 4194560 1200 0 0 0 50 100 0 0 20 0 1 0 100 "
            "12345678 2500 18446744073709551615\n"
        )
        with open(os.path.join(tmpdir, "101", "stat"), "w") as f:
            f.write(pid101_stat)

        # PID 202: python3 worker (running)
        os.makedirs(os.path.join(tmpdir, "202"), exist_ok=True)
        pid202_stat = (
            "202 (python3) R 101 202 202 0 -1 4194560 3000 0 0 0 500 200 0 0 20 0 4 0 200 "
            "23456789 5000 18446744073709551615\n"
        )
        with open(os.path.join(tmpdir, "202", "stat"), "w") as f:
            f.write(pid202_stat)

        # PID 303: zombie process
        os.makedirs(os.path.join(tmpdir, "303"), exist_ok=True)
        with open(os.path.join(tmpdir, "303", "stat"), "w") as f:
            f.write("303 (defunct_proc) Z 101 303 303 0 -1 0 0 0 0 0 10 5 0 0 20 0 0 0 300 0 0 0\n")

        yield tmpdir


@pytest.fixture
def mock_statvfs():
    """Mock statvfs callable returning controlled capacity and inode metrics."""
    def _statvfs(path: str) -> StatVFS:
        if path == "/":
            # 100GB total, 40GB free, 35GB avail (5GB reserved)
            # 10M inodes total, 8M free
            return StatVFS(
                f_bsize=4096,
                f_frsize=4096,
                f_blocks=26214400,     # ~100 GiB
                f_bfree=10485760,      # ~40 GiB
                f_bavail=9175040,      # ~35 GiB
                f_files=10000000,
                f_ffree=8000000,
                f_favail=8000000,
                f_flag=0,
                f_namemax=255,
            )
        elif path == "/boot/efi":
            # FAT32 filesystem: 0 inodes
            return StatVFS(
                f_bsize=4096,
                f_frsize=4096,
                f_blocks=262144,       # ~1 GiB
                f_bfree=200000,
                f_bavail=200000,
                f_files=0,             # FAT32 has no inodes
                f_ffree=0,
                f_favail=0,
                f_flag=0,
                f_namemax=255,
            )
        raise FileNotFoundError(f"Mountpoint {path} not found")

    return _statvfs
