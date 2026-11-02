# Linux Network Subsystem & Performance Monitoring

**Project:** Linux System Monitoring & Reliability Lab  
**Phase:** 1.3.1 — Linux Network Monitoring  
**Author:** Senior Linux Systems & Site Reliability Engineer  
**Target Environment:** Ubuntu 24.04 LTS (Kernel `7.0.0-38-generic`, Intel Core i7-1355U, `wlo1` Wi-Fi)  

---

## 1. Network Subsystem Architecture

The Linux network subsystem processes packets through a layered kernel architecture designed for high-concurrency packet dispatch, routing, and socket management.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        User Space Applications                         │
│             (Web Browsers, Prometheus, Proxies, Daemons)               │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ system calls (socket, connect, accept, read, write)
┌───────────────────────────────────▼────────────────────────────────────┐
│                       Kernel Socket Layer & VFS                        │
│                 (struct socket, struct sock, inodes)                   │
├────────────────────────────────────────────────────────────────────────┤
│                       Transport Layer (L4)                             │
│       TCP (Congestion Control, State Machine, Recv/Send Buffers)       │
│       UDP (Stateless Datagram Delivery, Socket Receive Queues)         │
├────────────────────────────────────────────────────────────────────────┤
│                        Network Layer (L3)                              │
│       IP Routing (FIB, Route Tables: Local/Main, Netfilter / iptables) │
│       Neighbor Discovery / ARP Table (struct neighbour)                │
├────────────────────────────────────────────────────────────────────────┤
│                       Link Layer / Driver (L2)                         │
│       Traffic Control / Queuing Discipline (qdisc, fq_codel, pfifo)   │
│       Network Device Driver (NAPI poll loop, sk_buff allocation)       │
├────────────────────────────────────────────────────────────────────────┤
│                        Physical Hardware (L1)                          │
│       NIC Ring Buffers (RX/TX DMA rings), PHY, Hardware Interrupts     │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Ingress Packet Processing Pipeline
1. **Hardware Ingress**: Incoming frames trigger Direct Memory Access (DMA) transfer into the Network Interface Card's (NIC) receive (RX) ring buffer.
2. **Hard IRQ**: The NIC issues a hardware interrupt to the CPU. The CPU executes the driver’s interrupt handler, which disables NIC interrupts and schedules a software interrupt via **NAPI** (New API).
3. **SoftIRQ (`NET_RX_SOFTIRQ`)**: Kernel thread `ksoftirqd` executes the driver's `poll()` method, pulling packets out of the ring buffer and packaging them into `struct sk_buff` (socket buffer) structures.
4. **qdisc / Traffic Classification**: Frames pass through bridge/VLAN parsing and netfilter prerouting hooks.
5. **L3 Routing Lookup**: The kernel inspects the destination IP against the Forwarding Information Base (FIB). If destined for the local host, packets proceed up the stack; otherwise, they are forwarded or dropped.
6. **L4 Transport Processing**: For TCP, the sequence number is validated, TCP window tracking is executed, and payloads are copied into the socket receive buffer (`sk_rcvqueues`).
7. **Application Wakeup**: The waiting thread is woken up from `epoll_wait()` or blocking `read()`.

---

## 2. Network Interfaces & Operational States

Network interfaces represent the abstraction layer bridging the Linux kernel network stack with hardware adapters (e.g., Ethernet `eth0`, Wi-Fi `wlo1`) or virtual abstractions (e.g., loopback `lo`, bridges `br0`, virtual Ethernet `veth*`).

### 2.1 Interface Inspection Commands

```bash
# Brief interface status
ip -br link
# Example Host Output:
# lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
# wlo1             UP             dc:46:28:30:a5:2a <BROADCAST,MULTICAST,UP,LOWER_UP>

# Detailed link layer attributes and queue disciplines
ip -d link show dev wlo1
```

### 2.2 Operational States Explained

| State Flag | Kernel Meaning | SRE Operational Implication |
| :--- | :--- | :--- |
| **`UP`** | The administrative state is enabled (`IFF_UP`). The administrator or network manager brought the interface up. | Administrative intent is active, but does not guarantee cable or link connection. |
| **`LOWER_UP`** | The physical link layer is operational (`IFF_LOWER_UP`). Ethernet carrier is detected or wireless association is established. | Data frames can physically traverse the medium. |
| **`UNKNOWN`** | Normal for loopback (`lo`) and certain virtual tunnels where physical carrier detection is unsupported by the driver. | Expected on `lo`; not an error. |
| **`DOWN`** | Interface is administratively disabled or has no physical carrier. | Traffic will be discarded immediately at the interface layer. |
| **`DORMANT`** | Interface is waiting for an external driver condition (e.g., 802.1X authentication handshake). | Link cannot transmit user data until authentication completes. |

> [!NOTE]
> **The `ip` vs. `ifconfig` Deprecation Context**: The `ifconfig` utility (from `net-tools`) relies on outdated `ioctl` calls that cannot inspect secondary addresses with proper prefixes, lacks support for multiple routing tables, cannot view network namespaces, and truncates interface statistics over 32 bits on older builds. Modern SRE operations exclusively mandate the `iproute2` suite (`ip link`, `ip addr`, `ip route`), which interfaces directly with the kernel via **Netlink sockets** (`NETLINK_ROUTE`).

---

## 3. IP Addressing & Subnet Architecture

Linux network interfaces can bind multiple IPv4 and IPv6 addresses across different scopes.

```bash
ip -br addr
# Example Host Output:
# lo               UNKNOWN        127.0.0.1/8 ::1/128
# wlo1             UP             10.10.3.81/19 2401:dd00:10:20:b484:34e7:7a01:3d9/64 fe80::ba8a:d0d:dc64:eec/64
```

### 3.1 Host IP Configuration Analysis
- **Loopback (`lo`)**:
  - `127.0.0.1/8`: Loopback IPv4 subnet ($127.0.0.0 - 127.255.255.255$).
  - `::1/128`: Loopback IPv6 host address.
- **Wireless Interface (`wlo1`)**:
  - **IPv4 Address**: `10.10.3.81/19`.
    - Subnet Mask: `/19` ($255.255.224.0$).
    - Usable Host Range: $10.10.0.1 - 10.10.31.254$ ($8,190\text{ usable hosts}$).
    - Broadcast Address: $10.10.31.255$.
  - **IPv6 Addresses**:
    - `fe80::ba8a:d0d:dc64:eec/64`: Link-Local address (`scope link`), valid exclusively within the local Layer 2 broadcast domain. Non-routable across routers.
    - `2401:dd00:10:20:b484:34e7:7a01:3d9/64`: Global Unicast Address (`scope global dynamic`), routable on the public internet, generated via SLAAC / DHCPv6.

---

## 4. Routing Tables, Gateways & Policy Routing

The Linux kernel maintains independent routing tables evaluated by the **Routing Policy Database (RPDB)**.

### 4.1 Routing Table Structure

```bash
# View the routing policy database rules
ip rule show
# Output:
# 0:     from all lookup local
# 32766: from all lookup main
# 32767: from all lookup default

# View the main routing table (used for unicast forwarding)
ip route show table main
# Output:
# default via 10.10.31.254 dev wlo1 proto dhcp src 10.10.3.81 metric 600
# 10.10.0.0/19 dev wlo1 proto kernel scope link src 10.10.3.81 metric 600

# View the local routing table (used for local IP loopback dispatch)
ip route show table local
# Output:
# local 10.10.3.81 dev wlo1 proto kernel scope host src 10.10.3.81
# broadcast 10.10.31.255 dev wlo1 proto kernel scope link src 10.10.3.81
# local 127.0.0.1 dev lo proto kernel scope host src 127.0.0.1
```

### 4.2 Route Fields Explained
1. **`default via 10.10.31.254`**: The default gateway next-hop router. Any packet whose destination IP does not match a more specific route is encapsulated in an L2 Ethernet frame addressed to the MAC address of `10.10.31.254`.
2. **`dev wlo1`**: Egress interface used to transmit matching packets.
3. **`proto dhcp`**: Identifies that the route was dynamically installed by the DHCP client (NetworkManager / systemd-networkd).
4. **`scope link`**: Destination network is directly reachable on the local Layer 2 broadcast domain without passing through a gateway router.
5. **`scope host`**: Destination IP is assigned to the local machine; packets are looped back internally without entering physical transmission.
6. **`metric 600`**: Route administrative preference distance. Lower metric values take precedence. Metric 600 is standard for Wi-Fi connections, whereas wired Ethernet typically uses metric 100 to prioritize faster links.

---

## 5. DNS Resolution & Service Discovery

Modern Linux distributions decouple application-level DNS queries from raw network lookups using a multi-tiered resolution stack.

```
┌────────────────────────────────────────────────────────┐
│             Application (curl, browser, python)        │
└───────────────────────────┬────────────────────────────┘
                            │ getaddrinfo() / gethostbyname()
┌───────────────────────────▼────────────────────────────┐
│                  glibc Name Service Switch             │
│                     /etc/nsswitch.conf                 │
│         (hosts: files mdns4_minimal [NOTFOUND=return] dns)
└─────────────┬───────────────────────────────┬──────────┘
              │ 1. /etc/hosts                 │ 2. DNS query
              ▼                               ▼
    ┌──────────────────┐          ┌───────────────────────┐
    │ Static Host File │          │ Local Stub Resolver   │
    │  127.0.0.1 host  │          │ systemd-resolved      │
    └──────────────────┘          │ 127.0.0.53:53         │
                                  └───────────┬───────────┘
                                              │ Forward upstream
                                  ┌───────────▼───────────┐
                                  │ Upstream DNS Servers  │
                                  │ 10.15.250.111         │
                                  │ 192.248.8.97          │
                                  └───────────────────────┘
```

### 5.1 Systemd-Resolved & The Stub Resolver
On Ubuntu 24.04, `/etc/resolv.conf` is a symlink pointing to `/run/systemd/resolve/stub-resolv.conf`, containing `nameserver 127.0.0.53`.

```bash
resolvectl status
# Example Host Output:
# Global
#          Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
#   resolv.conf mode: stub
#
# Link 2 (wlo1)
#     Current Scopes: DNS
#          Protocols: +DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
# Current DNS Server: 10.15.250.111
#        DNS Servers: 192.248.8.97 10.15.250.111
#         DNS Domain: wifi.uom.lk
```

### 5.2 Resolution Testing & Common Traps
- **`getent hosts <hostname>`**: Queries the exact glibc NSS resolution pipeline defined in `/etc/nsswitch.conf`. This mirrors how applications resolve names.
- **`resolvectl query <hostname>`**: Directly queries the `systemd-resolved` bus interface, showing the serving interface, cache hit/miss status, and latency.
- **The `nslookup` / `dig` Pitfall**: Tools like `dig @nameserver` bypass `/etc/nsswitch.conf` and `/etc/hosts`. An SRE testing with `dig` may verify that upstream DNS is working while an application fails because `/etc/hosts` contains a stale override or NSS order is broken.

---

## 6. Transport Layer: TCP & UDP Sockets

Sockets are the kernel endpoint abstractions for network communication, represented as file descriptors within the calling process.

### 6.1 Socket Inventory (`ss -s`)
```bash
ss -s
# Output:
# Total: 1638
# TCP:   100 (estab 60, closed 8, orphaned 0, timewait 6)
# Transport Total     IP        IPv6
# RAW       1         0         1
# UDP       17        10        7
# TCP       92        65        27
```

- **`orphaned`**: Sockets that are no longer attached to any user file descriptor (e.g., closed by application but kernel is flushing remaining transmission). High orphan counts indicate kernel memory pressure.
- **`timewait`**: Sockets in `TIME_WAIT` state, awaiting $2 \times \text{MSL}$ (Maximum Segment Lifetime, 60 seconds) to ensure delayed duplicate segments dissipate.

### 6.2 TCP Connection State Machine

```
              ┌──────────────┐
              │    CLOSED    │
              └──────┬───────┘
                     │ connect() / SYN
                     ▼
              ┌──────────────┐
              │   SYN_SENT   │
              └──────┬───────┘
                     │ RCVD SYN+ACK / ACK
                     ▼
              ┌──────────────┐
              │ ESTABLISHED  │ ◄── Normal Data Exchange
              └──────┬───────┘
                     │ close() / FIN
                     ▼
              ┌──────────────┐
              │  FIN_WAIT_1  │
              └──────┬───────┘
                     │ RCVD ACK
                     ▼
              ┌──────────────┐
              │  FIN_WAIT_2  │
              └──────┬───────┘
                     │ RCVD FIN / ACK
                     ▼
              ┌──────────────┐
              │  TIME_WAIT   │ (60s timer prevents stale segment contamination)
              └──────┬───────┘
                     │ Timeout
                     ▼
              ┌──────────────┐
              │    CLOSED    │
              └──────────────┘
```

### 6.3 State Breakdown & SRE Troubleshooting

| TCP State | Trigger / Meaning | SRE Troubleshooting Context |
| :--- | :--- | :--- |
| **`LISTEN`** | Server process called `listen()` and is awaiting client connections. | Verified with `ss -tuln`. Ensure port is bound to correct IP (`127.0.0.1` vs `0.0.0.0`). |
| **`SYN_SENT`** | Client sent TCP SYN packet and is awaiting SYN-ACK from server. | If persistent, indicates network firewall dropping SYN, routing failure, or server offline. |
| **`ESTABLISHED`**| 3-way handshake completed. Sockets actively transferring or idling. | High counts require connection pooling, keepalive tuning, or worker scaling. |
| **`CLOSE_WAIT`** | Remote endpoint closed connection (sent FIN); local kernel acknowledged. Local process has **not** closed its socket. | **Application Bug**: File descriptor leak. The application failed to call `close()` on the socket. |
| **`TIME_WAIT`** | Local endpoint initiated active close. Socket remains reserved for $2 \times \text{MSL}$ (60s). | Normal in high volume; can exhaust ephemeral port range ($32768 - 60999$) if pooling is missing. |

---

## 7. Socket Queue Monitoring (`ss` Deep Dive)

One of the most common operational errors in Linux systems engineering is misunderstanding the `Recv-Q` and `Send-Q` columns in `ss` output. **Their meaning completely inverts between listening sockets and established sockets.**

```bash
ss -tuln
# Listening Sockets Example:
# Netid  State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port
# tcp    LISTEN  0       4096     127.0.0.1:9090       0.0.0.0:*
# tcp    LISTEN  0       50               *:8080               *:*
```

### 7.1 Semantics on Listening Sockets (`State == LISTEN`)
- **`Send-Q`**: The **Maximum Backlog Queue Size**. This is the limit set by the application's `listen(sockfd, backlog)` system call, clamped by the kernel parameter `/proc/sys/net/core/somaxconn` (default 4096 on Ubuntu 24.04).
- **`Recv-Q`**: The **Current Number of Pending Connections**. These are connections that have completed the 3-way TCP handshake and are sitting in the accept queue waiting for the application thread to call `accept()`.

> [!CAUTION]
> **Saturation Indicator**: If `Recv-Q > 0` and approaches `Send-Q` on a listening socket, the application server is **CPU-bound, thread-starved, or blocked on I/O**, and cannot accept incoming connections fast enough. When `Recv-Q > Send-Q`, the kernel drops new incoming SYN packets or sends resets according to `/proc/sys/net/ipv4/tcp_abort_on_overflow`.

### 7.2 Semantics on Established Sockets (`State == ESTABLISHED`)
- **`Recv-Q`**: Number of bytes received from the network and held in the kernel socket receive buffer, waiting for the application process to invoke `read()` / `recv()`. Non-zero values indicate the application is slow in reading data.
- **`Send-Q`**: Number of bytes buffered in the kernel socket transmit buffer that have been sent but not yet acknowledged (ACKed) by the remote peer, or queued waiting to be transmitted. Elevated values indicate network bottleneck, high latency, packet loss, or unacknowledged TCP windows.

### 7.3 Empirical Host Investigation: Real CLOSE-WAIT Sockets
Inspecting the monitored host revealed active sockets in `CLOSE-WAIT` state:

```bash
ss -tan state CLOSE-WAIT
# Output:
# Recv-Q  Send-Q  Local Address:Port       Peer Address:Port
# 64      0       10.10.3.81:35498         35.95.213.228:443
# 40      0       [2401:...]:46044         [2606:...]:443
```
- **SRE Analysis**: Notice `Recv-Q = 64` and `40`. The remote cloud endpoints sent data followed by a FIN to terminate the connection. The kernel acknowledged the FIN and queued the remaining 64 bytes. The local client process has stalled or abandoned the socket without reading the final bytes or calling `close()`. If left unmitigated in microservices, this pattern causes file descriptor exhaustion (`EMFILE`).

---

## 8. Network Throughput, Packet Drops & Error Accounting

The primary kernel interface for hardware and link-layer statistics is `/proc/net/dev`.

### 8.1 Anatomy of `/proc/net/dev`
```bash
cat /proc/net/dev
# Output:
# Inter-|   Receive                                                |  Transmit
#  face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
#     lo: 16577174805 8211290    0    0    0     0          0         0 16577174805 8211290    0    0    0     0       0          0
#   wlo1: 7505996525 7804476    0   41    0     0          0         0 4493996786 2659382    0  287    0     0       0          0
```

### 8.2 Field Definitions & Root Causes

| Column | Direction | Root Cause / SRE Metric Interpretation |
| :--- | :--- | :--- |
| **`bytes`** | RX / TX | Cumulative byte counter since interface initialization or boot. Used to compute differential bandwidth: $(\Delta\text{bytes} \times 8) / \Delta t = \text{bps}$. |
| **`packets`** | RX / TX | Total packet count. Average packet size $= \Delta\text{bytes} / \Delta\text{packets}$. |
| **`errs`** | RX / TX | Framing errors, CRC checksum mismatches, physical layer corruption. On wired links, non-zero values indicate faulty cables, bad SFP modules, or duplex mismatches. |
| **`drop`** | RX | Packet dropped due to lack of buffer memory in the ring buffer (`rx_dropped`) or CPU softnet backlog overflow (`/proc/net/softnet_stat`). |
| **`drop`** | TX | Packets dropped due to transmission queue saturation (`txqueuelen`), traffic shaping limits, or Wi-Fi contention drops. |
| **`fifo`** | RX / TX | FIFO buffer overrun in the hardware queue. |
| **`carrier`** | TX | Carrier loss events; link flapping, cable disconnections, or wireless renegotiations. |
| **`colls`** | TX | Ethernet collisions (should be zero in full-duplex switched networks). |

### 8.3 Rate Calculation Formula
Because `/proc/net/dev` is a monotonic counter, instantaneous values are meaningless without differential sampling:

$$\text{Throughput (Mbps)} = \frac{(\text{Bytes}_{t_2} - \text{Bytes}_{t_1}) \times 8}{(t_2 - t_1) \times 1,000,000}$$

$$\text{Packet Rate (PPS)} = \frac{\text{Packets}_{t_2} - \text{Packets}_{t_1}}{t_2 - t_1}$$

---

## 9. Diagnostic & Troubleshooting Toolkit

| Tool | Primary Purpose | Key Flags | Measurement Target | SRE Limitations |
| :--- | :--- | :--- | :--- | :--- |
| **`ip link`** | Link state and MAC configuration | `-s`, `-d`, `-br` | MTU, link state, hardware address, packet counters | Does not measure transport-layer socket state. |
| **`ip addr`** | IP configuration | `-br`, `show` | Assigned IPv4/IPv6 addresses, subnet scope, broadcast | Static view; does not test actual reachability. |
| **`ip route`** | Routing table inspection | `show`, `get <ip>` | Next-hop gateways, routing metrics, interface bindings | Route existence does not prove downstream path health. |
| **`ss`** | Socket inspection | `-tuln`, `-tanp`, `-s` | Listening ports, connection states, buffer queues | Cannot capture live packet payloads (requires `tcpdump`). Requires root for process names on non-owned sockets. |
| **`ping`** | Round-trip latency and packet loss | `-c 4`, `-W 2`, `-i 0.2` | ICMP Echo Request / Reply round-trip time (RTT) | Many production routers and firewalls drop or de-prioritize ICMP; false negatives common. |
| **`curl`** | Application layer probe | `-I`, `-s`, `-w "%{time_total}\n"` | HTTP/HTTPS handshake, TLS negotiation, response headers | Tests only application protocol endpoints; cannot diagnose low-level transport errors. |
| **`resolvectl`** | DNS resolver inspection | `status`, `query` | Upstream DNS servers, DNSSEC, cache state, link scope | Specific to systemd-resolved environments; not on legacy distributions. |
| **`getent`** | glibc name resolution | `hosts <domain>` | End-to-end NSS resolution matching application behavior | Does not expose intermediate DNS cache details. |
| **`ethtool`** | Physical NIC driver & transceiver stats | `-S <dev>`, `-g <dev>` | Ring buffer sizes, offload features, link speed, pause frames | Requires `CAP_NET_ADMIN` (root); unsupported or restricted on many wireless/virtual NICs. |

---

## 10. SRE Best Practices & Operational Traps

1. **Beware the Deprecated `netstat` and `ifconfig`**:
   - `netstat -s` and `netstat -an` parse `/proc/net/tcp` slowly via single-threaded text iteration. On systems with 50,000+ connections, `netstat` introduces severe kernel lock contention. `ss` uses kernel Netlink sockets and is orders of magnitude faster and safer.
2. **Never Ignore `Recv-Q` on Listening Sockets**:
   - If an alert triggers on server port 8080 with `Recv-Q > 0`, do not restart the network adapter. The bottleneck is inside the application process failing to service its accept queue.
3. **Monitor `TIME_WAIT` Socket Recycling**:
   - High connection rates without HTTP Keep-Alive will flood the system with `TIME_WAIT` sockets. Do **not** enable `net.ipv4.tcp_tw_recycle` (removed in kernel 4.12+ due to NAT breakage). Use connection pooling or enable `net.ipv4.tcp_tw_reuse` for outgoing client connections.
4. **Separate Wireless Packet Loss from Infrastructure Degradation**:
   - On the monitored host, `wlo1` shows 41 dropped RX packets and 287 dropped TX packets out of millions of packets. On Wi-Fi 802.11, Layer 2 frame retries and transient drops are normal due to RF interference. On wired server interfaces (e.g., `eth0`), non-zero drops require immediate investigation of ring buffer sizing (`ethtool -G`) or CPU softirq starvation (`/proc/net/softnet_stat`).
