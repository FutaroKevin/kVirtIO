# Documentazione Servizio: KvirtIO Multipath Watcher

Il servizio **KvirtIO Multipath Watcher** monitora lo stato di salute dei percorsi multipath Fibre Channel (FC) su ciascun nodo KVM nei cluster definiti in `/etc/kvirtio`.

---

## 📋 Descrizione Funzionale

Il watcher scansiona ciclicamente tutti i file `.conf` all'interno della directory `/etc/kvirtio/clusters/`. Per ogni file di configurazione caricato, si connette via SSH a ciascun nodo ipervisore e ispeziona la topologia multipath attiva eseguendo `multipath -ll`.

### Obiettivo del Monitoraggio

L'obiettivo principale è rilevare configurazioni multipath FC degradate prima che possano causare errori di I/O o interruzioni delle macchine virtuali. Un dispositivo multipath sano (`dm-X`) deve avere **tutti i percorsi previsti** in stato `active ready`. Qualsiasi percorso che passa allo stato `failed faulty` o che scompare del tutto deve attivare immediatamente un allarme.

### Logica di Controllo e File di Stato Multi-Cluster

Per evitare conflitti tra nodi con nomi simili appartenenti a cluster diversi, lo stato di ciascun nodo viene tracciato con il nome del cluster incorporato nel percorso del file di stato temporaneo:

1. Lo script viene eseguito ogni **2 minuti** tramite il Timer Systemd.
2. Carica dinamicamente ciascun file `.conf` da `/etc/kvirtio/clusters/`, ereditando le soglie specifiche del cluster e l'elenco dei nodi.
3. Si connette via SSH a ciascun nodo ipervisore utilizzando l'utente `kvirtwatch`.
4. Esegue `sudo multipath -ll` e analizza l'output per verificare la salute di ciascun dispositivo multipath (`mpatha`, `mpathb`, ...), rilevando il numero di percorsi in stato `active ready` rispetto a quelli in stato `failed faulty` o `shaky`.
5. Un dispositivo con almeno 1 percorso degradato genera uno stato `WARNING`; un dispositivo con tutti i percorsi degradati genera uno stato `CRITICAL`.
6. All'attivazione dell'allarme:
   - Scrive lo stato in `/tmp/kvirtio_multipath_state_${CLUSTER_NAME}_${node}.json`.
   - Invia una notifica email asincrona tramite `kvirtio-mail-alerter.py`.
7. Quando tutti i percorsi tornano a `active ready`:
   - Il file di stato viene aggiornato/ripristinato.
   - Viene loggata una notifica di ripristino ed eventualmente inviata per email.

---

## 📈 Metrice Monitorate

| Metrica | Descrizione |
|---|---|
| **Active paths per LUN** | Numero di percorsi in stato `active ready` per ciascun dispositivo multipath (`dm-X`) |
| **Failed paths per LUN** | Numero di percorsi in stato `failed faulty` o `shaky` |
| **Total DM devices** | Numero totale di dispositivi multipath (`dm-*`) rilevati sul nodo |

### Riferimento Stati Percorso

| Stato | Significato | Azione |
|---|---|---|
| `active ready` | Percorso sano e traffico I/O regolare | Nessuna azione |
| `active ghost` | Percorso attivo ma in gruppo non preferito | Monitoraggio |
| `failed faulty` | Percorso fallito, I/O reindirizzato sui restanti percorsi | **Allarme** |
| `failed shaky` | Percorso con guasto intermittente | **Allarme** |
| `undef` | Stato del percorso sconosciuto (può indicare un problema HBA) | **Allarme** |

---

## 🔔 Soglie e Allarmi

Le soglie e le condizioni di allarme sono gestite internamente dai watcher in base allo stato del percorso:
- Se almeno un percorso di una LUN è degradato, viene registrato un evento `WARNING`.
- Se tutti i percorsi di una LUN sono degradati, viene registrato un evento `CRITICAL` e viene inviata una notifica immediata.

Le email di allarme vengono inviate in background per evitare blocchi:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO CRITICAL: [MULTIPATH] [cluster_db] — Nodo node1: device mpatha tutti i path degradati (4/4 failed)." \
    --body "Cluster: cluster_db\nNodo: node1\nDettaglio: Rilevato degrado completo per mpatha.\nTimestamp: $(date)" &
```

---

## 📄 Output JSON

Ad ogni esecuzione, il watcher scrive un file di stato JSON per ciascun nodo. Questo file viene utilizzato da KvirtIO HTML Generator per popolare la sezione di salute multipath del dashboard.

**Percorso di output**: `/var/www/html/kvirtio/data/multipath_<cluster>_<nodo>.json`

**Esempio** (`multipath_cluster_db_node1.json`):
```json
{
  "devices": [
    {"name": "mpatha", "total_paths": 4, "active_paths": 4, "failed_paths": 0, "status": "healthy"},
    {"name": "mpathb", "total_paths": 4, "active_paths": 3, "failed_paths": 1, "status": "degraded"}
  ]
}
```

---

## ⚙️ Integrazione Systemd

### Unità di Servizio (`kvirtio-multipath-watcher.service`)
```ini
[Unit]
Description=KvirtIO Multipath Path Health Watcher
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kvirtio-multipath-watcher.sh
User=root
StandardOutput=journal
StandardError=journal
```

### Unità Timer (`kvirtio-multipath-watcher.timer`)
```ini
[Unit]
Description=Run KvirtIO Multipath Watcher every 2 minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=120
Unit=kvirtio-multipath-watcher.service

[Install]
WantedBy=timers.target
```

### Abilitazione e Avvio
```bash
sudo cp systemd/kvirtio-multipath-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-multipath-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-multipath-watcher.timer
```

---

## 🔐 Requisiti Sudo sui Nodi KVM

L'utente `kvirtwatch` deve poter eseguire i seguenti comandi senza password su ciascun nodo KVM. Aggiungere la seguente voce a `/etc/sudoers.d/kvirtwatch`:

```sudoers
kvirtwatch ALL=(ALL) NOPASSWD: /usr/sbin/multipath -ll
```

Verificare la sintassi di sudoers dopo la modifica:
```bash
sudo visudo -c
```

---

## 🪵 Ispezione Log

Tutti gli eventi del watcher multipath vengono inviati al registro di sistema sotto l'identificatore `KvirtIO-Multipath`.

### Seguire i log in tempo reale:
```bash
journalctl -fu kvirtio-multipath-watcher.service
```

### Filtrare per tag syslog:
```bash
journalctl -t KvirtIO-Multipath -f
```

### Riferimento dei messaggi di log:

| Livello | Esempio Messaggio |
|---|---|
| `INFO` | `INFO: [cluster_db] Nodo node1: device mpatha tutti i path attivi.` |
| `WARNING` | `WARNING: [cluster_db] Nodo node1: device mpathb path parzialmente degradato (1/4 failed).` |
| `CRITICAL` | `CRITICAL: [cluster_db] Nodo node1: device mpatha tutti i path degradati (4/4 failed).` |
| `ERROR` | `ERROR: [cluster_db] Impossibile raggiungere il nodo node3 via SSH.` |
