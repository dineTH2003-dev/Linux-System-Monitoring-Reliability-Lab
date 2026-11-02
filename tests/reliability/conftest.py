"""Fixtures and mock environments for reliability testing."""

import os
import shutil
import tempfile
import pytest

from scripts.reliability.remediation.controller import RemediationController


@pytest.fixture
def temp_sandbox_dir():
    """Create a temporary sandbox directory that is guaranteed safe and non-root."""
    temp_dir = tempfile.mkdtemp(prefix="lab_reliability_test_")
    yield temp_dir
    if os.path.exists(temp_dir):
        shutil.rmtree(temp_dir, ignore_errors=True)


@pytest.fixture
def mock_controller(temp_sandbox_dir):
    """Instantiate a RemediationController with temporary state and audit files."""
    state_file = os.path.join(temp_sandbox_dir, "controller_state.json")
    audit_file = os.path.join(temp_sandbox_dir, "remediation_audit.log")
    return RemediationController(state_file=state_file, audit_file=audit_file)
