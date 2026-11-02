"""Tests for incident lifecycle mathematics, timelines, and MTBF formulations."""

import time
import pytest

from scripts.reliability.lifecycle_tracker import IncidentTimeline, calculate_mtbf


def test_timeline_milestones_and_intervals():
    """Verify exact interval calculations between lifecycle milestones."""
    tl = IncidentTimeline(scenario_id="SRE-TEST", scenario_name="Test Scenario")

    # Set explicit synthetic epochs
    tl.t_inject = 1000.0
    tl.t_detect = 1012.5
    tl.t_alert = 1015.0
    tl.t_investigate = 1018.0
    tl.t_recover_start = 1025.0
    tl.t_restored = 1030.5

    assert tl.mttd == 12.5
    assert tl.alert_latency == 2.5
    assert tl.mttr == 5.5
    assert tl.total_duration == 30.5

    data = tl.to_dict()
    assert data["scenario_id"] == "SRE-TEST"
    assert data["mttd_seconds"] == 12.5
    assert data["mttr_seconds"] == 5.5
    assert data["total_duration_seconds"] == 30.5


def test_timeline_partial_milestones_fallback():
    """Verify zero/fallback behavior when milestones are incomplete."""
    tl = IncidentTimeline(scenario_id="SRE-INCOMPLETE", scenario_name="Incomplete")
    assert tl.mttd == 0.0
    assert tl.mttr == 0.0
    assert tl.total_duration == 0.0


def test_calculate_mtbf():
    """Verify MTBF calculation across multiple observations."""
    # 30 days = 2,592,000 seconds, 3 incidents -> MTBF = 864,000.0 seconds
    assert calculate_mtbf(2592000, 3) == 864000.0

    # 1000 seconds, 4 failures -> 250.0
    assert calculate_mtbf(1000, 4) == 250.0

    # 0 failures -> None
    assert calculate_mtbf(1000, 0) is None
    assert calculate_mtbf(1000, -1) is None
