# Service Documentation: KvirtIO Cluster Watcher

The **KvirtIO Cluster Watcher** service monitors the health of Pacemaker/Corosync high-availability clusters — tracking quorum state, node online/offline transitions, and resource failures — on all clusters defined under `/etc/kvirtio`.

---

## 📋 Functional Description

The watcher cyclically scans all `.conf` files inside `/etc/kvirtio/clusters/`. For each configured cluster it executes `crm_mon` and `corosync-cfgtool` via SSH on a designated node (typically the primary node), parses the structured XML output, and writes a consolidated status JSON to the web dashboard data directory.

### Monitoring Objective

Pacemaker/Corosync cluster health is the foundational layer of KVM HA. If quorum is lost or a node goes offline, Pacemaker may fence nodes and stop resources to protect data integrity. The watcher provides early visibility into:

- **Quorum loss**: Immediate alerting when the cluster loses quorum, preventing split-brain situations from going unnoticed.
- **Node offline events**: Detecting nodes leaving the cluster membership ring.
- **Resource failures**: Tracking Pacemaker resources in `FAILED` state that require manual intervention to clear.

### Control Logic

1. The script executes every **5 minutes** via the Systemd Timer.
2. It loads each cluster `.conf` from `/etc/kvirtio/clusters/`.
3. It connects via SSH to the cluster's designated monitoring node.
4. It runs `sudo crm_mon -1 --output-as=xml` and parses the XML output:
   - Extracts quorum status (`quorum_type`, `with_quorum`).
   - Lists all nodes with their state (`online`, `offline`, `standby`, `unclean`).
   - Lists all resources with their state (`Started`, `Stopped`, `FAILED`) and the node they are running on.
5. It runs `sudo corosync-cfgtool -s` to collect ring status and detect token transmission errors.
6. If any alert condition is met:
   - A `CRITICAL` or `WARNING` syslog entry is written.
   - `kvirtio-mail-alerter.py` is invoked asynchronously.
   - The JSON output file is written with `status: "critical"` or `"degraded"`.

---

## 📈 Monitored Metrics

### Quorum (via `crm_mon -1 --output-as=xml`)

| Metric | Description |
|--------|-------------|
| **with_quorum** | Boolean — whether the cluster currently holds quorum |
| **quorum_type** | Expected quorum type (`fencing`, `freeze`, etc.) |

### Node Status

| Metric | Description |
|--------|-------------|
| **node name** | Cluster node identifier |
| **online** | `true` / `false` |
| **standby** | Whether node is in standby (intentional or forced) |
| **unclean** | Whether node is in unclean/fencing state |
| **maintenance** | Whether node is in maintenance mode |

### Resources (via `crm_mon -1 --output-as=xml`)

| Metric | Description |
|--------|-------------|
| **resource id** | Pacemaker resource identifier |
| **resource type** | Primitive, clone, group |
| **role** | `Started`, `Stopped`, `Master`, `Slave` |
| **failed** | `true` if resource is in FAILED state |
| **managed** | Whether resource is under Pacemaker management |
| **node** | Node where the resource is currently running |

### Corosync Ring Status (via `corosync-cfgtool -s`)

| Metric | Description |
|--------|-------------|
| **ring id** | Corosync ring identifier |
| **status** | `ring 0 active with no faults` or fault description |

---

## 🔔 Alert Thresholds

Alert conditions are evaluated at every execution with no configurable threshold delay — **cluster health events are always immediate alerts**:

| Condition | Severity | Action |
|-----------|----------|--------|
| `with_quorum = false` | **CRITICAL** | Immediate email + `CRITICAL` syslog |
| Any node in `online = false` (and not in maintenance) | **CRITICAL** | Immediate email + `CRITICAL` syslog |
| Any node in `unclean = true` | **CRITICAL** | Immediate email + `CRITICAL` syslog |
| Any resource with `failed = true` | **CRITICAL** | Immediate email + `CRITICAL` syslog |
| Any resource in `Stopped` state unexpectedly | **WARNING** | `WARNING` syslog + email |
| Corosync ring fault detected | **WARNING** | `WARNING` syslog + email |

Alert email example:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO CRITICAL: Quorum lost on cluster_db" \
    --body "Cluster cluster_db has lost quorum. Immediate intervention required to prevent fencing cascades." &
```

---

## 📄 JSON Output

At each execution, the watcher writes a single JSON file per cluster (not per node, since cluster state is global).

**Output path**: `/var/www/html/kvirtio/data/cluster_<cluster>.json`

**Example** (`cluster_cluster_db.json`):
```json
{
  "cluster": "cluster_db",
  "timestamp": "2026-06-10T14:15:00Z",
  "status": "critical",
  "quorum": {
    "with_quorum": false,
    "quorum_type": "fencing"
  },
  "nodes": [
    { "name": "node1", "online": true,  "standby": false, "unclean": false, "maintenance": false },
    { "name": "node2", "online": true,  "standby": false, "unclean": false, "maintenance": false },
    { "name": "node3", "online": false, "standby": false, "unclean": true,  "maintenance": false }
  ],
  "resources": [
    { "id": "vm_oracle_01", "role": "Started", "node": "node1", "failed": false, "managed": true },
    { "id": "vm_oracle_02", "role": "FAILED",  "node": null,    "failed": true,  "managed": true },
    { "id": "vip_db",       "role": "Started", "node": "node2", "failed": false, "managed": true }
  ],
  "corosync_rings": [
    { "ring_id": 0, "status": "ring 0 active with no faults" }
  ]
}
```

---

## ⚙️ Systemd Integration

### Service Unit (`kvirtio-cluster-watcher.service`)
```ini
[Unit]
Description=KvirtIO Pacemaker/Corosync Cluster Health Watcher
After=network.target
Wants=kvirtio-cluster-watcher.timer

[Service]
Type=oneshot
User=kvirtwatch
ExecStart=/usr/local/sbin/kvirtio-cluster-watcher.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=KvirtIO-Cluster

[Install]
WantedBy=multi-user.target
```

### Timer Unit (`kvirtio-cluster-watcher.timer`)
```ini
[Unit]
Description=KvirtIO Cluster Watcher — runs every 5 minutes
Requires=kvirtio-cluster-watcher.service

[Timer]
OnBootSec=60s
OnUnitActiveSec=5min
AccuracySec=10s
Unit=kvirtio-cluster-watcher.service

[Install]
WantedBy=timers.target
```

### Enabling and Starting
```bash
sudo cp systemd/kvirtio-cluster-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-cluster-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-cluster-watcher.timer
```

---

## 🔐 Sudo Requirements on KVM Nodes

Add the following entries to `/etc/sudoers.d/kvirtwatch` on each KVM node:

```sudoers
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/crm_mon -1 --output-as=xml
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/crm_mon -1
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/crm_attribute *
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/corosync-cfgtool -s
```

Verify the sudoers syntax after editing:
```bash
sudo visudo -c
```

---

## 🪵 Log Inspection

All events are sent to the system journal under the `KvirtIO-Cluster` syslog identifier.

### Follow live logs:
```bash
journalctl -fu kvirtio-cluster-watcher.service
```

### Filter by syslog tag:
```bash
journalctl -t KvirtIO-Cluster -f
```

### Filter by cluster:
```bash
journalctl -t KvirtIO-Cluster | grep '\[cluster_db\]'
```

### Log message reference:

| Level | Example Message |
|-------|----------------|
| `INFO` | `INFO: Starting cluster monitoring for cluster: cluster_db.` |
| `INFO` | `INFO: [cluster_db] Cluster healthy — 3/3 nodes online, quorum OK, 0 failed resources.` |
| `CRITICAL` | `CRITICAL: [cluster_db] Quorum LOST. Cluster has 2/3 nodes. Fencing may occur.` |
| `CRITICAL` | `CRITICAL: [cluster_db] Node node3 is OFFLINE (unclean).` |
| `CRITICAL` | `CRITICAL: [cluster_db] Resource vm_oracle_02 is in FAILED state.` |
| `WARNING` | `WARNING: [cluster_db] Corosync ring 0 fault detected on node2.` |
| `ERROR` | `ERROR: [cluster_db] Cannot reach monitoring node (node1) via SSH.` |

---


