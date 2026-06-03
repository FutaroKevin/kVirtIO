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
            # CPU (lettura differenziale su /proc/stat)
            read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
            prev_idle=\$((idle + iowait))
            prev_non_idle=\$((user + nice + system + irq + softirq + steal))
            prev_total=\$((prev_idle + prev_non_idle))
            sleep 0.5
            read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
            idle=\$((idle + iowait))
            non_idle=\$((user + nice + system + irq + softirq + steal))
            total=\$((idle + non_idle))
            total_d=\$((total - prev_total))
            idle_d=\$((idle - prev_idle))
            if [ \$total_d -gt 0 ]; then
                cpu_usage=\$(( (total_d - idle_d) * 100 / total_d ))
            else
                cpu_usage=0
            fi

            # RAM (MemAvailable su /proc/meminfo)
            read -r _ mem_total _ < <(grep MemTotal /proc/meminfo)
            read -r _ mem_avail _ < <(grep MemAvailable /proc/meminfo)
            mem_used=\$((mem_total - mem_avail))
            ram_usage=\$((mem_used * 100 / mem_total))
            
            echo \"\$cpu_usage \$ram_usage\"
        " 2>/dev/null)

        if [ -z "$read_stats" ]; then
            logger -t KvirtIO-Host "ERROR: [$CLUSTER_NAME] Impossibile contattare il nodo ${node}."
            continue
        fi

        read -r cpu_val ram_val <<< "$read_stats"

        # Verifica soglie
        if [ "$cpu_val" -gt "$CPU_THRESHOLD" ] || [ "$ram_val" -gt "$RAM_THRESHOLD" ]; then
            COUNT=$((COUNT + 1))
            
            if [ "$COUNT" -ge "$CONSECUTIVE_LIMIT" ]; then
                if [ "$STATUS" != "overloaded" ]; then
                    # Aggiorna attributo su Pacemaker
                    if ssh $SSH_OPTS "${SSH_USER}@${node}" "sudo crm_attribute --node ${node} --name status-load --update 'overloaded'" 2>/dev/null; then
                        STATUS="overloaded"
                        logger -t KvirtIO-Host "CRITICAL: [$CLUSTER_NAME] Nodo ${node} sovraccarico da ${CONSECUTIVE_LIMIT} controlli (CPU: ${cpu_val}%, RAM: ${ram_val}%). Impostato 'overloaded'."
                    else
                        logger -t KvirtIO-Host "ERROR: [$CLUSTER_NAME] Errore esecuzione crm_attribute su ${node}."
                    fi
                fi
            else
                logger -t KvirtIO-Host "WARNING: [$CLUSTER_NAME] Picco di carico su ${node} (CPU: ${cpu_val}%, RAM: ${ram_val}%). Consecutivi: ${COUNT}/${CONSECUTIVE_LIMIT}."
            fi
        else
            COUNT=0
            if [ "$STATUS" = "overloaded" ]; then
                # Ripristina lo stato healthy
                if ssh $SSH_OPTS "${SSH_USER}@${node}" "sudo crm_attribute --node ${node} --name status-load --update 'healthy'" 2>/dev/null; then
                    STATUS="healthy"
                    logger -t KvirtIO-Host "INFO: [$CLUSTER_NAME] Nodo ${node} rientrato nei parametri (CPU: ${cpu_val}%, RAM: ${ram_val}%). Impostato 'healthy'."
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
    done
done
