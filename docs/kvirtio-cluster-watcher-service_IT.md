# Documentazione Servizio: KvirtIO Cluster Watcher

Il servizio **KvirtIO Cluster Watcher** monitora lo stato di salute dei cluster ad alta affidabilità Pacemaker/Corosync — tracciando lo stato del quorum, le transizioni online/offline dei nodi e i fallimenti delle risorse — su tutti i cluster definiti sotto `/etc/kvirtio`.

---

## 📋 Descrizione Funzionale

Il watcher scansiona ciclicamente tutti i file `.conf` all'interno di `/etc/kvirtio/clusters/`. Per ogni cluster configurato, esegue `crm_mon` e `corosync-cfgtool` tramite SSH su un nodo designato (tipicamente il primo nodo online disponibile), decodifica l'output XML strutturato e scrive un JSON di stato consolidato nella directory dei dati del dashboard web.

### Obiettivo del Monitoraggio

Lo stato di salute di Pacemaker/Corosync è lo strato fondamentale dell'alta affidabilità KVM. Se il quorum viene perso o un nodo va offline, Pacemaker potrebbe eseguire il fencing dei nodi e arrestare le risorse per proteggere l'integrità dei dati. Il watcher fornisce visibilità immediata su:

- **Perdita del Quorum**: Notifica immediata quando il cluster perde il quorum, impedendo che situazioni di split-brain passino inosservate.
- **Eventi di Nodi Offline**: Rilevamento dei nodi che escono dall'anello di appartenenza del cluster.
- **Fallimenti delle Risorse**: Monitoraggio delle risorse Pacemaker in stato `FAILED` che richiedono un intervento manuale per essere ripristinate.

### Logica di Controllo

1. Lo script viene eseguito ogni **60 secondi** tramite il Timer Systemd.
2. Carica ciascuna configurazione di cluster `.conf` da `/etc/kvirtio/clusters/`.
3. Si connette tramite SSH al nodo di monitoraggio designato del cluster.
4. Esegue `sudo crm_mon -1 --output-as=xml` e decodifica l'output XML:
   - Estrae lo stato del quorum (`quorum_type`, `with_quorum`).
   - Elenca tutti i nodi con il loro stato (`online`, `offline`, `standby`, `unclean`).
   - Elenca tutte le risorse con il loro stato (`Started`, `Stopped`, `FAILED`) e il nodo su cui sono in esecuzione.
5. Esegue `sudo corosync-cfgtool -s` per raccogliere lo stato dell'anello e rilevare errori di trasmissione dei token.
6. Se viene soddisfatta una condizione di allarme:
   - Viene scritta una voce di syslog `CRITICAL` o `WARNING`.
   - `kvirtio-mail-alerter.py` viene invocato in modo asincrono.
   - Il file JSON di output viene scritto con `status: "critical"` o `"degraded"`.

---

## 📈 Metriche Monitorate

### Quorum (tramite `crm_mon -1 --output-as=xml`)

| Metrica | Descrizione |
|---|---|
| **with_quorum** | Booleano — se il cluster ha attualmente il quorum |
| **quorum_type** | Tipo di quorum previsto (`fencing`, `freeze`, ecc.) |

### Stato dei Nodi

| Metrica | Descrizione |
|---|---|
| **node name** | Identificatore del nodo del cluster |
| **online** | `true` / `false` |
| **standby** | Se il nodo è in standby (intenzionale o forzato) |
| **unclean** | Se il nodo è in uno stato unclean/fencing |
| **maintenance** | Se il nodo è in modalità manutenzione |

### Risorse (tramite `crm_mon -1 --output-as=xml`)

| Metrica | Descrizione |
|---|---|
| **resource id** | Identificatore della risorsa Pacemaker |
| **resource type** | Primitiva, clone, gruppo |
| **role** | `Started`, `Stopped`, `Master`, `Slave` |
| **failed** | `true` se la risorsa è in stato FAILED |
| **managed** | Se la risorsa è sotto la gestione di Pacemaker |
| **node** | Nodo su cui la risorsa è attualmente in esecuzione |

### Stato dell'Anello Corosync (tramite `corosync-cfgtool -s`)

| Metrica | Descrizione |
|---|---|
| **ring id** | Identificatore dell'anello Corosync |
| **status** | `ring 0 active with no faults` o descrizione del guasto |

---

## 🔔 Soglie e Allarmi

Le condizioni di allarme vengono valutate a ogni esecuzione senza ritardi configurabili — **gli eventi sullo stato del cluster generano sempre allarmi immediati**:

| Condizione | Gravità | Azione |
|---|---|---|
| `with_quorum = false` | **CRITICAL** | Email immediata + syslog `CRITICAL` |
| Qualsiasi nodo in `online = false` (non in manutenzione) | **CRITICAL** | Email immediata + syslog `CRITICAL` |
| Qualsiasi nodo in `unclean = true` | **CRITICAL** | Email immediata + syslog `CRITICAL` |
| Qualsiasi risorsa con `failed = true` | **CRITICAL** | Email immediata + syslog `CRITICAL` |
| Qualsiasi risorsa in stato `Stopped` in modo inatteso | **WARNING** | Syslog `WARNING` + email |
| Rilevato guasto all'anello Corosync | **WARNING** | Syslog `WARNING` + email |

Esempio di email di allarme:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO CRITICAL: Quorum lost on cluster_db" \
    --body "Cluster cluster_db has lost quorum. Immediate intervention required to prevent fencing cascades." &
```

---

## 📄 Output JSON

Ad ogni esecuzione, il watcher scrive un singolo file JSON per cluster (non per nodo, poiché lo stato del cluster è globale).

**Percorso di output**: `/var/www/html/kvirtio/data/cluster_<cluster>.json`

**Esempio** (`cluster_cluster_db.json`):
```json
{
  "cluster": "cluster_db",
  "timestamp": "2026-06-10T14:15:00Z",
  "status": "critical",
  "quorum": {
    "with_quorum": false,
    "quorum_type": "fencing"
  },
  "nodes": [
    { "name": "node1", "online": true,  "standby": false, "unclean": false, "maintenance": false },
    { "name": "node2", "online": true,  "standby": false, "unclean": false, "maintenance": false },
    { "name": "node3", "online": false, "standby": false, "unclean": true,  "maintenance": false }
  ],
  "resources": [
    { "id": "vm_oracle_01", "role": "Started", "node": "node1", "failed": false, "managed": true },
    { "id": "vm_oracle_02", "role": "FAILED",  "node": null,    "failed": true,  "managed": true },
    { "id": "vip_db",       "role": "Started", "node": "node2", "failed": false, "managed": true }
  ],
  "corosync_rings": [
    { "ring_id": 0, "status": "ring 0 active with no faults" }
  ]
}
```

---

## ⚙️ Integrazione Systemd

### Unità di Servizio (`kvirtio-cluster-watcher.service`)
```ini
[Unit]
Description=KvirtIO Pacemaker/Corosync Cluster Health Watcher
After=network.target
Wants=kvirtio-cluster-watcher.timer

[Service]
Type=oneshot
User=kvirtwatch
ExecStart=/usr/local/sbin/kvirtio-cluster-watcher.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=KvirtIO-Cluster

[Install]
WantedBy=multi-user.target
```

### Unità Timer (`kvirtio-cluster-watcher.timer`)
```ini
[Unit]
Description=KvirtIO Cluster Watcher — esecuzione ogni 60 secondi
Requires=kvirtio-cluster-watcher.service

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=kvirtio-cluster-watcher.service

[Install]
WantedBy=timers.target
```

### Abilitazione e Avvio
```bash
sudo cp systemd/kvirtio-cluster-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-cluster-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-cluster-watcher.timer
```

---

## 🔐 Requisiti Sudo sui Nodi KVM

Aggiungere le seguenti voci a `/etc/sudoers.d/kvirtwatch` su ciascun nodo KVM:

```sudoers
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/crm_mon -1 --output-as=xml
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/crm_mon -1
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/crm_attribute *
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/corosync-cfgtool -s
```

Verificare la sintassi di sudoers dopo la modifica:
```bash
sudo visudo -c
```

---

## 🪵 Ispezione Log

Tutti gli eventi vengono inviati al registro di sistema sotto l'identificatore syslog `KvirtIO-Cluster`.

### Seguire i log in tempo reale:
```bash
journalctl -fu kvirtio-cluster-watcher.service
```

### Filtrare per tag syslog:
```bash
journalctl -t KvirtIO-Cluster -f
```

### Riferimento dei messaggi di log:

| Livello | Esempio Messaggio |
|---|---|
| `INFO` | `INFO: Starting cluster monitoring for cluster: cluster_db.` |
| `INFO` | `INFO: [cluster_db] Cluster healthy — 3/3 nodes online, quorum OK, 0 failed resources.` |
| `CRITICAL` | `CRITICAL: [cluster_db] Quorum LOST. Cluster has 2/3 nodes. Fencing may occur.` |
| `CRITICAL` | `CRITICAL: [cluster_db] Node node3 is OFFLINE (unclean).` |
| `CRITICAL` | `CRITICAL: [cluster_db] Resource vm_oracle_02 is in FAILED state.` |
| `WARNING` | `WARNING: [cluster_db] Corosync ring 0 fault detected on node2.` |
| `ERROR` | `ERROR: [cluster_db] Cannot reach monitoring node (node1) via SSH.` |
