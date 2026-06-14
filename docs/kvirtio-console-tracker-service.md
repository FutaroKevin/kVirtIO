# Service Documentation: KvirtIO Console Tracker

The **KvirtIO Console Tracker** is a background daemon that keeps the Websockify token configuration directory aligned with the real-time VNC console outputs of running virtual machines in the clusters.

---

## 📋 Functional Description

The script `kvirtio-console-tracker.sh` acts as a service on the management server. It periodically (every 10 seconds) polls all KVM nodes of each configured cluster via SSH to check which VMs are running and retrieve their VNC display port (using Libvirt's `virsh domdisplay`). It then dynamically updates the Websockify token files and outputs a JSON state file for the monitoring dashboard.

### Core Monitoring and Syncing Objectives

1.  **noVNC Console Proxying**: To allow administrators to access VM consoles via web browsers, Websockify maps VM tokens to their respective target hypervisor VNC socket (host IP and port).
2.  **Dynamic Tracking**: When a VM starts, stops, or migrates to a different hypervisor node, the Console Tracker automatically detects the change, updates the active mapping, and updates the token directory.
3.  **Security**: Minimizes remote SSH connections by querying VM details as the low-privilege `kvirtwatch` user.

---

## 📈 Process Logic

1.  **Initialize directories**: Creates token and JSON data directories if they do not exist.
2.  **Scan clusters**: Reads `/etc/kvirtio/clusters/*.conf` to discover clusters and target KVM nodes.
3.  **Fetch VM state**: For each node:
    -   Connects via SSH and executes `sudo virsh list --state-running --name` to list running VMs.
    -   For each running VM, runs `sudo virsh domdisplay <vm>` to get the VNC protocol details (e.g. `vnc://0.0.0.0:5901` or `vnc://:5901`).
    -   Translates the hypervisor hostname to an IP address and extracts the VNC port (e.g. `5901`).
4.  **Write WebSockify Tokens**: Writes entries to `/var/lib/kvirtio/novnc/tokens/<cluster_name>.conf` in the format:
    `<vm_name>: <node_ip>:<vnc_port>`
5.  **Write Dashboard JSON**: Writes `/var/www/html/kvirtio/data/console_<cluster_name>.json` detailing available consoles and their noVNC target paths.
6.  **Sleep**: Pauses for 10 seconds before starting the next polling cycle.

---

## 📄 Output Files

### WebSockify Token File (`/var/lib/kvirtio/novnc/tokens/cluster_db.conf`)
```ini
# KvirtIO noVNC Token Directory - Cluster: cluster_db
# Generato da kvirtio-console-tracker il: 2026-06-10T14:20:00Z

lv_vmdb01: 10.10.10.11:5900
lv_vmdb02: 10.10.10.12:5901
```

### Dashboard Console Mapping (`/var/www/html/kvirtio/data/console_cluster_db.json`)
```json
{
  "type": "console",
  "cluster_name": "cluster_db",
  "timestamp": "2026-06-10T14:20:00Z",
  "consoles": [
    {
      "vm": "lv_vmdb01",
      "host": "node1",
      "host_ip": "10.10.10.11",
      "vnc_port": 5900,
      "token": "lv_vmdb01",
      "novnc_url": "/novnc/vnc.html?autoconnect=true&path=websockify&token=lv_vmdb01"
    }
  ]
}
```

---

## ⚙️ Systemd Integration

### Service Unit (`kvirtio-console-tracker.service`)
```ini
[Unit]
Description=KvirtIO noVNC Console Tracker Daemon
After=network.target

[Service]
Type=simple
User=kvirtwatch
ExecStart=/usr/local/bin/kvirtio-console-tracker.sh
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=KvirtIO-ConsoleTracker

[Install]
WantedBy=multi-user.target
```

### Enabling and Starting
```bash
sudo cp systemd/kvirtio-console-tracker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-console-tracker.service
```

---

## 🔐 Sudo Requirements on KVM Nodes

The `kvirtwatch` SSH user must have sudo permissions to run the following commands on KVM nodes:

```sudoers
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh list --state-running --name
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh domdisplay *
```

---

## 🪵 Log Inspection

Self-logs of the daemon are sent to syslog with the tag `KvirtIO-ConsoleTracker`.

*   **View real-time logs**:
    ```bash
    journalctl -t KvirtIO-ConsoleTracker -f
    ```
*   **Log message examples**:
    -   `INFO: KvirtIO Console Tracker avviato. Polling ogni 10s.`
    -   `INFO: [cluster_db] Aggiornato token: lv_vmdb01 -> 10.10.10.11:5900`
    -   `INFO: [cluster_db] Token directory aggiornata: /var/lib/kvirtio/novnc/tokens/cluster_db.conf`
