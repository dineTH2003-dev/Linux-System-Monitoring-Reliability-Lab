"""Network metrics collector inspecting /proc/net/dev."""

import os
from typing import List

from agent.collector.base import BaseCollector
from agent.models import MetricFamily, MetricType


class NetworkCollector(BaseCollector):
    """Collects network throughput, packet counters, drop rates, and error statistics."""

    name: str = "network"

    def collect(self) -> List[MetricFamily]:
        families: List[MetricFamily] = []

        rx_bytes_fam = MetricFamily(
            name="linux_network_receive_bytes_total",
            type=MetricType.COUNTER,
            documentation="Total number of bytes received on network interface.",
        )
        tx_bytes_fam = MetricFamily(
            name="linux_network_transmit_bytes_total",
            type=MetricType.COUNTER,
            documentation="Total number of bytes transmitted on network interface.",
        )
        rx_packets_fam = MetricFamily(
            name="linux_network_receive_packets_total",
            type=MetricType.COUNTER,
            documentation="Total number of packets received on network interface.",
        )
        tx_packets_fam = MetricFamily(
            name="linux_network_transmit_packets_total",
            type=MetricType.COUNTER,
            documentation="Total number of packets transmitted on network interface.",
        )
        rx_errs_fam = MetricFamily(
            name="linux_network_receive_errors_total",
            type=MetricType.COUNTER,
            documentation="Total number of receive errors encountered on network interface.",
        )
        tx_errs_fam = MetricFamily(
            name="linux_network_transmit_errors_total",
            type=MetricType.COUNTER,
            documentation="Total number of transmit errors encountered on network interface.",
        )
        rx_drops_fam = MetricFamily(
            name="linux_network_receive_drops_total",
            type=MetricType.COUNTER,
            documentation="Total number of received packets dropped on network interface.",
        )
        tx_drops_fam = MetricFamily(
            name="linux_network_transmit_drops_total",
            type=MetricType.COUNTER,
            documentation="Total number of transmitted packets dropped on network interface.",
        )

        netdev_lines = self.read_lines(os.path.join(self.proc_path, "net", "dev"))
        if netdev_lines:
            for line in netdev_lines:
                if ":" not in line:
                    continue
                dev_part, stats_part = line.split(":", 1)
                device = dev_part.strip()
                stats = stats_part.split()
                if len(stats) < 16:
                    continue

                try:
                    rx_bytes = int(stats[0])
                    rx_packets = int(stats[1])
                    rx_errs = int(stats[2])
                    rx_drops = int(stats[3])

                    tx_bytes = int(stats[8])
                    tx_packets = int(stats[9])
                    tx_errs = int(stats[10])
                    tx_drops = int(stats[11])
                except ValueError:
                    continue

                labels = {"device": device}
                rx_bytes_fam.add_sample(labels=labels, value=rx_bytes)
                tx_bytes_fam.add_sample(labels=labels, value=tx_bytes)
                rx_packets_fam.add_sample(labels=labels, value=rx_packets)
                tx_packets_fam.add_sample(labels=labels, value=tx_packets)
                rx_errs_fam.add_sample(labels=labels, value=rx_errs)
                tx_errs_fam.add_sample(labels=labels, value=tx_errs)
                rx_drops_fam.add_sample(labels=labels, value=rx_drops)
                tx_drops_fam.add_sample(labels=labels, value=tx_drops)

            if rx_bytes_fam.samples:
                families.extend([
                    rx_bytes_fam, tx_bytes_fam, rx_packets_fam,
                    tx_packets_fam, rx_errs_fam, tx_errs_fam,
                    rx_drops_fam, tx_drops_fam
                ])

        return families
