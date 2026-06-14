# Documentazione Servizio: KvirtIO Host Watcher

Il servizio **KvirtIO Host Watcher** monitora lo stato delle risorse CPU/RAM dei nodi dei cluster definiti in `/etc/kvirtio` e interagisce con Pacemaker.

---

## 📋 Descrizione Funzionale
Il watcher scansiona ciclicamente tutti i file di configurazione con estensione `.conf` all'interno della directory `/etc/kvirtio/clusters/`. Per ogni file di configurazione caricato, esegue il controllo prestazionale di ciascun nodo ipervisore ad esso associato.

### Algoritmo di Controllo e File di Stato Multi-Cluster
Per evitare sovrapposizioni o conflitti tra nodi con nomi simili appartenenti a cluster differenti, lo script isola lo stato di ciascun nodo includendo il nome del cluster nel percorso dello stato temporaneo:

1.  Lo script viene eseguito ogni **5 minuti** tramite il Timer Systemd.
2.  Carica dinamicamente ciascun file `.conf` da `/etc/kvirtio/clusters/`, ereditandone le soglie specifiche e la lista di nodi.
3.  Esegue il controllo delle metriche CPU e RAM via SSH.
4.  **Soglie di Allarme**: Definite per singolo cluster nel file di configurazione (es. `CPU_THRESHOLD` e `RAM_THRESHOLD`).
5.  Se il carico supera una delle soglie, lo script incrementa di 1 il valore `COUNT` all'interno del file di stato specifico:
    `/tmp/kvirtio_host_state_${CLUSTER_NAME}_${node}`
6.  Se le soglie vengono superate per **3 controlli consecutivi** (o il valore impostato in `CONSECUTIVE_LIMIT`):
    *   Lo stato del nodo per quel determinato cluster viene marcato come `overloaded`.
    *   Viene eseguito sul nodo KVM remoto il comando:
        ```bash
        sudo crm_attribute --node [NOME_NODO] --name status-load --update 'overloaded'
        ```
7.  Al rientro del carico sotto le soglie:
    *   Il contatore `COUNT` viene azzerato (`COUNT=0`).
    *   Se lo stato memorizzato era `overloaded`, viene ripristinato a `healthy` eseguendo:
        ```bash
        sudo crm_attribute --node [NOME_NODO] --name status-load --update 'healthy'
        ```

---

## 📈 Metodologia di Raccolta Metriche

Le metriche vengono estratte in modo efficiente leggendo `/proc/stat` (calcolo differenziale CPU con `sleep 0.5`) e `/proc/meminfo` (calcolo RAM basato su `MemAvailable` e `MemTotal`) via SSH come utente `kvirtwatch`.

---

## 🪵 Tracciamento Log (Syslog)
Tutti i log del monitoraggio host includono la tag `[NOME_CLUSTER]` all'interno del messaggio, per facilitare il filtraggio e l'aggregazione su sistemi di log centralizzati:

*   **Avvio monitoraggio (Info)**:
    `INFO: Inizio monitoraggio host per il cluster: cluster_db (5 nodi).`
*   **Superamento soglia persistente (Critical)**:
    `CRITICAL: [cluster_db] Nodo node1 sovraccarico da 3 controlli (CPU: 89%, RAM: 92%). Impostato 'overloaded'.`
*   **Rientro nei limiti (Info)**:
    `INFO: [cluster_db] Nodo node1 rientrato nei parametri (CPU: 45%, RAM: 72%). Impostato 'healthy'.`
*   **Errore di connessione (Error)**:
    `ERROR: [cluster_db] Impossibile contattare il nodo node3.`
