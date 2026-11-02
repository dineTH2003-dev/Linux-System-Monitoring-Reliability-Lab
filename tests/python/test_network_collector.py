"""Unit tests for Network telemetry collector."""

from agent.collector.network import NetworkCollector
from agent.models import MetricType


def test_network_collector_parsing(mock_proc_dir):
    """Test parsing of /proc/net/dev counters for RX/TX bytes, packets, drops, and errors."""
    collector = NetworkCollector(proc_path=mock_proc_dir)
    families = collector.collect()
    fam_dict = {f.name: f for f in families}

    assert "linux_network_receive_bytes_total" in fam_dict
    rx_bytes = fam_dict["linux_network_receive_bytes_total"]
    assert rx_bytes.type == MetricType.COUNTER

    eth0_rx_bytes = [s for s in rx_bytes.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_rx_bytes.value == 50000000

    assert "linux_network_transmit_bytes_total" in fam_dict
    tx_bytes = fam_dict["linux_network_transmit_bytes_total"]
    eth0_tx_bytes = [s for s in tx_bytes.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_tx_bytes.value == 30000000

    assert "linux_network_receive_packets_total" in fam_dict
    rx_pkts = fam_dict["linux_network_receive_packets_total"]
    eth0_rx_pkts = [s for s in rx_pkts.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_rx_pkts.value == 100000

    assert "linux_network_transmit_packets_total" in fam_dict
    tx_pkts = fam_dict["linux_network_transmit_packets_total"]
    eth0_tx_pkts = [s for s in tx_pkts.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_tx_pkts.value == 75000

    assert "linux_network_receive_errors_total" in fam_dict
    rx_errs = fam_dict["linux_network_receive_errors_total"]
    eth0_rx_errs = [s for s in rx_errs.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_rx_errs.value == 10

    assert "linux_network_transmit_errors_total" in fam_dict
    tx_errs = fam_dict["linux_network_transmit_errors_total"]
    eth0_tx_errs = [s for s in tx_errs.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_tx_errs.value == 2

    assert "linux_network_receive_drops_total" in fam_dict
    rx_drops = fam_dict["linux_network_receive_drops_total"]
    eth0_rx_drops = [s for s in rx_drops.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_rx_drops.value == 5

    assert "linux_network_transmit_drops_total" in fam_dict
    tx_drops = fam_dict["linux_network_transmit_drops_total"]
    eth0_tx_drops = [s for s in tx_drops.samples if s.labels.get("device") == "eth0"][0]
    assert eth0_tx_drops.value == 1
