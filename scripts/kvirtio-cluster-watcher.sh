#!/bin/bash
# =============================================================================
# Script:      kvirtio-cluster-watcher.sh
# Descrizione: Monitora lo stato del cluster Pacemaker/Corosync e del fencing.
#              Legge i file .conf in /etc/kvirtio/clusters/, si connette al
#              primo nodo online disponibile per ogni cluster, e scrive lo
#              stato in un file JSON in /tmp/.
# Autore:      Kevin Tafuro
# Progetto:    KvirtIO Virtualization
# =============================================================================

set -o nounset
set -o pipefail

readonly SCRIPT_TAG="KvirtIO-Cluster"
readonly CONF_DIR="/etc/kvirtio/clusters"
readonly SSH_USER="kvirtwatch"
readonly SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new"
readonly ALERTER="/usr/local/bin/kvirtio-mail-alerter.py"
readonly ALERT_LOCK_DIR="/tmp"

log_info()     { logger -t "${SCRIPT_TAG}" "INFO: $*"; }
log_warning()  { logger -t "${SCRIPT_TAG}" "WARNING: $*"; }
log_critical() { logger -t "${SCRIPT_TAG}" "CRITICAL: $*"; }
log_error()    { logger -t "${SCRIPT_TAG}" "ERROR: $*"; }

# ---------------------------------------------------------------------------
# Invia alert via mail, con controllo cooldown.
# $1 = cluster_name, $2 = tipo_alert, $3 = subject, $4 = body
# ---------------------------------------------------------------------------
send_alert() {
    local cluster_name="$1"
    local alert_type="$2"
    local subject="$3"
    local body="$4"

    local lock_file="${ALERT_LOCK_DIR}/kvirtio_alert_lock_${cluster_name}_${alert_type}"
    local cooldown_minutes="${ALERT_COOLDOWN_MINUTES:-30}"
    local now
    now=$(date +%s)

    if [[ -f "${lock_file}" ]]; then
        local last_sent
        last_sent=$(cat "${lock_file}" 2>/dev/null || echo 0)
        local elapsed=$(( now - last_sent ))
        local cooldown_secs=$(( cooldown_minutes * 60 ))
        if (( elapsed < cooldown_secs )); then
            log_info "Alert '${alert_type}' per ${cluster_name} già inviato ${elapsed}s fa (cooldown ${cooldown_secs}s). Saltato."
            return
        fi
    fi

    echo "${now}" > "${lock_file}"
    #python3 "${ALERTER}" --subject "${subject}" --body "${body}" &
    log_info "Alert inviato: ${subject}"
}

# ---------------------------------------------------------------------------
# Trova il primo nodo raggiungibile di un cluster.
# Stampa il nome del nodo su stdout; ritorna 1 se nessun nodo è online.
# ---------------------------------------------------------------------------
find_first_online_node() {
    local -n _nodes_ref=$1
    for node in "${_nodes_ref[@]}"; do
        if ssh ${SSH_OPTS} "${SSH_USER}@${node}" "true" 2>/dev/null; then
            echo "${node}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Parsing XML di crm_mon: estrae stato nodi e risorse in FAILED/Stopped.
# Output: JSON inline (assegnato a variabili globali per semplicità bash)
# ---------------------------------------------------------------------------
parse_crm_xml() {
    local xml_output="$1"

    # Estrai stati nodi: <node name="node01" ... online="true" standby="false" .../>
    PARSED_NODES_JSON="["
    local first=1
    while IFS= read -r line; do
        local name online standby maintenance
        name=$(echo "${line}"   | grep -oP 'name="\K[^"]+')
        online=$(echo "${line}" | grep -oP 'online="\K[^"]+')
        standby=$(echo "${line}"| grep -oP 'standby="\K[^"]+')
        maintenance=$(echo "${line}" | grep -oP 'maintenance="\K[^"]+' || echo "false")

        [[ -z "${name}" ]] && continue

        local state="offline"
        [[ "${online}" == "true" && "${standby}" != "true" ]] && state="online"
        [[ "${standby}" == "true" ]] && state="standby"
        [[ "${maintenance}" == "true" ]] && state="maintenance"

        [[ "${first}" -eq 0 ]] && PARSED_NODES_JSON+=","
        PARSED_NODES_JSON+="{\"name\":\"${name}\",\"state\":\"${state}\"}"
        first=0
    done < <(echo "${xml_output}" | grep -oP '<node [^/]*/>' | grep -v 'type="remote"')
    PARSED_NODES_JSON+="]"

    # Estrai risorse in FAILED o Stopped
    PARSED_FAILED_JSON="["
    first=1
    while IFS= read -r line; do
        local res_name res_node res_status
        res_name=$(echo "${line}"   | grep -oP 'id="\K[^"]+')
        res_node=$(echo "${line}"   | grep -oP 'on_node="\K[^"]+' || echo "unknown")
        res_status=$(echo "${line}" | grep -oP '(FAILED|Stopped)')

        [[ -z "${res_name}" || -z "${res_status}" ]] && continue

        [[ "${first}" -eq 0 ]] && PARSED_FAILED_JSON+=","
        PARSED_FAILED_JSON+="{\"name\":\"${res_name}\",\"node\":\"${res_node}\",\"status\":\"${res_status}\"}"
        first=0
    done < <(echo "${xml_output}" | grep -E 'FAILED|Stopped' | grep -oP '<resource [^/]*/>')
    PARSED_FAILED_JSON+="]"
}

# ---------------------------------------------------------------------------
# Parsing output corosync-quorumtool -s
# ---------------------------------------------------------------------------
parse_quorum() {
    local quorum_output="$1"

    QUORUM_STATUS="lost"
    EXPECTED_VOTES=0
    ACTUAL_VOTES=0

    if echo "${quorum_output}" | grep -q "Quorum:.*Yes"; then
        QUORUM_STATUS="present"
    fi

    EXPECTED_VOTES=$(echo "${quorum_output}" | grep -oP 'Expected votes:\s+\K[0-9]+' || echo 0)
    ACTUAL_VOTES=$(echo "${quorum_output}"   | grep -oP 'Total votes:\s+\K[0-9]+'   || echo 0)
}

# ---------------------------------------------------------------------------
# Parsing output stonith_admin --list-registered
# ---------------------------------------------------------------------------
parse_stonith() {
    local stonith_output="$1"
    STONITH_AGENTS_JSON="["
    local first=1
    while IFS= read -r agent; do
        [[ -z "${agent}" ]] && continue
        [[ "${first}" -eq 0 ]] && STONITH_AGENTS_JSON+=","
        STONITH_AGENTS_JSON+="\"${agent}\""
        first=0
    done < <(echo "${stonith_output}" | grep -v '^$')
    STONITH_AGENTS_JSON+="]"
}

# ---------------------------------------------------------------------------
# Elabora un singolo cluster
# ---------------------------------------------------------------------------
process_cluster() {
    local conf_file="$1"

    # Reset variabili config
    CLUSTER_NAME=""
    NODES=()
    ALERT_COOLDOWN_MINUTES=30

    # Source configurazione
    # shellcheck source=/dev/null
    source "${conf_file}" || { log_error "Impossibile leggere ${conf_file}"; return 1; }

    [[ -z "${CLUSTER_NAME}" ]] && { log_error "CLUSTER_NAME non definito in ${conf_file}"; return 1; }
    [[ ${#NODES[@]} -eq 0 ]]  && { log_error "Array NODES vuoto in ${conf_file}"; return 1; }

    log_info "[${CLUSTER_NAME}] Avvio ciclo watcher cluster."

    local data_dir="/var/www/html/kvirtio/data"
    mkdir -p "${data_dir}" 2>/dev/null || true
    local state_file="${data_dir}/cluster_${CLUSTER_NAME}.json"
    local prev_state_file="/tmp/kvirtio_cluster_prev_state_${CLUSTER_NAME}"

    # Trova primo nodo online
    local active_node
    if ! active_node=$(find_first_online_node NODES); then
        log_critical "[${CLUSTER_NAME}] Nessun nodo raggiungibile via SSH."
        send_alert "${CLUSTER_NAME}" "no_node" \
            "KvirtIO CRITICAL: Cluster ${CLUSTER_NAME} — Nessun nodo raggiungibile" \
            "Cluster: ${CLUSTER_NAME}\nDettaglio: Nessun nodo del cluster è raggiungibile via SSH.\nTimestamp: $(date)"
        return 1
    fi

    log_info "[${CLUSTER_NAME}] Nodo rappresentativo: ${active_node}"

    # Raccolta dati via SSH (singola connessione per comando, stesso pattern esistente)
    local crm_xml quorum_out stonith_out
    crm_xml=$(ssh ${SSH_OPTS} "${SSH_USER}@${active_node}" \
        "sudo /usr/sbin/crm_mon --one-shot --output-as=xml" 2>/dev/null) || {
        log_error "[${CLUSTER_NAME}] Errore esecuzione crm_mon su ${active_node}."
        return 1
    }

    quorum_out=$(ssh ${SSH_OPTS} "${SSH_USER}@${active_node}" \
        "sudo /usr/sbin/corosync-quorumtool -s" 2>/dev/null) || {
        log_warning "[${CLUSTER_NAME}] Errore corosync-quorumtool su ${active_node}."
        quorum_out=""
    }

    stonith_out=$(ssh ${SSH_OPTS} "${SSH_USER}@${active_node}" \
        "sudo /usr/sbin/stonith_admin --list-registered" 2>/dev/null) || {
        log_warning "[${CLUSTER_NAME}] Errore stonith_admin su ${active_node}."
        stonith_out=""
    }

    # Parsing
    parse_crm_xml "${crm_xml}"
    parse_quorum  "${quorum_out}"
    parse_stonith "${stonith_out}"

    # Scrittura JSON di stato
    local generated_at
    generated_at=$(date -u +"%Y-%m-%dT%H:%M:%S")
    cat > "${state_file}" <<EOF
{
  "generated_at": "${generated_at}",
  "cluster_name": "${CLUSTER_NAME}",
  "quorum": "${QUORUM_STATUS}",
  "expected_votes": ${EXPECTED_VOTES},
  "actual_votes": ${ACTUAL_VOTES},
  "nodes": ${PARSED_NODES_JSON},
  "failed_resources": ${PARSED_FAILED_JSON},
  "stonith_agents": ${STONITH_AGENTS_JSON}
}
EOF

    # ---- Logica di stato e alerting ----
    local current_state="OK"

    # Quorum
    if [[ "${QUORUM_STATUS}" == "lost" ]]; then
        log_critical "[${CLUSTER_NAME}] Quorum perso: ${ACTUAL_VOTES}/${EXPECTED_VOTES} voti attivi."
        current_state="CRITICAL"
        send_alert "${CLUSTER_NAME}" "quorum_lost" \
            "KvirtIO CRITICAL: Cluster ${CLUSTER_NAME} — Quorum perso" \
            "Cluster: ${CLUSTER_NAME}\nDettaglio: Quorum perso. Voti attivi: ${ACTUAL_VOTES}/${EXPECTED_VOTES}.\nTimestamp: $(date)"
    fi

    # Nodi offline non attesi
    local offline_nodes
    offline_nodes=$(echo "${PARSED_NODES_JSON}" | grep -oP '"name":"[^"]+","state":"offline"' | grep -oP '"name":"\K[^"]+')
    if [[ -n "${offline_nodes}" ]]; then
        while IFS= read -r offline_node; do
            log_critical "[${CLUSTER_NAME}] Nodo non previsto offline: ${offline_node}."
            current_state="CRITICAL"
            send_alert "${CLUSTER_NAME}" "node_offline_${offline_node}" \
                "KvirtIO CRITICAL: Cluster ${CLUSTER_NAME} — Nodo ${offline_node} offline" \
                "Cluster: ${CLUSTER_NAME}\nNodo: ${offline_node}\nDettaglio: Nodo offline non pianificato.\nTimestamp: $(date)"
        done <<< "${offline_nodes}"
    fi

    # Risorse in FAILED
    if [[ "${PARSED_FAILED_JSON}" != "[]" ]]; then
        log_warning "[${CLUSTER_NAME}] Risorse in stato FAILED/Stopped rilevate."
        [[ "${current_state}" != "CRITICAL" ]] && current_state="WARNING"
    fi

    # STONITH
    if [[ "${STONITH_AGENTS_JSON}" == "[]" ]]; then
        log_warning "[${CLUSTER_NAME}] Nessun agente STONITH registrato."
        [[ "${current_state}" != "CRITICAL" ]] && current_state="WARNING"
    fi

    # Recovery da stato precedente
    local prev_state
    prev_state=$(cat "${prev_state_file}" 2>/dev/null || echo "UNKNOWN")
    if [[ "${prev_state}" != "OK" && "${current_state}" == "OK" ]]; then
        log_info "[${CLUSTER_NAME}] Cluster tornato in stato OK (era: ${prev_state})."
        send_alert "${CLUSTER_NAME}" "cluster_recovery" \
            "KvirtIO RECOVERY: Cluster ${CLUSTER_NAME} — Tornato OK" \
            "Cluster: ${CLUSTER_NAME}\nDettaglio: Cluster tornato in stato normale.\nTimestamp: $(date)"
    fi

    echo "${current_state}" > "${prev_state_file}"

    if [[ "${current_state}" == "OK" ]]; then
        log_info "[${CLUSTER_NAME}] Ciclo watcher completato. Stato: OK. Quorum: ${QUORUM_STATUS}. Nodi online: $(echo "${PARSED_NODES_JSON}" | grep -c 'online')."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [[ ! -d "${CONF_DIR}" ]]; then
        log_error "Directory configurazione non trovata: ${CONF_DIR}"
        exit 1
    fi

    local conf_files
    mapfile -t conf_files < <(find "${CONF_DIR}" -maxdepth 1 -name "*.conf" -type f)

    if [[ ${#conf_files[@]} -eq 0 ]]; then
        log_warning "Nessun file .conf trovato in ${CONF_DIR}."
        exit 0
    fi

    for conf_file in "${conf_files[@]}"; do
        process_cluster "${conf_file}" || true
    done
}

main "$@"