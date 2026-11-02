"""Abstract base class and shared utilities for telemetry collectors."""

from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Tuple

from agent.models import MetricFamily


class BaseCollector(ABC):
    """Abstract base class for all system telemetry collectors."""

    name: str = "base"

    def __init__(self, proc_path: str = "/proc", sys_path: str = "/sys") -> None:
        self.proc_path = proc_path
        self.sys_path = sys_path

    @abstractmethod
    def collect(self) -> List[MetricFamily]:
        """Collect and return metric families."""
        raise NotImplementedError

    def read_file(self, filepath: str) -> Optional[str]:
        """Safely read an entire file, returning None if missing or inaccessible."""
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                return f.read()
        except (FileNotFoundError, PermissionError, IsADirectoryError, OSError):
            return None

    def read_lines(self, filepath: str) -> Optional[List[str]]:
        """Safely read lines from a file, returning None if missing or inaccessible."""
        content = self.read_file(filepath)
        if content is None:
            return None
        return content.splitlines()

    def parse_psi_line(self, line: str) -> Optional[Tuple[str, Dict[str, float], float]]:
        """
        Parse a Pressure Stall Information (PSI) line.
        Format: 'some avg10=0.00 avg60=0.00 avg300=0.00 total=322516615'
        Returns: (type_name, {'10': avg10, '60': avg60, '300': avg300}, total_seconds)
        """
        parts = line.strip().split()
        if not parts:
            return None
        type_name = parts[0]  # 'some' or 'full'
        averages: Dict[str, float] = {}
        total_seconds = 0.0

        for kv in parts[1:]:
            if "=" not in kv:
                continue
            key, val = kv.split("=", 1)
            try:
                if key == "avg10":
                    averages["10"] = float(val)
                elif key == "avg60":
                    averages["60"] = float(val)
                elif key == "avg300":
                    averages["300"] = float(val)
                elif key == "total":
                    # PSI total is reported in microseconds; convert to seconds
                    total_seconds = float(val) / 1_000_000.0
            except ValueError:
                continue

        return type_name, averages, total_seconds
