"""Tests for automated remediation controller guardrails."""

import json
import os
import pytest

from scripts.reliability.remediation.controller import RemediationController, RemediationResult


def test_remediation_idempotency_when_already_healthy(mock_controller):
    """When verification passes upfront, remediation should be a no-op (ALREADY_HEALTHY)."""
    calls = []

    def mock_remediation():
        calls.append("remediated")
        return True

    res = mock_controller.execute(
        target_name="test_target",
        precondition_fn=lambda: True,
        remediation_fn=mock_remediation,
        verification_fn=lambda: True,  # Already healthy
    )

    assert res.success is True
    assert res.status == "ALREADY_HEALTHY"
    assert len(calls) == 0  # Remediation was never invoked
    assert res.attempts == 0


def test_remediation_precondition_failure(mock_controller):
    """When preconditions fail, remediation should not run."""
    calls = []

    res = mock_controller.execute(
        target_name="test_target",
        precondition_fn=lambda: False,  # Precondition failed
        remediation_fn=lambda: calls.append("run") or True,
        verification_fn=lambda: False,
    )

    assert res.success is False
    assert res.status == "PRECONDITION_FAILED"
    assert len(calls) == 0


def test_remediation_successful_on_first_try(mock_controller):
    """Normal successful remediation flow."""
    state = {"healthy": False}

    def do_remediate():
        state["healthy"] = True
        return True

    res = mock_controller.execute(
        target_name="test_target",
        precondition_fn=lambda: True,
        remediation_fn=do_remediate,
        verification_fn=lambda: state["healthy"],
    )

    assert res.success is True
    assert res.status == "SUCCESS"
    assert res.attempts == 1
    assert res.verified is True


def test_remediation_circuit_breaker_trips_after_max_retries(mock_controller):
    """After 3 failed attempts, circuit breaker must trip and block subsequent executions."""
    # First execution fails all 3 retries
    res1 = mock_controller.execute(
        target_name="flapping_service",
        precondition_fn=lambda: True,
        remediation_fn=lambda: True,
        verification_fn=lambda: False,  # Keeps failing verification
    )

    assert res1.success is False
    assert res1.status == "RETRY_EXCEEDED"
    assert res1.attempts == 3
    assert mock_controller.is_circuit_open("flapping_service") is True

    # Immediate second call should be blocked by circuit breaker
    res2 = mock_controller.execute(
        target_name="flapping_service",
        precondition_fn=lambda: True,
        remediation_fn=lambda: True,
        verification_fn=lambda: False,
    )

    assert res2.success is False
    assert res2.status == "CIRCUIT_OPEN"
    assert "Circuit breaker tripped" in res2.message


def test_remediation_executes_rollback_on_failure(mock_controller):
    """When retries exhaust, registered rollback callback must execute."""
    rollback_called = []

    def mock_rollback():
        rollback_called.append(True)
        return True

    res = mock_controller.execute(
        target_name="broken_service",
        precondition_fn=lambda: True,
        remediation_fn=lambda: False,
        verification_fn=lambda: False,
        rollback_fn=mock_rollback,
    )

    assert res.success is False
    assert res.rollback_executed is True
    assert len(rollback_called) == 1


def test_remediation_human_approval_gate(mock_controller, monkeypatch):
    """High-risk action must block unless SRE_REMEDIATION_APPROVED=1 is provided."""
    monkeypatch.delenv("SRE_REMEDIATION_APPROVED", raising=False)

    res = mock_controller.execute(
        target_name="risky_action",
        precondition_fn=lambda: True,
        remediation_fn=lambda: True,
        verification_fn=lambda: False,
        requires_human_approval=True,
    )

    assert res.success is False
    assert res.status == "APPROVAL_REQUIRED"

    # Now grant approval
    monkeypatch.setenv("SRE_REMEDIATION_APPROVED", "1")
    res_approved = mock_controller.execute(
        target_name="risky_action",
        precondition_fn=lambda: True,
        remediation_fn=lambda: True,
        verification_fn=lambda: True,
        requires_human_approval=True,
    )
    assert res_approved.success is True


def test_remediation_writes_audit_log(mock_controller):
    """Ensure structured audit logging occurs during remediation."""
    mock_controller.execute(
        target_name="audited_service",
        precondition_fn=lambda: True,
        remediation_fn=lambda: True,
        verification_fn=lambda: True,
    )

    assert os.path.exists(mock_controller.audit_file)
    with open(mock_controller.audit_file, "r", encoding="utf-8") as f:
        lines = [json.loads(line) for line in f]

    actions = [entry["action"] for entry in lines]
    assert "REMEDIATION_TRIGGERED" in actions
    assert "IDEMPOTENT_NOOP" in actions or "REMEDIATION_SUCCESS" in actions
