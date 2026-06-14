# Monitoring Watchers Deployment Guide: KvirtIO

This document provides step-by-step instructions to install, configure, and verify the monitoring watchers of the **KvirtIO** project with native multi-cluster support.

---

## 🛠️ Watcher Architecture and Configuration

The monitoring system adopts a decoupled design based on modular configuration files:
*   **Configuration directory**: `/etc/kvirtio/clusters/`
*   **Configuration files**: Each cluster is defined by an independent `.conf` file (e.g., `cluster_db.conf`, `cluster_web.conf`), allowing for different target nodes, SSH users, and alarm thresholds per managed cluster.
*   **Watchers (Management Server)**: These scripts dynamically scan the configuration folder and iterate over the nodes of all detected clusters.

---

## 📋 Prerequisites

1.  **User and SSH setup (on all KVM nodes and the Management Server)**:
    *   Create the dedicated `kvirtwatch` user on all machines (management server and KVM hosts of all clusters):
        ```bash
        sudo useradd -m -s /bin/bash kvirtwatch
        ```
    *   Generate the SSH key for the `kvirtwatch` user on the management server without a passphrase:
        ```bash
        sudo -u kvirtwatch ssh-keygen -t ed25519 -N "" -f /home/kvirtwatch/.ssh/id_ed25519
        ```
    *   Distribute the public key to all hypervisor nodes of all clusters (e.g., for the DB cluster):
        ```bash
        sudo -u kvirtwatch ssh-copy-id -i /home/kvirtwatch/.ssh/id_ed25519.pub kvirtwatch@node1
        # Repeat for all nodes defined in the configuration files
        ```
    *   Verify passwordless SSH connection:
        ```bash
        sudo -u kvirtwatch ssh -o StrictHostKeyChecking=accept-new kvirtwatch@node1 "hostname"
        ```

2.  **Required packages on KVM nodes (SLES)**:
    *   Ensure that the `sysstat` package is installed on all KVM hosts:
        ```bash
        sudo zypper install sysstat
        ```

---

## 🚀 Step 1: KVM Nodes Configuration (Compute Hosts)

On each hypervisor node of all managed clusters:

1.  Create the sudoers configuration file to allow passwordless execution of required commands by the `kvirtwatch` user:
    *   Copy the content of the logical configuration file [kvirtwatch (sudoers)](../sudoers/kvirtwatch) to `/etc/sudoers.d/kvirtwatch`.
2.  Set the correct security permissions:
    ```bash
    sudo chmod 0440 /etc/sudoers.d/kvirtwatch
    sudo chown root:root /etc/sudoers.d/kvirtwatch
    ```
3.  Verify the sudoers syntax:
    ```bash
    sudo visudo -c
    ```

---

## 🚀 Step 2: Management Server Configuration

On the external Management Server:

1.  **Create Directory Structure**:
    ```bash
    sudo mkdir -p /etc/kvirtio/clusters
    sudo mkdir -p /var/lib/kvirtio/logs
    sudo mkdir -p /var/lib/kvirtio/novnc/tokens
    sudo mkdir -p /var/www/html/kvirtio/data
    ```

2.  **Place Configuration Files**:
    *   Create configuration files for each cluster in `/etc/kvirtio/clusters/` using the following templates:
        *   [etc/kvirtio/clusters/cluster_db.conf](../etc/kvirtio/clusters/cluster_db.conf): Database cluster configuration with strict thresholds.
        *   [etc/kvirtio/clusters/cluster_web.conf](../etc/kvirtio/clusters/cluster_web.conf): Web/General-purpose cluster configuration.
    *   Configure SMTP parameters in the global `/etc/kvirtio/mail.conf` file (refer to [kvirtio-mail-config.md](kvirtio-mail-config.md)).
    *   Set permissions on the configuration directory:
        ```bash
        sudo chown -R kvirtwatch:kvirtwatch /etc/kvirtio
        sudo chmod 750 /etc/kvirtio
        sudo chmod 640 /etc/kvirtio/clusters/*.conf
        sudo chmod 640 /etc/kvirtio/mail.conf
        ```
    *   Assign appropriate permissions for the log and state directories to the web server group (`wwwrun` or `www-data` depending on the SLES version):
        ```bash
        sudo chown -R kvirtwatch:wwwrun /var/lib/kvirtio
        sudo chmod -R 770 /var/lib/kvirtio
        ```

3.  **Deploy Watcher Scripts**:
    *   Copy the scripts to `/usr/local/bin/`:
        ```bash
        sudo cp scripts/kvirtio-* /usr/local/bin/
        sudo chmod 750 /usr/local/bin/kvirtio-*
        sudo chown root:kvirtwatch /usr/local/bin/kvirtio-*
        ```

4.  **Configure Systemd Services**:
    *   Copy service and timer files from [systemd/](../systemd/) to `/etc/systemd/system/`:
        ```bash
        sudo cp systemd/kvirtio-*.service /etc/systemd/system/
        sudo cp systemd/kvirtio-*.timer /etc/systemd/system/
        ```
    *   Reload the systemd daemon:
        ```bash
        sudo systemctl daemon-reload
        ```

5.  **Enable and Start Systemd Timers and Daemons**:
    *   Enable and start systemd timers for periodic watchers:
        ```bash
        sudo systemctl enable --now kvirtio-host-watcher.timer
        sudo systemctl enable --now kvirtio-io-watcher.timer
        sudo systemctl enable --now kvirtio-cluster-watcher.timer
        sudo systemctl enable --now kvirtio-multipath-watcher.timer
        sudo systemctl enable --now kvirtio-vm-watcher.timer
        sudo systemctl enable --now kvirtio-html-generator.timer
        ```
    *   Enable and start persistent background services (daemons):
        ```bash
        sudo systemctl enable --now kvirtio-console-tracker.service
        sudo systemctl enable --now kvirtio-log-collector.service
        ```

---

## 🔍 Step 3: Verification and Monitoring

### Timer and Service Status
Verify that the systemd timers are active and correctly scheduled:
```bash
systemctl list-timers --all | grep kvirtio
```
Verify the status of background services:
```bash
systemctl status kvirtio-console-tracker.service
systemctl status kvirtio-log-collector.service
```

### Manual Execution Test
You can manually trigger the one-shot services to validate the configuration files and rule out syntax errors:
```bash
sudo systemctl start kvirtio-host-watcher.service
sudo systemctl start kvirtio-io-watcher.service
sudo systemctl start kvirtio-cluster-watcher.service
sudo systemctl start kvirtio-multipath-watcher.service
sudo systemctl start kvirtio-vm-watcher.service
sudo systemctl start kvirtio-html-generator.service
```

### Log Inspection
Logs in syslog will explicitly denote the cluster being processed (e.g., `[cluster_db]`, `[cluster_web]`):
*   **Host Watcher**: `journalctl -t KvirtIO-Host -f`
*   **I/O Watcher**: `journalctl -t KvirtIO-IO -f`
*   **Cluster Watcher**: `journalctl -t KvirtIO-Cluster -f`
*   **Multipath Watcher**: `journalctl -t KvirtIO-Multipath -f`
*   **VM Watcher**: `journalctl -t KvirtIO-VM -f`
*   **Log Collector**: `journalctl -t KvirtIO-LogCollector -f`

---

## 📜 Step 4: Log Routing and Centralization (KVM, Pacemaker, Audit)

To comply with the requested naming convention (`[service]-[cluster]-[node].log`), the rsyslog configuration on the receiving server is generated dynamically by reading `/etc/kvirtio/clusters/*.conf`, correctly mapping each node to its respective cluster.

### 1. Configuration on KVM Nodes (Clients)

On the compute nodes, `rsyslog` is configured to forward specific logs to the virtual IP (or dedicated IP) of the Watcher server, while `auditd` is configured to send its events to syslog.

#### 1.1 Rsyslog Forwarding (`/etc/rsyslog.d/10-kvirtio-forward.conf`)
Create this file on each KVM node to forward target logs to the Watcher server's IP (e.g., `10.10.10.100`):

```rsyslog
# Forward Pacemaker / Corosync logs
if $programname == ['pacemakerd','crmd','pengine','corosync'] then @10.10.10.100:514

# Forward KVM / QEMU / Libvirt logs
if $programname == ['libvirtd','qemu','qemu-kvm','qemu-system-x86_64'] then @10.10.10.100:514

# Forward Auditd logs
if $programname == ['audisp-syslog','auditd'] then @10.10.10.100:514
```

#### 1.2 Auditd Plugin Configuration
Edit `/etc/audit/plugins.d/syslog.conf` (or `/etc/audisp/plugins.d/syslog.conf` on older SLES releases):
```ini
active = yes
direction = out
path = /sbin/audisp-syslog
type = always
args = LOG_WARNING
format = string
```

#### 1.3 Restart Services on Compute Nodes
```bash
sudo systemctl restart auditd
sudo systemctl restart rsyslog
```

---

### 2. Configuration on the Watcher Server

Since rsyslog is not natively aware of the "Cluster" grouping, we use a helper script that reads the kVirtIO topology and compiles the exact routing rules for each node.

#### 2.1 Directory Preparation
On the Watcher server:
```bash
sudo mkdir -p /var/log/kvirtio/
sudo chown syslog:kvirtwatch /var/log/kvirtio/
sudo chmod 755 /var/log/kvirtio/
```

#### 2.2 Rsyslog Configuration Generation
Run the generator script to map each node to its respective cluster:
```bash
sudo chmod +x /usr/local/bin/kvirtio-setup-rsyslog-generator.sh
sudo /usr/local/bin/kvirtio-setup-rsyslog-generator.sh
```
This generates `/etc/rsyslog.d/30-kvirtio-receiver.conf`, writing logs into `/var/log/kvirtio/[service]-[cluster]-[node].log`.

#### 2.3 Restart Rsyslog
```bash
sudo systemctl restart rsyslog
```

*(Operational Note: Whenever a new node or cluster is added in `/etc/kvirtio/clusters/*.conf`, simply rerun the generator script and restart rsyslog).*
