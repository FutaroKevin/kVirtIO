#!/usr/bin/env bash
# ==============================================================================
# Script: kvirtio-vm-migrate.sh
# Descrizione: Esegue la Live Migration a caldo di una VM da un nodo sorgente
#              a un nodo di destinazione, all'interno dello stesso cluster KvirtIO.
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
  --cluster    <nome>   Nome del cluster KvirtIO (es: cluster_db)
  --vm-name    <nome>   Nome della VM da migrare (es: vm-db-prod-01)
  --from       <nodo>   Nodo sorgente su cui e' attualmente in esecuzione la VM
  --to         <nodo>   Nodo di destinazione per la migrazione

Opzioni facoltative:
  --live               Esegue migrazione a caldo senza interruzione (default: abilitato)
  --compressed         Abilita la compressione della RAM durante il trasferimento
  --timeout    <sec>   Timeout massimo in secondi per il completamento (default: 300)
  --help               Mostra questo messaggio

Esempi:
  # Migrazione standard a caldo da node1 a node3
  $(basename "$0") --cluster cluster_db --vm-name vm-db-prod-01 --from node1 --to node3

  # Migrazione con compressione RAM (utile per VM con elevato working set)
  $(basename "$0") --cluster cluster_db --vm-name vm-db-prod-01 --from node2 --to node4 --compressed
EOF
    exit 1
}

log() {
    local level="$1"
    local msg="$2"
    logger -t KvirtIO-Migrate "${level}: ${msg}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
}

# ==============================================================================
# PARSING ARGOMENTI
# ==============================================================================
CLUSTER_NAME=""
VM_NAME=""
FROM_NODE=""
TO_NODE=""
COMPRESSED=0
TIMEOUT=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)    CLUSTER_NAME="$2"; shift 2 ;;
        --vm-name)    VM_NAME="$2";      shift 2 ;;
        --from)       FROM_NODE="$2";    shift 2 ;;
        --to)         TO_NODE="$2";      shift 2 ;;
        --live)       shift ;;
        --compressed) COMPRESSED=1;      shift ;;
        --timeout)    TIMEOUT="$2";      shift 2 ;;
        --help)       usage ;;
        *) log "ERROR" "Parametro non riconosciuto: $1"; usage ;;
    esac
done

for param in CLUSTER_NAME VM_NAME FROM_NODE TO_NODE; do
    if [ -z "${!param}" ]; then
        log "ERROR" "Parametro obbligatorio mancante: --${param//_/-}"
        usage
    fi
done

if [ "$FROM_NODE" = "$TO_NODE" ]; then
    log "ERROR" "Il nodo sorgente e il nodo di destinazione non possono coincidere ('${FROM_NODE}')."
    exit 1
fi

# ==============================================================================
# CARICAMENTO CONFIGURAZIONE CLUSTER
# ==============================================================================
CLUSTER_CONF="${CONFIG_DIR}/${CLUSTER_NAME}.conf"
if [ ! -f "$CLUSTER_CONF" ]; then
    log "ERROR" "Configurazione del cluster '$CLUSTER_NAME' non trovata in ${CONFIG_DIR}."
    exit 1
fi

SSH_USER="kvirtwatch"
NODES=()
# shellcheck source=/dev/null
. "$CLUSTER_CONF"

SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# Verifica che entrambi i nodi appartengano al cluster
for CHECK_NODE in "$FROM_NODE" "$TO_NODE"; do
    NODE_FOUND=0
    for n in "${NODES[@]}"; do
        [ "$n" = "$CHECK_NODE" ] && NODE_FOUND=1 && break
    done
    if [ "$NODE_FOUND" -eq 0 ]; then
        log "ERROR" "Il nodo '$CHECK_NODE' non appartiene al cluster '$CLUSTER_NAME'."
        log "ERROR" "Nodi disponibili: ${NODES[*]}"
        exit 1
    fi
done

# ==============================================================================
# VERIFICA PRE-MIGRAZIONE
# ==============================================================================
log "INFO" "Verifica stato della VM '${VM_NAME}' sul nodo sorgente '${FROM_NODE}'..."

VM_STATE=$(ssh $SSH_OPTS "${SSH_USER}@${FROM_NODE}" \
    "sudo virsh domstate '${VM_NAME}' 2>/dev/null" | tr -d '[:space:]')

if [ -z "$VM_STATE" ]; then
    log "ERROR" "Impossibile recuperare lo stato della VM '${VM_NAME}' su ${FROM_NODE}. VM non trovata o nodo irraggiungibile."
    exit 1
fi

if [ "$VM_STATE" != "running" ]; then
    log "ERROR" "La VM '${VM_NAME}' non e' in stato 'running' (stato attuale: '${VM_STATE}'). La live migration richiede che la VM sia in esecuzione."
    exit 1
fi

log "INFO" "VM '${VM_NAME}' verificata in stato 'running' su '${FROM_NODE}'."

# Verifica raggiungibilita' del nodo di destinazione
log "INFO" "Verifica raggiungibilita' del nodo di destinazione '${TO_NODE}'..."
if ! ssh $SSH_OPTS "${SSH_USER}@${TO_NODE}" "sudo virsh version --daemon > /dev/null 2>&1"; then
    log "ERROR" "Il nodo di destinazione '${TO_NODE}' non e' raggiungibile o libvirtd non e' operativo."
    exit 1
fi
log "INFO" "Nodo di destinazione '${TO_NODE}' raggiungibile e pronto."

# ==============================================================================
# COSTRUZIONE DEL COMANDO DI MIGRAZIONE
# ==============================================================================
# La migrazione avviene da nodo a nodo tramite libvirt: il nodo sorgente
# apre una connessione TCP diretta al daemon libvirtd del nodo destinazione
# usando il protocollo nativo qemu+tcp (rete di live migration dedicata a 25GbE).
MIGRATE_FLAGS="--live --persistent --undefinesource"
if [ "$COMPRESSED" -eq 1 ]; then
    MIGRATE_FLAGS="$MIGRATE_FLAGS --compressed"
fi

DEST_URI="qemu+tcp://${TO_NODE}/system"

log "INFO" "======================================================"
log "INFO" "Avvio Live Migration"
log "INFO" "  VM      : ${VM_NAME}"
log "INFO" "  Cluster : ${CLUSTER_NAME}"
log "INFO" "  Da      : ${FROM_NODE}"
log "INFO" "  A       : ${TO_NODE}"
log "INFO" "  Timeout : ${TIMEOUT}s"
log "INFO" "  Compress: $([ $COMPRESSED -eq 1 ] && echo 'Si' || echo 'No')"
log "INFO" "======================================================"

START_TS=$(date +%s)

# Il comando virsh migrate viene eseguito via SSH sul nodo SORGENTE,
# che si occupa di inviare la RAM della VM al nodo destinazione.
# Tutta l'operazione e' orchestrata dal management server senza
# che l'amministratore acceda mai direttamente all'hypervisor.
MIGRATE_OUTPUT=$(ssh $SSH_OPTS "${SSH_USER}@${FROM_NODE}" \
    "timeout ${TIMEOUT} sudo virsh migrate ${MIGRATE_FLAGS} '${VM_NAME}' '${DEST_URI}'" 2>&1)
MIGRATE_EXIT=$?

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

if [ "$MIGRATE_EXIT" -ne 0 ]; then
    log "ERROR" "Live Migration di '${VM_NAME}' fallita dopo ${ELAPSED}s."
    log "ERROR" "Output: ${MIGRATE_OUTPUT}"

    if [ -f "$MAIL_ALERTER" ]; then
        python3 "$MAIL_ALERTER" \
            --subject "KvirtIO ERROR: Live Migration '${VM_NAME}' FALLITA [${CLUSTER_NAME}]" \
            --body "La live migration della VM ${VM_NAME} da ${FROM_NODE} verso ${TO_NODE} nel cluster ${CLUSTER_NAME} e' FALLITA dopo ${ELAPSED} secondi.

Dettaglio errore:
${MIGRATE_OUTPUT}

Verificare:
- Lo stato della rete di Live Migration (VLAN 20 - 2x25GbE bonded)
- La disponibilita' di RAM fisica libera sul nodo destinazione ${TO_NODE}
- I log di libvirtd: journalctl -u libvirtd su ${FROM_NODE} e ${TO_NODE}" &
    fi
    exit 1
fi

# ==============================================================================
# VERIFICA POST-MIGRAZIONE
# ==============================================================================
log "INFO" "Verifica stato post-migrazione su '${TO_NODE}'..."
sleep 2

NEW_STATE=$(ssh $SSH_OPTS "${SSH_USER}@${TO_NODE}" \
    "sudo virsh domstate '${VM_NAME}' 2>/dev/null" | tr -d '[:space:]')

if [ "$NEW_STATE" = "running" ]; then
    log "INFO" "======================================================"
    log "INFO" "Live Migration completata con SUCCESSO in ${ELAPSED}s."
    log "INFO" "  VM '${VM_NAME}' ora in esecuzione su '${TO_NODE}'."
    log "INFO" "======================================================"

    if [ -f "$MAIL_ALERTER" ]; then
        python3 "$MAIL_ALERTER" \
            --subject "KvirtIO: Live Migration '${VM_NAME}' completata [${CLUSTER_NAME}]" \
            --body "La live migration della VM ${VM_NAME} e' completata con successo.

Dettagli:
- Cluster     : ${CLUSTER_NAME}
- Sorgente    : ${FROM_NODE}
- Destinazione: ${TO_NODE}
- Durata      : ${ELAPSED} secondi
- Stato VM    : running" &
    fi
else
    log "ERROR" "La migrazione sembra completata ma la VM '${VM_NAME}' risulta in stato '${NEW_STATE}' su '${TO_NODE}'."
    exit 1
fi
