# Documentazione Servizio: KvirtIO VM Watcher

Il servizio **KvirtIO VM Watcher** monitora lo stato, il posizionamento e lo stato delle risorse Pacemaker di tutte le macchine virtuali definite nei cluster in `/etc/kvirtio`.

---

## 📋 Descrizione Funzionale

Il VM Watcher scansiona ciclicamente tutti i file di configurazione dei cluster in `/etc/kvirtio/clusters/`. Per ogni cluster, interroga un nodo online rappresentativo tramite SSH, recupera l'elenco delle VM locali di Libvirt (`virsh list --all`) e lo stato globale del cluster Pacemaker (`crm_mon`), correla le due fonti e scrive un file JSON unificato letto dal dashboard.

### Obiettivo del Monitoraggio

In un cluster virtualizzato ad alta affidabilità (HA), Pacemaker gestisce le VM come risorse HA (usando l'agente di risorsa `VirtualDomain`). Per evitare discrepanze, è fondamentale garantire che:
1.  **Lo stato di Libvirt corrisponda allo stato di Pacemaker**: Una VM deve essere in stato `running` sotto Libvirt se Pacemaker la elenca come `Started`.
2.  **Nessun downtime non pianificato delle VM**: Se una VM entra in stato `crashed` o `paused` (senza manutenzione pianificata), o se la sua risorsa Pacemaker è `Stopped` in modo imprevisto, deve essere attivato immediatamente un allarme.

### Logica di Controllo

1.  Lo script viene eseguito ogni **2 minuti** tramite un Timer Systemd.
2.  Legge le configurazioni dei cluster in `/etc/kvirtio/clusters/*.conf`.
3.  Trova il primo nodo online nel cluster che fungerà da destinazione per le query.
4.  Esegue:
    -   `sudo virsh list --all` per elencare tutte le VM e il loro stato Libvirt locale.
    -   `sudo crm_mon --one-shot --output-as=xml` per recuperare le risorse Pacemaker attive di tipo `VirtualDomain` e il nodo su cui sono in esecuzione.
5.  Correla i nomi delle VM di Libvirt con le risorse `VirtualDomain` di Pacemaker.
6.  Scrive il file JSON consolidato dello stato delle VM nella directory web.
7.  Attiva un allarme (tramite syslog e `kvirtio-mail-alerter.py`) se:
    -   Una VM si trova in stato `crashed`.
    -   Una VM si trova in stato `paused` (non pianificato).
    -   Una risorsa VM di Pacemaker è in stato `Stopped` in modo imprevisto.
8.  Rileva il ripristino quando il cluster torna a uno stato completamente sano.

---

## 📈 Metrice Monitorate

| Metrica | Fonte | Descrizione |
|---|---|---|
| **name** | Libvirt / Pacemaker | Il nome della macchina virtuale |
| **libvirt_state** | `virsh list --all` | Stato corrente dell'hypervisor: `running`, `paused`, `shut off`, `crashed`, ecc. |
| **pacemaker_resource**| `crm_mon` | L'ID della risorsa Pacemaker che gestisce questa VM |
| **pacemaker_node** | `crm_mon` | Il nodo hypervisor in cui Pacemaker si aspetta che la VM sia in esecuzione |
| **pacemaker_status** | `crm_mon` | Stato della risorsa Pacemaker: `Started`, `Stopped`, `FAILED` |

---

## 🔔 Soglie e Condizioni di Allarme

La valutazione dello stato avviene a ogni esecuzione (ogni 2 minuti):

| Condizione | Gravità | Azione |
|---|---|---|
| Stato Libvirt = `crashed` | **CRITICAL** | Email + syslog `CRITICAL` |
| Stato Libvirt = `paused` (non pianificato) | **CRITICAL** | Email + syslog `CRITICAL` |
| Stato Pacemaker = `Stopped` in modo imprevisto | **WARNING** | Syslog `WARNING` |
| Ripristino da warning/critical a uno stato sano | **INFO** | Email + syslog `INFO` (Ripristino) |

Le email di allarme vengono inviate in modo asincrono in background. I file di blocco temporanei (`/tmp/kvirtio_alert_lock_<cluster>_<alert_type>`) impediscono l'invio continuo di email per allarmi persistenti (tempo di cooldown predefinito: 30 minuti).

---

## 📄 Output JSON

**Percorso di output**: `/var/www/html/kvirtio/data/vm_<cluster>.json`

**Esempio** (`vm_cluster_db.json`):
```json
{
  "generated_at": "2026-06-10T14:12:00",
  "cluster_name": "cluster_db",
  "vms": [
    {
      "name": "lv_vmdb01",
      "libvirt_state": "running",
      "pacemaker_resource": "res_vm_db01",
      "pacemaker_node": "node01",
      "pacemaker_status": "Started"
    },
    {
      "name": "lv_vmdb02",
      "libvirt_state": "shut off",
      "pacemaker_resource": "res_vm_db02",
      "pacemaker_node": "node02",
      "pacemaker_status": "Stopped"
    }
  ]
}
```

---

## ⚙️ Integrazione Systemd

### Unità di Servizio (`kvirtio-vm-watcher.service`)
```ini
[Unit]
Description=KvirtIO VM Health Watcher
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kvirtio-vm-watcher.sh
User=root
StandardOutput=journal
StandardError=journal
```

### Unità Timer (`kvirtio-vm-watcher.timer`)
```ini
[Unit]
Description=Run KvirtIO VM Watcher every 2 minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=120
Unit=kvirtio-vm-watcher.service

[Install]
WantedBy=timers.target
```

### Abilitazione e Avvio
```bash
sudo cp systemd/kvirtio-vm-watcher.service /etc/systemd/system/
sudo cp systemd/kvirtio-vm-watcher.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kvirtio-vm-watcher.timer
```

---

## 🔐 Requisiti Sudo sui Nodi KVM

L'utente SSH `kvirtwatch` deve avere i permessi sudo per eseguire `virsh` e `crm_mon` senza password. Aggiungere le seguenti righe a `/etc/sudoers.d/kvirtwatch`:

```sudoers
kvirtwatch ALL=(ALL) NOPASSWD: /usr/bin/virsh list --all
kvirtwatch ALL=(ALL) NOPASSWD: /usr/sbin/crm_mon --one-shot --output-as=xml
```

---

## 🪵 Ispezione Log

Gli eventi vengono registrati nel registro di sistema sotto il tag `KvirtIO-VM`.

*   **Visualizzare i log in tempo reale**:
    ```bash
    journalctl -t KvirtIO-VM -f
    ```
*   **Esempi di messaggi di log**:
    -   `INFO: [cluster_db] Representative node: node1`
    -   `INFO: [cluster_db] VM cycle completed. 2 VMs found. State: OK.`
    -   `CRITICAL: [cluster_db] VM lv_vmdb01: state 'crashed'.`
