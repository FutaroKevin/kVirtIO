# Modelli XML Libvirt per il Provisioning delle VM

Questo documento fornisce i modelli di configurazione XML di Libvirt rappresentativi e ottimizzati a livello enterprise per i tre principali tipi di carichi di lavoro implementati nell'architettura **KvirtIO**:
1.  **Database IO-Intensive** (Linux, ottimizzato per database transazionali come Oracle o PostgreSQL).
2.  **Application Server** (Linux, server web/applicazione generico).
3.  **Active Directory Domain Controller** (Windows Server 2022, ottimizzato con estensioni Hyper-V e supporto UEFI/TPM).

---

## 🗄️ 1. Database IO-Intensive (ottimizzato per Oracle/PostgreSQL)

Questo profilo è progettato per garantire il massimo throughput, una bassissima latenza e un posizionamento dinamico basato su NUMA. Caratteristiche principali:
*   **Auto-Pinning NUMA**: il posizionamento di vCPU e memoria è delegato a `numad`, ricalcolato ad ogni avvio o Live Migration, evitando la rigidità (e il rischio di CPU Steal Time) del pinning statico.
*   **Virtio-SCSI Multi-Queue** (il numero di code corrisponde al numero di vCPU) con un thread I/O dedicato.
*   Bypass della cache dell'host tramite accesso raw al volume LVM (`cache='none'` e `io='native'`).
*   Memory ballooning disabilitato (`memballoon model='none'`) per evitare kernel panic del guest o crash da OOM dovuti al recupero dinamico della memoria.

```xml
<domain type='kvm'>
  <name>vm-db-prod-01</name>
  <uuid>a123bc45-de67-89fa-bcde-0123456789ab</uuid>
  
  <!-- Allocazione Hardware -->
  <memory unit='KiB'>268435456</memory> <!-- 256 GB -->
  <currentMemory unit='KiB'>268435456</currentMemory>

  <!-- Allocazione CPU e posizionamento NUMA dinamico (delegato a numad) -->
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

  <!-- CPU Host Passthrough per sfruttare le istruzioni fisiche native -->
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
    
    <!-- Controller Virtio-SCSI con Multi-Queue e IOThread -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='32' iothread='1'/>
    </controller>

    <!-- Volume LVM SAN Clusterizzato (Accesso raw a blocchi) -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='/dev/vg_iointensive/lv_vm_db01'/>
      <target dev='sda' bus='scsi'/>
    </disk>

    <!-- Interfaccia di Rete in Bridge (Produzione) -->
    <interface type='bridge'>
      <source bridge='br-vlan30'/>
      <model type='virtio'/>
      <!-- Abilita la multi-coda di rete corrispondente ai thread della CPU -->
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

    <!-- Console Grafica & Video (Socket VNC tracciato dal demone) -->
    <video>
      <model type='vga' vram='16384' heads='1'/>
    </video>
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'>
      <listen type='address' address='0.0.0.0'/>
    </graphics>

    <!-- Memory Ballooning disabilitato per prevenire frammentazione e swap -->
    <memballoon model='none'/>
  </devices>
  
  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>iointensive</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>cluster_db</kvirtio:cluster>
  </metadata>
</domain>
```

---

## 🌐 2. Application Server (Linux General Purpose)

Questo profilo è ottimizzato per server web, applicativi o di caching. Caratteristiche:
*   Memoria RAM standard senza Hugepages.
*   Virtualizzazione CPU standard (modello host-model o host-passthrough, allocazione automatica).
*   Disco VirtIO Block su volume LVM con cache writeback per sfruttare la page-cache dell'host.
*   Memory ballooning attivo per consentire il recupero della memoria non utilizzata.

```xml
<domain type='kvm'>
  <name>vm-web-prod-01</name>
  <uuid>b234cd56-ef78-90ab-cdef-123456789abc</uuid>
  
  <!-- Allocazione Hardware -->
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

  <!-- CPU Host Model per garantire compatibilità tra gli host -->
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

    <!-- Disco VirtIO standard su LVM clusterizzato con cache writeback -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source dev='/dev/vg_web/lv_vm_web01'/>
      <target dev='vda' bus='virtio'/>
    </disk>

    <!-- Interfaccia di rete in bridge -->
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

    <!-- Ballooning attivo: controlla lo stato della memoria ogni 10 secondi -->
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

Questo profilo è ottimizzato specificamente per carichi di lavoro Windows Server, abilitando le estensioni di virtualizzazione Hyper-V (enlightenments) sotto KVM, l'avvio UEFI (Secure Boot) e un dispositivo TPM 2.0 emulato.

*   **Estensioni Hyper-V**: Parametri quali `relaxed`, `vapic`, `spinlocks`, `synic` e `stimer` riducono al minimo l'overhead del kernel Windows all'interno del sistema guest.
*   **UEFI (OVMF)**: Percorso del caricatore UEFI standard per ambienti Windows Secure Boot su SLES.
*   **TPM 2.0**: Dispositivo TPM emulato con backend `swtpm`, obbligatorio per soddisfare i requisiti di sicurezza e compatibilità di Windows Server 2022.
*   **Driver VirtIO**: Configurazione delle schede di rete e dei controller dischi in modalità VirtIO (è necessario caricare l'ISO dei driver guest di VirtIO durante l'installazione del sistema operativo).

```xml
<domain type='kvm'>
  <name>vm-dc-prod-01</name>
  <uuid>c345de67-fg89-01bc-defa-23456789abcd</uuid>
  
  <memory unit='KiB'>16777216</memory> <!-- 16 GB -->
  <currentMemory unit='KiB'>16777216</currentMemory>

  <vcpu placement='static'>4</vcpu>

  <!-- UEFI con Secure Boot abilitato utilizzando i percorsi SLES standard -->
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
      <!-- Ottimizzazioni della CPU e dello scheduler per sistemi guest Windows -->
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

  <!-- Configurazione dell'orologio locale per la sincronizzazione oraria di Windows -->
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

    <!-- Controller Virtio-SCSI per i dischi virtuali Windows -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='4' iothread='1'/>
    </controller>

    <!-- Disco di sistema Windows (tramite driver SCSI VirtIO) -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source dev='/dev/vg_web/lv_vm_dc01'/>
      <target dev='sda' bus='scsi'/>
    </disk>

    <!-- Dispositivo TPM 2.0 richiesto da Windows Server 2022 -->
    <tpm model='tpm-tis'>
      <backend type='emulator' version='2.0'/>
    </tpm>

    <!-- Interfaccia di rete VirtIO in bridge -->
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

    <!-- Scheda video QXL per garantire fluidità nel rendering della console e di RDP -->
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1'/>
    </video>
    
    <!-- Accesso VNC -->
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'>
      <listen type='address' address='0.0.0.0'/>
    </graphics>

    <!-- Ballooning attivo -->
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

## 📐 4. Profili XML Standard (rif. KvirtIO HLD §2.4.2)

I due file profilo completi, pronti all'uso, definiti dalla High-Level Design come baseline di classificazione per ogni VM distribuita su KvirtIO. Ogni nuova definizione di VM deve essere costruita partendo da uno di questi due profili.

### 4.1 Profilo A — "IOIntensive" (Database / SAP HANA)

File: `profile-iointensive.xml`

```xml
<domain type='kvm'>
  <name>vm-iointensive-template</name>
  <uuid>d456ef78-9012-3abc-def0-3456789abcde</uuid>

  <!-- Allocazione Hardware -->
  <memory unit='GiB'>256</memory>
  <currentMemory unit='GiB'>256</currentMemory>

  <!-- Auto-Pinning NUMA: posizionamento di vCPU/memoria delegato a numad -->
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

    <!-- Controller Virtio-SCSI con Multi-Queue e IOThread dedicato -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='16' iothread='1'/>
    </controller>

    <!-- Volume LVM SAN Clusterizzato (accesso raw a blocchi, bypass cache host) -->
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

    <!-- VNC agnostico: nessun listen/IP statico, porta scelta da QEMU nel range del nodo locale -->
    <graphics type='vnc' port='-1' autoport='yes' keymap='it'/>

    <!-- Memory Ballooning ASSOLUTAMENTE DISABILITATO per i carichi database/IOIntensive -->
    <memballoon model='none'/>
  </devices>

  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>iointensive</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>cluster_db</kvirtio:cluster>
  </metadata>
</domain>
```

### 4.2 Profilo B — "AppServer" (General Purpose / Web)

File: `profile-appserver.xml`

```xml
<domain type='kvm'>
  <name>vm-appserver-template</name>
  <uuid>e567fa89-0123-4bcd-ef01-456789abcdef</uuid>

  <!-- Allocazione Hardware: currentMemory inferiore al massimo per consentire il ballooning -->
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

    <!-- VNC agnostico: nessun listen/IP statico, porta scelta da QEMU nel range del nodo locale -->
    <graphics type='vnc' port='-1' autoport='yes' keymap='it'/>

    <!-- VirtIO Balloon ATTIVO: consente recupero dinamico della memoria / maggiore densità di consolidamento -->
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