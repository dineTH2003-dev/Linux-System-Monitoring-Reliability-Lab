"""Main entrypoint for the Linux System Monitoring Agent."""

import argparse
import signal
import sys
from typing import Optional

from agent.collector import (
    CPUCollector,
    DiskIOCollector,
    FilesystemCollector,
    InodeCollector,
    MemoryCollector,
    NetworkCollector,
    ProcessCollector,
    SwapCollector,
    SystemdCollector,
)
from agent.config import AgentConfig, ConfigError, load_config
from agent.logger import setup_logger
from agent.registry import MetricRegistry
from agent.server import MonitoringServer


def parse_args(args: Optional[list] = None) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Linux System Monitoring Agent for Prometheus metrics exposition."
    )
    parser.add_argument(
        "-c", "--config",
        dest="config_path",
        default=None,
        help="Path to YAML configuration file.",
    )
    parser.add_argument(
        "--host",
        dest="host",
        default=None,
        help="Override server listen host address.",
    )
    parser.add_argument(
        "-p", "--port",
        dest="port",
        type=int,
        default=None,
        help="Override server listen port (default: 9101).",
    )
    parser.add_argument(
        "--log-level",
        dest="log_level",
        default=None,
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Override log level.",
    )
    parser.add_argument(
        "--json-logs",
        dest="json_logs",
        action="store_true",
        default=False,
        help="Emit structured single-line JSON logs.",
    )
    parser.add_argument(
        "--validate-config-only",
        dest="validate_only",
        action="store_true",
        default=False,
        help="Validate configuration and exit.",
    )
    return parser.parse_args(args)


def build_registry(config: AgentConfig) -> MetricRegistry:
    """Instantiate and register collectors according to configuration flags."""
    registry = MetricRegistry()

    if config.collectors.cpu:
        registry.register(CPUCollector())
    if config.collectors.memory:
        registry.register(MemoryCollector())
    if config.collectors.swap:
        registry.register(SwapCollector())
    if config.collectors.filesystem:
        registry.register(FilesystemCollector(filter_config=config.filesystem_filter))
    if config.collectors.inode:
        registry.register(InodeCollector(filter_config=config.filesystem_filter))
    if config.collectors.disk_io:
        registry.register(DiskIOCollector(filter_config=config.disk_filter))
    if config.collectors.network:
        registry.register(NetworkCollector())
    if config.collectors.process:
        registry.register(ProcessCollector(filter_config=config.process_filter))
    if config.collectors.systemd:
        registry.register(SystemdCollector(config=config.systemd))

    return registry


def main() -> None:
    """Run the monitoring agent service."""
    args = parse_args()

    try:
        config = load_config(args.config_path)
    except ConfigError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)

    # CLI Overrides
    if args.host:
        config.server.host = args.host
    if args.port is not None:
        config.server.port = args.port
    if args.log_level:
        config.logging.level = args.log_level
    if args.json_logs:
        config.logging.json_format = True

    try:
        config.validate()
    except ConfigError as e:
        print(f"Configuration validation error: {e}", file=sys.stderr)
        sys.exit(1)

    logger = setup_logger(
        "agent",
        level=config.logging.level,
        json_format=config.logging.json_format,
    )

    if args.validate_only:
        logger.info("Configuration is valid.")
        sys.exit(0)

    logger.info("Initializing Linux System Monitoring Agent...")
    registry = build_registry(config)
    server = MonitoringServer(config, registry)

    # Setup signal handlers
    def signal_handler(sig, frame):
        logger.info(f"Received signal {signal.Signals(sig).name}. Stopping agent...")
        server.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        server.start()
    except Exception as e:
        logger.critical(f"Fatal error starting server: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
