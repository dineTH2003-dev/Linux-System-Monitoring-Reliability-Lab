"""Memory metrics collector inspecting /proc/meminfo and /proc/pressure/memory."""

import os
from typing import Dict, List

from agent.collector.base import BaseCollector
from agent.models import MetricFamily, MetricType


class MemoryCollector(BaseCollector):
    """Collects RAM totals, available, used, cached, buffers, and memory PSI metrics."""

    name: str = "memory"

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        meminfo_lines = self.read_lines(os.path.join(self.proc_path, "meminfo"))
        if meminfo_lines:
            mem_data: Dict[str, int] = {}
            for line in meminfo_lines:
                if ":" not in line:
                    continue
                key, val = line.split(":", 1)
                parts = val.strip().split()
                if parts:
                    try:
                        # Values in /proc/meminfo are in kB
                        mem_data[key.strip()] = int(parts[0]) * 1024
                    except ValueError:
                        continue

            total_bytes = mem_data.get("MemTotal", 0)
            avail_bytes = mem_data.get("MemAvailable", 0)
            free_bytes = mem_data.get("MemFree", 0)
            cached_bytes = mem_data.get("Cached", 0)
            buffers_bytes = mem_data.get("Buffers", 0)
            shmem_bytes = mem_data.get("Shmem", 0)
            sreclaimable_bytes = mem_data.get("SReclaimable", 0)

            # SRE definition: used = MemTotal - MemAvailable
            used_bytes = max(0, total_bytes - avail_bytes) if avail_bytes > 0 else max(0, total_bytes - free_bytes)

            # 1. Memory Total Bytes
            total_fam = MetricFamily(
                name="linux_memory_total_bytes",
                type=MetricType.GAUGE,
                documentation="Total usable physical RAM in bytes.",
            )
            total_fam.add_sample(value=total_bytes)
            families.append(total_fam)

            # 2. Memory Available Bytes
            avail_fam = MetricFamily(
                name="linux_memory_available_bytes",
                type=MetricType.GAUGE,
                documentation="Estimated memory available for starting new applications without swapping in bytes.",
            )
            avail_fam.add_sample(value=avail_bytes)
            families.append(avail_fam)

            # 3. Memory Used Bytes
            used_fam = MetricFamily(
                name="linux_memory_used_bytes",
                type=MetricType.GAUGE,
                documentation="Memory currently in use by applications and kernel buffers in bytes.",
            )
            used_fam.add_sample(value=used_bytes)
            families.append(used_fam)

            # 4. Memory Free Bytes
            free_fam = MetricFamily(
                name="linux_memory_free_bytes",
                type=MetricType.GAUGE,
                documentation="Completely unallocated physical memory currently holding no data or cache.",
            )
            free_fam.add_sample(value=free_bytes)
            families.append(free_fam)

            # 5. Cached & Buffers Bytes
            cached_fam = MetricFamily(
                name="linux_memory_cached_bytes",
                type=MetricType.GAUGE,
                documentation="In-memory page cache for file reads in bytes.",
            )
            cached_fam.add_sample(value=cached_bytes)
            families.append(cached_fam)

            buffers_fam = MetricFamily(
                name="linux_memory_buffers_bytes",
                type=MetricType.GAUGE,
                documentation="Raw block device buffer cache in bytes.",
            )
            buffers_fam.add_sample(value=buffers_bytes)
            families.append(buffers_fam)

            shmem_fam = MetricFamily(
                name="linux_memory_shmem_bytes",
                type=MetricType.GAUGE,
                documentation="Shared memory consumption (shmem, tmpfs) in bytes.",
            )
            shmem_fam.add_sample(value=shmem_bytes)
            families.append(shmem_fam)

            sreclaim_fam = MetricFamily(
                name="linux_memory_sreclaimable_bytes",
                type=MetricType.GAUGE,
                documentation="In-kernel SLAB cache that can be reclaimed under memory pressure in bytes.",
            )
            sreclaim_fam.add_sample(value=sreclaimable_bytes)
            families.append(sreclaim_fam)

            # 6. Custom Memory Saturation Pressure Marker (from architecture contract)
            if total_bytes > 0:
                sat_ratio = used_bytes / total_bytes
                custom_press_fam = MetricFamily(
                    name="linux_custom_memory_pressure",
                    type=MetricType.GAUGE,
                    documentation="Memory saturation ratio calculated as (MemTotal - MemAvailable) / MemTotal.",
                )
                custom_press_fam.add_sample(labels={"type": "saturation"}, value=sat_ratio)
                families.append(custom_press_fam)

        # 7. Memory Pressure Stall Information (/proc/pressure/memory)
        psi_lines = self.read_lines(os.path.join(self.proc_path, "pressure", "memory"))
        if psi_lines:
            psi_ratio_fam = MetricFamily(
                name="linux_memory_pressure_ratio",
                type=MetricType.GAUGE,
                documentation="Memory allocation stall pressure ratio over rolling windows (0.0 to 1.0).",
            )
            psi_total_fam = MetricFamily(
                name="linux_memory_pressure_total_seconds",
                type=MetricType.COUNTER,
                documentation="Cumulative time stalled on memory allocation converted to seconds.",
            )

            for line in psi_lines:
                parsed = self.parse_psi_line(line)
                if not parsed:
                    continue
                type_name, avgs, total_sec = parsed
                for window, val in avgs.items():
                    psi_ratio_fam.add_sample(
                        labels={"type": type_name, "window": window},
                        value=val / 100.0,
                    )
                psi_total_fam.add_sample(
                    labels={"type": type_name},
                    value=total_sec,
                )

            if psi_ratio_fam.samples:
                families.append(psi_ratio_fam)
            if psi_total_fam.samples:
                families.append(psi_total_fam)

        return families
