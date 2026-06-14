# Configuration Guide: KvirtIO Files & Security Policies

This document details the configuration files and security policies used by the **KvirtIO** control plane and hypervisor nodes.

---

## 📂 1. Cluster Configurations (`/etc/kvirtio/clusters/*.conf`)

Each KvirtIO cluster is defined by a bash-sourceable `.conf` file inside the `/etc/kvirtio/clusters/` directory. Watcher scripts parse these files dynamically to discover the cluster topology and set specific alert thresholds.

### Parameters Reference

| Variable | Type | Description | Example |
|---|---|---|---|
| `CLUSTER_NAME` | String | Unique name of the cluster. | `"cluster_db"` |
| `NODES` | Array | List of hypervisor hostnames in the cluster. | `("node1" "node2" "node3")` |
| `SSH_USER` | String | SSH username used by the management server. | `"kvirtwatch"` |
| `CPU_THRESHOLD` | Integer | CPU usage percentage threshold before alerting. | `85` |
| `RAM_THRESHOLD` | Integer | RAM usage percentage threshold before alerting. | `90` |
| `LATENCY_THRESHOLD`| Float | Maximum disk I/O latency (`await`) threshold in ms. | `10.0` |
| `CONSECUTIVE_LIMIT`| Integer | Number of consecutive checks before marking host overloaded. | `3` |
| `ALERT_COOLDOWN_MINUTES`| Integer | Cooldown period between duplicate email alerts (default: 30). | `30` |

### Database Cluster Template (`cluster_db.conf`)
```ini
CLUSTER_NAME="cluster_db"
NODES=("node1" "node2" "node3" "node4" "node5")
SSH_USER="kvirtwatch"
CPU_THRESHOLD=85
RAM_THRESHOLD=90
LATENCY_THRESHOLD=10.0
CONSECUTIVE_LIMIT=3
ALERT_COOLDOWN_MINUTES=30
```

---

## ✉️ 2. SMTP Notification Configuration (`/etc/kvirtio/mail.conf`)

The global mail configuration file defines the SMTP server connection settings used by `kvirtio-mail-alerter.py` to send email alerts.

### Parameters Reference

| Parameter | Description |
|---|---|
| `SMTP_SERVER` | Hostname or IP address of the SMTP server. |
| `SMTP_PORT` | Port number of the SMTP service (e.g. 25, 587, 465). |
| `SMTP_STARTTLS` | Set to `True` to enable STARTTLS secure connection upgrade. |
| `SMTP_USER` | SMTP username for authentication (leave empty for open relays). |
| `SMTP_PASSWORD` | SMTP password for authentication. |
| `SMTP_FROM` | Sender email address appearing in the "From" header. |
| `SMTP_TO` | Recipient email address (sysadmin team or mailing list). |

### Template (`mail.conf`)
```ini
SMTP_SERVER=smtp.example.com
SMTP_PORT=587
SMTP_STARTTLS=True
SMTP_USER=alerts@kvirtio.local
SMTP_PASSWORD=secretpassword
SMTP_FROM=alerts@kvirtio.local
SMTP_TO=sysadmins@example.com
```

---

## 🛡️ 3. Sudoers Security Policy (`/etc/sudoers.d/kvirtwatch`)

To maintain the principle of least privilege, the management server connects to KVM compute nodes using the low-privilege `kvirtwatch` user. Specific administrative commands required for monitoring and VM provisioning are delegated using a sudoers configuration file.

### Required Commands on KVM Nodes

The `/etc/sudoers.d/kvirtwatch` file must contain the following lines on every KVM host:

```sudoers
# Cluster monitoring & Fencing
kvirtwatch ALL=(ALL) NOPASSWD: /usr/sbin/crm_mon --one-shot --output-as=xml, \
                                /usr/sbin/crm_attribute --node node[1-5] --name status-load --update overloaded, \
                                /usr/sbin/crm_attribute --node node[1-5] --name status-load --update healthy, \
                                /usr/bin/iostat -dx 1 2, \
                                /usr/sbin/stonith_admin --list-registered, \
                                /usr/sbin/corosync-quorumtool -s

# Multipath monitoring (read-only)
kvirtwatch ALL=(ALL) NOPASSWD: /usr/sbin/multipath -ll

# VM monitoring (read-only)
kvirtwatch ALL=(ALL) NOPASSWD: /usr/bin/virsh list --all, \
                                /usr/sbin/vgs -o vg_name\,vg_size\,vg_free --units G --nosuffix --noheadings, \
                                /usr/sbin/lvs -o lv_name\,vg_name\,lv_size --units G --nosuffix --noheadings

# VM Console Tracking
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh list --state-running --name
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh domdisplay *

# VM Management (Creation and Migration)
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh define *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh start *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh autostart *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh migrate *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh domstate *
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/virsh version --daemon
```

### Security Permissions
After copying the file, set strict permissions on the compute hosts:
```bash
sudo chown root:root /etc/sudoers.d/kvirtwatch
sudo chmod 0440 /etc/sudoers.d/kvirtwatch
sudo visudo -c
```
