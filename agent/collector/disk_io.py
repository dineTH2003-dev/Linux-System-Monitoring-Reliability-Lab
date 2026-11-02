"""Disk I/O metrics collector inspecting /proc/diskstats."""

import os
import re
from typing import List, Optional

from agent.collector.base import BaseCollector
from agent.config import DiskFilterConfig
from agent.models import MetricFamily, MetricType


class DiskIOCollector(BaseCollector):
    """Collects disk read/write operations, throughput in bytes, queue depths, and I/O time."""

    name: str = "disk_io"

    # Kernel sector size in bytes across Linux block architectures
    SECTOR_SIZE = 512.0

    def __init__(
        self,
        proc_path: str = "/proc",
        sys_path: str = "/sys",
        filter_config: Optional[DiskFilterConfig] = None,
    ) -> None:
        super().__init__(proc_path, sys_path)
        self.filter_config = filter_config or DiskFilterConfig()
        self._device_exclude_patterns = [
            re.compile(p) for p in self.filter_config.exclude_devices
        ]

    def _should_exclude(self, device: str) -> bool:
        for pattern in self._device_exclude_patterns:
            if pattern.search(device):
                return True
        return False

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        reads_fam = MetricFamily(
            name="linux_disk_reads_completed_total",
            type=MetricType.COUNTER,
            documentation="Total number of read operations completed successfully.",
        )
        writes_fam = MetricFamily(
            name="linux_disk_writes_completed_total",
            type=MetricType.COUNTER,
            documentation="Total number of write operations completed successfully.",
        )
        read_bytes_fam = MetricFamily(
            name="linux_disk_read_bytes_total",
            type=MetricType.COUNTER,
            documentation="Total number of bytes read from the block device.",
        )
        written_bytes_fam = MetricFamily(
            name="linux_disk_written_bytes_total",
            type=MetricType.COUNTER,
            documentation="Total number of bytes written to the block device.",
        )
        io_time_fam = MetricFamily(
            name="linux_disk_io_time_seconds_total",
            type=MetricType.COUNTER,
            documentation="Total time spent doing I/O operations in seconds.",
        )
        io_weighted_fam = MetricFamily(
            name="linux_disk_io_time_weighted_seconds_total",
            type=MetricType.COUNTER,
            documentation="Weighted time spent doing I/O operations in seconds.",
        )
        io_in_prog_fam = MetricFamily(
            name="linux_disk_io_in_progress",
            type=MetricType.GAUGE,
            documentation="Number of I/O operations currently in flight.",
        )

        diskstats_lines = self.read_lines(os.path.join(self.proc_path, "diskstats"))
        if diskstats_lines:
            for line in diskstats_lines:
                parts = line.strip().split()
                if len(parts) < 14:
                    continue

                device = parts[2]
                if self._should_exclude(device):
                    continue

                try:
                    reads_completed = int(parts[3])
                    sectors_read = int(parts[5])
                    writes_completed = int(parts[7])
                    sectors_written = int(parts[9])
                    ios_in_progress = int(parts[11])
                    io_ms = int(parts[12])
                    io_weighted_ms = int(parts[13])
                except ValueError:
                    continue

                labels = {"device": device}
                reads_fam.add_sample(labels=labels, value=reads_completed)
                writes_fam.add_sample(labels=labels, value=writes_completed)
                read_bytes_fam.add_sample(labels=labels, value=sectors_read * self.SECTOR_SIZE)
                written_bytes_fam.add_sample(labels=labels, value=sectors_written * self.SECTOR_SIZE)
                io_time_fam.add_sample(labels=labels, value=io_ms / 1000.0)
                io_weighted_fam.add_sample(labels=labels, value=io_weighted_ms / 1000.0)
                io_in_prog_fam.add_sample(labels=labels, value=ios_in_progress)

            if reads_fam.samples:
                families.extend([
                    reads_fam, writes_fam, read_bytes_fam,
                    written_bytes_fam, io_time_fam, io_weighted_fam,
                    io_in_prog_fam
                ])

        return families
