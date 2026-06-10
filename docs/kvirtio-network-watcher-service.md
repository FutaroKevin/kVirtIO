# Service Documentation: KvirtIO Network Watcher

The **KvirtIO Network Watcher** service monitors the health of LACP bond interfaces (802.3ad), MTU consistency, and `fq_codel` queue discipline backlog on every KVM node in all clusters defined under `/etc/kvirtio`.

---

## 📋 Functional Description

The watcher cyclically scans all `.conf` files inside `/etc/kvirtio/clusters/`. For each loaded cluster, it connects via SSH to every hypervisor node and inspects the network bonding state, interface statistics, and traffic scheduler queues.

### Monitoring Objective

In a KVM cluster with SR-IOV or bridged networking, network bond degradation can silently cause intermittent packet loss or latency spikes affecting all VMs running on the node. The watcher provides early warning of:

- **Slave interface failures**: A bond slave going `down` reduces redundancy and, depending on policy, may halve available throughput.
- **RX/TX error accumulation**: Persistent interface errors indicate hardware or cabling issues.
- **MTU mismatches**: A slave MTU differing from the bond MTU can cause silent packet truncation for jumbo-frame traffic (storage, VM live migration).
- **`fq_codel` backlog growth**: An expanding `fq_codel` backlog on the bridge or bond interface signals sustained congestion and impending latency spikes for VM network traffic.

---

## 📈 Monitored Metrics

### Bond Status (via `ip link show` and `/proc/net/bonding/`)

| Metric | Description |
|--------|-------------|
| **Bond mode** | Confirmed as `802.3ad` (LACP) |
| **Slave state** | `up` or `down` for each bond member interface |
| **Active slave count** | Number of slaves currently passing traffic |
| **LACP partner detected** | Whether the switch side of LACP is responding |

### Interface Error Counters (via `ethtool -S <iface>` or `/sys/class/net/`)

| Metric | Description |
|--------|-------------|
| **RX errors** | Receive error frames per interface |
| **TX errors** | Transmit error frames per interface |
| **RX dropped** | Dropped receive frames (kernel buffer overflow) |
| **TX dropped** | Dropped transmit frames |

### MTU Consistency (via `ip link show`)

| Metric | Description |
|--------|-------------|
| **Bond MTU** | Configured MTU on the bond interface |
| **Slave MTU** | MTU on each slave interface |
| **MTU mismatch** | Flag raised when any slave MTU ≠ bond MTU |

### `fq_codel` Queue Discipline (via `tc qdisc show`)

| Metric | Description |
|--------|-------------|
| **backlog bytes** | Bytes currently queued in the `fq_codel` discipline |
| **backlog packets** | Packets currently queued |
| **dropped** | Total packets dropped by `fq_codel` since last reset |

---

## 🔔 Alert Thresholds

Thresholds are defined per cluster inside the corresponding `.conf` file:

```ini
# Minimum number of bond slaves required in "up" state
BOND_MIN_SLAVES_UP=2

# MTU expected on bond and all slaves (0 = skip MTU check)
BOND_EXPECTED_MTU=9000

# fq_codel backlog alert threshold in bytes (0 = skip)
FQCODEL_BACKLOG_THRESHOLD=10485760

# Sustained packet drop alert threshold (drops > 0 for N consecutive checks)
PACKET_DROP_CONSECUTIVE_LIMIT=3
```

### Alert Conditions

| Condition | Severity | Action |
|-----------|----------|--------|
| Bond slave goes `down` (active slaves < `BOND_MIN_SLAVES_UP`) | **CRITICAL** | Immediate email alert |
| Slave MTU ≠ bond MTU | **WARNING** | Log + email alert |
| `fq_codel` backlog > `FQCODEL_BACKLOG_THRESHOLD` | **WARNING** | Log + email alert |
| Packet drop > 0 sustained for `PACKET_DROP_CONSECUTIVE_LIMIT` checks | **WARNING** | Log + email alert |
| Interface RX/TX error counter increment detected | **WARNING** | Log entry |

Alerts are sent asynchronously via `kvirtio-mail-alerter.py`:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO ALERT: Bond slave down on node2 [cluster_db]" \
    --body "Bond bond0 on node2 (cluster_db): slave eth1 is DOWN. Active slaves: 1/2." &
```

---

## 📄 JSON Output

At each execution, the watcher writes a JSON status file per node consumed by the KvirtIO HTML Generator dashboard.

**Output path**: `/var/www/html/kvirtio/data/network_<cluster>_<node>.json`

**Example** (`network_cluster_db_node2.json`):
```json
{
  "cluster": "cluster_db",
  "node": "node2",
  "timestamp": "2026-06-10T14:10:00Z",
  "status": "degraded",
  "bond": {
    "name": "bond0",
    "mode": "802.3ad",
    "mtu": 9000,
    "active_slaves": 1,
    "total_slaves": 2,
    "slaves": [
      { "iface": "eth0", "state": "up", "mtu": 9000, "rx_errors": 0, "tx_errors": 0 },
      { "iface": "eth1", "state": "down", "mtu": 9000, "rx_errors": 12, "tx_errors": 0 }
    ]
  },
  "fq_codel": {
    "iface": "bond0",
    "backlog_bytes": 524288,
    "backlog_packets": 64,
    "dropped": 0
  }
}
```

---

## ⚙️ Systemd Integration

The network watcher can be invoked in two ways:

### Option A — Dedicated Timer (Recommended)

**Service Unit** (`kvirtio-network-watcher.service`):
```ini
[Unit]
Description=KvirtIO Network Bond and Queue Health Watcher
After=network.target
Wants=kvirtio-network-watcher.timer

[Service]
Type=oneshot
User=kvirtwatch
ExecStart=/usr/local/sbin/kvirtio-network-watcher.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=KvirtIO-Network

[Install]
WantedBy=multi-user.target
```

**Timer Unit** (`kvirtio-network-watcher.timer`):
```ini
[Unit]
Description=KvirtIO Network Watcher — runs every 5 minutes
Requires=kvirtio-network-watcher.service

[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
AccuracySec=10s
Unit=kvirtio-network-watcher.service

[Install]
WantedBy=timers.target
```

### Option B — Invoked by `kvirtio-cluster-watcher`

If a single orchestration watcher is preferred, `kvirtio-cluster-watcher.sh` can call `kvirtio-network-watcher.sh` as a sub-module within its execution loop. No dedicated timer is needed in this case.

### Enabling the Dedicated Timer
```bash
sudo cp systemd/kvirtio-network-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-network-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-network-watcher.timer
```

---

## 🔐 Sudo Requirements on KVM Nodes

Add the following entries to `/etc/sudoers.d/kvirtwatch` on each KVM node:

```sudoers
kvirtwatch ALL=(root) NOPASSWD: /sbin/ip link show
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/ethtool *
kvirtwatch ALL=(root) NOPASSWD: /sbin/tc qdisc show *
```

Verify the sudoers syntax after editing:
```bash
sudo visudo -c
```

---

## 🪵 Log Inspection

All events are sent to the system journal under the `KvirtIO-Network` syslog identifier.

### Follow live logs:
```bash
journalctl -fu kvirtio-network-watcher.service
```

### Filter by syslog tag:
```bash
journalctl -t KvirtIO-Network -f
```

### Filter by cluster:
```bash
journalctl -t KvirtIO-Network | grep '\[cluster_db\]'
```

### Log message reference:

| Level | Example Message |
|-------|----------------|
| `INFO` | `INFO: Starting network monitoring for cluster: cluster_db (3 nodes).` |
| `INFO` | `INFO: [cluster_db] node2 — bond0 healthy: 2/2 slaves up, MTU 9000, backlog 0 bytes.` |
| `CRITICAL` | `CRITICAL: [cluster_db] node2 — bond0 degraded: slave eth1 DOWN. Active slaves: 1/2.` |
| `WARNING` | `WARNING: [cluster_db] node2 — MTU mismatch: bond0=9000 but eth1=1500.` |
| `WARNING` | `WARNING: [cluster_db] node2 — fq_codel backlog on bond0: 12582912 bytes (threshold: 10485760).` |
| `ERROR` | `ERROR: [cluster_db] Cannot reach node3 via SSH.` |

---
