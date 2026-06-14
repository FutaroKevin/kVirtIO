# Script Documentation: KvirtIO VM Creator

The **KvirtIO VM Creator** script is a command-line utility executed exclusively on the external management server to define, register, and start a virtual machine on a KVM hypervisor node in a specified cluster.

---

## 📋 Functional Description

The script `kvirtio-vm-create.sh` orchestrates virtual machine provisioning from the management plane. It accepts hardware parameters, applies optimized Libvirt XML profiles based on the VM workload type (transitional database vs. generic service), connects via SSH to the destination hypervisor, registers the VM definition via `virsh define`, starts the VM, and enables autostart. It also triggers SMTP status alerts.

---

## 🛠️ Command-Line Interface and Usage

### Mandatory Parameters
*   `--cluster <name>`: Target cluster (e.g. `cluster_db`).
*   `--node <name>`: Destination hypervisor node in the cluster (e.g. `node1`).
*   `--vm-name <name>`: Unique identifier for the VM (e.g. `vm-db-prod-01`).
*   `--profile <name>`: Workload optimization profile: `iointensive` or `general`.
*   `--vcpu <n>`: Number of vCPUs to allocate.
*   `--ram-gb <n>`: RAM allocation in Gigabytes.
*   `--disk-lv <path>`: Absolute path to the pre-created LVM Logical Volume (e.g. `/dev/vg_iointensive/lv_vm_db01`).

### Optional Parameters
*   `--network <vlan>`: VLAN tag for network bridging (default: `30`).
*   `--help`: Displays the help message.

### Usage Example
```bash
/usr/local/bin/kvirtio-vm-create.sh \
    --cluster cluster_db \
    --node node1 \
    --vm-name vm-db-prod-01 \
    --profile iointensive \
    --vcpu 32 \
    --ram-gb 256 \
    --disk-lv /dev/vg_iointensive/lv_vm_db01 \
    --network 30
```

---

## ⚙️ Workload Profiles Detail

### 1. `iointensive` Profile (Database Optimized)
-   **Disk Controller**: Model `virtio-scsi` with multi-queue support (number of queues matches allocated vCPUs) and dedicated `iothread`.
-   **Disk Driver**: Raw disk block access with `cache='none'` and `io='native'` for direct physical LVM I/O bypass.
-   **Memory**: Ballooning is completely disabled (`<memballoon model='none'/>`) to lock memory allocations on the hypervisor.
-   **NUMA Tuning**: Automatic memory binding configured (`<numatune><memory mode='strict' placement='auto'/></numatune>`).

### 2. `general` Profile (General Purpose)
-   **Disk Controller**: Standard direct `virtio` bus layout.
-   **Disk Driver**: Disk caching set to `cache='writeback'` for host page-cache caching.
-   **Memory**: Standard VirtIO balloon driver enabled with stats collection active (`period='10'`).

---

## 🚀 Execution Workflow

1.  **Arguments validation**: Ensures all required arguments are provided and valid.
2.  **Configuration Check**: Loads target cluster configuration (`/etc/kvirtio/clusters/<cluster>.conf`) and verifies that the destination node is part of the cluster.
3.  **XML Compilation**: Generates a standard q35 machine Libvirt domain configuration matching the chosen profile parameters.
4.  **Remote Definition**: Writes the XML code to a remote temporary file on the target node, calls `sudo virsh define`, and deletes the temporary XML file.
5.  **Start and Autostart**: Launches the virtual machine (`sudo virsh start`) and sets the Libvirt autostart flag (`sudo virsh autostart`).
6.  **Notification**: Triggers a notification email on success or failure.
