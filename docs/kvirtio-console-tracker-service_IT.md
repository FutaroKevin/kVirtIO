# Documentazione Servizio: KvirtIO Console Tracker

Il **KvirtIO Console Tracker** è un demone in background che mantiene allineata la directory di configurazione dei token di Websockify con gli output delle console VNC in tempo reale delle macchine virtuali in esecuzione nei cluster.

---

## 📋 Descrizione Funzionale

Lo script `kvirtio-console-tracker.sh` funge da servizio sul server di management. Interroga periodicamente (ogni 10 secondi) tutti i nodi KVM di ciascun cluster configurato via SSH per verificare quali VM sono in esecuzione e recuperare la loro porta display VNC (utilizzando `virsh domdisplay` di Libvirt). Successivamente aggiorna dinamicamente i file dei token di Websockify e genera un file di stato JSON per la dashboard di monitoraggio.

### Obiettivi di Monitoraggio e Sincronizzazione

1.  **Proxying delle Console noVNC**: Per consentire agli amministratori di accedere alle console delle VM tramite browser web, Websockify mappa i token delle VM ai rispettivi socket VNC dell'hypervisor di destinazione (IP e porta dell'host).
2.  **Tracciamento Dinamico**: Quando una VM viene avviata, arrestata o migrata su un nodo hypervisor diverso, il Console Tracker rileva automaticamente il cambiamento, aggiorna la mappatura attiva e allinea la directory dei token.
3.  **Sicurezza**: Riduce al minimo l'impatto delle connessioni SSH remote eseguendo le interrogazioni sui dettagli delle VM come utente a bassi privilegi `kvirtwatch`.

---

## 📈 Logica del Processo

1.  **Inizializzazione delle directory**: Crea le cartelle dei token e dei dati JSON se non esistono.
2.  **Scansione dei cluster**: Legge `/etc/kvirtio/clusters/*.conf` per identificare i cluster e i relativi nodi KVM.
3.  **Recupero dello stato delle VM**: Per ciascun nodo:
    -   Si connette via SSH ed esegue `sudo virsh list --state-running --name` per elencare le VM in esecuzione.
    -   Per ciascuna VM in esecuzione, esegue `sudo virsh domdisplay <vm>` per ottenere i dettagli del protocollo VNC (es. `vnc://0.0.0.0:5901` o `vnc://:5901`).
    -   Risolve l'hostname dell'hypervisor in un indirizzo IP ed estrae la porta VNC (es. `5901`).
4.  **Scrittura dei Token Websockify**: Scrive le voci in `/var/lib/kvirtio/novnc/tokens/<cluster_name>.conf` nel formato:
    `<nome_vm>: <ip_nodo>:<porta_vnc>`
5.  **Scrittura del JSON per la Dashboard**: Genera il file `/var/www/html/kvirtio/data/console_<cluster_name>.json` che riporta l'elenco delle console disponibili e i percorsi target noVNC.
6.  **Pausa**: Attende 10 secondi prima di avviare il ciclo di polling successivo.

---

## 📄 File di Output

### File dei Token Websockify (`/var/lib/kvirtio/novnc/tokens/cluster_db.conf`)
```ini
# KvirtIO noVNC Token Directory - Cluster: cluster_db
# Generato da kvirtio-console-tracker il: 2026-06-10T14:20:00Z

lv_vmdb01: 10.10.10.11:5900
lv_vmdb02: 10.10.10.12:5901
```

### Mappatura delle Console per Dashboard (`/var/www/html/kvirtio/data/console_cluster_db.json`)
```json
{
  "type": "console",
  "cluster_name": "cluster_db",
  "timestamp": "2026-06-10T14:20:00Z",
  "consoles": [
    {
      "vm": "lv_vmdb01",
      "host": "node1",
      "host_ip": "10.10.10.11",
      "vnc_port": 5900,
      "token": "lv_vmdb01",
      "novnc_url": "/novnc/vnc.html?autoconnect=true&path=websockify&token=lv_vmdb01"
    }
  ]
}
```

---

## ⚙️ Integrazione Systemd

### Unità di Servizio (`kvirtio-console-tracker.service`)
```ini
[Unit]
Description=KvirtIO noVNC Console Tracker Daemon
After=network.target

[Service]
Type=simple
User=kvirtwatch
ExecStart=/usr/local/bin/kvirtio-console-tracker.sh
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=KvirtIO-ConsoleTracker

[Install]
WantedBy=multi-user.target
```

### Abilitazione e Avvio
```bash
sudo cp systemd/kvirtio-console-tracker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-console-tracker.service
```

---

## 🔐 Requisiti Sudo sui Nodi KVM

L'utente SSH `kvirtwatch` deve disporre dei permessi sudo per eseguire i seguenti comandi senza password sui nodi KVM:

```sudoers
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh list --state-running --name
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh domdisplay *
```

---

## 🪵 Ispezione Log

I log interni del demone vengono inviati a syslog con il tag `KvirtIO-ConsoleTracker`.

*   **Visualizzare i log in tempo reale**:
    ```bash
    journalctl -t KvirtIO-ConsoleTracker -f
    ```
*   **Esempi di messaggi di log**:
    -   `INFO: KvirtIO Console Tracker avviato. Polling ogni 10s.`
    -   `INFO: [cluster_db] Aggiornato token: lv_vmdb01 -> 10.10.10.11:5900`
    -   `INFO: [cluster_db] Token directory aggiornata: /var/lib/kvirtio/novnc/tokens/cluster_db.conf`
