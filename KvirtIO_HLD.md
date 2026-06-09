# KvirtIO: High-Level Design
**Enterprise Virtualization Platform for High-Throughput Service Providers**

---

## 1. Executive Summary & Project Objectives

### 1.1 Vision and Introduction
The **KvirtIO** project defines the architecture of an Enterprise-class virtualization platform designed for extremely high I/O density and high availability (HA) scenarios, intended to host mission-critical workloads (e.g. transactional databases, high-throughput ERP systems, high-frequency messaging systems).

Unlike traditional commercial virtualization solutions, KvirtIO adopts a technology stack built entirely on native, enterprise-grade open-source components using **SUSE Linux Enterprise Server (SLES)**, ensuring complete control over the data plane and control plane, freedom from vendor lock-in, and near-bare-metal performance through rigorous hardware-software optimization.

```mermaid
graph TD
    subgraph Management & Control Plane [Dedicated External Management Infrastructure]
        MGT_SRV[Orchestrator & Dynamic Watcher]
        MON_SRV[Internal Scripts/MRTG/Zabbix]
    end

    subgraph KvirtIO 5-Node Compute Cluster
        N1[Host Node 1<br/>SLES KVM]
        N2[Host Node 2<br/>SLES KVM]
        N3[Host Node 3<br/>SLES KVM]
        N4[Host Node 4<br/>SLES KVM]
        N5[Host Node 5<br/>SLES KVM]
    end

    subgraph Network Planes
        NET_MGMT[Management VLAN / Corosync / iDRAC<br/>1GbE/10GbE]
        NET_PROD_LM[Production & Live Migration VLAN<br/>LACP Bonding 2x 25GbE]
    end

    subgraph Storage Area Network SAN
        SAN_SWITCH[Dual SAN Switch FC 32Gb]
        SBD_LUN[(Witness LUN SBD<br/>100 MB)]
        DATA_LUNS[(Storage Pool LUNs<br/>8x 2TB Multipath)]
    end

    %% Network Connections
    MGT_SRV --> NET_MGMT
    MON_SRV --> NET_MGMT
    N1 & N2 & N3 & N4 & N5 -- 25/10Gbe Port  --> NET_MGMT
    N1 & N2 & N3 & N4 & N5 -- 25/10Gbe --> NET_PROD_LM

    %% Storage Connections
    N1 & N2 & N3 & N4 & N5 -- FC HBA Dual Port --> SAN_SWITCH
    SAN_SWITCH --> SBD_LUN
    SAN_SWITCH --> DATA_LUNS
```

### 1.2 Key Project Objectives
*   **Zero Resource Contention (No Overcommit & No Swap)**: Deterministic allocation of physical resources (RAM and CPU) to prevent "noisy neighbor" phenomena and guarantee ultra-low, predictable response times.
*   **I/O Parallelism**: Optimization of the data path from the hypervisor to the 32Gb Fibre Channel SAN storage, overcoming the traditional limitations of SCSI queues (`lun_queue_depth`) through logical segmentation and blk-mq.
*   **Deterministic Dual-Level Fencing**: Absolute prevention of split-brain and data corruption on shared volumes through multi-level physical and storage-based STONITH policies.
*   **Control Plane Decoupling**: Isolation of monitoring, telemetry, and load balancing logic outside the Compute Cluster to preserve the stability of the hypervisor hosts.

---

## 2. Node Architecture (Compute)

The KvirtIO cluster consists of at least **3 homogeneous physical nodes** configured with SUSE Linux Enterprise Server (SLES) optimized for the KVM Hypervisor role.

### 2.1 Recommended Hardware Profile per Node
To ensure homogeneity and support live migration without performance degradation, each node adopts the following configuration:
*   **CPU**: Dual Socket Intel Xeon Scalable Platinum or high core-count AMD EPYC (e.g. AMD EPYC 9354, 32 cores, 3.25GHz).
*   **RAM**: 1TB or 2TB DDR5 ECC Registered.
*   **HBA**: Emulex or QLogic Dual-Port 32Gb Fibre Channel.
*   **NIC**: Dual-Port 25GbE SFP28 for production traffic and live migration; Dual-Port 10GbE RJ45 for management and cluster heartbeat.
*   **Out-of-Band**: Dell iDRAC9 Enterprise (or equivalent HPE iLO 6) with a dedicated 1GbE network interface.

### 2.2 Critical SWAP Requirement: Zero Swap Policy (vm.swappiness = 0)
In enterprise virtualization systems operating with "IOIntensive" workloads (such as transactional databases), the latency induced by disk access for host memory paging is destructive. If the host swaps out portions of RAM belonging to a virtual machine, the guest system will suffer a temporary stall or a sudden drop in I/O throughput, often interpreted by applications as a crash.

For this reason, the KvirtIO architecture mandates the **complete disabling of the swap partition** on all hypervisor nodes.

#### Kernel Hardening Configuration on SLES
During the SLES operating system installation phase:
1.  **Partition exclusion**: No swap partition is created on the host's local disks (typically configured in hardware RAID 1 on two SSDs/NVMe drives for the OS only).
2.  **Removal from `/etc/fstab`**: If present, any reference to swap must be removed.
3.  **Kernel parameter tuning (`sysctl`)**:
    Create the file `/etc/sysctl.d/99-kvirtio-memory.conf` with the following parameters:
    ```ini
    # Disable paging aggressiveness in favor of memory reclaim
    vm.swappiness = 0
    
    # Prevent unconstrained memory overcommit, ensuring real allocations
    vm.overcommit_memory = 2
    vm.overcommit_ratio = 90
    
    # Force kernel panic on out-of-memory (OOM) instead of randomly killing vm processes
    vm.panic_on_oom = 1
    kernel.panic = 10
    ```

4.  **Hot disabling**:
    ```bash
    swapoff -a
    ```

### 2.3 Native SLES Software Components for Virtualization
The virtualization layer relies on native packages from the SLES Virtualization channel:
*   **KVM (Kernel-based Virtual Machine)**: Linux kernel module (`kvm_intel` or `kvm_amd`) that transforms the kernel into a Type 1 hypervisor.
*   **QEMU (Quick Emulator)**: SLES-optimized version (`qemu-kvm` or `qemu-system-x86_64`) for hardware emulation and hardware-accelerated guest code execution via `/dev/kvm`.
*   **Libvirt**: The management daemon (`libvirtd.service`) and associated tool suite (`virsh`, XML API) for VM lifecycle management.

#### Libvirt/QEMU Tuning for IOIntensive VMs
The XML definition of virtual machines on KvirtIO must include optimization of the disk controller and memory via Hugepages:

```xml
<domain type='kvm'>
  <name>kvirtio-vm-db01</name>
  <memory unit='KiB'>268435456</memory> <!-- 256 GB -->
  <currentMemory unit='KiB'>268435456</currentMemory>
  <memoryBacking>
    <!-- Mandatory use of 1GB static Hugepages pre-allocated on the host -->
    <hugepages>
      <page size='1048576' unit='KiB'/>
    </hugepages>
    <locked/>
  </memoryBacking>
  <vcpu placement='static'>32</vcpu>
  <cpu mode='host-passthrough'>
    <topology sockets='2' dies='1' cores='16' threads='1'/>
    <numa>
      <cell id='0' cpus='0-15' memory='134217728' unit='KiB' memAccess='shared'/>
      <cell id='1' cpus='16-31' memory='134217728' unit='KiB' memAccess='shared'/>
    </numa>
  </cpu>
  <devices>
    <!-- Optimized SCSI controller with multiqueue enabled -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='32' iothread='1'/>
    </controller>
    <!-- Disk configuration based on lvmlockd (see Section 3) -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='/dev/vg_iointensive/lv_vm_db01'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
  </devices>
</domain>
```

---

## 3. Storage Topology & I/O Optimization

"IOIntensive" workloads require a storage infrastructure with low transit latency and high parallel IOPS capacity. The KvirtIO architecture relies on a **32Gb Fibre Channel (FC) SAN** in fully redundant mode.

### 3.1 The I/O Queue Depth Limitation (lun_queue_depth)
In Linux operating systems, every block device scanned by the kernel (including multipath-mapped external LUN paths) has an I/O queue managed by the SCSI driver. The `lun_queue_depth` parameter (typically set to 32 or 64 depending on the HBA) determines how many concurrent I/O requests can be sent to that specific LUN before the kernel starts queuing subsequent requests in host OS memory.

If a single large LUN (e.g. 16TB) is assigned to a high-load database virtual machine, all of the VM's I/O threads will compete on the same single SCSI queue. This creates a **systemic bottleneck** at the host driver (HBA) level, saturating the queue depth even when the underlying storage array still has physical bandwidth available.

### 3.2 Multi-LUN & blk-mq Stripe Strategy
To overcome this limitation, KvirtIO mandates a configuration in which every "IOIntensive" virtual machine is backed by a **Logical Volume (LV) distributed (striped) across a minimum of 8 separate physical LUNs**.

#### Architectural Example: 16TB Allocation per VM
Instead of presenting a single 16TB LUN, the Storage Administrator allocates **8 LUNs of 2TB each** on the FC SAN.
*   Each individual LUN has its own independent SCSI queue at the SLES host kernel level.
*   This yields a total queue depth of $8 \times$ `lun_queue_depth` per individual LUN (e.g. $8 \times 64 = 512$ parallel commands).
*   The SLES kernel, leveraging the multiqueue block layer subsystem (**blk-mq**), distributes I/O queue computation across different CPU cores, eliminating software locks internal to the host.

```
                  +-------------------------------------------------+
                  |                Virtual Machine                  |
                  |         (Guest OS - Write/Read IOPS)             |
                  +-------------------------------------------------+
                                           |  (virtio-scsi MultiQueue)
                                           v
                  +-------------------------------------------------+
                  |       Striped Logical Volume (LVM) on Host      |
                  |           /dev/vg_iointensive/lv_vm_db01        |
                  +-------------------------------------------------+
                     /       /       /     |     \       \       \
                    /       /       /      |      \       \       \
                   v       v       v       v       v       v       v
                 [LUN1]  [LUN2]  [LUN3]  [LUN4]  [LUN5]  [LUN6]  [LUN7]  [LUN8] (Each LUN = 2TB)
                 Depth64 Depth64 Depth64 Depth64 Depth64 Depth64 Depth64 Depth64
                   |       |       |       |       |       |       |       |
                   +-------+-------+-------+-------+-------+-------+-------+--> [SAN 32Gb FC]
                                           Total Queue Depth = 512
```

### 3.3 Shared Volume Management: Cluster LVM (lvmlockd & dlm)
Since virtual machines must be able to live-migrate from one node to another, all cluster nodes must simultaneously see the storage LUNs. However, uncontrolled simultaneous access to an LVM Volume Group (VG) from multiple hosts would immediately cause corruption of LVM metadata.

KvirtIO adopts **lvmlockd** (LVM lock daemon) integrated with the **DLM (Distributed Lock Manager)** of SLES. This stack replaces the legacy `clvmd` daemon.

#### Volume Locking Operation
1.  **DLM**: Manages lock coordination between nodes over the network through the Pacemaker/Corosync cluster manager.
2.  **lvmlockd**: Receives LVM metadata allocation or modification requests and validates them through DLM.
3.  When a VM is started on Node 1, `lvmlockd` acquires an exclusive lock (write lock) on the VM's Logical Volume. Other nodes can see the volume but cannot write to it or start it, ensuring safety.
4.  During Live Migration, the lock is atomically released by Node 1 and acquired by Node 2, coordinated by Pacemaker.

#### Storage Configuration Workflow on SLES Host
1.  **DLM Initialization**: Ensure the DLM service is integrated into the Pacemaker cluster.
2.  **LVM Configuration**: Enable `locking_type = 1` and set `use_lvmlockd = 1` in `/etc/lvm/lvm.conf`.
3.  **Create Physical Volumes (PV)** on the 8 multipath LUNs (e.g. `/dev/mapper/mpatha` through `/dev/mapper/mpathh`):
    ```bash
    pvcreate /dev/mapper/mpatha /dev/mapper/mpathb /dev/mapper/mpathc /dev/mapper/mpathd \
             /dev/mapper/mpathe /dev/mapper/mpathf /dev/mapper/mpathg /dev/mapper/mpathh
    ```
4.  **Create the Cluster Volume Group**:
    Use the `--lock-type dlm` flag to instruct LVM to delegate locks to the cluster:
    ```bash
    vgcreate --lock-type dlm vg_iointensive \
             /dev/mapper/mpatha /dev/mapper/mpathb /dev/mapper/mpathc /dev/mapper/mpathd \
             /dev/mapper/mpathe /dev/mapper/mpathf /dev/mapper/mpathg /dev/mapper/mpathh
    ```
5.  **Create the Striped Logical Volume**:
    Create the Logical Volume distributing blocks across all 8 physical PVs to maximize queue parallelism:
    ```bash
    lvcreate -i 8 -I 64k -n lv_vm_db01 -L 16T vg_iointensive
    ```
    *   `-i 8`: Number of stripes (matches the number of LUNs/PVs).
    *   `-I 64k`: Stripe unit size (64 KB is optimal for most relational databases).

---

## 4. High Availability, Fencing & Quorum (STONITH)

The high availability of the 5-node KvirtIO cluster is entirely orchestrated by the **High Availability Enterprise Extension** stack of SLES, based on Pacemaker (the cluster manager) and Corosync (the internal communication engine).

### 4.1 Pacemaker & Corosync
*   **Corosync**: Manages low-latency messaging (heartbeat) between nodes and detects connectivity loss. In the 5-node KvirtIO cluster, the minimum quorum required for correct operation is **3 active nodes** ($\text{Quorum} = \lfloor N/2 \rfloor + 1$).
*   **Pacemaker**: Continuously monitors the state of nodes and virtual resources (VMs defined via the `ocf:heartbeat:VirtualDomain` resource agent). In the event of a hardware failure on a node, Pacemaker decides on which of the remaining nodes to restart the affected VMs.

### 4.2 Multi-Level Fencing Configuration (STONITH)
In shared-storage architectures (FC SAN) with clustered LVM, the worst imaginable scenario is a node losing network connectivity without shutting down (split-brain scenario). If two nodes believe they are the sole survivors and attempt to write simultaneously to the same Logical Volume, **irreversible filesystem or database corruption** occurs.

To prevent this scenario, Pacemaker enforces the **STONITH (Shoot The Other Node In The Head)** mechanism. The KvirtIO architecture implements a **two independent levels** system, guaranteeing that an unresponsive node is physically and electrically isolated before its VMs are started elsewhere.

```
                        +---------------------------+
                        |      Node to be Fenced    |
                        +---------------------------+
                                      |
              +-----------------------+-----------------------+
              |                                               |
              v (Level 1: Out-of-Band Network)               v (Level 2: Witness SAN)
     +-----------------+                             +-----------------+
     |   fence_idrac   |                             |    SBD Daemon   |
     +-----------------+                             +-----------------+
              |                                               |
              | (IPMI/OOB Command)                            | (Missed Heartbeat/Mailbox)
              v                                               v
     [Power Off Chassis]                            [Hardware Watchdog]
              |                                               |
              +-----------------------+-----------------------+
                                      |
                                      v
                             [Node Off/Reset]
```

#### Level A: Physical Fencing (fence_idrac)
*   **Agent**: `fence_idrac` (based on Redfish or IPMI protocol over the out-of-band network).
*   **Operation**: In case of node non-response via Corosync, Pacemaker sends a direct command to the iDRAC card of the target node to request an **immediate hard electrical reset (poweroff / powercycle)**.
*   This operation guarantees the deactivation of the node at the hardware level.

#### Level B: Storage / Witness Fencing (SBD - Storage-based Death)
In the event of a partial management network failure that makes it impossible to contact both the host and the iDRAC card, the **SBD** mechanism kicks in.
*   **Witness LUN**: A dedicated **100MB** LUN is created on the Fibre Channel SAN (shared among all 5 nodes). This LUN does not host a filesystem and is initialized for exclusive use by SBD.
*   **Hardware Watchdog**: Each node must have an active system watchdog module at the kernel level (e.g. `iTCO_wdt` for Intel hardware or `/dev/watchdog`).
*   **Operation**:
    1.  The `sbd` daemon running on each host continuously writes a heartbeat to the shared LUN and polls its reserved "mailbox" on the same LUN.
    2.  If Pacemaker determines that Node 3 is isolated and unreachable via network, it writes a "fencing target" message into Node 3's mailbox on the SBD LUN.
    3.  Node 3's `sbd` daemon reads the fencing message on the LUN (since the 32Gb FC path is still active) and performs an **immediate node self-fence** via the Linux watchdog-controlled hardware reset, completely bypassing the IP network and the software shutdown stack.
    4.  If the `sbd` daemon stops writing or hangs, the hardware watchdog no longer receives the "keep-alive" signal and forcibly restarts the physical machine after a few seconds.

### 4.3 Prohibition of Custom Scripts
The use of custom scripts or application-level mechanisms operating at the guest level (e.g. ping inside the VM, software agents inside the guest OS) to trigger fencing or forced host migration is strictly forbidden. The engineering reasons are:
*   **Cascading Failures**: A network failure at the VM level (e.g. a disruption on a guest production switch) does not necessarily reflect a health problem on the hypervisor host. Fencing the host would cause an unnecessary restart of all other healthy VMs hosted on the same node.
*   **False Positives**: High application load inside a VM could delay the responses of a custom monitoring script, generating false positives with consequent cyclical reboots (fencing loops).
*   **State Inconsistency**: Only the cluster manager (Pacemaker) has a global view of resource state and shared storage topology. Only Pacemaker can safely and coordinately decide on node isolation.

---

## 5. Control Plane & External Orchestration

The cornerstone principle of the KvirtIO design is **plane separation**. Hypervisor hosts must dedicate their CPU cycles, memory, and storage I/O exclusively to computing customer virtual machines.

### 5.1 Externalization of the Control Plane and Watchers
All software components that are not critical for the direct execution of the data plane must reside on a management infrastructure (Management Plane) that is physically and logically decoupled:
*   **Monitoring and Log Collection**: Metric export daemons (e.g. `prometheus-node-exporter`, `libvirt-exporter`) run on KVM hosts with minimum CPU priority (`nice` set to high values) and send data to an external Prometheus/Grafana cluster.
*   **Dynamic Balancer & Capacity Management**: Any predictive load analysis scripts or daemons responsible for dynamic resource balancing (e.g. custom DRS that invokes live migration APIs via `virsh` based on host CPU usage) must run outside the KVM cluster (on VMs or servers dedicated to management). These watchers query the `libvirt` API remotely (via TLS-encrypted connection) and make the necessary calls without burdening the hypervisor host kernels.

### 5.2 Network Topology and Segregation
The KvirtIO cluster network is structured to strictly isolate traffic flows on separate physical interfaces and logical interfaces (VLANs).

#### Logical Network Connection Schema per Node
```
                         +-----------------------------------+
                         |             Host Node             |
                         +-----------------------------------+
                           /                               \
        (Dual 10GbE PCI-e) /                                 \ (Dual 25GbE LACP Bond)
                          /                                   \
  +--------------------------------+                 +--------------------------------+
  |  Physical Intf.: eth0 / eth1   |                 |   Physical Intf.: ens1 / ens2  |
  +--------------------------------+                 +--------------------------------+
     |             |             |                      |                          |
     v             v             v                      v                          v
  [VLAN 10]     [VLAN 11]     [OOB IP]               [VLAN 20]                  [VLAN 30+]
  Management   Corosync HB     iDRAC                  Live Migration             VM Prod Traffic
  (SSH/API)    (Multicast)   (Fencing)               (Uncapped)                 (VLAN Trunking)
```

1.  **Management / Cluster Network (Dual 10GbE / Separate Physical Interfaces)**:
    *   **VLAN 10 - Management**: Traffic for remote administration via SSH, `libvirt` API calls, and monitoring.
    *   **VLAN 11 - Corosync Heartbeat**: Ultra-low latency channel dedicated exclusively to cluster messaging. Corosync packets must have the highest priority and be configured with dedicated QoS/CoS at the physical switch level.
    *   **OOB Network (iDRAC)**: Physically separate cabled network (on switches dedicated to hardware infrastructure management) for secure access to the iDRAC cards of the 5 physical nodes and for routing STONITH `fence_idrac` commands.

2.  **Production & Live Migration Plane (Dual 25GbE SFP28 in Bonding)**:
    *   The two 25GbE interfaces are configured in **LACP Bonding (Mode 4)** at the host OS level (using the SLES kernel `bonding` module) to ensure redundancy and bandwidth aggregation.
    *   The link aggregation configuration uses the L3+L4 hashing policy (`xmit_hash_policy = layer3+4`) to optimize TCP network flow distribution.
    *   Two types of traffic are attached to the logical bond via VLAN tagging:
        *   **VLAN 20 - Live Migration**: Dedicated exclusively to the transit of virtual machine RAM during hot migration processes between hosts. This network requires maximum available throughput without software caps, to complete the memory page transfer in the shortest possible time and avoid VM performance degradation during the "dirtying phase".
        *   **VLAN 30+ - VM Production**: VLANs trunked directly into virtual machines via host virtual switches (e.g. Linux Bridges or Open vSwitch) to enable network connectivity for the application services provided by the VMs.

---

## 6. Architectural Decision Matrix and Engineering Rationale

| Component | Technology Choice | Excluded Alternative | Engineering Rationale |
| :--- | :--- | :--- | :--- |
| **Hypervisor** | Native KVM (SLES) | VMware ESXi / Hyper-V | Full control of the Linux stack, reduced licensing costs, direct integration with the SLES Enterprise kernel and ease of automation via Libvirt API. |
| **Swap Management** | Statically disabled + `vm.swappiness=0` | Active swap on fast disk (SSD) | Eliminates the risk of spurious latencies induced by the host paging memory allocated to virtual machines. RAM must be deterministic. |
| **Storage Topology** | Multi-LUN Striped (8 LUNs of 2TB for a 16TB VM) | Single 16TB LUN | Parallelization of queues at the host kernel level. Moves from a single queue depth (e.g. 64) to an aggregated multipath queue (512) leveraging blk-mq. |
| **Volume Locking** | `lvmlockd` + `dlm` | Legacy `clvmd` | Greater resilience, better management of modern Pacemaker clusters, elimination of clvmd single-point-of-failure in case of cluster freeze. |
| **Fencing Level 1** | `fence_idrac` (OOB) | Fencing via VM network | Guarantees a clean electrical reset of the node at the hardware level, independent of the host OS state. |
| **Fencing Level 2** | SBD (Witness LUN + Watchdog) | Network ping script | Provides a quorum and self-isolation channel (host suicide) via hardware watchdog operating directly on the SAN FC storage bus, immune to IP network failures. |
| **Live Migration Network** | Dedicated 2x25GbE Bonded network | Shared with Management network | Prevents saturation of cluster communication channels (Corosync) during the massive RAM transfer of large VMs (256GB+), reducing the transient block duration (migration downtime). |