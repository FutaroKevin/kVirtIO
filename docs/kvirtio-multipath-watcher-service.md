# Service Documentation: KvirtIO Multipath Watcher

The **KvirtIO Multipath Watcher** service monitors the health of Fibre Channel (FC) multipath paths on every KVM node in all clusters defined under `/etc/kvirtio`.

---

## 📋 Functional Description

The watcher cyclically scans all `.conf` files inside `/etc/kvirtio/clusters/`. For each loaded cluster configuration, it connects via SSH to every hypervisor node and inspects the active multipath topology using `multipathd show paths` and `multipath -ll`.

### Monitoring Objective

The primary goal is to detect degraded FC multipath configurations before they can cause I/O errors or VM interruptions. A fully healthy multipath device (`dm-X`) must have **all expected paths** in `active ready` state. Any path transitioning to `failed faulty` or disappearing entirely must trigger an immediate alert.

### Control Logic and Multi-Cluster State Files

To avoid conflicts between nodes with similar names belonging to different clusters, each node's state is tracked with the cluster name embedded in the temporary state file path:

1. The script executes every **5 minutes** via the Systemd Timer.
2. It dynamically loads each `.conf` file from `/etc/kvirtio/clusters/`, inheriting cluster-specific thresholds and node lists.
3. It connects via SSH to each hypervisor node using the `kvirtwatch` user.
4. It runs `sudo multipathd show paths` and parses the output to count, for each multipath device (`dm-X`), how many paths are in `active ready` state versus `failed faulty` or any other degraded state.
5. **Alert Threshold**: If the number of active paths for any `dm-X` device drops below the expected value configured in the cluster `.conf` file (`MULTIPATH_MIN_PATHS`, default: `2`), the alert condition is triggered immediately.
6. On alert:
   - The state for that node/cluster is written to `/tmp/kvirtio_multipath_state_${CLUSTER_NAME}_${node}`.
   - An email alert is sent asynchronously via `kvirtio-mail-alerter.py`.
7. When all paths recover to `active ready`:
   - The state file is reset.
   - A recovery notification is logged and optionally emailed.

---

## 📈 Monitored Metrics

| Metric | Description |
|--------|-------------|
| **Active paths per LUN** | Number of paths in `active ready` state for each `dm-X` multipath device |
| **Failed paths per LUN** | Number of paths in `failed faulty` or `shaky` state |
| **Path priority group** | Whether the active paths belong to the preferred priority group |
| **Total DM devices** | Total number of multipath devices (`dm-*`) detected on the node |

### Path States Reference

| State | Meaning | Action |
|-------|---------|--------|
| `active ready` | Path healthy and I/O flowing | None required |
| `active ghost` | Path active but in non-preferred group | Monitor |
| `failed faulty` | Path failed, I/O redirected to remaining paths | **Alert** |
| `failed shaky` | Path intermittently failing | **Alert** |
| `undef` | Path state unknown (may indicate HBA issue) | **Alert** |

---

## 🔔 Thresholds and Alerting

Thresholds are defined per cluster inside the corresponding `.conf` file:

```ini
# Minimum number of active paths required per dm-X device
MULTIPATH_MIN_PATHS=2
```

When the active path count for **any** `dm-X` device falls below `MULTIPATH_MIN_PATHS`:

1. A `CRITICAL` syslog entry is written with the cluster tag.
2. `kvirtio-mail-alerter.py` is invoked in background (`&`) to avoid blocking the monitoring loop:
   ```bash
   python3 /usr/local/bin/kvirtio-mail-alerter.py \
       --subject "KvirtIO ALERT: Multipath degraded on node1 [cluster_db]" \
       --body "Device dm-3 on node1 (cluster_db) has only 1 active path (min: 2). Failed path: 3:0:1:5 failed faulty." &
   ```

---

## 📄 JSON Output

At each execution, the watcher writes a JSON status file for each node. This file is consumed by the KvirtIO HTML Generator to populate the dashboard's multipath health section.

**Output path**: `/var/www/html/kvirtio/data/multipath_<cluster>_<node>.json`

**Example** (`multipath_cluster_db_node1.json`):
```json
{
  "cluster": "cluster_db",
  "node": "node1",
  "timestamp": "2026-06-10T14:05:00Z",
  "status": "degraded",
  "devices": [
    {
      "dm": "dm-0",
      "wwid": "360000000000000001",
      "alias": "lun_ora_data",
      "total_paths": 4,
      "active_paths": 4,
      "failed_paths": 0,
      "health": "ok"
    },
    {
      "dm": "dm-3",
      "wwid": "360000000000000004",
      "alias": "lun_ora_redo",
      "total_paths": 4,
      "active_paths": 1,
      "failed_paths": 3,
      "health": "critical"
    }
  ]
}
```

The top-level `status` field is `"ok"` only when all devices report `"health": "ok"`. Any degraded device sets `status` to `"degraded"` or `"critical"`.

---

## ⚙️ Systemd Integration

### Service Unit (`kvirtio-multipath-watcher.service`)
```ini
[Unit]
Description=KvirtIO Multipath Path Health Watcher
After=network.target
Wants=kvirtio-multipath-watcher.timer

[Service]
Type=oneshot
User=kvirtwatch
ExecStart=/usr/local/sbin/kvirtio-multipath-watcher.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=KvirtIO-Multipath

[Install]
WantedBy=multi-user.target
```

### Timer Unit (`kvirtio-multipath-watcher.timer`)
```ini
[Unit]
Description=KvirtIO Multipath Watcher — runs every 5 minutes
Requires=kvirtio-multipath-watcher.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=10s
Unit=kvirtio-multipath-watcher.service

[Install]
WantedBy=timers.target
```

### Enabling and Starting
```bash
sudo cp systemd/kvirtio-multipath-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-multipath-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-multipath-watcher.timer
```

---

## 🔐 Sudo Requirements on KVM Nodes

The `kvirtwatch` user must be allowed to run the following commands without a password on each KVM node. Add the following entries to `/etc/sudoers.d/kvirtwatch`:

```sudoers
kvirtwatch ALL=(root) NOPASSWD: /sbin/multipathd show paths
kvirtwatch ALL=(root) NOPASSWD: /sbin/multipath -ll
```

Verify the sudoers syntax after editing:
```bash
sudo visudo -c
```

---

## 🪵 Log Inspection

All watcher events are sent to the system journal under the `KvirtIO-Multipath` identifier.

### Follow live logs:
```bash
journalctl -fu kvirtio-multipath-watcher.service
```

### Filter by syslog tag:
```bash
journalctl -t KvirtIO-Multipath -f
```

### Filter critical events for a specific cluster:
```bash
journalctl -t KvirtIO-Multipath | grep '\[cluster_db\]'
```

### Log message reference:

| Level | Example Message |
|-------|----------------|
| `INFO` | `INFO: Starting multipath monitoring for cluster: cluster_db (3 nodes).` |
| `INFO` | `INFO: [cluster_db] node1 — all multipath paths healthy (4/4 active).` |
| `CRITICAL` | `CRITICAL: [cluster_db] node1 — dm-3 degraded: 1/4 active paths. Failed: 3:0:1:5 failed faulty.` |
| `INFO` | `INFO: [cluster_db] node1 — dm-3 recovered: 4/4 active paths. Alert cleared.` |
| `ERROR` | `ERROR: [cluster_db] Cannot reach node3 via SSH.` |

---


