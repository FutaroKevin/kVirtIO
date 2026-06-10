#!/usr/bin/env bash
# ==============================================================================
# Script:       kvirtio-console-tracker.sh
# Descrizione:  Demone che mantiene allineata la Token Directory di websockify
#               con lo stato reale del cluster. Per ogni VM in esecuzione,
#               interroga virsh domdisplay e ricava l'IP:Porta VNC attuale,
#               aggiornando il file dei token usato da websockify per il proxy
#               della console noVNC.
#
# Architettura:
#   - Viene eseguito sul nodo di Management (watcher), NON sui KVM hypervisor.
#   - Legge i cluster da /etc/kvirtio/clusters/*.conf
#   - Per ogni cluster, interroga i nodi via SSH (con sudo virsh) per ottenere
#     l'elenco VM running e il loro display VNC.
#   - Scrive un file token per websockify: /var/lib/kvirtio/novnc/tokens/<cluster>.conf
#   - Aggiorna anche il JSON per il dashboard: /var/www/html/kvirtio/data/console_<cluster>.json
#
# Dipendenze:   bash, ssh, virsh (remoto via sudo), jq (opzionale), logger
#
# Autore:       Kevin Tafuro
# ==============================================================================

set -euo pipefail

# --- Configurazione ---
readonly CONF_DIR="/etc/kvirtio/clusters"
readonly TOKEN_DIR="/var/lib/kvirtio/novnc/tokens"
readonly DATA_DIR="/var/www/html/kvirtio/data"
readonly LOG_TAG="KvirtIO-ConsoleTracker"
readonly POLL_INTERVAL=10          # secondi tra un ciclo e il successivo
readonly SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no"
readonly SSH_USER="${KVIRTIO_SSH_USER:-kvirtio-watcher}"

# --- Funzioni di supporto ---

log_info()  { logger -t "$LOG_TAG" -- "INFO:  $*"; echo "[INFO]  $*"; }
log_warn()  { logger -t "$LOG_TAG" -- "WARN:  $*"; echo "[WARN]  $*" >&2; }
log_error() { logger -t "$LOG_TAG" -- "ERROR: $*"; echo "[ERROR] $*" >&2; }

# Verifica dipendenze iniziali
check_dependencies() {
    local missing=0
    for cmd in ssh virsh; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Comando '$cmd' non trovato. Installarlo prima di continuare."
            missing=1
        fi
    done
    [ "$missing" -eq 1 ] && exit 1
}

# Legge la lista dei nodi dal file di configurazione del cluster
# Formato atteso: NODE_LIST="node1 node2 node3"
get_nodes_for_cluster() {
    local conf_file="$1"
    local node_list=""
    if grep -q "^NODE_LIST=" "$conf_file"; then
        node_list=$(grep "^NODE_LIST=" "$conf_file" | cut -d'"' -f2 | tr ' ' '\n' | grep -v '^$')
    fi
    echo "$node_list"
}

# Ottiene il nome del cluster dal file di configurazione
# Formato atteso: CLUSTER_NAME="cluster1"
get_cluster_name() {
    local conf_file="$1"
    grep "^CLUSTER_NAME=" "$conf_file" | cut -d'"' -f2
}

# ==============================================================================
# Funzione core: aggiorna i token per un singolo cluster
# Interroga ogni nodo KVM via SSH e recupera la mappa VM -> VNC display
# ==============================================================================
update_tokens_for_cluster() {
    local cluster_name="$1"
    local conf_file="$2"

    local nodes
    nodes=$(get_nodes_for_cluster "$conf_file")

    if [ -z "$nodes" ]; then
        log_warn "[$cluster_name] Nessun nodo trovato nel file di configurazione."
        return 1
    fi

    # Token file temporaneo per scrittura atomica
    local token_file="${TOKEN_DIR}/${cluster_name}.conf"
    local token_tmp="${token_file}.tmp.$$"
    local json_file="${DATA_DIR}/console_${cluster_name}.json"
    local json_tmp="${json_file}.tmp.$$"

    # Intestazione file token websockify
    # Formato: <token>: <host>:<porta>
    echo "# KvirtIO noVNC Token Directory - Cluster: ${cluster_name}" > "$token_tmp"
    echo "# Generato da kvirtio-console-tracker il: $(date --iso-8601=seconds)" >> "$token_tmp"
    echo "" >> "$token_tmp"

    # Intestazione JSON
    local json_entries=""
    local ts
    ts=$(date --iso-8601=seconds)

    for node in $nodes; do
        # Recupera lista VM in esecuzione sul nodo via SSH
        local running_vms
        if ! running_vms=$(ssh $SSH_OPTS "${SSH_USER}@${node}" \
            "sudo virsh list --state-running --name 2>/dev/null" 2>/dev/null); then
            log_warn "[$cluster_name] Impossibile raggiungere il nodo ${node}. Salto."
            continue
        fi

        # Itera su ogni VM in esecuzione
        while IFS= read -r vm_name; do
            [ -z "$vm_name" ] && continue

            # Recupera l'indirizzo VNC: es. "vnc://0.0.0.0:5900"
            local display_raw
            if ! display_raw=$(ssh $SSH_OPTS "${SSH_USER}@${node}" \
                "sudo virsh domdisplay ${vm_name} 2>/dev/null" 2>/dev/null); then
                log_warn "[$cluster_name] Impossibile ottenere il display di ${vm_name} su ${node}."
                continue
            fi

            # Estrai porta VNC dall'output (formato: vnc://0.0.0.0:5900 o vnc://:5900)
            local vnc_port
            vnc_port=$(echo "$display_raw" | grep -oP ':\K[0-9]+$' | head -1)

            if [ -z "$vnc_port" ]; then
                log_warn "[$cluster_name] Nessuna porta VNC per ${vm_name} su ${node}."
                continue
            fi

            # Usa l'IP di management del nodo (risoluzione DNS o come nel conf)
            local node_ip
            node_ip=$(getent hosts "$node" 2>/dev/null | awk '{print $1}' | head -1)
            [ -z "$node_ip" ] && node_ip="$node"

            # Scrivi token per websockify
            # Formato: token_name: host:port
            echo "${vm_name}: ${node_ip}:${vnc_port}" >> "$token_tmp"

            # Accumula entry JSON
            if [ -n "$json_entries" ]; then
                json_entries="${json_entries},"
            fi
            json_entries="${json_entries}
    {
      \"vm\": \"${vm_name}\",
      \"host\": \"${node}\",
      \"host_ip\": \"${node_ip}\",
      \"vnc_port\": ${vnc_port},
      \"token\": \"${vm_name}\",
      \"novnc_url\": \"/novnc/vnc.html?autoconnect=true&path=websockify&token=${vm_name}\"
    }"

            log_info "[$cluster_name] Aggiornato token: ${vm_name} -> ${node_ip}:${vnc_port}"

        done <<< "$running_vms"
    done

    # Scrittura atomica del file token
    mv "$token_tmp" "$token_file"

    # Scrittura atomica del JSON per il dashboard
    cat > "$json_tmp" <<EOF
{
  "type": "console",
  "cluster_name": "${cluster_name}",
  "timestamp": "${ts}",
  "consoles": [${json_entries}
  ]
}
EOF
    mv "$json_tmp" "$json_file"

    log_info "[$cluster_name] Token directory aggiornata: ${token_file}"
}

# ==============================================================================
# Ciclo principale del demone
# ==============================================================================
main() {
    check_dependencies

    # Crea le directory necessarie se non esistono
    mkdir -p "$TOKEN_DIR" "$DATA_DIR"

    if [ ! -d "$CONF_DIR" ]; then
        log_error "Directory di configurazione '$CONF_DIR' non trovata. Uscita."
        exit 1
    fi

    log_info "KvirtIO Console Tracker avviato. Polling ogni ${POLL_INTERVAL}s."
    log_info "Token directory: ${TOKEN_DIR}"
    log_info "Data directory:  ${DATA_DIR}"

    # Loop infinito del demone (gestito da systemd con Restart=on-failure)
    while true; do
        local conf_count=0

        # Itera su tutti i file di configurazione cluster
        for conf_file in "${CONF_DIR}"/*.conf; do
            [ -f "$conf_file" ] || continue
            conf_count=$((conf_count + 1))

            local cluster_name
            cluster_name=$(get_cluster_name "$conf_file")

            if [ -z "$cluster_name" ]; then
                log_warn "File di configurazione senza CLUSTER_NAME: ${conf_file}. Salto."
                continue
            fi

            # Aggiorna i token per questo cluster (gestione errori non-fatale)
            update_tokens_for_cluster "$cluster_name" "$conf_file" || \
                log_warn "[$cluster_name] Errore durante l'aggiornamento token. Riprovo al ciclo successivo."
        done

        if [ "$conf_count" -eq 0 ]; then
            log_warn "Nessun file .conf trovato in ${CONF_DIR}. In attesa..."
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Gestione segnali (per uscita pulita da systemd)
trap 'log_info "Console Tracker arrestato (SIGTERM)."; exit 0' TERM INT

main "$@"
