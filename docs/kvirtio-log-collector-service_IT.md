# Documentazione Servizio: KvirtIO Log Collector

Il **KvirtIO Log Collector** è un servizio basato su Python progettato per centralizzare, strutturare e filtrare gli eventi di log generati da tutti i watcher di KvirtIO. Genera un file JSON consolidato contenente gli eventi delle ultime 24 ore, che viene poi consumato dal dashboard per l'ispezione dei log tramite interfaccia web.

---

## 📋 Descrizione Funzionale

Lo script `kvirtio-log-collector.py` aggrega i record di log dal journal systemd di SLES, li filtra in base a specifici identificatori syslog, ne deriva il livello di gravità analizzando il testo del messaggio, applica le regole di retention (mantenendo solo gli eventi delle ultime 24 ore fino a un massimo di 5000 eventi) e scrive il risultato in un file JSON leggibile dal gruppo Apache.

### Identificatori Syslog Aggregati

Il collector interroga journalctl per raccogliere i log contrassegnati dai seguenti tag:
-   `KvirtIO-Host` (Host Watcher)
-   `KvirtIO-IO` (I/O Watcher)
-   `KvirtIO-Cluster` (HA Cluster Watcher)
-   `KvirtIO-Multipath` (Multipath Watcher)
-   `KvirtIO-VM` (VM Watcher)
-   `KvirtIO-Network` (Network Watcher)
-   `KvirtIO-HTMLGen` (HTML Generator)
-   `KvirtIO-LogCollector` (I log dello stesso collector)

### Derivazione del Livello di Log

Poiché le voci del journal standard potrebbero non includere sempre un livello di gravità esplicito in formato testo, il collector scansiona il corpo del messaggio e ne deduce il livello tramite espressioni regolari:
1.  `CRITICAL` (priorità massima)
2.  `ERROR`
3.  `WARNING`
4.  `SUCCESS`
5.  `INFO` (valore predefinito)

---

## 📈 Logica del Processo

1.  **Lettura del Journal**: Il collector avvia `journalctl` per i tag specificati e recupera i log degli ultimi 30 minuti.
2.  **Caricamento dei Log Esistenti**: Carica il file `/var/log/kvirtio/logs/kvirtio-events.json` per garantire la continuità degli eventi storici.
3.  **Retention e Deduplicazione**:
    -   Rimuove le voci più vecchie di 24 ore.
    -   Deduplica i nuovi eventi confrontandoli con quelli esistenti.
    -   Ordina gli eventi inserendo i più recenti all'inizio.
    -   Limita la dimensione massima a 5000 eventi per evitare un consumo eccessivo di memoria e spazio su disco.
4.  **Scrittura Atomica**: Scrive i log aggiornati in `/var/log/kvirtio/logs/kvirtio-events.json` tramite file temporaneo e sostituzione atomica. Imposta i permessi a `0644` in modo che Apache possa accedervi in lettura.

---

## 📄 Output JSON

**Percorso di output**: `/var/log/kvirtio/logs/kvirtio-events.json`

**Esempio**:
```json
{
  "generated_at": "2026-06-10T14:30:00",
  "event_count": 1,
  "events": [
    {
      "timestamp": "2026-06-10T14:28:45",
      "source": "KvirtIO-Cluster",
      "level": "CRITICAL",
      "message": "[cluster_db] Quorum lost: 2/5 nodes active."
    }
  ]
}
```

---

## ⚙️ Integrazione Systemd

### Unità di Servizio (`kvirtio-log-collector.service`)
```ini
[Unit]
Description=KvirtIO Log collector Service
After=network.target

[Service]
Type=oneshot
User=kvirtwatch
ExecStart=python3 /usr/local/bin/kvirtio-log-collector.py
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/tmp

[Install]
WantedBy=multi-user.target
```

### Abilitazione e Avvio
```bash
sudo cp systemd/kvirtio-log-collector.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-log-collector.service
```

---

## 🪵 Ispezione Log

I log interni del log collector vengono inviati a syslog con il tag `KvirtIO-LogCollector`.

*   **Visualizzare i log del collector**:
    ```bash
    journalctl -t KvirtIO-LogCollector -f
    ```
*   **Esempi di messaggi**:
    -   `INFO: Avvio raccolta log.`
    -   `INFO: Raccolti 15 nuovi eventi dal journal.`
    -   `INFO: File eventi aggiornato: 125 eventi totali in /var/log/kvirtio/logs/kvirtio-events.json.`
