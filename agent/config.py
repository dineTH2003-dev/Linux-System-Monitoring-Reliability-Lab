"""Agent configuration schema, loader, and validation."""

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

import yaml


class ConfigError(Exception):
    """Raised when configuration validation fails."""
    pass


@dataclass
class ServerConfig:
    host: str = "127.0.0.1"
    port: int = 9101
    timeout: float = 30.0

    def validate(self) -> None:
        if not self.host or not isinstance(self.host, str):
            raise ConfigError(f"Invalid host: '{self.host}'. Must be a non-empty string.")
        if not isinstance(self.port, int) or not (1 <= self.port <= 65535):
            raise ConfigError(f"Invalid port: {self.port}. Must be an integer between 1 and 65535.")
        if not isinstance(self.timeout, (int, float)) or self.timeout <= 0:
            raise ConfigError(f"Invalid timeout: {self.timeout}. Must be a positive number.")


@dataclass
class CollectorsConfig:
    cpu: bool = True
    memory: bool = True
    swap: bool = True
    filesystem: bool = True
    inode: bool = True
    disk_io: bool = True
    network: bool = True
    process: bool = True
    systemd: bool = True

    def validate(self) -> None:
        for attr in ("cpu", "memory", "swap", "filesystem", "inode",
                     "disk_io", "network", "process", "systemd"):
            val = getattr(self, attr)
            if not isinstance(val, bool):
                raise ConfigError(f"Collector toggle '{attr}' must be a boolean, got {type(val)}.")


@dataclass
class FilesystemFilterConfig:
    exclude_fstypes: List[str] = field(
        default_factory=lambda: [
            "autofs", "binfmt_misc", "bpf", "cgroup", "cgroup2", "configfs",
            "debugfs", "devpts", "devtmpfs", "fusectl", "hugetlbfs", "mqueue",
            "nsfs", "overlay", "proc", "pstore", "ramfs", "securityfs",
            "squashfs", "sysfs", "tmpfs", "tracefs"
        ]
    )
    exclude_mountpoints: List[str] = field(
        default_factory=lambda: [
            r"^/(dev|proc|sys|run|snap)($|/)"
        ]
    )

    def validate(self) -> None:
        if not isinstance(self.exclude_fstypes, list):
            raise ConfigError("exclude_fstypes must be a list of strings.")
        if not isinstance(self.exclude_mountpoints, list):
            raise ConfigError("exclude_mountpoints must be a list of regex strings.")


@dataclass
class DiskFilterConfig:
    exclude_devices: List[str] = field(
        default_factory=lambda: [
            r"^loop[0-9]+",
            r"^ram[0-9]+"
        ]
    )

    def validate(self) -> None:
        if not isinstance(self.exclude_devices, list):
            raise ConfigError("exclude_devices must be a list of regex strings.")


@dataclass
class ProcessFilterConfig:
    max_processes: int = 500
    top_n_cpu: int = 5
    top_n_mem: int = 5
    sanitize_names: bool = True

    def validate(self) -> None:
        if not isinstance(self.max_processes, int) or self.max_processes <= 0:
            raise ConfigError(f"max_processes must be positive integer, got {self.max_processes}.")
        if not isinstance(self.top_n_cpu, int) or self.top_n_cpu < 0:
            raise ConfigError(f"top_n_cpu must be non-negative integer, got {self.top_n_cpu}.")
        if not isinstance(self.top_n_mem, int) or self.top_n_mem < 0:
            raise ConfigError(f"top_n_mem must be non-negative integer, got {self.top_n_mem}.")


@dataclass
class SystemdConfig:
    monitored_units: List[str] = field(
        default_factory=lambda: [
            "ssh.service",
            "systemd-journald.service",
            "cron.service",
            "prometheus.service",
            "prometheus-node-exporter.service"
        ]
    )
    timeout_seconds: float = 2.0

    def validate(self) -> None:
        if not isinstance(self.monitored_units, list):
            raise ConfigError("monitored_units must be a list of unit names.")
        if not isinstance(self.timeout_seconds, (int, float)) or self.timeout_seconds <= 0:
            raise ConfigError(f"timeout_seconds must be positive number, got {self.timeout_seconds}.")


@dataclass
class LoggingConfig:
    level: str = "INFO"
    json_format: bool = False

    def validate(self) -> None:
        valid_levels = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
        if not isinstance(self.level, str) or self.level.upper() not in valid_levels:
            raise ConfigError(f"Invalid log level '{self.level}'. Must be one of {valid_levels}.")
        if not isinstance(self.json_format, bool):
            raise ConfigError(f"json_format must be boolean, got {type(self.json_format)}.")


@dataclass
class AgentConfig:
    server: ServerConfig = field(default_factory=ServerConfig)
    collectors: CollectorsConfig = field(default_factory=CollectorsConfig)
    filesystem_filter: FilesystemFilterConfig = field(default_factory=FilesystemFilterConfig)
    disk_filter: DiskFilterConfig = field(default_factory=DiskFilterConfig)
    process_filter: ProcessFilterConfig = field(default_factory=ProcessFilterConfig)
    systemd: SystemdConfig = field(default_factory=SystemdConfig)
    logging: LoggingConfig = field(default_factory=LoggingConfig)

    def validate(self) -> None:
        self.server.validate()
        self.collectors.validate()
        self.filesystem_filter.validate()
        self.disk_filter.validate()
        self.process_filter.validate()
        self.systemd.validate()
        self.logging.validate()


def load_config(config_path: Optional[str] = None) -> AgentConfig:
    """Load configuration from a YAML file or return defaults."""
    config = AgentConfig()
    if not config_path:
        default_path = Path(__file__).parent / "config.yaml"
        if default_path.exists():
            config_path = str(default_path)

    if config_path and os.path.exists(config_path):
        with open(config_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}

        if not isinstance(data, dict):
            raise ConfigError(f"Configuration file at '{config_path}' must be a YAML mapping.")

        if "server" in data and isinstance(data["server"], dict):
            s = data["server"]
            config.server = ServerConfig(
                host=s.get("host", config.server.host),
                port=int(s.get("port", config.server.port)),
                timeout=float(s.get("timeout", config.server.timeout)),
            )

        if "collectors" in data and isinstance(data["collectors"], dict):
            c = data["collectors"]
            config.collectors = CollectorsConfig(
                cpu=bool(c.get("cpu", config.collectors.cpu)),
                memory=bool(c.get("memory", config.collectors.memory)),
                swap=bool(c.get("swap", config.collectors.swap)),
                filesystem=bool(c.get("filesystem", config.collectors.filesystem)),
                inode=bool(c.get("inode", config.collectors.inode)),
                disk_io=bool(c.get("disk_io", config.collectors.disk_io)),
                network=bool(c.get("network", config.collectors.network)),
                process=bool(c.get("process", config.collectors.process)),
                systemd=bool(c.get("systemd", config.collectors.systemd)),
            )

        if "filesystem_filter" in data and isinstance(data["filesystem_filter"], dict):
            ff = data["filesystem_filter"]
            config.filesystem_filter = FilesystemFilterConfig(
                exclude_fstypes=list(ff.get("exclude_fstypes", config.filesystem_filter.exclude_fstypes)),
                exclude_mountpoints=list(ff.get("exclude_mountpoints", config.filesystem_filter.exclude_mountpoints)),
            )

        if "disk_filter" in data and isinstance(data["disk_filter"], dict):
            df = data["disk_filter"]
            config.disk_filter = DiskFilterConfig(
                exclude_devices=list(df.get("exclude_devices", config.disk_filter.exclude_devices)),
            )

        if "process_filter" in data and isinstance(data["process_filter"], dict):
            pf = data["process_filter"]
            config.process_filter = ProcessFilterConfig(
                max_processes=int(pf.get("max_processes", config.process_filter.max_processes)),
                top_n_cpu=int(pf.get("top_n_cpu", config.process_filter.top_n_cpu)),
                top_n_mem=int(pf.get("top_n_mem", config.process_filter.top_n_mem)),
                sanitize_names=bool(pf.get("sanitize_names", config.process_filter.sanitize_names)),
            )

        if "systemd" in data and isinstance(data["systemd"], dict):
            sd = data["systemd"]
            config.systemd = SystemdConfig(
                monitored_units=list(sd.get("monitored_units", config.systemd.monitored_units)),
                timeout_seconds=float(sd.get("timeout_seconds", config.systemd.timeout_seconds)),
            )

        if "logging" in data and isinstance(data["logging"], dict):
            lg = data["logging"]
            config.logging = LoggingConfig(
                level=str(lg.get("level", config.logging.level)),
                json_format=bool(lg.get("json_format", config.logging.json_format)),
            )

    config.validate()
    return config
