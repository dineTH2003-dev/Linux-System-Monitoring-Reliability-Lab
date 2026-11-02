"""Incident lifecycle telemetry recorder and MTTD/MTTR/MTBF calculator.

Grounding: Google SRE incident lifecycle standards.
All measurements are recorded from actual timestamps; no fabricated values.
"""

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
import time
from typing import Any, Dict, Optional


def now_utc_iso() -> str:
    """Return current UTC timestamp in ISO 8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class IncidentTimeline:
    scenario_id: str
    scenario_name: str
    t_inject: float = 0.0
    t_detect: float = 0.0
    t_alert: float = 0.0
    t_investigate: float = 0.0
    t_recover_start: float = 0.0
    t_restored: float = 0.0
    t_inject_iso: str = ""
    t_detect_iso: str = ""
    t_alert_iso: str = ""
    t_investigate_iso: str = ""
    t_recover_start_iso: str = ""
    t_restored_iso: str = ""
    detection_method: str = ""
    symptoms: str = ""
    root_cause_confirmed: str = ""
    recovery_action: str = ""
    verification_evidence: str = ""

    def mark_injected(self) -> None:
        self.t_inject = time.time()
        self.t_inject_iso = now_utc_iso()

    def mark_detected(self, method: str = "") -> None:
        self.t_detect = time.time()
        self.t_detect_iso = now_utc_iso()
        if method:
            self.detection_method = method

    def mark_alerted(self) -> None:
        self.t_alert = time.time()
        self.t_alert_iso = now_utc_iso()

    def mark_investigating(self) -> None:
        self.t_investigate = time.time()
        self.t_investigate_iso = now_utc_iso()

    def mark_recovery_started(self, action: str = "") -> None:
        self.t_recover_start = time.time()
        self.t_recover_start_iso = now_utc_iso()
        if action:
            self.recovery_action = action

    def mark_restored(self, evidence: str = "") -> None:
        self.t_restored = time.time()
        self.t_restored_iso = now_utc_iso()
        if evidence:
            self.verification_evidence = evidence

    @property
    def mttd(self) -> float:
        """Mean Time to Detect (seconds)."""
        if self.t_detect and self.t_inject:
            return round(max(0.0, self.t_detect - self.t_inject), 3)
        return 0.0

    @property
    def alert_latency(self) -> float:
        """Latency from detection to alert firing (seconds)."""
        if self.t_alert and self.t_detect:
            return round(max(0.0, self.t_alert - self.t_detect), 3)
        return 0.0

    @property
    def mttr(self) -> float:
        """Mean Time to Restore from remediation trigger to restored state (seconds)."""
        if self.t_restored and self.t_recover_start:
            return round(max(0.0, self.t_restored - self.t_recover_start), 3)
        return 0.0

    @property
    def total_duration(self) -> float:
        """Total elapsed incident duration (seconds)."""
        if self.t_restored and self.t_inject:
            return round(max(0.0, self.t_restored - self.t_inject), 3)
        return 0.0

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["mttd_seconds"] = self.mttd
        data["alert_latency_seconds"] = self.alert_latency
        data["mttr_seconds"] = self.mttr
        data["total_duration_seconds"] = self.total_duration
        return data

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)


def calculate_mtbf(total_uptime_seconds: float, failure_count: int) -> Optional[float]:
    """Calculate MTBF = total uptime / number of failures."""
    if failure_count <= 0:
        return None
    return round(total_uptime_seconds / failure_count, 2)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Lifecycle telemetry tracker")
    parser.add_argument("--scenario-id", required=True, help="Scenario ID (e.g. SRE-001)")
    parser.add_argument("--name", required=True, help="Scenario name")
    parser.add_argument("--output", help="JSON output file path")
    args = parser.parse_args()

    timeline = IncidentTimeline(scenario_id=args.scenario_id, scenario_name=args.name)
    timeline.mark_injected()
    time.sleep(0.1)
    timeline.mark_detected("Synthetic probe")
    time.sleep(0.1)
    timeline.mark_alerted()
    time.sleep(0.1)
    timeline.mark_recovery_started("Automated restart")
    time.sleep(0.1)
    timeline.mark_restored("Healthz 200 OK")

    payload = timeline.to_json()
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(payload)
    print(payload)
