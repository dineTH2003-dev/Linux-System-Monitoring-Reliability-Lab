"""Unit tests for agent main CLI entrypoint and argument parsing."""

from agent.config import AgentConfig
from agent.main import build_registry, parse_args


def test_parse_args_defaults():
    """Verify default CLI arguments."""
    args = parse_args([])
    assert args.config_path is None
    assert args.host is None
    assert args.port is None
    assert args.log_level is None
    assert args.json_logs is False
    assert args.validate_only is False


def test_parse_args_custom():
    """Verify custom CLI flag parsing."""
    args = parse_args([
        "-c", "/path/to/config.yaml",
        "--host", "127.0.0.5",
        "-p", "9105",
        "--log-level", "DEBUG",
        "--json-logs",
        "--validate-config-only",
    ])
    assert args.config_path == "/path/to/config.yaml"
    assert args.host == "127.0.0.5"
    assert args.port == 9105
    assert args.log_level == "DEBUG"
    assert args.json_logs is True
    assert args.validate_only is True


def test_build_registry_toggles():
    """Verify build_registry respects collector configuration toggles."""
    config = AgentConfig()
    config.collectors.cpu = True
    config.collectors.memory = True
    config.collectors.swap = False
    config.collectors.systemd = False

    registry = build_registry(config)
    collector_names = [c.name for c in registry._collectors]

    assert "cpu" in collector_names
    assert "memory" in collector_names
    assert "swap" not in collector_names
    assert "systemd" not in collector_names
