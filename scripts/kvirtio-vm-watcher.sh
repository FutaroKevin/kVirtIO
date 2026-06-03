#!/bin/bash
# =============================================================================
# Script:      kvirtio-vm-watcher.sh
# Descrizione: Monitora lo stato e il posizionamento delle VM definite in
#              Pacemaker. Correla virsh list con le risorse VirtualDomain
#              di Pacemaker e scrive lo stato in un file JSON per la UI.
# Autore:      Kevin Tafuro
# Progetto:    KvirtIO Virtualization
# =============================================================================

set -o nounset
set -o pipefail

readonly SCRIPT_TAG="KvirtIO-VM"
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
# Trova il primo nodo raggiungibile di un cluster
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
# Parsing output 'virsh list --all'
# Popola array associativo: VM_LIBVIRT_STATE[vm_name]="running|shut off|paused|crashed"
# ---------------------------------------------------------------------------
parse_virsh_list() {
    local virsh_output="$1"
    declare -gA VM_LIBVIRT_STATE=()

    while IFS= read -r line; do
        # Formato: <id>  <nome>  <stato>
        # Esempio:  1     vm_db01  running
        #           -     vm_web01 shut off
        local vm_name vm_state
        vm_name=$(echo "${line}"  | awk '{print $2}')
        vm_state=$(echo "${line}" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')

        [[ -z "${vm_name}" || "${vm_name}" == "Name" ]] && continue
        [[ "${vm_name}" == "---"* ]] && continue

        VM_LIBVIRT_STATE["${vm_name}"]="${vm_state}"
    done < <(echo "${virsh_output}" | tail -n +3)
}

# ---------------------------------------------------------------------------
# Parsing XML crm_mon per resource type VirtualDomain
# Popola array associativi:
#   VM_PCM_RESOURCE[vm_name]="res_vm_db01"
#   VM_PCM_NODE[vm_name]="node01"
#   VM_PCM_STATUS[vm_name]="Started|Stopped|FAILED"
# ---------------------------------------------------------------------------
parse_crm_vms() {
    local xml_output="$1"
    declare -gA VM_PCM_RESOURCE=()
    declare -gA VM_PCM_NODE=()
    declare -gA VM_PCM_STATUS=()

    # Cerca resource con class="ocf" type="VirtualDomain"
    # <resource id="res_vm_db01" ... active="true" ... >
    #   <node name="node01" .../>
    # </resource>
    local in_vm_block=0
    local res_id="" res_active="" res_failed="" node_name="" instance_attr=""

    while IFS= read -r line; do
        if echo "${line}" | grep -q 'type="VirtualDomain"'; then
            in_vm_block=1
            res_id=$(echo "${line}"     | grep -oP 'id="\K[^"]+')
            res_active=$(echo "${line}" | grep -oP 'active="\K[^"]+' || echo "false")
            res_failed=$(echo "${line}" | grep -oP 'failed="\K[^"]+' || echo "false")
            node_name=""
            instance_attr=""
            continue
        fi

        if [[ "${in_vm_block}" -eq 1 ]]; then
            if echo "${line}" | grep -q '<node '; then
                node_name=$(echo "${line}" | grep -oP 'name="\K[^"]+')
            fi
            # Cerca l'instance_attributes per trovare il nome della VM libvirt
            if echo "${line}" | grep -q 'config.*xml\|VirtualDomain\|instance_attr'; then
                instance_attr=$(echo "${line}" | grep -oP 'value="\K[^"]+' | head -1)
                # Estrai basename del file config per correlazione con virsh
                instance_attr=$(basename "${instance_attr}" .xml 2>/dev/null || echo "")
            fi

            if echo "${line}" | grep -q '</resource>'; then
                in_vm_block=0
                [[ -z "${res_id}" ]] && continue

                # Determina stato Pacemaker
                local pcm_status="Stopped"
                [[ "${res_active}" == "true" ]]                       && pcm_status="Started"
                [[ "${res_failed}" == "true" ]]                        && pcm_status="FAILED"
                [[ "${res_active}" == "false" && "${res_failed}" != "true" ]] && pcm_status="Stopped"

                # Usa il nome risorsa come chiave principale (la VM libvirt di solito corrisponde)
                local vm_key="${instance_attr:-${res_id}}"
                VM_PCM_RESOURCE["${vm_key}"]="${res_id}"
                VM_PCM_NODE["${vm_key}"]="${node_name:-unknown}"
                VM_PCM_STATUS["${vm_key}"]="${pcm_status}"
            fi
        fi
    done <<< "${xml_output}"
}

# ---------------------------------------------------------------------------
# Costruisce il JSON delle VM
# ---------------------------------------------------------------------------
build_vms_json() {
    local vms_json="["
    local first=1

    # Unione di tutte le VM note (da virsh + da Pacemaker)
    local all_vm_names=()
    for vm in "${!VM_LIBVIRT_STATE[@]}"; do
        all_vm_names+=("${vm}")
    done
    for vm in "${!VM_PCM_RESOURCE[@]}"; do
        # Aggiungi solo se non già presente
        local found=0
        for existing in "${all_vm_names[@]}"; do
            [[ "${existing}" == "${vm}" ]] && found=1 && break
        done
        [[ "${found}" -eq 0 ]] && all_vm_names+=("${vm}")
    done

    for vm in "${all_vm_names[@]}"; do
        local libvirt_state="${VM_LIBVIRT_STATE[${vm}]:-unknown}"
        local pcm_resource="${VM_PCM_RESOURCE[${vm}]:-}"
        local pcm_node="${VM_PCM_NODE[${vm}]:-unknown}"
        local pcm_status="${VM_PCM_STATUS[${vm}]:-unknown}"

        [[ "${first}" -eq 0 ]] && vms_json+=","
        vms_json+="{\"name\":\"${vm}\","
        vms_json+="\"libvirt_state\":\"${libvirt_state}\","
        vms_json+="\"pacemaker_resource\":\"${pcm_resource}\","
        vms_json+="\"pacemaker_node\":\"${pcm_node}\","
        vms_json+="\"pacemaker_status\":\"${pcm_status}\"}"
        first=0
    done

    vms_json+="]"
    echo "${vms_json}"
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

    log_info "[${CLUSTER_NAME}] Avvio ciclo watcher VM."

    local state_file="/tmp/kvirtio_vm_state_${CLUSTER_NAME}.json"
    local prev_state_file="/tmp/kvirtio_vm_prev_state_${CLUSTER_NAME}"

    # Trova primo nodo online
    local active_node
    if ! active_node=$(find_first_online_node NODES); then
        log_critical "[${CLUSTER_NAME}] Nessun nodo raggiungibile via SSH."
        return 1
    fi

    log_info "[${CLUSTER_NAME}] Nodo rappresentativo: ${active_node}"

    # Raccolta dati
    local virsh_out crm_xml
    virsh_out=$(ssh ${SSH_OPTS} "${SSH_USER}@${active_node}" \
        "sudo /usr/bin/virsh list --all" 2>/dev/null) || {
        log_error "[${CLUSTER_NAME}] Errore virsh list su ${active_node}."
        return 1
    }

    crm_xml=$(ssh ${SSH_OPTS} "${SSH_USER}@${active_node}" \
        "sudo /usr/sbin/crm_mon --one-shot --output-as=xml" 2>/dev/null) || {
        log_warning "[${CLUSTER_NAME}] Errore crm_mon su ${active_node}. Dati Pacemaker non disponibili."
        crm_xml=""
    }

    # Parsing
    parse_virsh_list "${virsh_out}"
    [[ -n "${crm_xml}" ]] && parse_crm_vms "${crm_xml}"

    local vms_json
    vms_json=$(build_vms_json)

    local generated_at
    generated_at=$(date -u +"%Y-%m-%dT%H:%M:%S")
    cat > "${state_file}" <<EOF
{
  "generated_at": "${generated_at}",
  "cluster_name": "${CLUSTER_NAME}",
  "vms": ${vms_json}
}
EOF

    # Logica di alerting
    local cluster_state="OK"

    for vm in "${!VM_LIBVIRT_STATE[@]}"; do
        local libvirt_state="${VM_LIBVIRT_STATE[${vm}]}"
        local pcm_status="${VM_PCM_STATUS[${vm}]:-}"

        case "${libvirt_state}" in
            crashed)
                log_critical "[${CLUSTER_NAME}] VM ${vm}: stato 'crashed'."
                cluster_state="CRITICAL"
                send_alert "${CLUSTER_NAME}" "vm_crashed_${vm}" \
                    "KvirtIO CRITICAL: VM ${cluster_name} — ${vm} in stato crashed" \
                    "Cluster: ${CLUSTER_NAME}\nVM: ${vm}\nDettaglio: VM in stato 'crashed'.\nTimestamp: $(date)"
                ;;
            paused)
                log_critical "[${CLUSTER_NAME}] VM ${vm}: stato 'paused' senza manutenzione pianificata."
                cluster_state="CRITICAL"
                send_alert "${CLUSTER_NAME}" "vm_paused_${vm}" \
                    "KvirtIO CRITICAL: VM ${CLUSTER_NAME} — ${vm} in stato paused" \
                    "Cluster: ${CLUSTER_NAME}\nVM: ${vm}\nDettaglio: VM in stato 'paused' (non pianificato).\nTimestamp: $(date)"
                ;;
        esac

        if [[ "${pcm_status}" == "Stopped" ]]; then
            log_warning "[${CLUSTER_NAME}] VM ${vm}: risorsa Pacemaker in stato Stopped."
            [[ "${cluster_state}" != "CRITICAL" ]] && cluster_state="WARNING"
        fi
    done

    # Check recovery
    local prev_state
    prev_state=$(cat "${prev_state_file}" 2>/dev/null || echo "UNKNOWN")
    if [[ "${prev_state}" != "OK" && "${cluster_state}" == "OK" ]]; then
        log_info "[${CLUSTER_NAME}] VM tornate in stato OK."
        send_alert "${CLUSTER_NAME}" "vm_recovery" \
            "KvirtIO RECOVERY: VM ${CLUSTER_NAME} — Tutte le VM tornate OK" \
            "Cluster: ${CLUSTER_NAME}\nDettaglio: Tutte le VM sono tornate in stato operativo.\nTimestamp: $(date)"
    fi
    echo "${cluster_state}" > "${prev_state_file}"

    local vm_count=${#VM_LIBVIRT_STATE[@]}
    log_info "[${CLUSTER_NAME}] Ciclo watcher VM completato. ${vm_count} VM rilevate. Stato: ${cluster_state}."
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