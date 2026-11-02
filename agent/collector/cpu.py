"""CPU metrics collector inspecting /proc/stat, /proc/loadavg, and /proc/pressure/cpu."""

import os
import time
from typing import Dict, List, Tuple

from agent.collector.base import BaseCollector
from agent.models import MetricFamily, MetricType


class CPUCollector(BaseCollector):
    """Collects CPU times, differential utilization, load averages, and PSI metrics."""

    name: str = "cpu"

    # Standard Linux kernel ticks per second (USER_HZ)
    USER_HZ = 100.0

    MODES = (
        "user", "nice", "system", "idle",
        "iowait", "irq", "softirq", "steal",
        "guest", "guest_nice"
    )

    def __init__(self, proc_path: str = "/proc", sys_path: str = "/sys") -> None:
        super().__init__(proc_path, sys_path)
        # Store previous sample for differential active utilization calculation:
        # dict: cpu_id -> (timestamp, total_ticks, idle_ticks)
        self._prev_stats: Dict[str, Tuple[float, int, int]] = {}

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        # 1. CPU Seconds Total by Mode
        cpu_seconds_family = MetricFamily(
            name="linux_cpu_seconds_total",
            type=MetricType.COUNTER,
            documentation="Total CPU time spent in each mode in seconds.",
        )

        # 2. CPU Utilization Ratio (Active / Total)
        cpu_util_family = MetricFamily(
            name="linux_cpu_utilization_ratio",
            type=MetricType.GAUGE,
            documentation="Instantaneous or differential active CPU utilization (0.0 to 1.0).",
        )

        stat_lines = self.read_lines(os.path.join(self.proc_path, "stat"))
        if stat_lines:
            now = time.time()
            for line in stat_lines:
                if not line.startswith("cpu"):
                    continue
                parts = line.split()
                cpu_label = parts[0]
                # 'cpu' is aggregate total; 'cpu0', 'cpu1' are per-core
                cpu_id = "total" if cpu_label == "cpu" else cpu_label[3:]

                # Parse numeric tick values
                try:
                    raw_ticks = [int(p) for p in parts[1:11]]
                except ValueError:
                    continue

                # Ensure 10 fields (pad with 0 if missing guest/guest_nice)
                ticks = raw_ticks + [0] * (10 - len(raw_ticks))

                # Step 1: True Total Ticks (excluding guest & guest_nice to avoid double counting)
                total_ticks = sum(ticks[:8])
                idle_ticks = ticks[3] + ticks[4]  # idle + iowait
                active_ticks = max(0, total_ticks - idle_ticks)

                # Differential utilization
                if cpu_id in self._prev_stats:
                    prev_time, prev_total, prev_idle = self._prev_stats[cpu_id]
                    delta_total = total_ticks - prev_total
                    delta_idle = idle_ticks - prev_idle
                    delta_active = max(0, delta_total - delta_idle)
                    if delta_total > 0:
                        util_ratio = min(1.0, max(0.0, delta_active / delta_total))
                    else:
                        util_ratio = 0.0
                    cpu_util_family.add_sample(
                        labels={"cpu": cpu_id},
                        value=util_ratio,
                    )
                else:
                    # Initial sample: calculate cumulative ratio as baseline
                    if total_ticks > 0:
                        util_ratio = min(1.0, max(0.0, active_ticks / total_ticks))
                        cpu_util_family.add_sample(
                            labels={"cpu": cpu_id},
                            value=util_ratio,
                        )

                self._prev_stats[cpu_id] = (now, total_ticks, idle_ticks)

                # Export cpu seconds by mode
                for mode, tick_val in zip(self.MODES, ticks):
                    cpu_seconds_family.add_sample(
                        labels={"cpu": cpu_id, "mode": mode},
                        value=tick_val / self.USER_HZ,
                    )

            families.append(cpu_seconds_family)
            if cpu_util_family.samples:
                families.append(cpu_util_family)

        # 3. Load Averages (/proc/loadavg)
        loadavg_content = self.read_file(os.path.join(self.proc_path, "loadavg"))
        if loadavg_content:
            parts = loadavg_content.strip().split()
            if len(parts) >= 3:
                try:
                    load1 = float(parts[0])
                    load5 = float(parts[1])
                    load15 = float(parts[2])

                    load1_fam = MetricFamily(
                        name="linux_load1",
                        type=MetricType.GAUGE,
                        documentation="1-minute exponentially damped moving system load average.",
                    )
                    load1_fam.add_sample(value=load1)
                    families.append(load1_fam)

                    load5_fam = MetricFamily(
                        name="linux_load5",
                        type=MetricType.GAUGE,
                        documentation="5-minute exponentially damped moving system load average.",
                    )
                    load5_fam.add_sample(value=load5)
                    families.append(load5_fam)

                    load15_fam = MetricFamily(
                        name="linux_load15",
                        type=MetricType.GAUGE,
                        documentation="15-minute exponentially damped moving system load average.",
                    )
                    load15_fam.add_sample(value=load15)
                    families.append(load15_fam)
                except ValueError:
                    pass

        # 4. CPU Pressure Stall Information (/proc/pressure/cpu)
        psi_lines = self.read_lines(os.path.join(self.proc_path, "pressure", "cpu"))
        if psi_lines:
            psi_ratio_fam = MetricFamily(
                name="linux_cpu_pressure_some_ratio",
                type=MetricType.GAUGE,
                documentation="CPU scheduling pressure stall ratio over rolling windows.",
            )
            psi_total_fam = MetricFamily(
                name="linux_cpu_pressure_some_total_seconds",
                type=MetricType.COUNTER,
                documentation="Cumulative microseconds stalled on CPU scheduling converted to seconds.",
            )

            for line in psi_lines:
                parsed = self.parse_psi_line(line)
                if not parsed:
                    continue
                type_name, avgs, total_sec = parsed
                if type_name == "some":
                    for window, val in avgs.items():
                        psi_ratio_fam.add_sample(
                            labels={"window": window},
                            value=val / 100.0,  # Convert percentage to ratio (0.0 to 1.0)
                        )
                    psi_total_fam.add_sample(value=total_sec)

            if psi_ratio_fam.samples:
                families.append(psi_ratio_fam)
            if psi_total_fam.samples:
                families.append(psi_total_fam)

        return families
