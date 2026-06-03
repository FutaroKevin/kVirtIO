#!/usr/bin/env bash
# ==============================================================================
# Script: kvirtio-io-watcher.sh
# Descrizione: Monitora la latenza delle LUN FC sui nodi dei cluster definiti in /etc/kvirtio.
# Progetto: KvirtIO Virtualization
# Autore: Kevin Tafuro
# ==============================================================================

set -o nounset
set -o pipefail

CONFIG_DIR="/etc/kvirtio/clusters"

if [ ! -d "$CONFIG_DIR" ]; then
    logger -t KvirtIO-IO "ERROR: Directory di configurazione $CONFIG_DIR non trovata."
    exit 1
fi

CONFIG_FILES=("$CONFIG_DIR"/*.conf)
if [ ! -e "${CONFIG_FILES[0]}" ]; then
    logger -t KvirtIO-IO "ERROR: Nessun file di configurazione .conf trovato in $CONFIG_DIR."
    exit 1
fi

SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

for config in "${CONFIG_FILES[@]}"; do
    # Inizializzazione variabili per evitare l'ereditarietà tra cicli di cluster
    CLUSTER_NAME=""
    NODES=()
    SSH_USER="kvirtwatch"
    LATENCY_THRESHOLD=10.0

    if ! . "$config"; then
        logger -t KvirtIO-IO "ERROR: Impossibile caricare la configurazione da $config. Salto il cluster."
        continue
    fi

    if [ -z "$CLUSTER_NAME" ] || [ ${#NODES[@]} -eq 0 ]; then
        logger -t KvirtIO-IO "ERROR: Configurazione invalida in $config (CLUSTER_NAME o NODES non definiti)."
        continue
    fi

    logger -t KvirtIO-IO "INFO: Inizio monitoraggio I/O per il cluster: $CLUSTER_NAME (${#NODES[@]} nodi)."

    for node in "${NODES[@]}"; do
        # Esegue iostat sul nodo KVM e processa localmente tramite awk
        max_await=$(ssh $SSH_OPTS "${SSH_USER}@${node}" "sudo iostat -dx 1 2" 2>/dev/null | awk '
            BEGIN { report = 0; max_val = 0.0; }
            /^(Device|Device:)/ { 
                report++; 
                for (i=1; i<=NF; i++) {
                    if ($i ~ /await/) {
                        await_cols[i] = 1;
                    }
                }
                next;
            }
            report == 2 && /^dm-/ {
                for (col in await_cols) {
                    val = $col;
                    gsub(/,/, ".", val);
                    if (val + 0 > max_val) {
                        max_val = val + 0;
                    }
                }
            }
            END { print max_val }
        ')

        if [ -z "$max_await" ]; then
            logger -t KvirtIO-IO "ERROR: [$CLUSTER_NAME] Impossibile raccogliere metriche I/O da ${node}."
            continue
        fi

        is_above_threshold=$(awk -v val="$max_await" -v thresh="$LATENCY_THRESHOLD" 'BEGIN { print (val > thresh) ? 1 : 0 }')

        if [ "$is_above_threshold" -eq 1 ]; then
            logger -t KvirtIO-IO "WARNING: [$CLUSTER_NAME] Latenza I/O anomala sul nodo ${node}. Massimo await riscontrato su multipath: ${max_await}ms (Soglia: ${LATENCY_THRESHOLD}ms)."
        fi
    done
done
