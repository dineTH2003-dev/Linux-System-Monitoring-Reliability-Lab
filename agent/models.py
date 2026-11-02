"""Data models for metrics, samples, and families."""

from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, List, Optional


class MetricType(str, Enum):
    """Prometheus metric types."""

    GAUGE = "gauge"
    COUNTER = "counter"


@dataclass(frozen=True)
class MetricSample:
    """A single metric sample with labels and value."""

    name: str
    labels: Dict[str, str] = field(default_factory=dict)
    value: float = 0.0
    timestamp: Optional[float] = None


@dataclass
class MetricFamily:
    """A group of samples sharing the same metric name, type, and help text."""

    name: str
    type: MetricType
    documentation: str
    samples: List[MetricSample] = field(default_factory=list)

    def add_sample(
        self,
        name: Optional[str] = None,
        labels: Optional[Dict[str, str]] = None,
        value: float = 0.0,
        timestamp: Optional[float] = None,
    ) -> None:
        """Add a metric sample to this family."""
        sample_name = name or self.name
        self.samples.append(
            MetricSample(
                name=sample_name,
                labels=labels or {},
                value=float(value),
                timestamp=timestamp,
            )
        )
