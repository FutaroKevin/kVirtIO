# Service Documentation: KvirtIO I/O Watcher

The **KvirtIO I/O Watcher** service monitors the latency of multipath disks (`dm-*`) associated with virtual machines with the "IOIntensive" profile on the nodes of all clusters defined in `/etc/kvirtio`.

---

## 📋 Functional Description
The watcher cyclically scans all `.conf` files inside the `/etc/kvirtio/clusters/` directory at each execution (every **1 minute**). For each loaded cluster, it queries the nodes using `iostat` to identify bottlenecks and abnormal latencies on the Fibre Channel storage paths.

### Logic Control Flow
1.  The script runs every minute.
2.  It finds all configured clusters in `/etc/kvirtio/clusters/*.conf`.
3.  It loads the parameters of the individual cluster (node list and specific latency threshold `LATENCY_THRESHOLD`).
4.  It connects via SSH to each host.
5.  It runs `sudo iostat -dx 1 2` and analyzes the output of the second report for `dm-*` (multipath) devices.
6.  It isolates the maximum response latency value (`await`).
7.  If the latency exceeds the cluster threshold (e.g., `10.0` ms for `cluster_db`), it writes a syslog `WARNING` log containing the specific cluster tag.

---

## 📈 I/O Analysis Methodology (iostat & AWK)
The analysis is performed by capturing the output of `iostat` on the hypervisor node and processing it locally on the management server using a high-efficiency AWK pipeline. This prevents wasting CPU cycles on production KVM nodes and guarantees correct conversion of decimal separators (e.g., European commas `,` are converted to dots `.`).

---

## 🪵 Log Tracking (Syslog)
Logs sent to syslog via `logger` include the cluster prefix `[CLUSTER_NAME]` to allow selective filtering:

*   **Monitoring Started (Info)**:
    `INFO: Starting I/O monitoring for cluster: cluster_db (5 nodes).`
*   **Threshold Exceeded (Warning)**:
    `WARNING: [cluster_db] Abnormal I/O latency on node node2. Max await found on multipath: 14.52ms (Threshold: 10.0ms).`
*   **Execution Error (Error)**:
    `ERROR: [cluster_db] Unable to collect I/O metrics from node5.`
