# Libvirt XML Templates for VM Provisioning

This document provides representative, enterprise-class Libvirt XML configuration templates for the three main types of workloads deployed in the **KvirtIO** architecture:
1.  **IO-Intensive Database** (Linux, tuned for transactional workloads like Oracle or PostgreSQL).
2.  **Application Server** (Linux, general-purpose web/app server).
3.  **Active Directory Domain Controller** (Windows Server 2022, tuned with Hyper-V enlightenments and UEFI/TPM support).

---

## 🗄️ 1. IO-Intensive Database (tuned for Oracle/PostgreSQL)

This profile is designed for maximum throughput, low latency, and dynamic NUMA-aware placement. It features:
*   **Auto-Pinning NUMA**: vCPU and memory placement is delegated to `numad`, recalculated at every boot or Live Migration, avoiding the rigidity (and CPU Steal Time risk) of static pinning.
*   **Virtio-SCSI Multi-Queue** (number of queues matches vCPUs) with a dedicated I/O thread.
*   Direct physical LVM I/O bypass (`cache='none'` and `io='native'`).
*   Disabled memory ballooning (`memballoon model='none'`) to prevent guest kernel panics or OOM crashes from dynamic memory reclamation.

```xml
<domain type='kvm'>
  <name>vm-db-prod-01</name>
  <uuid>a123bc45-de67-89fa-bcde-0123456789ab</uuid>
  
  <!-- Hardware Allocations -->
  <memory unit='KiB'>268435456</memory> <!-- 256 GB -->
  <currentMemory unit='KiB'>268435456</currentMemory>

  <!-- CPU Allocation and Dynamic NUMA Placement (delegated to numad) -->
  <vcpu placement='auto'>32</vcpu>
  <iothreads>1</iothreads>
  <numatune>
    <memory mode='strict' placement='auto'/>
  </numatune>

  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>

  <!-- CPU Host Passthrough for raw physical features -->
  <cpu mode='host-passthrough' check='none'>
    <topology sockets='1' dies='1' cores='16' threads='2'/> <!-- 32 Threads -->
  </cpu>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    
    <!-- Virtio-SCSI Controller with Multi-Queue and IOThread -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='32' iothread='1'/>
    </controller>

    <!-- Clustered SAN LVM Volume (Raw block access) -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='/dev/vg_iointensive/lv_vm_db01'/>
      <target dev='sda' bus='scsi'/>
    </disk>

    <!-- Production Bridged Interface -->
    <interface type='bridge'>
      <source bridge='br-vlan30'/>
      <model type='virtio'/>
      <!-- Enable network multi-queue matching CPU threads -->
      <driver name='vhost' queues='8'/>
    </interface>

    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>

    <!-- Video & Graphic Console (VNC socket dynamically tracked) -->
    <video>
      <model type='vga' vram='16384' heads='1'/>
    </video>
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'>
      <listen type='address' address='0.0.0.0'/>
    </graphics>

    <!-- Memory Ballooning: Disabled to prevent memory defragmentation/swapping -->
    <memballoon model='none'/>
  </devices>
  
  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>iointensive</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>cluster_db</kvirtio:cluster>
  </metadata>
</domain>
```

---

## 🌐 2. Application Server (General Purpose Linux)

This profile is optimized for web, application, or cache servers. It uses:
*   Standard RAM memory without Hugepages backing.
*   Standard KVM CPU virtualization (host-model or host-passthrough, auto placement).
*   Standard virtio-blk bus drive for storage with writeback cache.
*   Active memory ballooning to allow memory reclamation and stats gathering.

```xml
<domain type='kvm'>
  <name>vm-web-prod-01</name>
  <uuid>b234cd56-ef78-90ab-cdef-123456789abc</uuid>
  
  <!-- Hardware Allocations -->
  <memory unit='KiB'>33554432</memory> <!-- 32 GB -->
  <currentMemory unit='KiB'>33554432</currentMemory>

  <vcpu placement='auto'>8</vcpu>

  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>

  <features>
    <acpi/>
    <apic/>
  </features>

  <!-- CPU Host Model for hypervisor compatibility -->
  <cpu mode='host-model' check='partial'>
    <topology sockets='1' dies='1' cores='8' threads='1'/>
  </cpu>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Standard VirtIO Block disk on clustered LVM with host caching -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source dev='/dev/vg_web/lv_vm_web01'/>
      <target dev='vda' bus='virtio'/>
    </disk>

    <!-- Web/App Bridged Interface -->
    <interface type='bridge'>
      <source bridge='br-vlan30'/>
      <model type='virtio'/>
    </interface>

    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>

    <video>
      <model type='virtio' vram='16384' heads='1'/>
    </video>
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'>
      <listen type='address' address='0.0.0.0'/>
    </graphics>

    <!-- VirtIO Balloon active: checks memory stats every 10 seconds -->
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
  </devices>
  
  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>general</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>cluster_web</kvirtio:cluster>
  </metadata>
</domain>
```

---

## 🪟 3. Active Directory Domain Controller (Windows Server 2022)

This profile is heavily optimized for Windows Server workloads, enabling full Hyper-V virtualization extensions (enlightenments) under KVM, UEFI booting, Secure Boot, and an emulated TPM 2.0 device.

*   **Hyper-V Enlightenments**: Features like `relaxed`, `vapic`, `spinlocks`, `synic`, and `stimer` reduce overhead for the Windows kernel inside the VM.
*   **UEFI (OVMF)**: Standard UEFI loader path for Windows secure boot environments.
*   **TPM 2.0**: Emulated TPM using `swtpm` backend, necessary for Windows Server security baseline compliance.
*   **VirtIO Drivers**: VirtIO network and VirtIO SCSI drivers are selected (requires the VirtIO guest drivers ISO during initial OS installation).

```xml
<domain type='kvm'>
  <name>vm-dc-prod-01</name>
  <uuid>c345de67-fg89-01bc-defa-23456789abcd</uuid>
  
  <memory unit='KiB'>16777216</memory> <!-- 16 GB -->
  <currentMemory unit='KiB'>16777216</currentMemory>

  <vcpu placement='static'>4</vcpu>

  <!-- UEFI with secure boot enabled using SLES OVMF paths -->
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/qemu/ovmf-x86_64-code.bin</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/vm-dc-prod-01_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <hyperv mode='custom'>
      <!-- Hyper-V enlightenments for CPU and scheduling optimizations -->
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vpindex state='on'/>
      <synic state='on'/>
      <stimer state='on'/>
      <reset state='on'/>
      <vendor_id state='on' value='kvirtio'/>
      <frequencies state='on'/>
    </hyperv>
  </features>

  <cpu mode='host-passthrough' check='none'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
  </cpu>

  <!-- Localtime offset for Windows compatibility -->
  <clock offset='localtime'>
    <timer name='hypervclock' present='yes'/>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Virtio-SCSI controller for Windows storage -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='4' iothread='1'/>
    </controller>

    <!-- Windows System Disk (using VirtIO SCSI driver) -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source dev='/dev/vg_web/lv_vm_dc01'/>
      <target dev='sda' bus='scsi'/>
    </disk>

    <!-- TPM 2.0 device required for Windows Server 2022 -->
    <tpm model='tpm-tis'>
      <backend type='emulator' version='2.0'/>
    </tpm>

    <!-- VirtIO network interface -->
    <interface type='bridge'>
      <source bridge='br-vlan30'/>
      <model type='virtio'/>
    </interface>

    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>

    <!-- QXL VGA video for smooth RDP / console UI rendering -->
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1'/>
    </video>
    
    <!-- VNC Access -->
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'>
      <listen type='address' address='0.0.0.0'/>
    </graphics>

    <!-- VirtIO Balloon active -->
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
  </devices>
  
  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>general</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>cluster_web</kvirtio:cluster>
  </metadata>
</domain>
```

---

## 📐 4. Tuned XML Profiles (per KvirtIO HLD §2.4.2)

The two complete, ready-to-use profile files referenced by the High-Level Design as the baseline classification for every VM deployed on KvirtIO. Each new VM definition should be built starting from one of these two profiles.

### 4.1 Profile A — "IOIntensive" (Database / SAP HANA)

File: `profile-iointensive.xml`

```xml
<domain type='kvm'>
  <name>vm-iointensive-template</name>
  <uuid>d456ef78-9012-3abc-def0-3456789abcde</uuid>

  <!-- Hardware Allocations -->
  <memory unit='GiB'>256</memory>
  <currentMemory unit='GiB'>256</currentMemory>

  <!-- Auto-Pinning NUMA: vCPU/memory placement delegated to numad -->
  <vcpu placement='auto'>16</vcpu>
  <iothreads>1</iothreads>
  <numatune>
    <memory mode='strict' placement='auto'/>
  </numatune>

  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>

  <cpu mode='host-passthrough' check='none'/>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Virtio-SCSI Controller with Multi-Queue and dedicated IOThread -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='16' iothread='1'/>
    </controller>

    <!-- Clustered SAN LVM Volume (raw block access, host cache bypass) -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='/dev/vg_iointensive/lv_vm_iointensive_template'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>

    <interface type='bridge'>
      <source bridge='br-vlan30'/>
      <model type='virtio'/>
      <driver name='vhost' queues='8'/>
    </interface>

    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>

    <video>
      <model type='vga' vram='16384' heads='1'/>
    </video>

    <!-- Agnostic VNC: no static listen/IP, port chosen by QEMU from the local node range -->
    <graphics type='vnc' port='-1' autoport='yes' keymap='it'/>

    <!-- Memory Ballooning ABSOLUTELY DISABLED for database/IOIntensive workloads -->
    <memballoon model='none'/>
  </devices>

  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>iointensive</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>cluster_db</kvirtio:cluster>
  </metadata>
</domain>
```

### 4.2 Profile B — "AppServer" (General Purpose / Web)

File: `profile-appserver.xml`

```xml
<domain type='kvm'>
  <name>vm-appserver-template</name>
  <uuid>e567fa89-0123-4bcd-ef01-456789abcdef</uuid>

  <!-- Hardware Allocations: currentMemory can be set below max to allow ballooning -->
  <memory unit='GiB'>64</memory>
  <currentMemory unit='GiB'>16</currentMemory>

  <vcpu placement='auto'>8</vcpu>

  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>

  <features>
    <acpi/>
    <apic/>
  </features>

  <cpu mode='host-model' check='partial'/>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source dev='/dev/vg_web/lv_vm_appserver_template'/>
      <target dev='vda' bus='virtio'/>
    </disk>

    <interface type='bridge'>
      <source bridge='br-vlan30'/>
      <model type='virtio'/>
    </interface>

    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>

    <video>
      <model type='virtio' vram='16384' heads='1'/>
    </video>

    <!-- Agnostic VNC: no static listen/IP, port chosen by QEMU from the local node range -->
    <graphics type='vnc' port='-1' autoport='yes' keymap='it'/>

    <!-- VirtIO Balloon ACTIVE: enables dynamic memory reclamation / consolidation density -->
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
  </devices>

  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>general</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>cluster_web</kvirtio:cluster>
  </metadata>
</domain>
```