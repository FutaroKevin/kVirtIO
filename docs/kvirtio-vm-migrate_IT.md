# Documentazione Script: KvirtIO VM Migrator

Lo script **KvirtIO VM Migrator** è uno strumento da riga di comando eseguito sul server di management esterno per eseguire la migrazione a caldo (Live Migration) e senza interruzioni (zero-downtime) di una macchina virtuale tra nodi hypervisor all'interno dello stesso cluster.

---

## 📋 Descrizione Funzionale

Lo script `kvirtio-vm-migrate.sh` coordina le migrazioni live da ipervisore a ipervisore. Esegue verifiche preliminari sugli host sorgente e di destinazione, configura le opzioni di migrazione di Libvirt (supportando la compressione della RAM e timeout personalizzati), esegue il comando di migrazione in modalità remota sull'host sorgente, verifica l'avvio corretto sull'host di destinazione e invia notifiche via email.

---

## 🛠️ Interfaccia a Riga di Comando e Utilizzo

### Parametri Obbligatori
*   `--cluster <nome>`: Cluster di destinazione (es. `cluster_db`).
*   `--vm-name <nome>`: Il nome della VM da migrare (es. `vm-db-prod-01`).
*   `--from <nodo>`: Nodo ipervisore sorgente su cui la VM è attualmente in esecuzione (es. `node1`).
*   `--to <nodo>`: Nodo ipervisore di destinazione per la migrazione (es. `node3`).

### Parametri Facoltativi
*   `--live`: Esegue la migrazione a caldo (attiva di default).
*   `--compressed`: Abilita la compressione della memoria (RAM) durante il trasferimento, fortemente consigliata per carichi di database con tassi elevati di modifica delle pagine RAM.
*   `--timeout <secondi>`: Timeout massimo di esecuzione (default: `300` secondi).
*   `--help`: Mostra questo messaggio di aiuto.

### Esempio di Utilizzo
```bash
/usr/local/bin/kvirtio-vm-migrate.sh \
    --cluster cluster_db \
    --vm-name vm-db-prod-01 \
    --from node1 \
    --to node3 \
    --compressed \
    --timeout 600
```

---

## 🏎️ Protocollo di Migrazione e Architettura

La migrazione avviene in modalità peer-to-peer sfruttando la comunicazione diretta di QEMU tramite tunnel TCP:
1.  **Orchestrazione**: Il server di management invia la direttiva di migrazione all'ipervisore sorgente tramite connessione SSH.
2.  **Trasferimento Peer-to-Peer**: L'ipervisore sorgente stabilisce una sessione di rete diretta con il daemon libvirtd dell'ipervisore di destinazione sulla rete di migrazione dedicata tramite l'URI `qemu+tcp://[TO_NODE]/system`.
3.  **Storage LVM Condiviso**: Poiché lo storage delle VM risiede su SAN FC condivisa con LVM Cluster, non è richiesto il trasferimento dei dischi virtuali. Vengono copiati via rete solo lo stato della CPU, i registri di sistema e le pagine di memoria RAM attive.
4.  **Dettaglio Flag**:
    -   `--live`: Mantiene la VM in esecuzione durante la copia della RAM.
    -   `--persistent`: Preserva la definizione XML della VM sull'ipervisore di destinazione.
    -   `--undefinesource`: Rimuove la definizione XML della VM dall'ipervisore sorgente al termine della migrazione.

---

## 🚀 Flusso di Esecuzione

1.  **Validazione Preliminare**:
    -   Verifica che la VM si trovi in stato `running` sul nodo sorgente.
    -   Verifica che l'host di destinazione sia raggiungibile via SSH e che il servizio `libvirtd` sia operativo.
2.  **Avvio Migrazione**: Lancia il comando di migrazione sull'host sorgente ponendo un limite temporale tramite l'utility `timeout`.
3.  **Verifica Post-Migrazione**:
    -   Attende 2 secondi.
    -   Interroga il nodo di destinazione per verificare che lo stato della VM sia `running`.
4.  **Notifica SMTP**: Invia un'email con l'esito dell'operazione, allegando log diagnostici in caso di errore (controlli sulla VLAN di migrazione, disponibilità di RAM libera sul nodo target e stato di libvirtd).
