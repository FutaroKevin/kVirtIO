#!/usr/bin/env bash
# ==============================================================================
# Script: kvirtio-host-watcher.sh
# Descrizione: Monitora CPU e RAM dei nodi dei cluster KVM definiti in /etc/kvirtio.
#              Aggiorna l'attributo status-load in Pacemaker via SSH.
# Progetto: KvirtIO Virtualization
# Autore: Kevin Tafuro
# ==============================================================================

set -o nounset
set -o pipefail

CONFIG_DIR="/etc/kvirtio/clusters"

if [ ! -d "$CONFIG_DIR" ]; then
    logger -t KvirtIO-Host "ERROR: Directory di configurazione $CONFIG_DIR non trovata."
    exit 1
fi

# Cerca tutti i file di configurazione dei cluster (.conf)
CONFIG_FILES=("$CONFIG_DIR"/*.conf)
if [ ! -e "${CONFIG_FILES[0]}" ]; then
    logger -t KvirtIO-Host "ERROR: Nessun file di configurazione .conf trovato in $CONFIG_DIR."
    exit 1
fi

SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

for config in "${CONFIG_FILES[@]}"; do
    # Inizializzazione variabili per evitare l'ereditarietà tra cicli di cluster
    CLUSTER_NAME=""
    NODES=()
    SSH_USER="kvirtwatch"
    CPU_THRESHOLD=85
    RAM_THRESHOLD=90
    CONSECUTIVE_LIMIT=3

    # Carica la configurazione del singolo cluster
    # shellcheck source=/dev/null
    if ! . "$config"; then
        logger -t KvirtIO-Host "ERROR: Impossibile caricare la configurazione da $config. Salto il cluster."
        continue
    fi

    if [ -z "$CLUSTER_NAME" ] || [ ${#NODES[@]} -eq 0 ]; then
        logger -t KvirtIO-Host "ERROR: Configurazione invalida in $config (CLUSTER_NAME o NODES non definiti)."
        continue
    fi

    logger -t KvirtIO-Host "INFO: Inizio monitoraggio host per il cluster: $CLUSTER_NAME (${#NODES[@]} nodi)."

    for node in "${NODES[@]}"; do
        STATE_FILE="/tmp/kvirtio_host_state_${CLUSTER_NAME}_${node}"
        
        # Inizializza lo stato se non esiste
        if [ ! -f "$STATE_FILE" ]; then
            echo "COUNT=0" > "$STATE_FILE"
            echo "STATUS=healthy" >> "$STATE_FILE"
        fi

        # Carica lo stato
        # shellcheck source=/dev/null
        . "$STATE_FILE"

        # Recupera metriche via SSH
        read_stats=$(ssh $SSH_OPTS "${SSH_USER}@${node}" "
            # CPU Steal (lettura differenziale su /proc/stat)
            read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
            prev_total=\$((user + nice + system + idle + iowait + irq + softirq + steal))
            prev_steal=\$steal
            sleep 0.5
            read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
            total=\$((user + nice + system + idle + iowait + irq + softirq + steal))
            total_d=\$((total - prev_total))
            steal_d=\$((steal - prev_steal))
            
            if [ \$total_d -gt 0 ]; then
                # Calcola il per mille per avere precisione allo 0.1% con interi
                steal_permille=\$(( (steal_d * 1000) / total_d ))
            else
                steal_permille=0
            fi

            # HugePages_Free da /proc/meminfo
            hp_total=\$(awk '/HugePages_Total/ {print \$2}' /proc/meminfo)
            hp_free=\$(awk '/HugePages_Free/ {print \$2}' /proc/meminfo)
            if [ -z \"\$hp_total\" ]; then hp_total=0; fi
            if [ -z \"\$hp_free\" ]; then hp_free=0; fi
            
            echo \"\$steal_permille \$hp_total \$hp_free\"
        " 2>/dev/null)

        if [ -z "$read_stats" ]; then
            logger -t KvirtIO-Host "ERROR: [$CLUSTER_NAME] Impossibile contattare il nodo ${node}."
            continue
        fi

        read -r steal_permille hp_total hp_free <<< "$read_stats"

        # Verifica soglie HLD
        # Soglia Steal Time > 0.1% (ovvero steal_permille > 1)
        # Soglia HugePages: se hp_total > 0 e hp_free < 5 (rischio blocco)
        is_overloaded=0
        reason=""
        if [ "$steal_permille" -gt 1 ]; then
            is_overloaded=1
            reason="StealTime=${steal_permille}‰"
        elif [ "$hp_total" -gt 0 ] && [ "$hp_free" -lt 5 ]; then
            is_overloaded=1
            reason="HugePagesFree=${hp_free}"
        fi

        if [ "$is_overloaded" -eq 1 ]; then
            COUNT=$((COUNT + 1))
            
            if [ "$COUNT" -ge "$CONSECUTIVE_LIMIT" ]; then
                if [ "$STATUS" != "overloaded" ]; then
                    # Aggiorna attributo su Pacemaker
                    if ssh $SSH_OPTS "${SSH_USER}@${node}" "sudo crm_attribute --node ${node} --name status-load --update 'overloaded'" 2>/dev/null; then
                        STATUS="overloaded"
                        logger -t KvirtIO-Host "CRITICAL: [$CLUSTER_NAME] Nodo ${node} sovraccarico da ${CONSECUTIVE_LIMIT} controlli (${reason}). Impostato 'overloaded'."
                    else
                        logger -t KvirtIO-Host "ERROR: [$CLUSTER_NAME] Errore esecuzione crm_attribute su ${node}."
                    fi
                fi
            else
                logger -t KvirtIO-Host "WARNING: [$CLUSTER_NAME] Picco di carico su ${node} (${reason}). Consecutivi: ${COUNT}/${CONSECUTIVE_LIMIT}."
            fi
        else
            COUNT=0
            if [ "$STATUS" = "overloaded" ]; then
                # Ripristina lo stato healthy
                if ssh $SSH_OPTS "${SSH_USER}@${node}" "sudo crm_attribute --node ${node} --name status-load --update 'healthy'" 2>/dev/null; then
                    STATUS="healthy"
                    logger -t KvirtIO-Host "INFO: [$CLUSTER_NAME] Nodo ${node} rientrato nei parametri (Steal=${steal_permille}‰, HPFree=${hp_free}). Impostato 'healthy'."
                else
                    logger -t KvirtIO-Host "ERROR: [$CLUSTER_NAME] Errore ripristino crm_attribute su ${node}."
                fi
            fi
        fi

        # Salva stato
        cat <<EOF > "$STATE_FILE"
COUNT=${COUNT}
STATUS="${STATUS}"
EOF

        # Esporta JSON per il frontend
        DATA_DIR="/var/www/html/kvirtio/data"
        mkdir -p "$DATA_DIR" 2>/dev/null || true
        cat <<EOF > "${DATA_DIR}/host_${CLUSTER_NAME}_${node}.json"
{
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S")",
  "cluster_name": "${CLUSTER_NAME}",
  "node": "${node}",
  "status_ha": "${STATUS}",
  "metrics": {
    "steal_permille": ${steal_permille},
    "hugepages_total": ${hp_total},
    "hugepages_free": ${hp_free}
  }
}
EOF
    done
done
