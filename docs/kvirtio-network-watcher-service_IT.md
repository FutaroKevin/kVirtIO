# Documentazione Servizio: KvirtIO Network Watcher

Il servizio **KvirtIO Network Watcher** monitora lo stato di salute delle interfacce bond di rete (LACP o Active/Backup) e calcola il throughput differenziale sui nodi KVM per ciascun cluster definito in `/etc/kvirtio`.

---

## 📋 Descrizione Funzionale

Il watcher scansiona ciclicamente tutti i file `.conf` all'interno della directory `/etc/kvirtio/clusters/`. Per ciascun cluster caricato, si connette via SSH a ciascun nodo ipervisore ed esamina lo stato delle interfacce bonding (es. leggendo `/proc/net/bonding/bond0` o l'interfaccia specificata in `BOND_IFACE`) e i contatori di rete in `/proc/net/dev`.

### Obiettivo del Monitoraggio

In un cluster di virtualizzazione KVM, la perdita di una o più interfacce slave all'interno di un bond di rete riduce la ridondanza e la larghezza di banda disponibile. Il watcher fornisce visibilità immediata su:

- **Fallimenti delle interfacce slave**: Rilevamento degli slave in stato `MII Status: down` all'interno del bond.
- **Rottura totale del bond**: Allarme critico se tutti gli slave del bond sono disconnessi.
- **Statistiche di traffico (Throughput)**: Monitoraggio della larghezza di banda consumata (RX/TX Mbps) tramite calcolo differenziale a distanza di 1 secondo.

### Logica di Controllo

1. Lo script viene eseguito ogni **2 minuti** tramite il Timer Systemd.
2. Carica ciascun file `.conf` da `/etc/kvirtio/clusters/`.
3. Si connette via SSH a ciascun nodo ipervisore.
4. Legge `/proc/net/bonding/bond0` (o l'interfaccia specificata come `BOND_IFACE` in `.conf`, di default `bond0`):
   - Verifica lo stato di ogni interfaccia slave.
   - Rileva gli slave attivi e quelli degradati/offline.
5. Legge `/proc/net/dev` prima e dopo 1 secondo per calcolare il throughput reale in ingresso e in uscita (RX/TX Mbps).
6. Se viene rilevata un'interfaccia slave offline:
   - Viene generato un allarme `WARNING` (se almeno uno slave è ancora attivo) o `CRITICAL` (se tutti gli slave sono down).
   - Invia una notifica email asincrona tramite `kvirtio-mail-alerter.py`.
7. Scrive lo stato in `/tmp/kvirtio_network_state_${CLUSTER_NAME}_${node}.json`.

---

## 📈 Metrice Monitorate

| Metrica | Descrizione |
|---|---|
| **Stato degli Slave** | Stato delle singole interfacce fisiche slave (up / down) |
| **Throughput RX/TX** | Traffico di rete calcolato in Megabit al secondo (Mbps) |
| **Stato Complessivo** | `healthy` se tutti gli slave sono attivi, `degraded` se almeno uno slave è down, `critical` se tutti gli slave sono down |

---

## 🔔 Condizioni di Allarme

| Condizione | Gravità | Azione |
|---|---|---|
| Almeno uno slave del bond ha `MII Status: down` | **WARNING** | Syslog `WARNING` + email asincrona |
| Tutti gli slave del bond hanno `MII Status: down` | **CRITICAL** | Syslog `CRITICAL` + email asincrona |

Esempio di allarme via email:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO WARNING: [NETWORK] [cluster_db] — Nodo node2 slave eth1 DOWN" \
    --body "Cluster: cluster_db\nNodo: node2\nDettaglio: Rilevato slave eth1 down nel bond bond0.\nTimestamp: $(date)" &
```

---

## 📄 Output JSON

Ad ogni esecuzione, lo script scrive lo stato della rete in un file JSON per ciascun nodo, che viene poi caricato nel dashboard HTML:

**Percorso di output**: `/var/www/html/kvirtio/data/network_<cluster>_<nodo>.json`

**Esempio** (`network_cluster_db_node1.json`):
```json
{
  "bond": "bond0",
  "active_slaves": ["ens1"],
  "degraded_slaves": ["ens2"],
  "status": "degraded",
  "rx_mbps": 1.2,
  "tx_mbps": 0.8
}
```

---

## ⚙️ Integrazione Systemd

### Unità di Servizio (`kvirtio-network-watcher.service`)
```ini
[Unit]
Description=KvirtIO Network Watcher
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kvirtio-network-watcher.sh
User=root
StandardOutput=journal
StandardError=journal
```

### Unità Timer (`kvirtio-network-watcher.timer`)
```ini
[Unit]
Description=Run KvirtIO Network Watcher every 2 minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=120
Unit=kvirtio-network-watcher.service

[Install]
WantedBy=timers.target
```

### Abilitazione e Avvio
```bash
sudo cp systemd/kvirtio-network-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-network-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-network-watcher.timer
```

---

## 🔐 Requisiti Sudo sui Nodi KVM

Le letture delle informazioni sul bonding e sui dispositivi in `/proc/` non richiedono privilegi root (sono leggibili in modalità utente). Pertanto, non sono necessarie regole aggiuntive in sudoers per questo watcher, a meno che non si utilizzino utility avanzate come `ethtool` o `ip link` che richiedono privilegi sudo. Per uniformità, l'utente `kvirtwatch` si collega e legge direttamente le metriche da `/proc/net/bonding/` e `/proc/net/dev`.

---

## 🪵 Ispezione Log

Tutti gli eventi sono registrati in syslog con il tag `KvirtIO-Network`.

### Seguire i log in tempo reale:
```bash
journalctl -fu kvirtio-network-watcher.service
```

### Filtrare per tag syslog:
```bash
journalctl -t KvirtIO-Network -f
```

### Riferimento dei messaggi di log:

| Livello | Esempio Messaggio |
|---|---|
| `INFO` | `INFO: [cluster_db] Nodo node1: bond0 in stato healthy (ens1 up, ens2 up). RX: 12.4 Mbps, TX: 8.2 Mbps.` |
| `WARNING` | `WARNING: [cluster_db] Nodo node1: bond0 degradato, slave ens2 down.` |
| `CRITICAL` | `CRITICAL: [cluster_db] Nodo node1: bond0 critico, tutti gli slave sono down!` |
| `ERROR` | `ERROR: [cluster_db] Impossibile connettersi al nodo node2 via SSH.` |
