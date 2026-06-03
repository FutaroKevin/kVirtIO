#!/bin/bash
# Percorsi standard di kVirtIO
CONF_DIR="/etc/kvirtio/clusters"
OUT_FILE="/etc/rsyslog.d/30-kvirtio-receiver.conf"

# Verifica esistenza directory configurazioni
if [ ! -d "$CONF_DIR" ]; then
    echo "Errore: Directory $CONF_DIR non trovata."
    exit 1
fi

# Inizializza il file di ricezione rsyslog
cat << 'EOF' > "$OUT_FILE"
# =========================================================
# File generato dinamicamente da kVirtIO Rsyslog Generator
# =========================================================
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")

EOF

# Parsing dei cluster .conf
for CONF in "$CONF_DIR"/*.conf; do
    [ -e "$CONF" ] || continue
    
    # Importa CLUSTER_NAME e NODES
    source "$CONF"
    
    for NODE in "${NODES[@]}"; do
        # Genera le regole di smistamento per ogni singolo nodo
        cat << EOF >> "$OUT_FILE"
# Regole per il nodo $NODE (Cluster: $CLUSTER_NAME)
if \$hostname == '${NODE}' then {
    if \$programname == ['pacemakerd', 'crmd', 'pengine', 'corosync'] then { 
        action(type="omfile" file="/var/log/kvirtio/pacemaker-${CLUSTER_NAME}-${NODE}.log") 
        stop 
    }
    if \$programname == ['libvirtd', 'qemu', 'qemu-kvm', 'qemu-system-x86_64'] then { 
        action(type="omfile" file="/var/log/kvirtio/kvm-${CLUSTER_NAME}-${NODE}.log") 
        stop 
    }
    if \$programname == ['audisp-syslog', 'auditd'] then { 
        action(type="omfile" file="/var/log/kvirtio/audit-${CLUSTER_NAME}-${NODE}.log") 
        stop 
    }
}
EOF
    done
done

echo "Configurazione rsyslog generata con successo in $OUT_FILE"