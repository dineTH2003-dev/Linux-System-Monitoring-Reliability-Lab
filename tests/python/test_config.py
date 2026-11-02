"""Unit tests for configuration validation and loading."""

import os
import tempfile
import pytest

from agent.config import AgentConfig, ConfigError, load_config


def test_default_config_validity():
    """Verify that default configuration passes all validation checks."""
    config = AgentConfig()
    config.validate()
    assert config.server.host == "127.0.0.1"
    assert config.server.port == 9101
    assert config.collectors.cpu is True
    assert config.logging.level == "INFO"


def test_invalid_port_out_of_range():
    """Verify that invalid ports raise ConfigError."""
    config = AgentConfig()
    config.server.port = 0
    with pytest.raises(ConfigError, match="Invalid port"):
        config.validate()

    config.server.port = 70000
    with pytest.raises(ConfigError, match="Invalid port"):
        config.validate()

    config.server.port = "not_a_number"  # type: ignore
    with pytest.raises(ConfigError, match="Invalid port"):
        config.validate()


def test_invalid_host():
    """Verify that empty host raises ConfigError."""
    config = AgentConfig()
    config.server.host = ""
    with pytest.raises(ConfigError, match="Invalid host"):
        config.validate()


def test_invalid_logging_level():
    """Verify that unknown log levels raise ConfigError."""
    config = AgentConfig()
    config.logging.level = "INVALID_LEVEL"
    with pytest.raises(ConfigError, match="Invalid log level"):
        config.validate()


def test_invalid_process_filter():
    """Verify that negative or zero process bounds raise ConfigError."""
    config = AgentConfig()
    config.process_filter.max_processes = 0
    with pytest.raises(ConfigError, match="max_processes must be positive integer"):
        config.validate()


def test_load_config_from_yaml():
    """Verify loading and overriding settings from a YAML file."""
    yaml_content = """
server:
  host: "127.0.0.2"
  port: 9200
  timeout: 15.0

collectors:
  cpu: true
  systemd: false

logging:
  level: "DEBUG"
  json_format: true
"""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(yaml_content)
        f.flush()
        temp_path = f.name

    try:
        loaded = load_config(temp_path)
        assert loaded.server.host == "127.0.0.2"
        assert loaded.server.port == 9200
        assert loaded.server.timeout == 15.0
        assert loaded.collectors.cpu is True
        assert loaded.collectors.systemd is False
        assert loaded.logging.level == "DEBUG"
        assert loaded.logging.json_format is True
    finally:
        os.unlink(temp_path)


def test_load_config_invalid_yaml():
    """Verify that non-mapping YAML raises ConfigError."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(" - item1\n - item2\n")
        f.flush()
        temp_path = f.name

    try:
        with pytest.raises(ConfigError, match="must be a YAML mapping"):
            load_config(temp_path)
    finally:
        os.unlink(temp_path)
