# Troubleshooting Runbook: Host Network Packet Drops & CRC/FIFO Errors

## 1. Alert Overview
- **Associated Alerts:** `HostNetworkDropsHigh`, `HostNetworkErrorsDetected`
- **PromQL Triggers:**
  - `sum by (device) (rate(node_network_receive_drop_total[5m]) + rate(node_network_transmit_drop_total[5m])) > 10` (Drops > 10/s for 5m)
  - `sum by (device) (rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m])) > 0` (Errors > 0 for 2m)
- **Severity:** Warning
- **SLO Impact:** Packet loss leads to TCP retransmissions, socket timeouts, and degraded service communication.

---

## 2. Immediate Triage & Diagnostics
1. **Check Interface Statistics via ip & ethtool:**
   ```bash
   ip -s link
   bash scripts/monitoring/monitor_network.sh
   ```
2. **Check Socket Buffer Sizes and Drops:**
   ```bash
   netstat -s | grep -iE "(drop|error|overflow|retransmit)"
   ```

---

## 3. Resolution Procedures
1. **Verify Physical / Virtual Interface State:**
   ```bash
   ip link show <interface>
   ```
2. **Increase Socket Backlog / Ring Buffers (if buffer overruns occur):**
   ```bash
   sysctl -w net.core.netdev_max_backlog=5000
   sysctl -w net.core.rmem_max=16777216
   ```

---

## 4. Recovery Verification
- Confirm `rate(node_network_receive_errs_total[5m])` returns to 0.
