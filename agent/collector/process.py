"""Process metrics collector with bounded scanning and credential sanitization."""

import os
import re
from typing import Dict, List, Optional, Tuple

import psutil

from agent.collector.base import BaseCollector
from agent.config import ProcessFilterConfig
from agent.models import MetricFamily, MetricType


class ProcessCollector(BaseCollector):
    """Collects system process state counts and resource consumption for top processes."""

    name: str = "process"

    # Mapping of Linux process state characters to standardized state names
    STATE_MAP = {
        "R": "running",
        "S": "sleeping",
        "D": "disk_sleep",
        "Z": "zombie",
        "T": "stopped",
        "t": "stopped",
        "I": "idle",
        "X": "dead",
        "x": "dead",
        "W": "wakekill",
    }

    # Allowed characters for sanitized process names
    NAME_CLEAN_RE = re.compile(r"[^a-zA-Z0-9_\-\.:]")

    def __init__(
        self,
        proc_path: str = "/proc",
        sys_path: str = "/sys",
        filter_config: Optional[ProcessFilterConfig] = None,
        use_psutil: bool = True,
    ) -> None:
        super().__init__(proc_path, sys_path)
        self.filter_config = filter_config or ProcessFilterConfig()
        self.use_psutil = use_psutil and (proc_path == "/proc")

    def _sanitize_name(self, raw_name: str) -> str:
        """Sanitize process name to eliminate control characters, paths, and length bloat."""
        clean = os.path.basename(raw_name.rstrip("/\\")).strip()
        clean = self.NAME_CLEAN_RE.sub("_", clean)
        return clean[:32] if clean else "unknown"

    def _collect_via_proc(self) -> Tuple[Dict[str, int], int, List[Dict]]:
        """Fallback / synthetic collector directly inspecting /proc/[pid]/stat."""
        state_counts: Dict[str, int] = {
            "running": 0, "sleeping": 0, "disk_sleep": 0,
            "zombie": 0, "stopped": 0, "idle": 0
        }
        total_procs = 0
        proc_list: List[Dict] = []

        try:
            entries = os.listdir(self.proc_path)
        except (FileNotFoundError, PermissionError, OSError):
            return state_counts, total_procs, proc_list

        pid_dirs = [e for e in entries if e.isdigit()]
        # Enforce bounded limit
        for pid_str in pid_dirs[: self.filter_config.max_processes]:
            total_procs += 1
            stat_content = self.read_file(os.path.join(self.proc_path, pid_str, "stat"))
            if not stat_content:
                continue

            # /proc/[pid]/stat format: pid (name) state ...
            # Name can contain parentheses, so parse after the last ')'
            rparen_idx = stat_content.rfind(")")
            if rparen_idx == -1:
                continue

            lparen_idx = stat_content.find("(")
            raw_name = stat_content[lparen_idx + 1: rparen_idx] if lparen_idx != -1 else "unknown"
            remaining = stat_content[rparen_idx + 2:].split()
            if not remaining:
                continue

            state_char = remaining[0]
            canonical_state = self.STATE_MAP.get(state_char, "sleeping")
            state_counts[canonical_state] = state_counts.get(canonical_state, 0) + 1

            # Estimate RSS from field 24 (index 21 after remaining[0]): rss pages * 4096
            rss_bytes = 0
            if len(remaining) > 21:
                try:
                    rss_bytes = int(remaining[21]) * 4096
                except ValueError:
                    pass

            proc_list.append({
                "pid": pid_str,
                "name": self._sanitize_name(raw_name),
                "rss": rss_bytes,
                "cpu_percent": 0.0,
            })

        return state_counts, total_procs, proc_list

    def _collect_via_psutil(self) -> Tuple[Dict[str, int], int, List[Dict]]:
        """Efficient process collection leveraging psutil."""
        state_counts: Dict[str, int] = {
            "running": 0, "sleeping": 0, "disk_sleep": 0,
            "zombie": 0, "stopped": 0, "idle": 0
        }
        total_procs = 0
        proc_list: List[Dict] = []

        count = 0
        for proc in psutil.process_iter(
            attrs=["pid", "name", "status", "cpu_percent", "memory_info"]
        ):
            count += 1
            if count > self.filter_config.max_processes:
                break
            try:
                info = proc.info
                status = info.get("status") or "sleeping"
                canonical_state = status.lower()
                if canonical_state == "disk-sleep":
                    canonical_state = "disk_sleep"
                elif canonical_state not in state_counts:
                    canonical_state = "sleeping"

                state_counts[canonical_state] = state_counts.get(canonical_state, 0) + 1
                total_procs += 1

                mem_info = info.get("memory_info")
                rss = getattr(mem_info, "rss", 0) if mem_info else 0
                vms = getattr(mem_info, "vms", 0) if mem_info else 0
                cpu_p = info.get("cpu_percent") or 0.0

                proc_list.append({
                    "pid": str(info.get("pid")),
                    "name": self._sanitize_name(info.get("name") or "unknown"),
                    "rss": rss,
                    "vms": vms,
                    "cpu_percent": cpu_p,
                })
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue

        return state_counts, total_procs, proc_list

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        count_fam = MetricFamily(
            name="linux_process_count",
            type=MetricType.GAUGE,
            documentation="Number of processes grouped by scheduling execution state.",
        )
        total_fam = MetricFamily(
            name="linux_process_total",
            type=MetricType.GAUGE,
            documentation="Total number of running processes on the host.",
        )
        cpu_cons_fam = MetricFamily(
            name="linux_process_cpu_consumption_ratio",
            type=MetricType.GAUGE,
            documentation="Instantaneous CPU consumption ratio for top consuming processes.",
        )
        mem_cons_fam = MetricFamily(
            name="linux_process_memory_consumption_bytes",
            type=MetricType.GAUGE,
            documentation="Memory footprint in bytes for top consuming processes.",
        )

        if self.use_psutil:
            try:
                state_counts, total_procs, proc_list = self._collect_via_psutil()
            except Exception:
                state_counts, total_procs, proc_list = self._collect_via_proc()
        else:
            state_counts, total_procs, proc_list = self._collect_via_proc()

        for state, cnt in state_counts.items():
            count_fam.add_sample(labels={"state": state}, value=cnt)
        total_fam.add_sample(value=total_procs)

        # Top N processes by memory
        top_mem = sorted(proc_list, key=lambda x: x.get("rss", 0), reverse=True)[
            : self.filter_config.top_n_mem
        ]
        for p in top_mem:
            labels_rss = {"pid": p["pid"], "name": p["name"], "type": "rss"}
            mem_cons_fam.add_sample(labels=labels_rss, value=p.get("rss", 0))
            if "vms" in p:
                labels_vms = {"pid": p["pid"], "name": p["name"], "type": "vms"}
                mem_cons_fam.add_sample(labels=labels_vms, value=p.get("vms", 0))

        # Top N processes by CPU
        top_cpu = sorted(proc_list, key=lambda x: x.get("cpu_percent", 0.0), reverse=True)[
            : self.filter_config.top_n_cpu
        ]
        for p in top_cpu:
            labels_cpu = {"pid": p["pid"], "name": p["name"]}
            # Convert cpu_percent (0-100%) to ratio (0.0-1.0)
            cpu_cons_fam.add_sample(labels=labels_cpu, value=p.get("cpu_percent", 0.0) / 100.0)

        families.extend([count_fam, total_fam])
        if mem_cons_fam.samples:
            families.append(mem_cons_fam)
        if cpu_cons_fam.samples:
            families.append(cpu_cons_fam)

        return families
