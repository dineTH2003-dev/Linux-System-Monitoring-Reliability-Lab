# Multi-Host Linux Monitoring Guide

This guide explains how to monitor multiple separate Linux machines using the centralized Linux System Monitoring & Reliability Lab platform.

---

## 1. Multi-Host Architecture Overview

```
+----------------------------------------------------------------------------------------------------+
|                                     CENTRAL OBSERVABILITY SERVER                                   |
|                                                                                                    |
|  +--------------------+        +--------------------+        +----------------------------------+  |
|  |   Grafana (:3001)  |        | Alertmanager(:9094)|        |      Grafana Loki (:3100)        |  |
|  | $instance Dropdown |        | Routing by instance|        | Streams: {host="node-01|02"}     |  |
|  +---------^----------+        +---------^----------+        +-----------------^----------------+  |
|            |                             |                                     |                   |
|  +---------+-----------------------------+----------+                          | (HTTP Push)       |
|  |                  Prometheus (:9090)              |                          |                   |
|  | Scrapes via File-SD: prometheus/targets/*.json   |                          |                   |
|  +---------^-----------------------------^----------+                          |                   |
+------------|-----------------------------|-------------------------------------|-------------------+
             |                             |                                     |
   (Scrape: :9100, :9101)        (Scrape: :9100, :9101)                          |
             |                             |                                     |
+------------+-------------+ +-------------+-------------------------------------+-------------------+
|     HOST 1 (Local Host)  | |                    HOST 2 (Remote Linux Machine)                      |
| - Node Exporter (:9100)  | | - Node Exporter (:9100)                                               |
| - Python Agent  (:9101)  | | - Python Agent  (:9101) [Optional]                                    |
| - Grafana Alloy (Push)   | | - Grafana Alloy / Forwarder (Push to Central Loki)                    |
+--------------------------+ +-----------------------------------------------------------------------+
```

### Key Principles:
- **Zero-Downtime Dynamic Target Discovery:** Prometheus uses File-Based Service Discovery (`file_sd_configs`). Adding or removing target JSON files in `prometheus/targets/` takes effect within 30 seconds without restarting Prometheus.
- **Deterministic Host Isolation:** Every host is labeled with its unique `instance` name. Grafana dashboards automatically isolate metrics per host using the `$instance` template variable (`label_values(node_uname_info, instance)`).
- **Centralized Log Streams:** Logs pushed to Loki are tagged with `host="<hostname>"`, allowing operators to isolate host logs via LogQL `{host="<hostname>"}`.

---

## 2. Quick Test: Local Multi-Host Simulation

You can verify multi-host monitoring immediately on your local machine using the included secondary and tertiary node fixtures:

```bash
# 1. Start the simulated secondary and tertiary Linux nodes (node-02, node-03)
docker compose -f docker-compose.multihost.yml up -d

# 2. Register node-02 and node-03 in Prometheus targets
./scripts/monitoring/add_remote_host.sh node-02 lab-mock-node-02 9100
./scripts/monitoring/add_remote_host.sh node-03 lab-mock-node-03 9100

# 3. Run the automated multi-host verification test (14 assertions)
bash tests/multihost/test_multihost_monitoring.sh
```

---

## 3. Adding a Real Remote Linux Machine

### Step 1: Install Exporters on the Remote Machine

On the remote Linux machine (e.g., `192.168.1.50` or `node-02.corp.internal`):

#### Option A: Native Node Exporter (Recommended)
```bash
sudo apt update && sudo apt install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
```

#### Option B: Containerized Node Exporter
```bash
docker run -d \
  --name node-exporter \
  --restart unless-stopped \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:latest \
  --path.rootfs=/host
```

Verify that the remote exporter is listening:
```bash
curl -s http://localhost:9100/metrics | head -n 10
```

---

### Step 2: Register the Remote Machine in Central Prometheus

On the **central monitoring server**, run:

```bash
./scripts/monitoring/add_remote_host.sh <hostname> <ip_or_fqdn> [node_port] [agent_port]
```

**Examples:**
```bash
# Add a remote host running Node Exporter on default port 9100:
./scripts/monitoring/add_remote_host.sh db-server-01 192.168.1.50

# Add a remote host running both Node Exporter (9100) and the Custom Python Agent (9101):
./scripts/monitoring/add_remote_host.sh app-server-01 192.168.1.51 9100 9101
```

This generates `prometheus/targets/node_<hostname>.json`. Prometheus will automatically pick up the new target within 30 seconds.

---

### Step 3: Forward Remote Logs to Central Loki (Optional)

On the remote machine, configure Grafana Alloy, Promtail, or a lightweight shipper to push logs to the central Loki endpoint:

```alloy
// Example Alloy push endpoint on remote host
loki.write "central" {
  endpoint {
    url = "http://<CENTRAL_SERVER_IP>:3100/loki/api/v1/push"
  }
}

loki.source.journal "systemd" {
  forward_to = [loki.write.central.receiver]
  labels     = {
    job  = "systemd-journal",
    host = "<REMOTE_HOSTNAME>",
  }
}
```

---

### Step 4: Verify Multi-Host Telemetry

1. **Check Prometheus Targets:**
   ```bash
   curl -s http://127.0.0.1:9091/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, instance: .labels.instance, health: .health}'
   ```

2. **Check Grafana Dashboards:**
   - Open Grafana at `http://127.0.0.1:3001` (user: `labadmin`).
   - Navigate to **01 - Linux System Overview**.
   - Open the **Host Instance** (`$instance`) dropdown at the top.
   - Both your primary host and remote hosts (`node-02`, etc.) will be listed.
   - Selecting a host filters all panels, CPU, memory, disk, and network graphs strictly to that machine.

---

## 4. Removing a Remote Host

To unregister a remote host:

```bash
./scripts/monitoring/remove_remote_host.sh <hostname>
```

**Example:**
```bash
./scripts/monitoring/remove_remote_host.sh db-server-01
```

Prometheus File-SD will automatically remove the target and stop scraping within 30 seconds.

---

## 5. Security & Network Considerations

1. **Private Networks / VPN:** In production, exporter ports (`9100`, `9101`) and Loki (`3100`) should never be exposed to the public internet. Use private subnets, WireGuard VPN, or firewall rules:
   ```bash
   # Restrict port 9100 on remote host to accept connections only from central server:
   sudo ufw allow from <CENTRAL_SERVER_IP> to any port 9100 proto tcp
   ```
2. **Mutual TLS (mTLS) or Reverse Proxy:** If metrics must traverse untrusted networks, front Node Exporter with Nginx/Caddy using Basic Auth or TLS certificates.
