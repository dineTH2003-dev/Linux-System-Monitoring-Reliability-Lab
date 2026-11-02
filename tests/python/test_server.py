"""Unit tests for HTTP Server, endpoints, and graceful shutdown."""

import json
import socket
import threading
import time
import urllib.request
import urllib.error
import pytest

from agent.config import AgentConfig, ServerConfig
from agent.models import MetricFamily, MetricType
from agent.registry import MetricRegistry
from agent.server import MonitoringServer


def find_free_port() -> int:
    """Locate an available ephemeral TCP port on localhost."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def running_server():
    """Spin up an active test server on an ephemeral port."""
    port = find_free_port()
    config = AgentConfig(
        server=ServerConfig(host="127.0.0.1", port=port),
    )
    registry = MetricRegistry()
    fam = MetricFamily(
        name="test_metric_total",
        type=MetricType.COUNTER,
        documentation="Sample test metric.",
    )
    fam.add_sample(labels={"env": "test"}, value=42.0)

    class DummyCollector:
        name = "dummy"

        def collect(self):
            return [fam]

    registry.register(DummyCollector())
    server = MonitoringServer(config, registry)

    server_thread = threading.Thread(target=server.start, daemon=True)
    server_thread.start()
    time.sleep(0.2)  # Allow socket to bind

    base_url = f"http://127.0.0.1:{port}"
    yield base_url, server

    server.stop()
    server_thread.join(timeout=2.0)


def test_metrics_endpoint(running_server):
    """Verify GET /metrics returns standard Prometheus text exposition."""
    base_url, _ = running_server
    req = urllib.request.Request(f"{base_url}/metrics")
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        content_type = resp.headers.get("Content-Type")
        assert "text/plain" in content_type
        assert "version=0.0.4" in content_type
        body = resp.read().decode("utf-8")
        assert "# HELP test_metric_total Sample test metric." in body
        assert "# TYPE test_metric_total counter" in body
        assert 'test_metric_total{env="test"} 42.0' in body
        assert "linux_agent_collector_success{collector=\"dummy\"} 1.0" in body


def test_healthz_endpoint(running_server):
    """Verify GET /healthz returns valid JSON with healthy status."""
    base_url, _ = running_server
    req = urllib.request.Request(f"{base_url}/healthz")
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        content_type = resp.headers.get("Content-Type")
        assert "application/json" in content_type
        data = json.loads(resp.read().decode("utf-8"))
        assert data["status"] == "healthy"
        assert "version" in data
        assert "uptime_seconds" in data


def test_root_endpoint(running_server):
    """Verify GET / returns navigation landing page."""
    base_url, _ = running_server
    with urllib.request.urlopen(f"{base_url}/") as resp:
        assert resp.status == 200
        assert "text/html" in resp.headers.get("Content-Type")


def test_not_found_endpoint(running_server):
    """Verify GET on unhandled path returns 404."""
    base_url, _ = running_server
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(f"{base_url}/nonexistent")
    assert exc_info.value.code == 404


def test_method_not_allowed(running_server):
    """Verify POST returns 405 Method Not Allowed."""
    base_url, _ = running_server
    req = urllib.request.Request(f"{base_url}/metrics", data=b"data", method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(req)
    assert exc_info.value.code == 405
