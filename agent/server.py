"""HTTP server and request handlers exposing Prometheus metrics and health check."""

import json
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional

from agent import __version__
from agent.config import AgentConfig
from agent.logger import setup_logger
from agent.registry import MetricRegistry


class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP Request Handler servicing /metrics and /healthz endpoints."""

    registry: MetricRegistry
    start_time: float
    logger = setup_logger("agent.server")

    def do_GET(self) -> None:
        """Handle HTTP GET requests."""
        if self.path in ("/metrics", "/metrics/"):
            self._handle_metrics()
        elif self.path in ("/healthz", "/healthz/", "/health", "/health/"):
            self._handle_healthz()
        elif self.path == "/":
            self._handle_root()
        else:
            self._send_response_body(
                status=HTTPStatus.NOT_FOUND,
                content_type="text/plain; charset=utf-8",
                body="404 Not Found\n",
            )

    def do_POST(self) -> None:
        self._handle_method_not_allowed()

    def do_PUT(self) -> None:
        self._handle_method_not_allowed()

    def do_DELETE(self) -> None:
        self._handle_method_not_allowed()

    def _handle_method_not_allowed(self) -> None:
        self._send_response_body(
            status=HTTPStatus.METHOD_NOT_ALLOWED,
            content_type="text/plain; charset=utf-8",
            body="405 Method Not Allowed\n",
        )

    def _handle_metrics(self) -> None:
        try:
            output = self.registry.format_prometheus()
            self._send_response_body(
                status=HTTPStatus.OK,
                content_type="text/plain; version=0.0.4; charset=utf-8",
                body=output,
            )
        except Exception as e:
            self.logger.error(f"Error servicing /metrics: {e}", exc_info=True)
            self._send_response_body(
                status=HTTPStatus.INTERNAL_SERVER_ERROR,
                content_type="text/plain; charset=utf-8",
                body=f"500 Internal Server Error: {e}\n",
            )

    def _handle_healthz(self) -> None:
        uptime = time.time() - self.start_time
        body_dict = {
            "status": "healthy",
            "version": __version__,
            "uptime_seconds": round(uptime, 2),
        }
        self._send_response_body(
            status=HTTPStatus.OK,
            content_type="application/json; charset=utf-8",
            body=json.dumps(body_dict, indent=2) + "\n",
        )

    def _handle_root(self) -> None:
        body = (
            "<html><head><title>Linux System Monitoring Agent</title></head>"
            "<body><h1>Linux System Monitoring Agent</h1>"
            "<p><a href=\"/metrics\">Metrics</a></p>"
            "<p><a href=\"/healthz\">Health</a></p>"
            "</body></html>\n"
        )
        self._send_response_body(
            status=HTTPStatus.OK,
            content_type="text/html; charset=utf-8",
            body=body,
        )

    def _send_response_body(self, status: HTTPStatus, content_type: str, body: str) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args) -> None:
        """Forward access logs to structured logger."""
        self.logger.debug("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), format % args))


class MonitoringServer:
    """Encapsulates the HTTP server and its lifecycle."""

    def __init__(self, config: AgentConfig, registry: MetricRegistry) -> None:
        self.config = config
        self.registry = registry
        self.logger = setup_logger("agent.server", level=config.logging.level, json_format=config.logging.json_format)
        self._httpd: Optional[ThreadingHTTPServer] = None
        self.start_time = time.time()

    def start(self) -> None:
        """Start listening for incoming scrape requests."""
        # Attach registry and start_time to handler class
        MetricsHandler.registry = self.registry
        MetricsHandler.start_time = self.start_time
        MetricsHandler.logger = self.logger

        server_address = (self.config.server.host, self.config.server.port)
        ThreadingHTTPServer.allow_reuse_address = True
        self._httpd = ThreadingHTTPServer(server_address, MetricsHandler)
        url = f"http://{self.config.server.host}:{self.config.server.port}/metrics"
        self.logger.info(f"Monitoring Agent listening on {url}")
        try:
            self._httpd.serve_forever()
        except KeyboardInterrupt:
            self.stop()

    def stop(self) -> None:
        """Gracefully stop the HTTP server."""
        if self._httpd:
            self.logger.info("Initiating graceful shutdown of Monitoring Agent...")
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
            self.logger.info("Monitoring Agent stopped successfully.")
