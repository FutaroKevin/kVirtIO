#!/usr/bin/env python3
# ==============================================================================
# Script: kvirtio-vm-create.py
# Descrizione: Provvede alla creazione automatica di VM KVM sui nodi del cluster
#              con LVM Striped dinamico e tuning prestazionale XML.
# Autore: Kevin Tafuro
# Progetto: KvirtIO Virtualization
# ==============================================================================

import os
import sys
import argparse
import subprocess
import glob
import syslog

CONFIG_DIR = "/etc/kvirtio/clusters"

def log(msg, priority=syslog.LOG_INFO):
    syslog.openlog(ident="KvirtIO-VMCreate", logoption=syslog.LOG_PID, facility=syslog.LOG_USER)
    syslog.syslog(priority, msg)
    syslog.closelog()

def get_cluster_config(cluster_name):
    """Carica la configurazione del cluster richiesto."""
    filepath = os.path.join(CONFIG_DIR, f"{cluster_name}.conf")
    if not os.path.exists(filepath):
        print(f"Errore: Configurazione per il cluster '{cluster_name}' non trovata.")
        return None
    
    config = {
        "CLUSTER_NAME": cluster_name,
        "NODES": [],
        "SSH_USER": "kvirtwatch",
        "VG_NAME": "vg_iointensive" # Default
    }
    
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                if key == "NODES":
                    nodes_str = val.replace("(", "").replace(")", "")
                    config["NODES"] = [n.strip('"').strip("'") for n in nodes_str.split() if n]
                elif key == "SSH_USER":
                    config["SSH_USER"] = val
                elif key == "VG_NAME":
                    config["VG_NAME"] = val
    return config

def execute_remote(node, user, command):
    """Esegue un comando remoto via SSH."""
    ssh_opts = ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
    try:
        res = subprocess.run(
            ["ssh"] + ssh_opts + [f"{user}@{node}", command],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15
        )
        return res.returncode, res.stdout, res.stderr
    except Exception as e:
        return -1, "", str(e)

def generate_vm_xml(name, cpu, ram_gb, profile, vg_name):
    """Genera l'XML di Libvirt ottimizzato in base al profilo di carico."""
    ram_kib = ram_gb * 1024 * 1024
    disk_path = f"/dev/{vg_name}/lv_vm_{name}"
    
    if profile == "IOIntensive":
        # Tuning estremo: NUMA pinning, Hugepages da 1GB bloccate in RAM e VirtIO Multi-Queue
        return f"""<domain type='kvm'>
  <name>{name}</name>
  <memory unit='KiB'>{ram_kib}</memory>
  <currentMemory unit='KiB'>{ram_kib}</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='1048576' unit='KiB'/>
    </hugepages>
    <locked/>
  </memoryBacking>
  <vcpu placement='static'>{cpu}</vcpu>
  <cpu mode='host-passthrough'>
    <topology sockets='1' cores='{cpu}' threads='1'/>
  </cpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='{cpu}' iothread='1'/>
    </controller>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='{disk_path}'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
    <interface type='bridge'>
      <source bridge='br-prod'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
</domain>
"""
    else:
        # Profilo General Purpose standard
        return f"""<domain type='kvm'>
  <name>{name}</name>
  <memory unit='KiB'>{ram_kib}</memory>
  <currentMemory unit='KiB'>{ram_kib}</currentMemory>
  <vcpu placement='static'>{cpu}</vcpu>
  <cpu mode='host-model'/>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source dev='{disk_path}'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <interface type='bridge'>
      <source bridge='br-prod'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
</domain>
"""

def main():
    parser = argparse.ArgumentParser(description="Creazione automatica VM nel cluster KvirtIO")
    parser.add_argument("--cluster", required=True, help="Nome del cluster")
    parser.add_argument("--node", required=True, help="Nodo iniziale su cui creare la VM")
    parser.add_argument("--name", required=True, help="Nome della Virtual Machine")
    parser.add_argument("--cpu", type=int, required=True, help="Numero di vCPU")
    parser.add_argument("--ram", type=int, required=True, help="RAM in Gigabyte")
    parser.add_argument("--disk", type=int, required=True, help="Dimensione disco in Gigabyte")
    parser.add_argument("--profile", choices=["IOIntensive", "General"], default="General", help="Profilo prestazionale")
    args = parser.parse_args()

    config = get_cluster_config(args.cluster)
    if not config:
        sys.exit(1)

    if args.node not in config["NODES"]:
        print(f"Errore: Il nodo '{args.node}' non appartiene al cluster '{args.cluster}'.")
        sys.exit(1)

    user = config["SSH_USER"]
    vg_name = config["VG_NAME"]

    print(f"=== Creazione VM '{args.name}' su '{args.node}' [Cluster: {args.cluster}] ===")
    
    # 1. Rileva i PV del Volume Group per ottimizzare lo striping
    print("Verifica della topologia storage LVM...")
    pv_cmd = f"sudo /usr/sbin/vgs -o pv_count --noheadings {vg_name} 2>/dev/null"
    code, out, err = execute_remote(args.node, user, pv_cmd)
    if code != 0 or not out.strip():
        print(f"Errore storage: Impossibile leggere il Volume Group {vg_name}. Dettaglio: {err}")
        sys.exit(1)
    
    try:
        pv_count = int(out.strip())
    except ValueError:
        pv_count = 1

    # 2. Alloca lo spazio disco remoto
    print(f"Allocazione spazio LVM ({args.disk}GB) sul Volume Group '{vg_name}'...")
    if args.profile == "IOIntensive" and pv_count > 1:
        # Ottimizza lo striping su tutte le LUN/PV disponibili nel cluster
        lv_cmd = f"sudo /usr/sbin/lvcreate -i {pv_count} -I 64k -n lv_vm_{args.name} -L {args.disk}G {vg_name}"
    else:
        lv_cmd = f"sudo /usr/sbin/lvcreate -n lv_vm_{args.name} -L {args.disk}G {vg_name}"
        
    code, out, err = execute_remote(args.node, user, lv_cmd)
    if code != 0:
        print(f"Errore: Allocazione LVM fallita. {err}")
        sys.exit(1)
    print("Spazio LVM allocato con successo.")

    # 3. Genera l'XML di definizione
    xml_content = generate_vm_xml(args.name, args.cpu, args.ram, args.profile, vg_name)
    
    # 4. Registra l'XML sul nodo ed esegue il define
    temp_xml_path = f"/tmp/kvirtio_vm_{args.name}.xml"
    print("Registrazione e definizione della VM su Libvirt...")
    
    # Scrive l'XML su un file temporaneo locale e lo copia via SSH (o lo passa in stdin)
    def_cmd = f"cat <<'EOF' > {temp_xml_path}\n{xml_content}\nEOF\nsudo /usr/bin/virsh define {temp_xml_path} && rm -f {temp_xml_path}"
    code, out, err = execute_remote(args.node, user, def_cmd)
    if code != 0:
        # Rollback LVM in caso di errore define
        print(f"Errore: Definizione VM fallita. Eseguo rollback storage. Dettaglio: {err}")
        execute_remote(args.node, user, f"sudo /usr/sbin/lvremove -f /dev/{vg_name}/lv_vm_{args.name}")
        sys.exit(1)
    print("VM definita correttamente in Libvirt.")

    # 5. Avvia la Virtual Machine
    print("Avvio della Virtual Machine...")
    start_cmd = f"sudo /usr/bin/virsh start {args.name}"
    code, out, err = execute_remote(args.node, user, start_cmd)
    if code != 0:
        print(f"Errore: Impossibile avviare la VM. Dettaglio: {err}")
        sys.exit(1)
        
    print(f"SUCCESS: Virtual Machine '{args.name}' creata e avviata correttamente.")
    log(f"SUCCESS: Creata e avviata VM '{args.name}' sul nodo {args.node} (CPU: {args.cpu}, RAM: {args.ram}GB, Profilo: {args.profile})")

if __name__ == "__main__":
    main()
