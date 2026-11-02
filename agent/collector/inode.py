"""Inode metrics collector inspecting filesystem inode counts."""

import os
import re
from typing import Callable, List, Optional

from agent.collector.base import BaseCollector
from agent.config import FilesystemFilterConfig
from agent.models import MetricFamily, MetricType


class InodeCollector(BaseCollector):
    """Collects inode capacity, available inodes, and used inodes across filesystems."""

    name: str = "inode"

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

        total_fam = MetricFamily(
            name="linux_inode_total",
            type=MetricType.GAUGE,
            documentation="Total inode capacity of the filesystem.",
        )
        free_fam = MetricFamily(
            name="linux_inode_free",
            type=MetricType.GAUGE,
            documentation="Number of free inodes available for file creation.",
        )
        used_fam = MetricFamily(
            name="linux_inode_used",
            type=MetricType.GAUGE,
            documentation="Number of allocated inodes in use.",
        )

        mount_lines = self.read_lines(os.path.join(self.proc_path, "mounts"))
        if mount_lines:
            seen_mounts = set()
            for line in mount_lines:
                parts = line.split()
                if len(parts) < 3:
                    continue
                device, mountpoint, fstype = parts[0], parts[1], parts[2]

                if mountpoint in seen_mounts:
                    continue
                seen_mounts.add(mountpoint)

                if self._should_exclude(device, mountpoint, fstype):
                    continue

                try:
                    stat = self._statvfs(mountpoint)
                except (PermissionError, FileNotFoundError, OSError):
                    continue

                # Note on FAT32/vfat (like /boot/efi): statvfs reports f_files = 0
                # because FAT32 does not use traditional inodes.
                total_inodes = stat.f_files
                free_inodes = stat.f_ffree
                used_inodes = max(0, total_inodes - free_inodes)

                labels = {
                    "device": device,
                    "mountpoint": mountpoint,
                    "fstype": fstype,
                }

                total_fam.add_sample(labels=labels, value=total_inodes)
                free_fam.add_sample(labels=labels, value=free_inodes)
                used_fam.add_sample(labels=labels, value=used_inodes)

            if total_fam.samples:
                families.extend([total_fam, free_fam, used_fam])

        return families
