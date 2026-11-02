"""Swap metrics collector inspecting /proc/meminfo and /proc/vmstat."""

import os
from typing import Dict, List

from agent.collector.base import BaseCollector
from agent.models import MetricFamily, MetricType


class SwapCollector(BaseCollector):
    """Collects swap space capacity, utilization, and kernel swap page-in/out counters."""

    name: str = "swap"

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        # 1. Swap capacity from /proc/meminfo
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
                        mem_data[key.strip()] = int(parts[0]) * 1024
                    except ValueError:
                        continue

            swap_total = mem_data.get("SwapTotal", 0)
            swap_free = mem_data.get("SwapFree", 0)
            swap_used = max(0, swap_total - swap_free)

            total_fam = MetricFamily(
                name="linux_swap_total_bytes",
                type=MetricType.GAUGE,
                documentation="Total configured swap space in bytes.",
            )
            total_fam.add_sample(value=swap_total)
            families.append(total_fam)

            free_fam = MetricFamily(
                name="linux_swap_free_bytes",
                type=MetricType.GAUGE,
                documentation="Unallocated swap space in bytes.",
            )
            free_fam.add_sample(value=swap_free)
            families.append(free_fam)

            used_fam = MetricFamily(
                name="linux_swap_used_bytes",
                type=MetricType.GAUGE,
                documentation="Allocated swap space in bytes.",
            )
            used_fam.add_sample(value=swap_used)
            families.append(used_fam)

        # 2. Swap page counters from /proc/vmstat
        vmstat_lines = self.read_lines(os.path.join(self.proc_path, "vmstat"))
        if vmstat_lines:
            pswpin = 0
            pswpout = 0
            found_in = False
            found_out = False

            for line in vmstat_lines:
                parts = line.strip().split()
                if len(parts) >= 2:
                    key, val = parts[0], parts[1]
                    try:
                        if key == "pswpin":
                            pswpin = int(val)
                            found_in = True
                        elif key == "pswpout":
                            pswpout = int(val)
                            found_out = True
                    except ValueError:
                        continue

            if found_in:
                in_fam = MetricFamily(
                    name="linux_swap_in_pages_total",
                    type=MetricType.COUNTER,
                    documentation="Total number of memory pages paged in from swap storage since boot.",
                )
                in_fam.add_sample(value=pswpin)
                families.append(in_fam)

            if found_out:
                out_fam = MetricFamily(
                    name="linux_swap_out_pages_total",
                    type=MetricType.COUNTER,
                    documentation="Total number of memory pages paged out to swap storage since boot.",
                )
                out_fam.add_sample(value=pswpout)
                families.append(out_fam)

        return families
