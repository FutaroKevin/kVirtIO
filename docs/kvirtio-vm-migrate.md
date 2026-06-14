# Script Documentation: KvirtIO VM Migrator

The **KvirtIO VM Migrator** script is a command-line tool executed on the external management server to perform a live, zero-downtime migration of a virtual machine between hypervisor hosts in the same cluster.

---

## 📋 Functional Description

The script `kvirtio-vm-migrate.sh` coordinates hypervisor-to-hypervisor live migrations. It runs checks on both the source and target hosts, builds the appropriate Libvirt migration flags (supporting RAM compression and custom timeouts), runs the migration command remotely on the source host, verifies successful startup on the destination host, and triggers email notifications.

---

## 🛠️ Command-Line Interface and Usage

### Mandatory Parameters
*   `--cluster <name>`: Target cluster (e.g. `cluster_db`).
*   `--vm-name <name>`: The VM name to migrate (e.g. `vm-db-prod-01`).
*   `--from <node>`: Source hypervisor node where the VM is currently running (e.g. `node1`).
*   `--to <node>`: Destination hypervisor node for the migration (e.g. `node3`).

### Optional Parameters
*   `--live`: Executes hot migration (active by default).
*   `--compressed`: Enables memory (RAM) compression during transfer, which is highly recommended for database workloads with high memory-dirtying rates.
*   `--timeout <seconds>`: Maximum execution timeout (default: `300` seconds).
*   `--help`: Displays the help message.

### Usage Example
```bash
/usr/local/bin/kvirtio-vm-migrate.sh \
    --cluster cluster_db \
    --vm-name vm-db-prod-01 \
    --from node1 \
    --to node3 \
    --compressed \
    --timeout 600
```

---

## 🏎️ Migration Protocol and Architecture

The migration is handled peer-to-peer using QEMU direct TCP tunneling:
1.  **Orchestration**: The management server issues the migration directive to the source hypervisor via SSH.
2.  **Peer-to-Peer Transfer**: The source hypervisor establishes a direct network channel to the destination hypervisor's libvirtd daemon on a dedicated migration network interface using the `qemu+tcp://[TO_NODE]/system` URI.
3.  **LVM Storage**: The underlying VM storage is hosted on shared cluster storage (FC SAN + LVM Clustered). Therefore, only the CPU state, system registers, and active memory pages are transferred over the network.
4.  **Flags details**:
    -   `--live`: Keeps the VM running during transfer.
    -   `--persistent`: Preserves the VM configuration file on the destination hypervisor.
    -   `--undefinesource`: Removes the VM configuration file from the source hypervisor upon completion.

---

## 🚀 Execution Workflow

1.  **Pre-migration validation**:
    -   Verifies that the VM is currently in a `running` state on the source node.
    -   Verifies that the destination host is reachable via SSH and its `libvirtd` service is operational.
2.  **Migration Trigger**: Runs the migration command on the source host within a shell `timeout` constraint.
3.  **Post-migration validation**:
    -   Pauses for 2 seconds.
    -   Queries the target host to verify the VM's state is `running`.
4.  **SMTP Alerts**: Senders a success or failure notification email with diagnostic logs (VLAN, RAM availability, and libvirtd status checks).
