"""
Unit Tests for Mock Alert Receiver
Project: Linux System Monitoring & Reliability Lab
Tests: AlertStore record/retrieve/clear, HTTP request dispatching, payload validation.
"""

import json
import threading
import urllib.request
import urllib.error
import pytest
from http.server import HTTPServer
from scripts.reliability.mock_alert_receiver import AlertStore, make_handler


def test_alert_store_in_memory():
    store = AlertStore()
    assert store.get_all() == []

    payload = {
        "status": "firing",
        "receiver": "default-webhook",
        "alerts": [
            {
                "status": "firing",
                "labels": {"alertname": "TestAlert", "severity": "warning", "instance": "test:9090"},
                "annotations": {"summary": "Test alert summary"},
            }
        ],
    }
    store.record("/api/alerts", payload)
    events = store.get_all()
    assert len(events) == 1
    assert events[0]["endpoint"] == "/api/alerts"
    assert events[0]["payload"]["status"] == "firing"

    store.clear()
    assert store.get_all() == []


def test_alert_store_persistence(tmp_path):
    log_file = tmp_path / "alerts.jsonl"
    store = AlertStore(log_file=str(log_file))

    payload = {"status": "resolved", "alerts": []}
    store.record("/api/alerts", payload)

    assert log_file.exists()
    lines = log_file.read_text(encoding="utf-8").strip().splitlines()
    assert len(lines) == 1
    data = json.loads(lines[0])
    assert data["endpoint"] == "/api/alerts"
    assert data["payload"]["status"] == "resolved"


@pytest.fixture(scope="module")
def mock_server():
    store = AlertStore()
    handler_class = make_handler(store)
    # Bind to ephemeral port on loopback
    server = HTTPServer(("127.0.0.1", 0), handler_class)
    host, port = server.server_address
    base_url = f"http://{host}:{port}"

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    yield base_url, store

    server.shutdown()
    server.server_close()


def test_http_healthz_endpoint(mock_server):
    base_url, _ = mock_server
    req = urllib.request.Request(f"{base_url}/healthz")
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        body = json.loads(resp.read().decode("utf-8"))
        assert body["status"] == "healthy"


def test_http_post_alerts(mock_server):
    base_url, store = mock_server
    store.clear()

    payload = {
        "version": "4",
        "status": "firing",
        "receiver": "default-webhook",
        "alerts": [
            {
                "status": "firing",
                "labels": {"alertname": "NodeDown", "severity": "critical", "instance": "node-01:9100"},
            }
        ],
    }

    req = urllib.request.Request(
        f"{base_url}/api/alerts",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        res = json.loads(resp.read().decode("utf-8"))
        assert res["status"] == "received"
        assert res["alerts_processed"] == 1

    # Verify via GET
    get_req = urllib.request.Request(f"{base_url}/api/alerts")
    with urllib.request.urlopen(get_req) as resp:
        assert resp.status == 200
        data = json.loads(resp.read().decode("utf-8"))
        assert data["total_received"] == 1
        assert data["events"][0]["payload"]["receiver"] == "default-webhook"


def test_http_post_invalid_json(mock_server):
    base_url, _ = mock_server
    req = urllib.request.Request(
        f"{base_url}/api/alerts",
        data=b"not-a-valid-json",
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(req)
    assert exc_info.value.code == 400
