#!/bin/bash
# =============================================================================
# Script:      kvirtio-multipath-watcher.sh
# Descrizione: Monitora la salute dei path multipath FC su ogni nodo KVM.
#              Identifica device con path degradati o completamente falliti
#              e scrive lo stato in file JSON per il dashboard HTML.
# Autore:      Kevin Tafuro
# Progetto:    KvirtIO Virtualization
# =============================================================================

set -o nounset
set -o pipefail

readonly SCRIPT_TAG="KvirtIO-Multipath"
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
# Invia alert via mail con controllo cooldown
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
            log_info "Alert '${alert_type}' già inviato ${elapsed}s fa. Saltato."
            return
        fi
    fi

    echo "${now}" > "${lock_file}"
    python3 "${ALERTER}" --subject "${subject}" --body "${body}" &
    log_info "Alert inviato: ${subject}"
}

# ---------------------------------------------------------------------------
# Parsing output di 'multipath -ll'
# Popola le variabili DEVICES_JSON con la struttura JSON dei device trovati.
# ---------------------------------------------------------------------------
parse_multipath_output() {
    local mp_output="$1"

    DEVICES_JSON="["
    local first_dev=1
    local current_device=""
    local total_paths=0
    local active_paths=0
    local failed_paths=0

    # Funzione interna per finalizzare il device corrente
    flush_device() {
        [[ -z "${current_device}" ]] && return
        local status="healthy"
        (( failed_paths > 0 && active_paths > 0 )) && status="degraded"
        (( active_paths == 0 && total_paths > 0 )) && status="critical"

        [[ "${first_dev}" -eq 0 ]] && DEVICES_JSON+=","
        DEVICES_JSON+="{\"name\":\"${current_device}\",\"total_paths\":${total_paths},"
        DEVICES_JSON+="\"active_paths\":${active_paths},\"failed_paths\":${failed_paths},"
        DEVICES_JSON+="\"status\":\"${status}\"}"
        first_dev=0
    }

    while IFS= read -r line; do
        # Nuova definizione device: riga inizia con mpath<x> o il WWID
        if echo "${line}" | grep -qP '^\w+\s+\(.*\)\s+dm-\d+'; then
            flush_device
            current_device=$(echo "${line}" | grep -oP '^\w+')
            total_paths=0
            active_paths=0
            failed_paths=0
            continue
        fi

        # Riga di path: contiene "active ready", "failed faulty", "shaky" ecc.
        if [[ -n "${current_device}" ]]; then
            if echo "${line}" | grep -qP '\d+:\d+:\d+:\d+'; then
                (( total_paths++ ))
                if echo "${line}" | grep -q "active ready"; then
                    (( active_paths++ ))
                elif echo "${line}" | grep -qP "failed faulty|shaky|active ghost|inactive|offline"; then
                    (( failed_paths++ ))
                fi
            fi
        fi
    done <<< "${mp_output}"

    # Ultimo device
    flush_device

    DEVICES_JSON+="]"
}

# ---------------------------------------------------------------------------
# Elabora un singolo nodo per un cluster
# ---------------------------------------------------------------------------
process_node() {
    local cluster_name="$1"
    local node="$2"

    local data_dir="/var/www/html/kvirtio/data"
    mkdir -p "${data_dir}" 2>/dev/null || true
    local state_file="${data_dir}/multipath_${cluster_name}_${node}.json"
    local prev_state_file="/tmp/kvirtio_multipath_prev_state_${cluster_name}_${node}"

    local mp_output
    mp_output=$(ssh ${SSH_OPTS} "${SSH_USER}@${node}" \
        "sudo /usr/sbin/multipath -ll" 2>/dev/null)
    local ssh_exit=$?

    if [[ ${ssh_exit} -ne 0 ]]; then
        log_error "[${cluster_name}] Nodo ${node}: impossibile eseguire multipath -ll (exit ${ssh_exit})."
        return 1
    fi

    if [[ -z "${mp_output}" ]]; then
        log_info "[${cluster_name}] Nodo ${node}: nessun device multipath trovato."
        cat > "${state_file}" <<EOF
{
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S")",
  "cluster_name": "${cluster_name}",
  "node": "${node}",
  "devices": []
}
EOF
        return 0
    fi

    parse_multipath_output "${mp_output}"

    local generated_at
    generated_at=$(date -u +"%Y-%m-%dT%H:%M:%S")
    cat > "${state_file}" <<EOF
{
  "generated_at": "${generated_at}",
  "cluster_name": "${cluster_name}",
  "node": "${node}",
  "devices": ${DEVICES_JSON}
}
EOF

    # Logica di alerting per ogni device
    local node_worst_state="OK"
    local current_device_name="" total_paths=0 active_paths=0 failed_paths=0 device_status=""

    # Re-itera sull'output per il logging (DEVICES_JSON è già scritto)
    # Usiamo un approccio diverso: parsiamo DEVICES_JSON con grep/sed
    local device_entries
    device_entries=$(echo "${DEVICES_JSON}" | grep -oP '\{[^}]+\}')

    while IFS= read -r entry; do
        current_device_name=$(echo "${entry}" | grep -oP '"name":"\K[^"]+')
        total_paths=$(echo "${entry}"   | grep -oP '"total_paths":\K[0-9]+')
        active_paths=$(echo "${entry}"  | grep -oP '"active_paths":\K[0-9]+')
        failed_paths=$(echo "${entry}"  | grep -oP '"failed_paths":\K[0-9]+')
        device_status=$(echo "${entry}" | grep -oP '"status":"\K[^"]+')

        case "${device_status}" in
            critical)
                log_critical "[${cluster_name}] Nodo ${node}: device ${current_device_name} tutti i path degradati (${failed_paths}/${total_paths} failed)."
                node_worst_state="CRITICAL"
                send_alert "${cluster_name}" "mpath_critical_${node}_${current_device_name}" \
                    "KvirtIO CRITICAL: Multipath ${cluster_name} — ${node}/${current_device_name} tutti path degradati" \
                    "Cluster: ${cluster_name}\nNodo: ${node}\nDettaglio: Device ${current_device_name}: tutti i path degradati (${failed_paths}/${total_paths} failed).\nTimestamp: $(date)"
                ;;
            degraded)
                log_warning "[${cluster_name}] Nodo ${node}: device ${current_device_name} path parzialmente degradato (${failed_paths}/${total_paths} failed)."
                [[ "${node_worst_state}" != "CRITICAL" ]] && node_worst_state="WARNING"
                ;;
            healthy)
                log_info "[${cluster_name}] Nodo ${node}: device ${current_device_name} OK (${active_paths}/${total_paths} path attivi)."
                ;;
        esac
    done <<< "${device_entries}"

    # Check recovery
    local prev_state
    prev_state=$(cat "${prev_state_file}" 2>/dev/null || echo "UNKNOWN")
    if [[ "${prev_state}" == "CRITICAL" && "${node_worst_state}" == "OK" ]]; then
        log_info "[${cluster_name}] Nodo ${node}: multipath tornato in stato OK."
        send_alert "${cluster_name}" "mpath_recovery_${node}" \
            "KvirtIO RECOVERY: Multipath ${cluster_name} — ${node} tornato OK" \
            "Cluster: ${cluster_name}\nNodo: ${node}\nDettaglio: Tutti i path multipath tornati attivi.\nTimestamp: $(date)"
    fi
    echo "${node_worst_state}" > "${prev_state_file}"
}

# ---------------------------------------------------------------------------
# Elabora un singolo cluster
# ---------------------------------------------------------------------------
process_cluster() {
    local conf_file="$1"

    CLUSTER_NAME=""
    NODES=()
    ALERT_COOLDOWN_MINUTES=30

    # shellcheck source=/dev/null
    source "${conf_file}" || { log_error "Impossibile leggere ${conf_file}"; return 1; }

    [[ -z "${CLUSTER_NAME}" ]] && { log_error "CLUSTER_NAME non definito in ${conf_file}"; return 1; }
    [[ ${#NODES[@]} -eq 0 ]]  && { log_error "Array NODES vuoto in ${conf_file}"; return 1; }

    log_info "[${CLUSTER_NAME}] Avvio ciclo watcher multipath (${#NODES[@]} nodi)."

    for node in "${NODES[@]}"; do
        process_node "${CLUSTER_NAME}" "${node}" || true
    done

    log_info "[${CLUSTER_NAME}] Ciclo watcher multipath completato."
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