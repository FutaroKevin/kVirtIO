#!/usr/bin/env bash
# ==============================================================================
# Script: kvirtio-vm-create.sh
# Descrizione: Crea una nuova Virtual Machine su un nodo KVM del cluster specificato.
#              Lo script viene eseguito ESCLUSIVAMENTE dal server di management esterno.
#              Gli amministratori non si collegano mai direttamente ai nodi hypervisor.
# Autore: Kevin Tafuro
# Progetto: KvirtIO Virtualization
# ==============================================================================



set -o nounset
set -o pipefail

CONFIG_DIR="/etc/kvirtio/clusters"
MAIL_ALERTER="/usr/local/bin/kvirtio-mail-alerter.py"

# ==============================================================================
# UTILIZZO
# ==============================================================================
usage() {
    cat <<EOF
Utilizzo: $(basename "$0") [OPZIONI]

Opzioni obbligatorie:
  --cluster    <nome>   Nome del cluster di destinazione (es: cluster_db)
  --node       <nome>   Nodo hypervisor di destinazione all'interno del cluster
  --vm-name    <nome>   Nome identificativo della VM (es: vm-db-prod-01)
  --profile    <nome>   Profilo della VM: 'iointensive' oppure 'general'
  --vcpu       <n>      Numero di vCPU da assegnare
  --ram-gb     <n>      Quantità di RAM in GB da assegnare
  --disk-lv    <path>   Path completo del Logical Volume LVM gia' creato (es: /dev/vg_iointensive/lv_vm_db01)

Opzioni facoltative:
  --network    <vlan>   VLAN di produzione (default: 30)
  --help                Mostra questo messaggio

Esempi:
  $(basename "$0") --cluster cluster_db --node node1 --vm-name vm-db-prod-01 \\
                   --profile iointensive --vcpu 32 --ram-gb 256 \\
                   --disk-lv /dev/vg_iointensive/lv_vm_db01 --network 30

  $(basename "$0") --cluster cluster_web --node webnode1 --vm-name vm-web-01 \\
                   --profile general --vcpu 4 --ram-gb 16 \\
                   --disk-lv /dev/vg_web/lv_vm_web01
EOF
    exit 1
}

log() {
    local level="$1"
    local msg="$2"
    logger -t KvirtIO-VMCreate "${level}: ${msg}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
}

# ==============================================================================
# PARSING ARGOMENTI
# ==============================================================================
CLUSTER_NAME=""
TARGET_NODE=""
VM_NAME=""
PROFILE=""
VCPU=""
RAM_GB=""
DISK_LV=""
NETWORK_VLAN="30"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)   CLUSTER_NAME="$2";  shift 2 ;;
        --node)      TARGET_NODE="$2";   shift 2 ;;
        --vm-name)   VM_NAME="$2";       shift 2 ;;
        --profile)   PROFILE="$2";       shift 2 ;;
        --vcpu)      VCPU="$2";          shift 2 ;;
        --ram-gb)    RAM_GB="$2";        shift 2 ;;
        --disk-lv)   DISK_LV="$2";       shift 2 ;;
        --network)   NETWORK_VLAN="$2";  shift 2 ;;
        --help)      usage ;;
        *) log "ERROR" "Parametro non riconosciuto: $1"; usage ;;
    esac
done

# Validazione parametri obbligatori
for param in CLUSTER_NAME TARGET_NODE VM_NAME PROFILE VCPU RAM_GB DISK_LV; do
    if [ -z "${!param}" ]; then
        log "ERROR" "Parametro obbligatorio mancante: --${param//_/-}"
        usage
    fi
done

PROFILE_LC="${PROFILE,,}"
if [[ "$PROFILE_LC" != "iointensive" && "$PROFILE_LC" != "general" ]]; then
    log "ERROR" "Profilo '$PROFILE' non valido. Usare 'iointensive' o 'general'."
    exit 1
fi

# ==============================================================================
# CARICAMENTO CONFIGURAZIONE CLUSTER
# ==============================================================================
CLUSTER_CONF="${CONFIG_DIR}/${CLUSTER_NAME}.conf"
if [ ! -f "$CLUSTER_CONF" ]; then
    log "ERROR" "File di configurazione del cluster '$CLUSTER_NAME' non trovato in ${CONFIG_DIR}."
    exit 1
fi

SSH_USER="kvirtwatch"
NODES=()
# shellcheck source=/dev/null
. "$CLUSTER_CONF"

# Verifica che il nodo di destinazione appartenga al cluster
NODE_FOUND=0
for n in "${NODES[@]}"; do
    if [ "$n" = "$TARGET_NODE" ]; then
        NODE_FOUND=1
        break
    fi
done

if [ "$NODE_FOUND" -eq 0 ]; then
    log "ERROR" "Il nodo '$TARGET_NODE' non appartiene al cluster '$CLUSTER_NAME'."
    log "ERROR" "Nodi disponibili: ${NODES[*]}"
    exit 1
fi

SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

log "INFO" "Avvio creazione VM '$VM_NAME' su nodo '$TARGET_NODE' (cluster: $CLUSTER_NAME, profilo: $PROFILE_LC)."

# ==============================================================================
# COSTRUZIONE XML LIBVIRT IN BASE AL PROFILO
# ==============================================================================
RAM_KIB=$(( RAM_GB * 1024 * 1024 ))

if [ "$PROFILE_LC" = "iointensive" ]; then
    # PROFILO IOINTENSIVE: hugepages 1GB, virtio-scsi multiqueue, cache=none io=native
    DISK_DRIVER_OPTS="cache='none' io='native' discard='unmap'"
    # RIMOSSO --> MEMORY_BACKING="<memoryBacking><hugepages><page size='1048576' unit='KiB'/></hugepages><locked/></memoryBacking>"
    DISK_BUS="scsi"
    DISK_CONTROLLER="<controller type='scsi' index='0' model='virtio-scsi'><driver queues='${VCPU}' iothread='1'/></controller>"
    NUMATUNE="<numatune><memory mode='strict' placement='auto'/></numatune>"
    MEMBALLOON="<memballoon model='none'/>"
    VCPU_PLACEMENT="auto"
else
    # PROFILO GENERAL: nessuna hugepage, virtio standard
    DISK_DRIVER_OPTS="cache='writeback'"
    MEMORY_BACKING=""
    DISK_BUS="virtio"
    DISK_CONTROLLER=""
    NUMATUNE=""
    MEMBALLOON="<memballoon model='virtio'><stats period='10'/></memballoon>"
    VCPU_PLACEMENT="auto"
fi

# Costruisce il documento XML della VM
VM_XML=$(cat <<XMLEOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <uuid>$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)</uuid>
  <memory unit='KiB'>${RAM_KIB}</memory>
  <currentMemory unit='KiB'>${RAM_KIB}</currentMemory>
  ${MEMBALLOON}
  <vcpu placement='${VCPU_PLACEMENT}'>${VCPU}</vcpu>
  ${NUMATUNE}
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none'><topology sockets='1' dies='1' cores='${VCPU}' threads='1'/></cpu>
  <clock offset='utc'><timer name='rtc' tickpolicy='catchup'/></clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    ${DISK_CONTROLLER}
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' ${DISK_DRIVER_OPTS}/>
      <source dev='${DISK_LV}'/>
      <target dev='vda' bus='${DISK_BUS}'/>
    </disk>
    <interface type='bridge'>
      <source bridge='br-vlan${NETWORK_VLAN}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target type='isa-serial' port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <video><model type='vga' vram='16384' heads='1'/></video>
  </devices>
  <metadata>
    <kvirtio:profile xmlns:kvirtio='http://kvirtio.local/metadata'>${PROFILE_LC}</kvirtio:profile>
    <kvirtio:cluster xmlns:kvirtio='http://kvirtio.local/metadata'>${CLUSTER_NAME}</kvirtio:cluster>
  </metadata>
</domain>
XMLEOF
)

# ==============================================================================
# INVIO XML AL NODO E DEFINIZIONE DELLA VM TRAMITE VIRSH VIA SSH
# ==============================================================================
log "INFO" "Invio della definizione XML della VM al nodo ${TARGET_NODE}..."

# Scrive il file XML temporaneo sul nodo e lancia virsh define
DEFINE_OUTPUT=$(echo "$VM_XML" | ssh $SSH_OPTS "${SSH_USER}@${TARGET_NODE}" "
    TMP_XML=\$(mktemp /tmp/kvirtio_vm_XXXXXX.xml)
    cat > \"\$TMP_XML\"
    virsh define \"\$TMP_XML\"
    RETCODE=\$?
    rm -f \"\$TMP_XML\"
    exit \$RETCODE
" 2>&1)
DEFINE_EXIT=$?

if [ "$DEFINE_EXIT" -ne 0 ]; then
    log "ERROR" "Definizione della VM '${VM_NAME}' fallita su ${TARGET_NODE}: ${DEFINE_OUTPUT}"
    if [ -f "$MAIL_ALERTER" ]; then
        python3 "$MAIL_ALERTER" \
            --subject "KvirtIO ERROR: Creazione VM '${VM_NAME}' fallita su ${TARGET_NODE} [${CLUSTER_NAME}]" \
            --body "La definizione della VM ${VM_NAME} (profilo: ${PROFILE_LC}) sul nodo ${TARGET_NODE} del cluster ${CLUSTER_NAME} e' fallita.

Output di errore:
${DEFINE_OUTPUT}

Verificare la disponibilita' del LV: ${DISK_LV}" &
    fi
    exit 1
fi

log "INFO" "VM '${VM_NAME}' definita con successo su ${TARGET_NODE}."

# Avvio automatico della VM
log "INFO" "Avvio della VM '${VM_NAME}'..."
START_OUTPUT=$(ssh $SSH_OPTS "${SSH_USER}@${TARGET_NODE}" "virsh start '${VM_NAME}'" 2>&1)
START_EXIT=$?

if [ "$START_EXIT" -ne 0 ]; then
    log "ERROR" "Avvio della VM '${VM_NAME}' fallito su ${TARGET_NODE}: ${START_OUTPUT}"
    exit 1
fi

# Abilita l'avvio automatico al boot del nodo (autostart)
ssh $SSH_OPTS "${SSH_USER}@${TARGET_NODE}" "virsh autostart '${VM_NAME}'" 2>/dev/null

log "INFO" "====================================================="
log "INFO" "VM '${VM_NAME}' creata e avviata con successo."
log "INFO" "  Cluster  : ${CLUSTER_NAME}"
log "INFO" "  Nodo     : ${TARGET_NODE}"
log "INFO" "  Profilo  : ${PROFILE_LC}"
log "INFO" "  vCPU     : ${VCPU}"
log "INFO" "  RAM      : ${RAM_GB} GB"
log "INFO" "  Disco LV : ${DISK_LV}"
log "INFO" "  VLAN     : ${NETWORK_VLAN}"
log "INFO" "====================================================="

if [ -f "$MAIL_ALERTER" ]; then
    python3 "$MAIL_ALERTER" \
        --subject "KvirtIO: VM '${VM_NAME}' creata su ${TARGET_NODE} [${CLUSTER_NAME}]" \
        --body "La VM ${VM_NAME} e' stata creata e avviata con successo.

Dettagli:
- Cluster : ${CLUSTER_NAME}
- Nodo    : ${TARGET_NODE}
- Profilo : ${PROFILE_LC}
- vCPU    : ${VCPU}
- RAM     : ${RAM_GB} GB
- Disco   : ${DISK_LV}
- VLAN    : ${NETWORK_VLAN}" &
fi
