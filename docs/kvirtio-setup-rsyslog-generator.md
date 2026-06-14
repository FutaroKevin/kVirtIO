# Script Documentation: KvirtIO Rsyslog Configuration Generator

The **KvirtIO Rsyslog Configuration Generator** script dynamically builds rsyslog receiver rules on the management server to sort incoming remote logs from KVM compute nodes into distinct log files using a specific naming convention.

---

## 📋 Functional Description

The script `kvirtio-setup-rsyslog-generator.sh` parses all cluster config files (`*.conf`) in `/etc/kvirtio/clusters/` to determine the list of hostnames belonging to each cluster. It then generates an rsyslog configuration file (`/etc/rsyslog.d/30-kvirtio-receiver.conf`) containing conditional routing blocks for each node to ensure log isolation.

---

## 📈 Process Logic

1.  **Validation**: Ensures that the configuration directory `/etc/kvirtio/clusters` exists.
2.  **Initialize Receiver**: Writes the core UDP/TCP module loading configurations to the output file `/etc/rsyslog.d/30-kvirtio-receiver.conf`.
3.  **Read Clusters**: Loops over each configuration file, sources the bash array `NODES` and variable `CLUSTER_NAME`, and loops through the nodes.
4.  **Write Rule Blocks**: For each node, it appends rsyslog configuration blocks matching the node hostname:
    -   **Pacemaker/Corosync** logs (`pacemakerd`, `crmd`, `pengine`, `corosync`) are sent to `/var/log/kvirtio/pacemaker-[cluster]-[node].log`.
    -   **KVM/QEMU/Libvirt** logs (`libvirtd`, `qemu`, `qemu-kvm`, `qemu-system-x86_64`) are sent to `/var/log/kvirtio/kvm-[cluster]-[node].log`.
    -   **Audit** logs (`audisp-syslog`, `auditd`) are sent to `/var/log/kvirtio/audit-[cluster]-[node].log`.
    -   A `stop` rule is appended to prevent these logs from spilling over into `/var/log/messages`.
5.  **Output Confirm**: Confirms generation on completion. System administrators must restart `rsyslog` to apply the changes.

---

## 📄 Output Configuration Example

**Output path**: `/etc/rsyslog.d/30-kvirtio-receiver.conf`

**Example snippet**:
```rsyslog
# =========================================================
# File generato dinamicamente da kVirtIO Rsyslog Generator
# =========================================================
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")

# Regole per il nodo node1 (Cluster: cluster_db)
if $hostname == 'node1' then {
    if $programname == ['pacemakerd', 'crmd', 'pengine', 'corosync'] then { 
        action(type="omfile" file="/var/log/kvirtio/pacemaker-cluster_db-node1.log") 
        stop 
    }
    if $programname == ['libvirtd', 'qemu', 'qemu-kvm', 'qemu-system-x86_64'] then { 
        action(type="omfile" file="/var/log/kvirtio/kvm-cluster_db-node1.log") 
        stop 
    }
    if $programname == ['audisp-syslog', 'auditd'] then { 
        action(type="omfile" file="/var/log/kvirtio/audit-cluster_db-node1.log") 
        stop 
    }
}
```

---

## ⚙️ How to Run

1.  Whenever a cluster configuration or node list changes:
    ```bash
    sudo /usr/local/bin/kvirtio-setup-rsyslog-generator.sh
    ```
2.  Restart the rsyslog service:
    ```bash
    sudo systemctl restart rsyslog
    ```
