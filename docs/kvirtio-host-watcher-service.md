# Service Documentation: KvirtIO Host Watcher

The **KvirtIO Host Watcher** service monitors the CPU and RAM resources of KVM nodes across all clusters defined under `/etc/kvirtio` and interacts with Pacemaker.

---

## 📋 Functional Description
The watcher cyclically scans all configuration files with a `.conf` extension in the `/etc/kvirtio/clusters/` directory. For each loaded configuration, it performs resource monitoring checks on each associated hypervisor node.

### Control Algorithm and Multi-Cluster State Files
To prevent overlap or conflicts between nodes with similar names belonging to different clusters, the script isolates the state of each node by including the cluster name in the temporary state file path:

1.  The script runs every **5 minutes** via a Systemd Timer.
2.  It dynamically loads each `.conf` file from `/etc/kvirtio/clusters/`, inheriting its specific thresholds and node list.
3.  It checks CPU and RAM metrics via SSH.
4.  **Alarm Thresholds**: Defined per cluster in the configuration file (e.g., `CPU_THRESHOLD` and `RAM_THRESHOLD`).
5.  If the load exceeds one of the thresholds, the script increments the `COUNT` value inside the node-specific state file:
    `/tmp/kvirtio_host_state_${CLUSTER_NAME}_${node}`
6.  If the thresholds are exceeded for **3 consecutive checks** (or the value set in `CONSECUTIVE_LIMIT`):
    *   The node's status for that cluster is marked as `overloaded`.
    *   The following command is executed on the remote KVM node:
        ```bash
        sudo crm_attribute --node [NODE_NAME] --name status-load --update 'overloaded'
        ```
7.  Once the load returns below the thresholds:
    *   The `COUNT` counter is reset to `0`.
    *   If the saved state was `overloaded`, it is restored to `healthy` by executing:
        ```bash
        sudo crm_attribute --node [NODE_NAME] --name status-load --update 'healthy'
        ```

---

## 📈 Metric Collection Methodology

Metrics are efficiently gathered by reading `/proc/stat` (CPU differential calculation with `sleep 0.5`) and `/proc/meminfo` (RAM calculation based on `MemAvailable` and `MemTotal`) via SSH as the `kvirtwatch` user.

---

## 🪵 Log Tracking (Syslog)
All host monitoring logs include the `[CLUSTER_NAME]` tag in the message to facilitate filtering and aggregation on centralized logging systems:

*   **Monitoring Started (Info)**:
    `INFO: Starting host monitoring for cluster: cluster_db (5 nodes).`
*   **Persistent Threshold Exceeded (Critical)**:
    `CRITICAL: [cluster_db] Node node1 overloaded for 3 checks (CPU: 89%, RAM: 92%). Set to 'overloaded'.`
*   **Normal Limits Restored (Info)**:
    `INFO: [cluster_db] Node node1 returned within parameters (CPU: 45%, RAM: 72%). Set to 'healthy'.`
*   **Connection Error (Error)**:
    `ERROR: [cluster_db] Unable to contact node node3.`
