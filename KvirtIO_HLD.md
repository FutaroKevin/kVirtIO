# KvirtIO: High-Level Design
**Enterprise Virtualization Platform for High-Throughput Service Providers**

---

## 1. Executive Summary & Project Objectives

### 1.1 Introduction and Vision
The **KvirtIO** project defines the architecture of an Enterprise-grade virtualization platform designed for extreme I/O-density and high availability (HA) scenarios, intended to host mission-critical workloads (e.g. transactional databases, high-throughput ERP, high-frequency messaging systems).

Unlike traditional commercial virtualization solutions, KvirtIO adopts a technology stack built entirely on native and open-source components available in **SUSE Linux Enterprise Server (SLES)**, ensuring full control over the data plane and control plane, freedom from vendor lock-in, and near bare-metal performance through rigorous hardware-software optimization.

```mermaid
graph TD
    subgraph Management & Control Plane [Dedicated External Management Infrastructure]
        MGT_SRV[Orchestrator & Dynamic Watcher]
        MON_SRV[Custom Script/MRTG/Zabbix]
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
        SBD_LUN[(SBD Witness LUN<br/>100 MB)]
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
*   **I/O Parallelism**: Optimization of the data path from the hypervisor to the storage on a 32Gb Fibre Channel SAN, overcoming the traditional limits of SCSI queues (`lun_queue_depth`) through logical segmentation and blk-mq.
*   **Deterministic Dual-Level Fencing**: Absolute prevention of split-brain and data corruption on shared volumes through multi-level physical and storage-based STONITH policies.
*   **Control Plane Decoupling**: Isolation of monitoring, telemetry, and load-balancing logic outside the Compute Cluster to preserve the stability of the hypervisor hosts.

---

## 2. Node Architecture (Compute)

The KvirtIO cluster consists of at least **3 homogeneous physical nodes** (heterogeneous nodes have not been tested) configured with SUSE Linux Enterprise Server (SLES) optimized for the KVM Hypervisor role.

### 2.1 Recommended Hardware Profile per Node
To ensure homogeneity and support live migration without performance degradation, each node adopts the following configuration:
*   **CPU**: Dual Socket Intel Xeon Scalable Platinum or high-core-count AMD EPYC (e.g. AMD EPYC 9354, 32 cores, 3.25GHz).
*   **RAM**: 1TB or 2TB DDR5 ECC Registered.
*   **HBA**: Emulex or QLogic Dual-Port 32Gb Fibre Channel.
*   **NIC**: Dual-Port 25GbE SFP28 for production traffic and live migration; Dual-Port 10GbE RJ45 for management and cluster heartbeat (Dual-Port 1GbE could also be used since it carries management traffic only).
*   **Out-of-Band**: Dell iDRAC9 Enterprise (or equivalent HPE iLO 6) with a dedicated 1GbE network interface.

### 2.2 Critical Requirement SWAP: Zero Swap Policy (vm.swappiness = 0)
In enterprise virtualization systems running "IOIntensive" workloads (such as transactional databases), the latency introduced by disk access for host memory paging is destructive. If the host swaps out portions of RAM belonging to a virtual machine, the guest system will experience a temporary freeze or a sudden I/O throughput drop, often interpreted by applications as a crash.

For this reason, the KvirtIO architecture mandates the **total disabling of the swap partition** on all hypervisor nodes.

#### Configuration and Hardening on the SLES Kernel
During the SLES operating system installation phase:
1.  **Partition exclusion**: No swap partition is created on the host's local disks (typically configured in hardware RAID 1 on two SSDs/NVMe for the OS only).
2.  **Removal from `/etc/fstab`**: If present, any reference to swap must be removed.
3.  **Kernel parameter tuning (`sysctl`)**:
    Create the file `/etc/sysctl.d/99-kvirtio-memory.conf` with the following parameters:
    ```ini
    # Disables paging aggressiveness in favour of memory reclaim
    vm.swappiness = 0
    
    # Prevents uncontrolled memory overcommit, ensuring real allocations
    vm.overcommit_memory = 2
    vm.overcommit_ratio = 90
    
    # Forces kernel panic on Out-Of-Memory (OOM) instead of randomly killing QEMU processes
    vm.panic_on_oom = 1
    kernel.panic = 10
    ```
4.  **Hot disabling**:
    ```bash
    swapoff -a
    ```
This configuration is necessary in a cluster environment to ensure that, should a node run out of memory, it begins killing QEMU/KVM processes randomly, forcing them to fail over to other cluster nodes rather than degrading silently.

### 2.3 Native SLES Software Components for Virtualization
The virtualization layer relies on the native packages from the SLES Virtualization channel:
*   **KVM (Kernel-based Virtual Machine)**: Linux kernel module (`kvm_intel` or `kvm_amd`) that turns the kernel into a Type 1 hypervisor.
*   **QEMU (Quick Emulator)**: SLES-optimized version (`qemu-kvm` or `qemu-system-x86_64`) for hardware emulation and hardware-accelerated guest code execution via `/dev/kvm`.
*   **Libvirt**: The management daemon (`libvirtd.service`) and the associated toolset (`virsh`, XML API) for managing the VM lifecycle.

#### Libvirt/QEMU Tuning for IOIntensive VMs
The XML definition of virtual machines on KvirtIO must include optimization of the disk controller and memory via Hugepages:

```xml
<domain type='kvm'>
  <name>kvirtio-vm-db01</name>
  <memory unit='KiB'>268435456</memory> <!-- 256 GB -->
  <currentMemory unit='KiB'>268435456</currentMemory>
  <memballoon model='none'/> <!-- must absolutely not be enabled for database systems, only for app server systems -->
  <vcpu placement='auto'>16</vcpu>

  <numatune>
    <memory mode='strict' placement='auto'/>
  </numatune>
</domain>
  <devices>
    <!-- SCSI controller optimized with multiqueue enabled -->
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

### 2.4 Advanced CPU and Memory Optimization (Dynamic Tuning)

In high-density Enterprise scenarios, hardcoding physical resources (e.g. static CPU Pinning) introduces rigidity and risks generating bottlenecks (high *CPU Steal Time*) following Live Migration or failover. KvirtIO adopts a **Dynamic Tuning** approach based on workload classification at the individual VM level.

#### 2.4.1 Hypervisor Host Configuration (Tuned & Numad)
The host operating system delegates kernel optimization and NUMA balancing to standardized native services, avoiding manual GRUB modifications that could break during updates.

*   **Tuned (`virtual-host`)**: The `tuned` profile specific to hypervisors is applied. This optimizes network and disk latency, sets the appropriate I/O scheduler, and reduces the aggressiveness of processor power saving (C-States).
*   **Numad**: The NUMA (Non-Uniform Memory Access) balancing daemon is kept active on the host. It constantly monitors the CPU and physical memory topology.
*   **Transparent HugePages (THP)**: Set globally to `madvise` rather than `always`. Aggressive THP fragments memory and causes micro-freezes (lock latencies) that are unacceptable for databases.

```bash
# On the SLES KVM host
zypper install tuned numad
systemctl enable --now tuned numad
tuned-adm profile virtual-host
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

#### 2.4.2 VM Classification and XML Profiles (Libvirt)
Resource allocation is delegated to the XML file of each individual virtual machine. This allows safe coexistence of heterogeneous workloads on the same node or within the same KvirtIO cluster.

**Profile A: "IOIntensive" (Database / SAP HANA)**

In-memory and relational databases are extremely sensitive to changes in physical topology and do not tolerate dynamic RAM reclamation.

*   **Memory Ballooning Disabled**: Ballooning is absolutely forbidden (`<memballoon model='none'/>`) to prevent guest Kernel Panic or database crash due to Out-Of-Memory (OOM).
*   **Auto-Pinning NUMA**: Delegates to `numad` the dynamic placement of vCPUs and RAM on the same physical node, recalculated instantly at every boot or Live Migration.

*IOIntensive Profile XML Excerpt:*
```xml
<domain type='kvm'>
  <memory unit='GiB'>256</memory>
  <currentMemory unit='GiB'>256</currentMemory>
  <memballoon model='none'/>

  <vcpu placement='auto'>16</vcpu>

  <numatune>
    <memory mode='strict' placement='auto'/>
  </numatune>
</domain>
```

**Profile B: "AppServer" (General Purpose / Web)**

Application virtual machines have fluctuating workloads and can leverage dynamic memory reclaim to increase cluster consolidation density.

*   **Memory Ballooning Active**: The `virtio-balloon` driver allows the guest kernel to return RAM to the host when idle, and allows the host to push the VM towards its configured maximum limit based on load.

*AppServer Profile XML Excerpt:*
```xml
<domain type='kvm'>
  <memory unit='GiB'>64</memory>
  <currentMemory unit='GiB'>16</currentMemory>

  <memballoon model='virtio'> <!-- as mentioned, ballooning is enabled on app server systems -->
    <stats period='10'/>
  </memballoon>

  <vcpu placement='auto'>8</vcpu>
</domain>
```

---

### 2.5 Network Tuning & I/O Optimization (Jumbo Frames & Global AQM)

In a high-density as-a-Service infrastructure with 25GbE or faster physical interfaces, the networking bottleneck shifts from cable capacity to the **PPS (Packets Per Second)** processed by the host CPU (SoftIRQ). To ensure deterministic latencies without imposing complex and costly per-VM bandwidth limits (QoS), KvirtIO adopts a "Global Fabric" approach.

#### 2.5.1 Offloading to Silicon: End-to-End Jumbo Frames (MTU 9000)
To drastically reduce the computational overhead on hypervisor CPUs, the entire network chain (Top of Rack Switch, Physical Interfaces, LACP Bond, and Linux Bridges) must mandatorily operate with **Jumbo Frames (MTU 9000)**.
This reduces by 6x the number of packets processed by the host network stack at equal throughput, shifting the burden of bulk forwarding onto the ASIC chips of the physical switches.

*   **Live Migration Network (VLAN 20):** Benefits enormously from MTU 9000, reducing RAM page transit times and minimizing the VM freeze window.
*   **VM Network (VLAN 30+):** The KvirtIO infrastructure is ready for Jumbo Frames. Customer VMs can use MTU 1500 (handled via Path MTU Discovery) or be configured for MTU 9000 if they require massive throughput between tenants on the same Layer 2.

#### 2.5.2 Hypervisor Optimization: vhost-net and Multi-Queue
To exploit 25GbE cards, the use of **virtio-net multiqueue** in combination with in-kernel **vhost-net** acceleration is mandated.

*   **Multiqueue (`queues='N'`):** The hypervisor is instructed to create *N* receive/transmit queues for the VM's vNIC, allowing the guest operating system to parallelize network interrupts across multiple cores.
*   **vhost-net:** Moves packet processing from QEMU user-space directly into the host Linux kernel, lowering latency.

*Standard XML Excerpt (Without per-VM QoS):*
```xml
<interface type='bridge'>
  <mac address='52:54:00:xx:xx:xx'/>
  <source bridge='br-vlan100'/>
  <model type='virtio'/>
  <driver name='vhost' queues='8' rx_queue_size='1024' tx_queue_size='1024'/>
</interface>
```

#### 2.5.3 Preventing the "Noisy Neighbor": Global Active Queue Management (AQM)
Instead of micro-managing artificial bandwidth limits (Policing) on individual VM XML interfaces, KvirtIO leverages **Active Queue Management (AQM)** policies at the SLES kernel level globally, specifically the **fq_codel** (Fair Queueing Controlled Delay) algorithm.

By applying `fq_codel` as the default queueing discipline (`qdisc`) on the host's physical bond interface:

*   The kernel autonomously identifies "elephant" flows (e.g. large file transfers or backups from a saturating VM) and "mouse" flows (e.g. interactive queries to another VM's database).
*   It interleaves packets, always guaranteeing priority and ultra-low latency to interactive flows, gently penalizing bulk flows only in the event of actual 50Gbps link saturation.
*   **The operational result**: Zero per-VM configurations, zero administrative overhead, and complete immunity to bufferbloat at the hypervisor level.

```bash
# Global setting of fq_codel for all interfaces
sysctl -w net.core.default_qdisc=fq_codel

# Expansion of Ring Buffers on physical interfaces to absorb micro-bursts
ethtool -G eth0 rx 4096 tx 4096
ethtool -G eth1 rx 4096 tx 4096
```

---

## 3. Storage Topology & I/O Optimization

"IOIntensive" workloads require a storage infrastructure with low transit latency and high parallel IOPS capacity. The KvirtIO architecture relies on a fully redundant **32Gb Fibre Channel (FC) SAN**.

### 3.1 The I/O Queue Limit (lun_queue_depth)
In Linux operating systems, every block device scanned by the kernel (including multipath paths mapped from external LUNs) has an I/O queue managed by the SCSI driver. The `lun_queue_depth` parameter (typically set to 32 or 64 depending on the HBA) determines how many concurrent I/O requests can be sent to that specific LUN before the kernel starts queuing subsequent ones in OS-level host memory.

If a single large LUN (e.g. 16TB) is assigned to a high-load database virtual machine, all VM I/O threads will compete on the same single SCSI queue. This creates a **systemic bottleneck** at the host driver (HBA) level, saturating the queue depth even when the underlying storage array still has physical bandwidth available.

### 3.2 Multi-LUN & blk-mq Stripe Strategy
To overcome this limit, KvirtIO mandates a configuration in which every virtual machine with an "IOIntensive" profile resides on a **Logical Volume (LV) striped (distributed) across a minimum of 8 separate physical LUNs**.

#### Architectural Example: 16TB Allocation per VM
Instead of presenting a single 16TB LUN, the Storage Administrator allocates **8 LUNs of 2TB each** on the FC SAN.
*   Each individual LUN has its own independent SCSI queue at the SLES host kernel level.
*   This yields an aggregate queue depth equal to $8 \times$ `lun_queue_depth` of the single LUN (e.g. $8 \times 64 = 512$ parallel commands).
*   The SLES kernel, leveraging the multiqueue block layer subsystem (**blk-mq**), distributes the I/O queue computation load across different CPU cores, eliminating software locks internal to the host.

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
Since virtual machines must be able to live-migrate from one node to another, all cluster nodes must simultaneously see the storage LUNs. However, uncontrolled simultaneous access to an LVM Volume Group (VG) from multiple hosts would immediately cause LVM metadata corruption.

KvirtIO adopts **lvmlockd** (LVM lock daemon) integrated with the **DLM (Distributed Lock Manager)** from SLES. This stack replaces the legacy `clvmd` daemon.

#### Volume Locking Operation
1.  **DLM**: Manages lock coordination between nodes over the network through the Pacemaker/Corosync cluster manager.
2.  **lvmlockd**: Receives LVM metadata allocation or modification requests and validates them through DLM.
3.  When a VM is started on Node 1, `lvmlockd` acquires an exclusive lock (write lock) on the VM's Logical Volume. Other nodes can see the volume but cannot write to it or start it, ensuring safety.
4.  During Live Migration, the lock is atomically released by Node 1 and acquired by Node 2, coordinated by Pacemaker.

#### Storage Configuration Workflow on the SLES Host
1.  **DLM Initialization**: Ensure the DLM service is integrated into the Pacemaker cluster.
2.  **LVM Configuration**: Enable `locking_type = 1` and set `use_lvmlockd = 1` in `/etc/lvm/lvm.conf`.
3.  **Physical Volume (PV) creation** on the 8 multipath LUNs (e.g. `/dev/mapper/mpatha` through `/dev/mapper/mpathh`):
    ```bash
    pvcreate /dev/mapper/mpatha /dev/mapper/mpathb /dev/mapper/mpathc /dev/mapper/mpathd \
             /dev/mapper/mpathe /dev/mapper/mpathf /dev/mapper/mpathg /dev/mapper/mpathh
    ```
4.  **Cluster Volume Group creation**:
    Use the `--lock-type dlm` flag to instruct LVM to delegate locking to the cluster:
    ```bash
    vgcreate --lock-type dlm vg_iointensive \
             /dev/mapper/mpatha /dev/mapper/mpathb /dev/mapper/mpathc /dev/mapper/mpathd \
             /dev/mapper/mpathe /dev/mapper/mpathf /dev/mapper/mpathg /dev/mapper/mpathh
    ```
5.  **Striped Logical Volume creation**:
    The Logical Volume is created by distributing blocks across all 8 physical PVs to maximize queue parallelism:
    ```bash
    lvcreate -i 8 -I 64k -n lv_vm_db01 -L 16T vg_iointensive
    ```
    *   `-i 8`: Number of stripes (matches the number of LUNs/PVs).
    *   `-I 64k`: Stripe unit size (64 KB optimal for most relational DBs).

---

## 4. High Availability, Fencing & Quorum (STONITH)

The high availability of the 5-node KvirtIO cluster is entirely orchestrated by the **High Availability Enterprise Extension** stack from SLES, based on Pacemaker (the cluster manager) and Corosync (the internal communication engine).

### 4.1 Pacemaker & Corosync
*   **Corosync**: Manages low-latency messaging (heartbeat) between nodes and detects connectivity loss. In the 5-node KvirtIO cluster, the minimum quorum required for correct operation is **3 active nodes** ($\text{Quorum} = \lfloor N/2 \rfloor + 1$).
*   **Pacemaker**: Constantly monitors the state of nodes and virtual resources (VMs defined via the `ocf:heartbeat:VirtualDomain` resource agent). In the event of a hardware failure of a node, Pacemaker decides on which of the remaining nodes to restart the affected VMs.

### 4.2 Multi-Level Fencing Configuration (STONITH)
In shared storage architectures (FC SAN) with clustered LVM, the worst imaginable scenario is the loss of network connectivity on a node without it powering off (split-brain scenario). If two nodes each believe they are the sole survivor and attempt to write simultaneously to the same Logical Volume, **irreversible filesystem or database corruption** occurs.

To prevent this scenario, Pacemaker enforces the **STONITH (Shoot The Other Node In The Head)** mechanism. The KvirtIO architecture implements a **two independent level** system, guaranteeing that an unresponsive node is physically and electrically isolated before its VMs are started elsewhere.

```
                        +---------------------------+
                        |      Node to be Fenced    |
                        +---------------------------+
                                      |
              +-----------------------+-----------------------+
              |                                               |
              v (Level 1: Out-of-Band Network)               v (Level 2: SAN Witness)
     +-----------------+                             +-----------------+
     |   fence_idrac   |                             |    SBD Daemon   |
     +-----------------+                             +-----------------+
              |                                               |
              | (IPMI/OOB Command)                            | (Missed Heartbeat/Mailbox)
              v                                               v
     [Power Off Chassis]                             [Hardware Watchdog]
              |                                               |
              +-----------------------+-----------------------+
                                      |
                                      v
                             [Node Off/Reset]
```

#### Level A: Physical Fencing (fence_idrac)
*   **Agent**: `fence_idrac` (based on Redfish or IPMI protocol over out-of-band network).
*   **Operation**: In the event of a node failing to respond via Corosync, Pacemaker sends a direct command to the iDRAC card of the target node to request an **immediate electrical hard reset (poweroff / powercycle)**.
*   This operation guarantees node deactivation at the hardware level.

#### Level B: Storage / Witness Fencing (SBD - Storage-based Death)
In the event of a partial management network failure that makes it impossible to contact both the host and the iDRAC card, the **SBD** mechanism kicks in.
*   **Witness LUN**: A dedicated **100MB** LUN is created on the Fibre Channel SAN (shared among all 5 nodes). This LUN hosts no filesystem and is initialized for exclusive use by SBD.
*   **Hardware Watchdog**: Each node must have an active system watchdog module at the kernel level (e.g. `iTCO_wdt` for Intel hardware or `/dev/watchdog`).
*   **Operation**:
    1.  The `sbd` daemon running on each host constantly writes a heartbeat to the shared LUN and polls its reserved "mailbox" on the same LUN.
    2.  If Pacemaker determines that Node 3 is isolated and unreachable via network, it writes a "fencing target" message into Node 3's mailbox on the SBD LUN.
    3.  The `sbd` daemon on Node 3 reads the fencing message from the LUN (since the 32Gb FC path is still active) and performs an **immediate node self-fence** via the hardware reset controlled by the Linux watchdog, completely bypassing the IP network and the software shutdown stack.
    4.  If the `sbd` daemon stops writing or hangs, the hardware watchdog no longer receives the "keep-alive" signal and forcibly reboots the physical machine after a few seconds.

### 4.3 Prohibition of Custom Scripts
The use of custom scripts or application-level mechanisms operating at the guest level (e.g. ping within the VM, software agents inside the guest operating system) to trigger fencing or forced host migration is strictly forbidden. The engineering reasons are:
*   **Cascading Failures**: A network block at the VM level (e.g. a disruption on a guest production switch) does not necessarily reflect a health problem on the hypervisor host. Fencing the host would cause the unnecessary restart of all other healthy VMs hosted on the same node.
*   **False Positives**: High application load inside a VM could delay responses from a custom monitoring script, generating false positives with consequent cyclic reboots (fencing loops).
*   **State Inconsistency**: Only the cluster manager (Pacemaker) has a global view of resource state and shared storage topology. Only Pacemaker can safely and coordinately decide on the isolation of a node.

### 4.4 Live Migration and Hysteresis Policy in Pacemaker

The activation of Live Migration processes and cluster reactivity in the event of anomalies or overloads must be governed by strict policies to prevent unjustified cyclic migrations (ping-pong effect) and to ensure data integrity during RAM transit over the 50Gbps network (VLAN 20).

#### 4.4.1 Cluster Hysteresis Configuration (Resource Stickiness)
By default, Pacemaker tends to relocate a resource back to its original node as soon as it comes back online or normalizes. In a production environment, this behaviour is destructive: moving a high-load VM has a computational and network cost that must not be duplicated without reason.

KvirtIO enforces a high-inertia global configuration via the `resource-stickiness` parameter.

```bash
# Setting the default stickiness at the Pacemaker cluster level
crm configure rsc_defaults resource-stickiness=1000
```

**Mathematical Logic of Hysteresis combined with the Watcher**

The external watcher (`kvirtio-host-watcher.sh`) updates the node attribute `status-load` setting it to `overloaded` if limits are exceeded for 3 consecutive checks. Pacemaker intercepts this change via a conditional location rule with a negative score (Negative Score). The rule is defined as follows for each VM:

```
crm configure location loc_vm_db01 vm_db01 \
    rule id="migrate-on-overload" score="-1500" status-load eq "overloaded"
```

The hysteresis resolves according to this score matrix:

*   **Nominal State**: The VM runs on Node 1. It has a base preference value plus its `resource-stickiness` (+1000). The cluster does not move it.
*   **Overload State**: The watcher detects saturation and sets `status-load="overloaded"`. Pacemaker applies the -1500 constraint. Node 1's score drops to $-500$ ($1000 - 1500$). Since any other empty node has a score of $0$, Pacemaker immediately initiates Live Migration to the least loaded host.
*   **Alarm Recovery**: Once the VM is evacuated, the load on Node 1 drops and the watcher resets it to `healthy`. The VM is now on Node 2, protected by its new `resource-stickiness` of +1000 on Node 2. Even though Node 1 has returned healthy (score 0), the VM remains stably on Node 2, since $1000 > 0$. This eliminates micro-migrations and stabilizes the infrastructure.

#### 4.4.2 Local Fault Tolerance (Migration Threshold)
If a VM experiences a transient internal problem (e.g. a Libvirt resource agent timeout or an isolated QEMU process startup error), Pacemaker must not immediately write off the physical host by performing a mass migration.

The `migration-threshold` parameter is introduced to align cluster HA with watcher hysteresis:

```bash
# Sets tolerance to 3 local failures before declaring evacuation
crm configure rsc_defaults migration-threshold=3
```

If the VM's resource agent fails local monitoring 3 times in a row, Pacemaker marks the node as ineligible for that specific resource and moves it live (if possible) or restarts it on another host.

#### 4.4.3 Live Migration Parameterization (Resource Agent)
Live migration must be configured to natively leverage kernel acceleration and avoid bottlenecks that would limit the bandwidth of the 25GbE links.

The `VirtualDomain` resource definition in Pacemaker must include the transport options dedicated to the Live Migration VLAN (VLAN 20):

```
primitive vm_db01 ocf:heartbeat:VirtualDomain \
    params config="/dev/vg_vm_definition/vm_db01.xml" \
    hypervisor="qemu:///system" \
    migration_transport="ssh" \
    migration_user="kvirtwatch" \
    migration_network_suffix="-lm.kvirtio.local" \
    op monitor interval="10s" timeout="30s" \
    op start interval="0s" timeout="90s" \
    op stop interval="0s" timeout="90s" \
    meta allow-migrate="true"
```

*   **`allow-migrate="true"`**: Explicitly enables Pacemaker to perform live (hot) migration rather than a destructive Stop/Start cycle when moving between nodes.
*   **`migration_network_suffix`**: Forces Libvirt to route migration traffic over the dedicated network (`-lm.kvirtio.local`), resolving the destination node hostname on the interfaces attached to VLAN 20, fully leveraging the 50Gbps bond and excluding the management or production network from the RAM copy load.

---

## 5. Control Plane & External Orchestration

The cardinal design principle of KvirtIO is **plane separation**. Hypervisor hosts must dedicate their CPU cycles, memory, and storage I/O exclusively to the computation of customer virtual machines.

### 5.1 Externalization of Control Plane and Watchers
All software components not critical for the direct execution of the data plane must reside on a physically and logically decoupled management infrastructure (Management Plane):
*   **Monitoring and Log Collection**: Metrics export daemons (e.g. `prometheus-node-exporter`, `libvirt-exporter`) run on KVM hosts with minimal CPU priority (`nice` set to high values) and send data to an external Prometheus/Grafana cluster.
*   **Dynamic Balancer & Capacity Management**: Any predictive load analysis scripts or daemons responsible for dynamic resource balancing (e.g. custom DRS that calls live migration APIs via `virsh` based on host CPU usage) must run outside the KVM cluster (on dedicated management VMs or servers). Such watchers query the `libvirt` API remotely (via encrypted TLS connection) and perform the necessary calls without burdening the hypervisor host kernels.

### 5.2 Network Topology and Segregation
The KvirtIO cluster network is structured to strictly isolate traffic flows on separate physical and logical (VLAN) interfaces.

#### Logical Network Connection Diagram per Node
```
                         +-----------------------------------+
                         |             Host Node             |
                         +-----------------------------------+
                           /                               \
        (Dual 10GbE PCI-e) /                                 \ (Dual 25GbE LACP Bond)
                          /                                   \
  +--------------------------------+                 +--------------------------------+
  |  Physical Int.: eth0 / eth1    |                 |   Physical Int.: ens1 / ens2   |
  +--------------------------------+                 +--------------------------------+
     |             |             |                      |                          |
     v             v             v                      v                          v
  [VLAN 10]     [VLAN 11]     [OOB IP]               [VLAN 20]                  [VLAN 30+]
  Management   Corosync HB     iDRAC                  Live Migration             VM Prod Traffic
  (SSH/API)    (Multicast)   (Fencing)               (Uncapped)                 (VLAN Trunking)
```

1.  **Management / Cluster Network (Dual 10GbE / Separate Physical Interfaces)**:
    *   **VLAN 10 - Management**: Traffic for remote administration via SSH, `libvirt` API calls, and monitoring.
    *   **VLAN 11 - Corosync Heartbeat**: Ultra-low latency channel dedicated exclusively to cluster messaging. Corosync packets must have maximum priority and be configured with dedicated QoS/CoS at the physical switch level.
    *   **OOB Network (iDRAC)**: Physically separate cabled network (on dedicated infrastructure management switches) for protected access to the iDRAC cards of the 5 physical nodes and for routing STONITH `fence_idrac` commands.

2.  **Production & Live Migration Plane (Dual 25GbE SFP28 in Bonding)**:
    *   The two 25GbE interfaces are configured in **LACP Bonding (Mode 4)** at the host operating system level (using the SLES kernel `bonding` module) to ensure redundancy and bandwidth aggregation.
    *   The link aggregation configuration uses the L3+L4 hashing policy (`xmit_hash_policy = layer3+4`) to optimize TCP network flow distribution.
    *   Two types of traffic are attached to the logical bond via VLAN tagging:
        *   **VLAN 20 - Live Migration**: Dedicated exclusively to the transit of virtual machine RAM during live migration processes between hosts. This network requires the maximum available throughput without software caps, to complete the memory page transfer in the shortest possible time and avoid VM performance degradation during the "dirtying phase".
        *   **VLAN 30+ - VM Production**: VLANs trunked directly inside virtual machines via host virtual switches (e.g. Linux Bridges or Open vSwitch) to provide network connectivity for application services hosted by the VMs.

---

## 6. Architectural Decision Matrix and Engineering Rationale

| Component | Technology Choice | Excluded Alternative | Engineering Rationale |
| :--- | :--- | :--- | :--- |
| **Hypervisor** | Native KVM (SLES) | VMware ESXi / Hyper-V | Full control of the Linux stack, reduced licensing costs, direct integration with the SLES Enterprise kernel, and easy automation via Libvirt API. |
| **Swap Management** | Statically disabled + `vm.swappiness=0` | Active swap on fast disk (SSD) | Elimination of the risk of spurious latencies induced by the host paging memory allocated to virtual machines. RAM must be deterministic. |
| **Storage Topology** | Multi-LUN Striped (8 x 2TB LUNs per 16TB VM) | Single 16TB LUN | Parallelization of queues at the host kernel level. Moves from a single queue depth (e.g. 64) to an aggregate multipath queue (512) leveraging blk-mq. |
| **Volume Locking** | `lvmlockd` + `dlm` | Legacy `clvmd` | Greater resilience, better management of modern Pacemaker clusters, elimination of clvmd single-point-of-failure in case of cluster freeze. |
| **Fencing Level 1** | `fence_idrac` (OOB) | Fencing via VM network | Guarantees a clean electrical reset of the node at the hardware level, regardless of the state of the host operating system. |
| **Fencing Level 2** | SBD (Witness LUN + Watchdog) | Network ping script | Provides a quorum and self-isolation channel (host self-fence) via hardware watchdog operating directly on the FC SAN storage bus, immune to IP network failures. |
| **Live Migration Network** | Dedicated 2x25GbE Bonded network | Shared with Management network | Prevents saturation of cluster communication channels (Corosync) during bulk RAM transfer of large VMs (256GB+), reducing the duration of the transient block (migration downtime). |
| **Network MTU** | End-to-End Jumbo Frames (MTU 9000) | Standard MTU 1500 | 6x reduction in PPS processed by the host CPU (SoftIRQ) at equal throughput. Bulk forwarding is delegated to the ToR switch ASICs, designed to operate at zero latency. |
| **Network QoS** | Global AQM `fq_codel` on physical bond | Per-VM Policing in Libvirt XML | Elimination of "noisy neighbor" without administrative overhead: the kernel autonomously differentiates elephant and mouse flows, guaranteeing minimum latency to interactive flows without any per-VM configuration. |
| **VM Profiles** | XML Classification (IOIntensive / AppServer) | Uniform configuration for all VMs | Allows safe coexistence of heterogeneous workloads: ballooning disabled and NUMA pinning for DBs, active ballooning to increase consolidation density for application VMs. |
| **Monitoring** | Latency and queue metrics (steal time, await, fq_codel backlog) | Generic percentage utilization (CPU%, RAM%) | Percentage saturation metrics do not intercept resource contention in a virtualized system. Only queue and latency metrics allow bottlenecks to be identified before they impact customers. |
| **Live Migration Policy** | `resource-stickiness=1000` + Negative Score Watcher (-1500) | Automatic migration on any load change | Prevents ping-pong effect: the VM migrates only under confirmed overload (3 consecutive checks) and remains stable on the destination node thanks to stickiness, even after the alarm clears on the source node. |



---

## 7. Monitoring & Observability (Operational KPIs)

In KvirtIO, monitoring is not limited to generic usage graphs: the objective is to intercept **queues** and **latencies** before they impact workloads. A host at 90% CPU with no steal time is healthy; a host at 30% CPU with 200ms I/O latency is already degrading hosted databases. The metrics below, exportable via `libvirt-exporter`, `node-exporter`, and custom scripts to an external Prometheus/Grafana backend (see Section 5.1), are organized by risk area.

### 7.1 Host Compute (Hypervisor Node)

Metrics to identify whether the host is becoming a bottleneck for its hosted VMs.

| Metric | Critical Threshold | Operational Meaning |
| :--- | :--- | :--- |
| `cpu_steal_time_seconds_total` (per vCPU) | > 0.1% | The queen metric: indicates how many CPU cycles the VMs requested and the host denied due to overcommit or saturation. Threshold exceeded = density or configuration problem. |
| `numa_hit` vs `numa_miss` | `numa_miss` growing | RAM allocated on a different physical socket from the one processing the data. Indicates a `numad` malfunction or incorrect VM XML configuration. |
| `host_interrupt_rate` | Anomalous value for workload | The host spends more time handling interrupts (NIC/disk) than running VMs. Symptom of misconfigured `irqbalance` or non-optimized drivers. |

### 7.2 Networking (Jumbo Frames & AQM)

Metrics to verify that the "Global Fabric" strategy (MTU 9000 + `fq_codel`) handles the load without itself becoming the bottleneck.

| Metric | Critical Threshold | Operational Meaning |
| :--- | :--- | :--- |
| `net_bond_packet_drop` | > 0 sustained drops | Drops on the 50Gbps bond indicate insufficient NIC buffers, not lack of bandwidth. Consider increasing ring buffers beyond the 4096 descriptors already set. |
| `net_fq_codel_backlog_bytes` | Sustained growth | Amount of queue on the physical interface. A growing backlog indicates too many "elephant" flows saturating the link; `fq_codel` is still working but approaching its limit. |
| `net_mtu_mismatches` | > 0 | Drops from oversized packets arriving on MTU 1500 interfaces. Indicates a VM or Linux Bridge configured with the wrong MTU; must be resolved immediately to avoid silent throughput degradation. |

### 7.3 Storage I/O

Do not look at total IOPS: the relevant metric is the latency **perceived by the kernel**, not the storage array's nominal latency.

| Metric | Critical Threshold | Operational Meaning |
| :--- | :--- | :--- |
| `io_await_seconds` (per physical LUN) | > 10ms on IOIntensive profiles | Total time of an I/O request in queue + service time. Once this threshold is exceeded, relational databases begin to suffer from timeouts and transaction degradation. |
| `io_queue_depth_utilization` (per LUN) | 1 LUN at 100%, others idle | The LVM stripe is unbalanced or a hotspot exists on the storage array. Parallelism across the 8 LUNs is not being properly exploited. |
| `dm_multipath_failures` | > 0 | Early indicator of a degrading FC optical cable or an unstable HBA port, before the SAN goes completely offline. |

### 7.4 Memory (No-Swap Environment)

In a no-swap environment, memory is a binary resource: available or exhausted. Monitoring must anticipate exhaustion, not react to it.

| Metric | Critical Threshold | Operational Meaning |
| :--- | :--- | :--- |
| `host_hugepages_free` | Approaching 0 | A "cluster block risk" metric: if 1GB Hugepages are exhausted, new IOIntensive VMs cannot start. Requires preventive load balancing action. |
| `guest_balloon_actual` vs `guest_balloon_target` | `actual` << `target` consistently | For "AppServer" VMs with active ballooning: the VM is under memory pressure and may be performing internal guest swap. Early indicator of the need for migration or reallocation. |

---

## 10. Remote Console Management (noVNC) & Live Migration

Access to virtual machine consoles is a critical requirement for out-of-band administration by system administrators. Since KvirtIO uses live migration orchestrated by Pacemaker, the physical host IP and the VNC port exposed by QEMU change dynamically with every VM move. The architecture solves the problem by combining three distinct layers: an agnostic XML, a centralized libvirt daemon configuration, and a token-based WebSocket proxy with auto-reconnection.

### 10.1 VNC Abstraction in XML and Network Hardening

The fundamental principle is the **separation between resource definition and its security policy**. The VM XML must never contain static references to the physical host IP: that information would change at every migration, making the definition non-portable and causing the QEMU bind to fail on the destination node (which does not own that IP address).

#### 10.1.1 Agnostic XML Configuration (VM)

The XML of each VM requires only dynamic VNC port allocation, with no explicit `listen`:

```xml
<devices>
  <graphics type='vnc' port='-1' autoport='yes' keymap='it'/>
  <video>
    <model type='vga' vram='16384' heads='1' primary='yes'/>
  </video>
</devices>
```

> **Rationale**: `port='-1'` and `autoport='yes'` delegate to QEMU the choice of the first available port in the range 5900-6900. Since there is no static `listen` in the XML, QEMU uses the global value defined in `qemu.conf` on the current node, which is correct regardless of which node the VM is running on.

#### 10.1.2 Libvirt Host-Level Configuration (qemu.conf)

On **every KVM node in the cluster**, the file `/etc/libvirt/qemu.conf` is configured to force VNC to listen on the specific node's Management interface. This ensures the QEMU bind is always valid, regardless of which VM is present:

```ini
# /etc/libvirt/qemu.conf
# Instructs QEMU to expose VNC on all interfaces (filtering delegated to the firewall)
# Preferred alternative: specify the Management VLAN IP for defence in depth
vnc_listen = "0.0.0.0"
vnc_auto_unix_socket = 0
```

After every change, the service must be restarted: `systemctl restart libvirtd`.

#### 10.1.3 Firewall Hardening (Defence-in-Depth on SLES)

The second security layer is implemented via `firewalld` on every KVM node. A **drop-all** policy is applied to the VNC range, with an explicit whitelist of only the Management cluster IPs (where the websockify proxy resides):

```bash
# Run on every KVM node in the cluster (IP_MGT_NODE_1/2 = Management Server IP)
firewall-cmd --permanent --zone=public --add-rich-rule='
  rule family="ipv4"
  source address="[IP_MGT_NODE_1]"
  port port="5900-6900" protocol="tcp"
  accept'

firewall-cmd --permanent --zone=public --add-rich-rule='
  rule family="ipv4"
  source address="[IP_MGT_NODE_2]"
  port port="5900-6900" protocol="tcp"
  accept'

# Deny the rest (implicit drop in the rich-rule chain)
firewall-cmd --permanent --zone=public --add-rich-rule='
  rule family="ipv4"
  port port="5900-6900" protocol="tcp"
  drop'

firewall-cmd --reload
```

This ensures that VNC ports are **physically unreachable** from any host other than the Management Server, even in the event of an application-level configuration error.

---

### 10.2 Central Proxy Architecture (Management Server)

The Management node hosts the **Websockify** service paired with the **noVNC** HTML5 client. The Management server acts as a bridge between the end user (over HTTPS/WSS) and the internal VNC ports of the KVM nodes, accessible exclusively by the proxy thanks to the firewall rules in section 10.1.3.

```
  Administrator Browser
        │
        │  wss://console.kvirtio.local/?token=VM_NAME
        ▼
  ┌─────────────────────────────────────────┐
  │  Management Server                      │
  │                                         │
  │  [Apache + noVNC (HTML5)]               │
  │       │                                 │
  │  [Websockify + Token Directory]         │
  │       │   token lookup: VM_NAME         │
  │       │   → IP_KVM_NODE_X:590Y          │
  └───────┼─────────────────────────────────┘
          │  TCP:590Y (Management VLAN)
          ▼
  ┌──────────────────────────────────────────┐
  │  KVM Node X (SLES Hypervisor)            │
  │  QEMU listens on 0.0.0.0:590Y            │
  │  Firewall: accepts only from MGT Server  │
  └──────────────────────────────────────────┘
```

The decoupling between the user connection and the physical node occurs via the websockify **Token Directory** mechanism:

*   The web client sends a request with `?token=VM_NAME` (e.g. `vm-oracle-db-01`).
*   Websockify consults its token file (e.g. `/var/lib/kvirtio/novnc/tokens/cluster1.conf`) to resolve the logical name into the current physical destination (`IP_NODE_X:VNC_PORT`).
*   The token file content is dynamically updated by the `kvirtio-console-tracker` daemon (section 10.3).

**Installing websockify and noVNC on the Management Server:**

```bash
# Installing dependencies
zypper install python3-websockify

# Downloading noVNC (HTML5 client)
cd /var/www/html
git clone https://github.com/novnc/noVNC.git novnc

# Starting websockify with Token Directory
websockify --web /var/www/html/novnc \
           --token-plugin TokenFile \
           --token-source /var/lib/kvirtio/novnc/tokens/cluster1.conf \
           6080 &
```

---

### 10.3 The Console Tracker Daemon (kvirtio-console-tracker)

To keep the websockify Token Directory aligned with the cluster reality (VMs that migrate, start, or stop), the **`kvirtio-console-tracker`** daemon is implemented on the Management node.

#### 10.3.1 Operation

The daemon operates according to the following cycle:

1.  **Configuration reading**: For each cluster defined in `/etc/kvirtio/clusters/*.conf`, reads the list of KVM nodes.
2.  **Remote querying**: Via SSH (with `kvirtio-watcher` user and restricted sudo), runs `virsh list --state-running --name` on each node to get the running VMs.
3.  **VNC port retrieval**: For each VM, runs `virsh domdisplay <VM_NAME>` to get the current VNC URL (e.g. `vnc://10.0.1.5:5901`).
4.  **Atomic token update**: Writes the token file with atomic substitution (`mv`) to avoid inconsistent states during the update, in the format expected by websockify:
    ```
    vm-oracle-db-01: 10.0.1.5:5901
    vm-sap-app-01: 10.0.1.6:5900
    ```
5.  **JSON Dashboard Update**: Simultaneously writes the file `/var/www/html/kvirtio/data/console_<cluster>.json` with console information for the web dashboard.

Polling is performed every 10 seconds (configurable), ensuring a maximum update latency compatible with Pacemaker live migration times.

#### 10.3.2 Flow During a Live Migration

```
Initial State:
  Token file: vm-oracle-db-01: 10.0.1.5:5900
  User connected via noVNC to Node 1, port 5900

Migration initiated by Pacemaker (Node 1 → Node 2):
  └─ QEMU allocates free port on Node 2: e.g. 5901

Console Tracker (next cycle, within 10s):
  └─ virsh domdisplay vm-oracle-db-01 on Node 2 → vnc://10.0.1.6:5901
  └─ Overwrites token: vm-oracle-db-01: 10.0.1.6:5901

noVNC Client:
  └─ Migration causes temporary drop of the VNC socket
  └─ noVNC enters "reconnecting" mode
  └─ On reconnect, websockify reads the new token → Node 2:5901
  └─ Console is transparently restored
```

#### 10.3.3 Systemd Integration

The daemon is managed as a systemd service of type `simple` with automatic restart policy:

```bash
# Deploying the daemon
cp scripts/kvirtio-console-tracker.sh /usr/local/sbin/
chmod 750 /usr/local/sbin/kvirtio-console-tracker.sh

# Installing the service
cp systemd/kvirtio-console-tracker.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now kvirtio-console-tracker.service

# Verification
systemctl status kvirtio-console-tracker.service
journalctl -fu kvirtio-console-tracker.service
```

---

### 10.4 sudoers Configuration for Console Tracker

To respect the principle of least privilege, the `kvirtio-watcher` user must have access only to the `virsh` commands required for the tracker, on the KVM nodes:

```
# /etc/sudoers.d/kvirtio-console (to be deployed on every KVM node)
kvirtio-watcher ALL=(root) NOPASSWD: /usr/bin/virsh list --state-running --name
kvirtio-watcher ALL=(root) NOPASSWD: /usr/bin/virsh domdisplay *
```

---

### 10.5 noVNC Component Matrix

| Component | Host | Role |
| :--- | :--- | :--- |
| **noVNC** (HTML5 client) | Management Server | WebSocket/VNC client served by Apache |
| **Websockify** | Management Server | TCP-over-WebSocket proxy with token resolution |
| **Token Directory** (`*.conf`) | Management Server | `VM_NAME → IP_KVM:PORT` mapping dynamically updated |
| **kvirtio-console-tracker** | Management Server | Daemon that keeps the Token Directory aligned |
| **qemu.conf** (`vnc_listen`) | Every KVM node | Forces VNC bind on all interfaces (or Management only) |
| **firewalld** (rich-rules) | Every KVM node | Restricts VNC access to the Management Server only |
| **VM XML** (agnostic) | libvirt definition | `port='-1' autoport='yes'` without static IP |

