"""Systemd service availability and unit state collector."""

import subprocess
from typing import Callable, Dict, List, Optional

from agent.collector.base import BaseCollector
from agent.config import SystemdConfig
from agent.models import MetricFamily, MetricType


class SystemdCollector(BaseCollector):
    """Monitors systemd service unit availability and execution states."""

    name: str = "systemd"

    # Standard systemd active states
    ACTIVE_STATES = ("active", "inactive", "failed", "activating", "deactivating")

    def __init__(
        self,
        proc_path: str = "/proc",
        sys_path: str = "/sys",
        config: Optional[SystemdConfig] = None,
        runner_func: Optional[Callable[..., subprocess.CompletedProcess]] = None,
    ) -> None:
        super().__init__(proc_path, sys_path)
        self.config = config or SystemdConfig()
        self._runner = runner_func or subprocess.run
        self._collection_errors = 0

    def _query_unit(self, unit: str) -> Optional[Dict[str, str]]:
        """Query unit states using systemctl show."""
        cmd = [
            "systemctl",
            "show",
            unit,
            "--property=ActiveState,SubState,LoadState,UnitFileState",
        ]
        try:
            res = self._runner(
                cmd,
                capture_output=True,
                text=True,
                timeout=self.config.timeout_seconds,
                check=False,
            )
            if res.returncode != 0:
                self._collection_errors += 1
                return None

            props: Dict[str, str] = {}
            for line in res.stdout.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    props[k.strip()] = v.strip()
            return props
        except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError):
            self._collection_errors += 1
            return None

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        active_fam = MetricFamily(
            name="linux_systemd_unit_active",
            type=MetricType.GAUGE,
            documentation=(
                "Boolean indicator of whether the systemd service unit is active "
                "(1 = active, 0 = inactive/failed)."
            ),
        )
        state_fam = MetricFamily(
            name="linux_systemd_unit_state",
            type=MetricType.GAUGE,
            documentation="Systemd unit execution state indicator.",
        )
        err_fam = MetricFamily(
            name="linux_systemd_service_collector_errors_total",
            type=MetricType.COUNTER,
            documentation="Total number of errors encountered querying systemd unit states.",
        )

        for unit in self.config.monitored_units:
            props = self._query_unit(unit)
            if props is None:
                # Service not found or error: mark inactive and state failed/inactive
                active_fam.add_sample(labels={"unit": unit}, value=0.0)
                for s in self.ACTIVE_STATES:
                    state_fam.add_sample(labels={"unit": unit, "state": s}, value=0.0)
                continue

            active_state = props.get("ActiveState", "inactive").lower()
            is_active = 1.0 if active_state == "active" else 0.0

            active_fam.add_sample(labels={"unit": unit}, value=is_active)
            for s in self.ACTIVE_STATES:
                state_val = 1.0 if s == active_state else 0.0
                state_fam.add_sample(labels={"unit": unit, "state": s}, value=state_val)

        err_fam.add_sample(value=self._collection_errors)

        families.extend([active_fam, state_fam, err_fam])
        return families
