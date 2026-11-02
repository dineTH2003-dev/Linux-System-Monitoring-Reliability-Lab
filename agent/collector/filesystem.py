"""Filesystem capacity and mount metrics collector."""

import os
import re
from typing import Callable, List, Optional

from agent.collector.base import BaseCollector
from agent.config import FilesystemFilterConfig
from agent.models import MetricFamily, MetricType


class FilesystemCollector(BaseCollector):
    """Collects filesystem block capacity, available bytes, and read-only status."""

    name: str = "filesystem"

    def __init__(
        self,
        proc_path: str = "/proc",
        sys_path: str = "/sys",
        filter_config: Optional[FilesystemFilterConfig] = None,
        statvfs_func: Optional[Callable[[str], os.statvfs_result]] = None,
    ) -> None:
        super().__init__(proc_path, sys_path)
        self.filter_config = filter_config or FilesystemFilterConfig()
        self._statvfs = statvfs_func or os.statvfs
        # Compile regexes for exclusion
        self._mount_exclude_patterns = [
            re.compile(p) for p in self.filter_config.exclude_mountpoints
        ]

    def _should_exclude(self, device: str, mountpoint: str, fstype: str) -> bool:
        if fstype in self.filter_config.exclude_fstypes:
            return True
        for pattern in self._mount_exclude_patterns:
            if pattern.search(mountpoint):
                return True
        return False

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        size_fam = MetricFamily(
            name="linux_filesystem_size_bytes",
            type=MetricType.GAUGE,
            documentation="Total capacity of the filesystem in bytes.",
        )
        avail_fam = MetricFamily(
            name="linux_filesystem_avail_bytes",
            type=MetricType.GAUGE,
            documentation="Bytes available for allocation by unprivileged users.",
        )
        free_fam = MetricFamily(
            name="linux_filesystem_free_bytes",
            type=MetricType.GAUGE,
            documentation="Total unallocated bytes including root reserve.",
        )
        used_fam = MetricFamily(
            name="linux_filesystem_used_bytes",
            type=MetricType.GAUGE,
            documentation="Bytes currently occupied on the filesystem.",
        )
        ro_fam = MetricFamily(
            name="linux_filesystem_readonly",
            type=MetricType.GAUGE,
            documentation="Boolean indicator for filesystem read-only state (1 = read-only, 0 = read-write).",
        )

        mount_lines = self.read_lines(os.path.join(self.proc_path, "mounts"))
        if mount_lines:
            seen_mounts = set()
            for line in mount_lines:
                parts = line.split()
                if len(parts) < 4:
                    continue
                device, mountpoint, fstype, options = parts[0], parts[1], parts[2], parts[3]

                # De-duplicate mounts
                if mountpoint in seen_mounts:
                    continue
                seen_mounts.add(mountpoint)

                if self._should_exclude(device, mountpoint, fstype):
                    continue

                try:
                    stat = self._statvfs(mountpoint)
                except (PermissionError, FileNotFoundError, OSError):
                    continue

                # Block size: f_frsize (fundamental filesystem block size)
                block_size = stat.f_frsize or stat.f_bsize
                size_bytes = stat.f_blocks * block_size
                free_bytes = stat.f_bfree * block_size
                avail_bytes = stat.f_bavail * block_size
                used_bytes = max(0, size_bytes - free_bytes)

                # Read-only flag: either from statvfs f_flag or mount options
                is_readonly = 1 if (
                    (stat.f_flag & os.ST_RDONLY) or "ro" in options.split(",")
                ) else 0

                labels = {
                    "device": device,
                    "mountpoint": mountpoint,
                    "fstype": fstype,
                }

                size_fam.add_sample(labels=labels, value=size_bytes)
                avail_fam.add_sample(labels=labels, value=avail_bytes)
                free_fam.add_sample(labels=labels, value=free_bytes)
                used_fam.add_sample(labels=labels, value=used_bytes)
                ro_fam.add_sample(labels=labels, value=is_readonly)

            if size_fam.samples:
                families.extend([size_fam, avail_fam, free_fam, used_fam, ro_fam])

        return families
