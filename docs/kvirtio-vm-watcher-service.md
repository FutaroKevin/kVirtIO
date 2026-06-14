# Service Documentation: KvirtIO VM Watcher

The **KvirtIO VM Watcher** service monitors the state, location, and Pacemaker resource status of all virtual machines defined across clusters in `/etc/kvirtio`.

---

## 📋 Functional Description

The VM Watcher cyclically scans all cluster configuration files in `/etc/kvirtio/clusters/`. For each cluster, it queries a representative online node via SSH, retrieves the local Libvirt VM list (`virsh list --all`) and the global Pacemaker cluster status (`crm_mon`), correlates the two sources, and exports a unified JSON file consumed by the dashboard.

### Monitoring Objective

In a high-availability (HA) virtualized cluster, Pacemaker manages VMs as HA resources (using the `VirtualDomain` resource agent). To prevent discrepancies, it is crucial to ensure that:
1.  **Libvirt state matches Pacemaker state**: A VM should be `running` under Libvirt if Pacemaker lists it as `Started`.
2.  **No unplanned VM downtime**: If a VM enters a `crashed` or `paused` state (without planned maintenance), or if its Pacemaker resource is `Stopped` unexpectedly, an alert must be fired immediately.

### Control Logic

1.  The script runs every **2 minutes** via a Systemd Timer.
2.  It reads cluster configurations in `/etc/kvirtio/clusters/*.conf`.
3.  It finds the first online node in the cluster to act as the query target.
4.  It executes:
    -   `sudo virsh list --all` to list all VMs and their local Libvirt status.
    -   `sudo crm_mon --one-shot --output-as=xml` to retrieve the active Pacemaker resources of type `VirtualDomain` and the node they are currently running on.
5.  It correlates the Libvirt VM names with Pacemaker `VirtualDomain` resources.
6.  It writes the consolidated VM status JSON file to the web directory.
7.  It triggers an alert (via syslog and `kvirtio-mail-alerter.py`) if:
    -   A VM is in `crashed` state.
    -   A VM is in `paused` state (unplanned).
    -   A Pacemaker VM resource is `Stopped` unexpectedly.
8.  It detects recovery if the cluster transitions back to an all-OK state.

---

## 📈 Monitored Metrics

| Metric | Source | Description |
|---|---|---|
| **name** | Libvirt / Pacemaker | The name of the virtual machine |
| **libvirt_state** | `virsh list --all` | Current hypervisor state: `running`, `paused`, `shut off`, `crashed`, etc. |
| **pacemaker_resource**| `crm_mon` | The ID of the Pacemaker resource managing this VM |
| **pacemaker_node** | `crm_mon` | The hypervisor node where Pacemaker expects the VM to run |
| **pacemaker_status** | `crm_mon` | Pacemaker resource state: `Started`, `Stopped`, `FAILED` |

---

## 🔔 Alert Thresholds and Conditions

State evaluations occur on every run (every 2 minutes):

| Condition | Severity | Action |
|---|---|---|
| Libvirt state = `crashed` | **CRITICAL** | Email + syslog `CRITICAL` |
| Libvirt state = `paused` (unplanned) | **CRITICAL** | Email + syslog `CRITICAL` |
| Pacemaker status = `Stopped` unexpectedly | **WARNING** | Syslog `WARNING` |
| Recovery from warning/critical back to healthy | **INFO** | Email + syslog `INFO` (Recovery) |

Alert emails are sent asynchronously in the background. Cooldown locks (`/tmp/kvirtio_alert_lock_<cluster>_<alert_type>`) prevent spamming alerts during persistent failures (default: 30 minutes cooldown).

---

## 📄 JSON Output

**Output path**: `/var/www/html/kvirtio/data/vm_<cluster>.json`

**Example** (`vm_cluster_db.json`):
```json
{
  "generated_at": "2026-06-10T14:12:00",
  "cluster_name": "cluster_db",
  "vms": [
    {
      "name": "lv_vmdb01",
      "libvirt_state": "running",
      "pacemaker_resource": "res_vm_db01",
      "pacemaker_node": "node01",
      "pacemaker_status": "Started"
    },
    {
      "name": "lv_vmdb02",
      "libvirt_state": "shut off",
      "pacemaker_resource": "res_vm_db02",
      "pacemaker_node": "node02",
      "pacemaker_status": "Stopped"
    }
  ]
}
```

---

## ⚙️ Systemd Integration

### Service Unit (`kvirtio-vm-watcher.service`)
```ini
[Unit]
Description=KvirtIO VM Health Watcher
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kvirtio-vm-watcher.sh
User=root
StandardOutput=journal
StandardError=journal
```

### Timer Unit (`kvirtio-vm-watcher.timer`)
```ini
[Unit]
Description=Run KvirtIO VM Watcher every 2 minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=120
Unit=kvirtio-vm-watcher.service

[Install]
WantedBy=timers.target
```

### Enabling and Starting
```bash
sudo cp systemd/kvirtio-vm-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-vm-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-vm-watcher.timer
```

---

## 🔐 Sudo Requirements on KVM Nodes

The `kvirtwatch` SSH user must have sudo permissions to run `virsh` and `crm_mon`. Add the following entries to `/etc/sudoers.d/kvirtwatch`:

```sudoers
kvirtwatch ALL=(ALL) NOPASSWD: /usr/bin/virsh list --all
kvirtwatch ALL=(ALL) NOPASSWD: /usr/sbin/crm_mon --one-shot --output-as=xml
```

---

## 🪵 Log Inspection

Events are logged to the system journal under the tag `KvirtIO-VM`.

*   **View real-time logs**:
    ```bash
    journalctl -t KvirtIO-VM -f
    ```
*   **Log message examples**:
    -   `INFO: [cluster_db] Representative node: node1`
    -   `INFO: [cluster_db] VM cycle completed. 2 VMs found. State: OK.`
    -   `CRITICAL: [cluster_db] VM lv_vmdb01: state 'crashed'.`
