# Documentazione Script: KvirtIO Rsyslog Configuration Generator

Lo script **KvirtIO Rsyslog Configuration Generator** compila dinamicamente le regole di ricezione di rsyslog sul server di management per smistare i log remoti provenienti dai nodi di calcolo KVM in file di log separati basati su una precisa naming convention.

---

## 📋 Descrizione Funzionale

Lo script `kvirtio-setup-rsyslog-generator.sh` analizza tutti i file di configurazione dei cluster (`*.conf`) presenti in `/etc/kvirtio/clusters/` per determinare l'elenco degli hostname associati a ciascun cluster. Genera quindi un file di configurazione rsyslog (`/etc/rsyslog.d/30-kvirtio-receiver.conf`) contenente blocchi di instradamento condizionale per ciascun nodo per garantire l'isolamento dei log.

---

## 📈 Logica del Processo

1.  **Verifica**: Assicura l'esistenza della directory `/etc/kvirtio/clusters`.
2.  **Inizializzazione Ricezione**: Scrive le configurazioni per il caricamento dei moduli UDP/TCP sul file di output `/etc/rsyslog.d/30-kvirtio-receiver.conf`.
3.  **Lettura Cluster**: Cicla sui file `.conf`, effettua il sourcing dell'array bash `NODES` e della variabile `CLUSTER_NAME` ed elabora singolarmente ciascun nodo.
4.  **Generazione Regole**: Per ciascun nodo, appende blocchi condizionali rsyslog corrispondenti al nome dell'host:
    -   I log di **Pacemaker/Corosync** (`pacemakerd`, `crmd`, `pengine`, `corosync`) vengono instradati a `/var/log/kvirtio/pacemaker-[cluster]-[nodo].log`.
    -   I log di **KVM/QEMU/Libvirt** (`libvirtd`, `qemu`, `qemu-kvm`, `qemu-system-x86_64`) vengono instradati a `/var/log/kvirtio/kvm-[cluster]-[nodo].log`.
    -   I log di **Audit** (`audisp-syslog`, `auditd`) vengono instradati a `/var/log/kvirtio/audit-[cluster]-[nodo].log`.
    -   Una regola di arresto (`stop`) viene inserita al termine per evitare che questi log vadano a inquinare il file standard `/var/log/messages`.
5.  **Conferma**: Visualizza un messaggio al termine della scrittura. L'amministratore deve riavviare `rsyslog` per applicare i filtri.

---

## 📄 Esempio Configurazione Generata

**Percorso di output**: `/etc/rsyslog.d/30-kvirtio-receiver.conf`

**Esempio di blocco**:
```rsyslog
# =========================================================
# File generato dinamicamente da kVirtIO Rsyslog Generator
# =========================================================
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")

# Regole per il nodo node1 (Cluster: cluster_db)
if $hostname == 'node1' then {
    if $programname == ['pacemakerd', 'crmd', 'pengine', 'corosync'] then { 
        action(type="omfile" file="/var/log/kvirtio/pacemaker-cluster_db-node1.log") 
        stop 
    }
    if $programname == ['libvirtd', 'qemu', 'qemu-kvm', 'qemu-system-x86_64'] then { 
        action(type="omfile" file="/var/log/kvirtio/kvm-cluster_db-node1.log") 
        stop 
    }
    if $programname == ['audisp-syslog', 'auditd'] then { 
        action(type="omfile" file="/var/log/kvirtio/audit-cluster_db-node1.log") 
        stop 
    }
}
```

---

## ⚙️ Modalità di Esecuzione

1.  Ogni volta che viene aggiunto o rimosso un cluster o un nodo:
    ```bash
    sudo /usr/local/bin/kvirtio-setup-rsyslog-generator.sh
    ```
2.  Riavviare il servizio rsyslog:
    ```bash
    sudo systemctl restart rsyslog
    ```
