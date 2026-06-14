# Service Documentation: KvirtIO HTML Generator

The **KvirtIO HTML Generator** service gathers metrics from all configured clusters and generates an interactive, modern HTML dashboard served by the Apache web server.

---

## 📋 Functional Description
The generator scans all `.conf` files inside the `/etc/kvirtio/clusters/` directory to gather information about active nodes. Compared to classic agent-based monitoring systems (such as Prometheus), this approach adopts a centralized agentless pull-based design that:
1.  Is executed every **5 minutes** via a Systemd Timer.
2.  Runs a single consolidated block of commands via SSH on each host to minimize connection latency.
3.  Processes the data and compiles a static HTML dashboard in `/var/www/html/kvirtio/index.html`.
4.  Allows system administrators to check infrastructure status via any web browser pointing to the management server's address.

---

## ⚙️ Parameters Tracked and Displayed

The dashboard displays the following sections in real-time for each cluster:

### 1. Host Nodes (Hypervisors)
*   **Health Status**: ONLINE (Green), OFFLINE (Red) in case of no SSH response, or OVERLOADED (Orange) if CPU/RAM exceed cluster thresholds.
*   **CPU Percentage**: Overall real load gathered from `/proc/stat`.
*   **RAM Percentage**: Actual physical memory used gathered from `MemAvailable` in `/proc/meminfo`.
*   **FC LUN I/O Latency**: The maximum peak latency of multipath queues (`dm-*`) extracted from the `iostat` command (expressed in milliseconds).

### 2. Shared Storage Status (LVM Volume Groups)
*   Total size and free space of each clustered Volume Group (e.g., `vg_iointensive`).
*   Remaining free space percentage (with a visual alarm if below 15%).

### 3. Virtual Machine Disk Space (LVM Logical Volumes)
*   Mapping of each individual VM (which corresponds to an LVM Logical Volume).
*   Association to its cluster Volume Group and allocated physical size (e.g., 16TB).

---

## 🏎️ Performance Optimization: Single SSH Connection
To maximize efficiency and reduce overhead on production KVM nodes, the generator **does not run multiple SSH queries** for each metric. Instead, it sends a single aggregated Bash script via SSH that returns concatenated information in stdout, separated by special tokens (e.g., `===VGS===`, `===IOSTAT===`).

Parsing of this combined stream is executed entirely in Python on the external management server.

---

## 🌐 Apache Hosting and Configuration

To serve the generated page via SLES's native Apache web server (`apache2`):

1.  **Create Document Root Directory**:
    ```bash
    sudo mkdir -p /var/www/html/kvirtio
    ```
2.  **Permissions Configuration**:
    To allow the Python script executed by the `kvirtwatch` user to write the HTML report, the directory must be owned by this user, while allowing Apache (group `www` or `wwwrun` on SLES) to read it:
    ```bash
    sudo chown -R kvirtwatch:wwwrun /var/www/html/kvirtio
    sudo chmod 750 /var/www/html/kvirtio
    ```
3.  **Apache Virtual Host Configuration (Optional but recommended)**:
    Create the file `/etc/apache2/vhosts.d/kvirtio.conf` to restrict access to the internal network:
    ```apache
    <VirtualHost *:80>
        DocumentRoot "/var/www/html/kvirtio"
        ServerName kvirtio-monitor.local
        
        <Directory "/var/www/html/kvirtio">
            Options Indexes FollowSymLinks
            AllowOverride None
            Require ip 10.0.0.0/8 192.168.0.0/16
        </Directory>
    </VirtualHost>
    ```
4.  **Start the Web Service**:
    ```bash
    sudo systemctl enable --now apache2
    ```
