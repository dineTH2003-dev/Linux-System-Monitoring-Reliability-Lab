#!/usr/bin/env python3
"""
Standalone Mock Alert Receiver
Project: Linux System Monitoring & Reliability Lab
Purpose: Safe local HTTP webhook sink for Alertmanager webhook notifications on port 5002.
         Prevents alert notification delivery errors during local development and testing
         without requiring live Slack or PagerDuty credentials.
"""

import argparse
import json
import logging
import os
import signal
import sys
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import List, Dict, Any, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [mock-alert-receiver] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("mock_alert_receiver")


class AlertStore:
    """Thread-safe in-memory alert event buffer with optional persistence."""

    def __init__(self, log_file: Optional[str] = None):
        self.received_events: List[Dict[str, Any]] = []
        self.log_file = log_file
        if self.log_file:
            os.makedirs(os.path.dirname(os.path.abspath(self.log_file)), exist_ok=True)

    def record(self, endpoint: str, payload: Dict[str, Any]) -> None:
        record = {
            "received_at": datetime.now(timezone.utc).isoformat(),
            "endpoint": endpoint,
            "payload": payload,
        }
        self.received_events.append(record)

        # Log summary of alerts
        alerts = payload.get("alerts", [])
        status = payload.get("status", "unknown")
        receiver = payload.get("receiver", "unknown")
        logger.info(
            "Webhook received on '%s' from receiver '%s': status=%s, count=%d",
            endpoint,
            receiver,
            status,
            len(alerts),
        )

        for alert in alerts:
            alertname = alert.get("labels", {}).get("alertname", "unknown")
            severity = alert.get("labels", {}).get("severity", "unknown")
            instance = alert.get("labels", {}).get("instance", "unknown")
            logger.info("  -> Alert: %s (severity=%s, instance=%s)", alertname, severity, instance)

        if self.log_file:
            try:
                with open(self.log_file, "a", encoding="utf-8") as f:
                    f.write(json.dumps(record) + "\n")
            except OSError as e:
                logger.error("Failed to write alert record to log file: %s", e)

    def get_all(self) -> List[Dict[str, Any]]:
        return list(self.received_events)

    def clear(self) -> None:
        self.received_events.clear()


def make_handler(store: AlertStore):
    class AlertWebhookHandler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: Any) -> None:
            # Suppress default BaseHTTPRequestHandler access log to stdout
            pass

        def _send_json(self, status_code: int, data: Dict[str, Any]) -> None:
            body = json.dumps(data).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/healthz":
                self._send_json(200, {"status": "healthy", "service": "mock-alert-receiver"})
            elif self.path in ("/api/alerts", "/api/blackbox-triage"):
                self._send_json(200, {
                    "status": "success",
                    "total_received": len(store.get_all()),
                    "events": store.get_all(),
                })
            else:
                self._send_json(404, {"error": "Not Found", "path": self.path})

        def do_POST(self) -> None:
            if self.path in ("/api/alerts", "/api/blackbox-triage"):
                content_length = int(self.headers.get("Content-Length", 0))
                if content_length == 0:
                    self._send_json(400, {"error": "Empty body"})
                    return

                try:
                    raw_body = self.rfile.read(content_length)
                    payload = json.loads(raw_body.decode("utf-8"))
                except (json.JSONDecodeError, UnicodeDecodeError) as err:
                    logger.warning("Malformed JSON received on %s: %s", self.path, err)
                    self._send_json(400, {"error": "Invalid JSON", "details": str(err)})
                    return

                store.record(self.path, payload)
                self._send_json(200, {
                    "status": "received",
                    "endpoint": self.path,
                    "alerts_processed": len(payload.get("alerts", [])),
                })
            else:
                self._send_json(404, {"error": "Not Found", "path": self.path})

        def do_DELETE(self) -> None:
            if self.path in ("/api/alerts", "/api/blackbox-triage"):
                store.clear()
                self._send_json(200, {"status": "cleared"})
            else:
                self._send_json(404, {"error": "Not Found", "path": self.path})

    return AlertWebhookHandler


def run_server(host: str = "127.0.0.1", port: int = 5002, log_file: Optional[str] = None) -> None:
    store = AlertStore(log_file=log_file)
    handler_class = make_handler(store)
    server = HTTPServer((host, port), handler_class)
    logger.info("Starting Mock Alert Receiver on %s:%d", host, port)
    if log_file:
        logger.info("Logging received payloads to: %s", log_file)

    def signal_handler(sig, frame):
        logger.info("Shutdown signal received (%s). Exiting...", sig)
        server.server_close()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
        logger.info("Mock Alert Receiver stopped.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Mock Alert Receiver for Alertmanager")
    parser.add_argument("--host", default="127.0.0.1", help="Listen host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=5002, help="Listen port (default: 5002)")
    parser.add_argument("--output-file", default=None, help="Path to jsonl log file for incoming alerts")
    args = parser.parse_args()

    run_server(host=args.host, port=args.port, log_file=args.output_file)


if __name__ == "__main__":
    main()
