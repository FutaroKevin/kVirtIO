#!/bin/bash
# =============================================================================
# Script:      kvirtio-network-watcher.sh
# Descrizione: Monitora lo stato dei bond di rete sui nodi KVM. Legge
#              /proc/net/bonding/ e /proc/net/dev via SSH senza sudo,
#              calcola throughput differenziale e scrive lo stato in JSON.
# Autore:      Kevin Tafuro
# Progetto:    KvirtIO Virtualization
# =============================================================================

set -o nounset
set -o pipefail

readonly SCRIPT_TAG="KvirtIO-Network"
readonly CONF_DIR="/etc/kvirtio/clusters"
readonly SSH_USER="kvirtwatch"
readonly SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new"
readonly ALERTER="/usr/local/bin/kvirtio-mail-alerter.py"
readonly ALERT_LOCK_DIR="/tmp"

# Default nome bond (sovrascrivibile nel .conf con BOND_IFACE="bond0")
BOND_IFACE="bond0"

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
# Legge /proc/net/dev su un nodo e restituisce bytes rx e tx per un'interfaccia
# Output: "<rx_bytes> <tx_bytes>" su stdout
# ---------------------------------------------------------------------------
read_net_dev_bytes() {
    local node="$1"
    local iface="$2"

    ssh ${SSH_OPTS} "${SSH_USER}@${node}" \
        "cat /proc/net/dev" 2>/dev/null | \
        grep -E "^\s*${iface}:" | \
        awk '{print $2, $10}'
}

# ---------------------------------------------------------------------------
# Parsing /proc/net/bonding/<bond>
# Popola:
#   ACTIVE_SLAVES   — array di slave attivi
#   DEGRADED_SLAVES — array di slave down
#   BOND_STATUS     — healthy|degraded|critical
# ---------------------------------------------------------------------------
parse_bonding_info() {
    local bonding_output="$1"

    ACTIVE_SLAVES=()
    DEGRADED_SLAVES=()
    BOND_STATUS="healthy"

    local current_slave=""
    local mii_status=""

    while IFS= read -r line; do
        # Nuovo slave
        if echo "${line}" | grep -qP "^Slave Interface:"; then
            # Finalizza slave precedente
            if [[ -n "${current_slave}" ]]; then
                if [[ "${mii_status}" == "up" ]]; then
                    ACTIVE_SLAVES+=("${current_slave}")
                else
                    DEGRADED_SLAVES+=("${current_slave}")
                fi
            fi
            current_slave=$(echo "${line}" | awk '{print $NF}')
            mii_status=""
            continue
        fi

        # Stato MII del slave
        if echo "${line}" | grep -qP "^MII Status:"; then
            mii_status=$(echo "${line}" | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
            continue
        fi
    done <<< "${bonding_output}"

    # Finalizza ultimo slave
    if [[ -n "${current_slave}" ]]; then
        if [[ "${mii_status}" == "up" ]]; then
            ACTIVE_SLAVES+=("${current_slave}")
        else
            DEGRADED_SLAVES+=("${current_slave}")
        fi
    fi

    # Determina stato bond
    local total_slaves=$(( ${#ACTIVE_SLAVES[@]} + ${#DEGRADED_SLAVES[@]} ))
    if [[ ${#DEGRADED_SLAVES[@]} -gt 0 && ${#ACTIVE_SLAVES[@]} -gt 0 ]]; then
        BOND_STATUS="degraded"
    elif [[ ${#ACTIVE_SLAVES[@]} -eq 0 && ${total_slaves} -gt 0 ]]; then
        BOND_STATUS="critical"
    fi
}

# ---------------------------------------------------------------------------
# Costruisce JSON array di stringhe da un array bash
# ---------------------------------------------------------------------------
bash_array_to_json() {
    local arr=("$@")
    local json="["
    local first=1
    for item in "${arr[@]}"; do
        [[ "${first}" -eq 0 ]] && json+=","
        json+="\"${item}\""
        first=0
    done
    json+="]"
    echo "${json}"
}

# ---------------------------------------------------------------------------
# Elabora un singolo nodo per un cluster
# ---------------------------------------------------------------------------
process_node() {
    local cluster_name="$1"
    local node="$2"
    local bond_iface="$3"

    local state_file="/tmp/kvirtio_network_state_${cluster_name}_${node}.json"
    local prev_state_file="/tmp/kvirtio_network_prev_state_${cluster_name}_${node}"

    # Leggi bonding info
    local bonding_out
    bonding_out=$(ssh ${SSH_OPTS} "${SSH_USER}@${node}" \
        "cat /proc/net/bonding/${bond_iface}" 2>/dev/null)
    local ssh_exit=$?

    if [[ ${ssh_exit} -ne 0 ]]; then
        log_error "[${cluster_name}] Nodo ${node}: impossibile leggere /proc/net/bonding/${bond_iface}."
        return 1
    fi

    parse_bonding_info "${bonding_out}"

    # Calcolo throughput differenziale (2 letture a distanza di 1 secondo)
    local rx1 tx1 rx2 tx2
    read -r rx1 tx1 < <(read_net_dev_bytes "${node}" "${bond_iface}")
    sleep 1
    read -r rx2 tx2 < <(read_net_dev_bytes "${node}" "${bond_iface}")

    local rx_mbps="0.0"
    local tx_mbps="0.0"

    if [[ -n "${rx1}" && -n "${rx2}" ]] 2>/dev/null; then
        rx_mbps=$(awk "BEGIN {printf \"%.2f\", (${rx2:-0} - ${rx1:-0}) * 8 / 1000000}")
        tx_mbps=$(awk "BEGIN {printf \"%.2f\", (${tx2:-0} - ${tx1:-0}) * 8 / 1000000}")
        # Evita valori negativi (wraparound contatori)
        rx_mbps=$(awk "BEGIN {v=${rx_mbps}; print (v < 0) ? \"0.00\" : v}")
        tx_mbps=$(awk "BEGIN {v=${tx_mbps}; print (v < 0) ? \"0.00\" : v}")
    fi

    local active_slaves_json degraded_slaves_json
    active_slaves_json=$(bash_array_to_json "${ACTIVE_SLAVES[@]+"${ACTIVE_SLAVES[@]}"}")
    degraded_slaves_json=$(bash_array_to_json "${DEGRADED_SLAVES[@]+"${DEGRADED_SLAVES[@]}"}")

    local generated_at
    generated_at=$(date -u +"%Y-%m-%dT%H:%M:%S")
    cat > "${state_file}" <<EOF
{
  "generated_at": "${generated_at}",
  "cluster_name": "${cluster_name}",
  "node": "${node}",
  "bond": "${bond_iface}",
  "active_slaves": ${active_slaves_json},
  "degraded_slaves": ${degraded_slaves_json},
  "status": "${BOND_STATUS}",
  "rx_mbps": ${rx_mbps},
  "tx_mbps": ${tx_mbps}
}
EOF

    # Logging e alerting
    case "${BOND_STATUS}" in
        critical)
            log_critical "[${cluster_name}] Nodo ${node}: bond ${bond_iface} — tutti gli slave down."
            send_alert "${cluster_name}" "net_critical_${node}" \
                "KvirtIO CRITICAL: Rete ${cluster_name} — ${node}/${bond_iface} tutti slave down" \
                "Cluster: ${cluster_name}\nNodo: ${node}\nDettaglio: Bond ${bond_iface}: tutti gli slave sono down.\nTimestamp: $(date)"
            ;;
        degraded)
            log_warning "[${cluster_name}] Nodo ${node}: bond ${bond_iface} — slave degradati: ${DEGRADED_SLAVES[*]}."
            ;;
        healthy)
            # Log throughput solo se > 0
            local rx_check tx_check
            rx_check=$(awk "BEGIN {print (${rx_mbps} > 0) ? 1 : 0}")
            tx_check=$(awk "BEGIN {print (${tx_mbps} > 0) ? 1 : 0}")
            if [[ "${rx_check}" -eq 1 || "${tx_check}" -eq 1 ]]; then
                log_info "[${cluster_name}] Nodo ${node}: bond ${bond_iface} OK — RX: ${rx_mbps} Mbit/s, TX: ${tx_mbps} Mbit/s."
            else
                log_info "[${cluster_name}] Nodo ${node}: bond ${bond_iface} OK — nessun traffico rilevato."
            fi
            ;;
    esac

    # Check recovery
    local prev_state
    prev_state=$(cat "${prev_state_file}" 2>/dev/null || echo "UNKNOWN")
    if [[ "${prev_state}" == "critical" && "${BOND_STATUS}" == "healthy" ]]; then
        log_info "[${cluster_name}] Nodo ${node}: rete tornata in stato healthy."
        send_alert "${cluster_name}" "net_recovery_${node}" \
            "KvirtIO RECOVERY: Rete ${cluster_name} — ${node} bond tornato OK" \
            "Cluster: ${cluster_name}\nNodo: ${node}\nDettaglio: Bond ${bond_iface} tornato operativo.\nTimestamp: $(date)"
    fi
    echo "${BOND_STATUS}" > "${prev_state_file}"
}

# ---------------------------------------------------------------------------
# Elabora un singolo cluster
# ---------------------------------------------------------------------------
process_cluster() {
    local conf_file="$1"

    CLUSTER_NAME=""
    NODES=()
    ALERT_COOLDOWN_MINUTES=30
    BOND_IFACE="bond0"

    # shellcheck source=/dev/null
    source "${conf_file}" || { log_error "Impossibile leggere ${conf_file}"; return 1; }

    [[ -z "${CLUSTER_NAME}" ]] && { log_error "CLUSTER_NAME non definito in ${conf_file}"; return 1; }
    [[ ${#NODES[@]} -eq 0 ]]  && { log_error "Array NODES vuoto in ${conf_file}"; return 1; }

    log_info "[${CLUSTER_NAME}] Avvio ciclo watcher rete (bond: ${BOND_IFACE}, ${#NODES[@]} nodi)."

    for node in "${NODES[@]}"; do
        process_node "${CLUSTER_NAME}" "${node}" "${BOND_IFACE}" || true
    done

    log_info "[${CLUSTER_NAME}] Ciclo watcher rete completato."
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