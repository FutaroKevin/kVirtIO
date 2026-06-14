# Guida alle Configurazioni: File di Configurazione e Politiche di Sicurezza KvirtIO

Questo documento fornisce dettagli sui file di configurazione e sulle politiche di sicurezza utilizzate dal control plane e dai nodi ipervisori di **KvirtIO**.

---

## 📂 1. Configurazioni del Cluster (`/etc/kvirtio/clusters/*.conf`)

Ogni cluster KvirtIO è definito da un file `.conf` (bash-sourceable) posizionato all'interno della directory `/etc/kvirtio/clusters/`. Gli script watcher analizzano questi file in modo dinamico per rilevare la topologia del cluster e applicare le soglie di allarme specifiche.

### Riferimento Parametri

| Variabile | Tipo | Descrizione | Esempio |
|---|---|---|---|
| `CLUSTER_NAME` | Stringa | Nome univoco del cluster. | `"cluster_db"` |
| `NODES` | Array | Elenco degli hostname degli ipervisori nel cluster. | `("node1" "node2" "node3")` |
| `SSH_USER` | Stringa | Utente SSH utilizzato dal server di management. | `"kvirtwatch"` |
| `CPU_THRESHOLD` | Intero | Soglia percentuale di utilizzo CPU prima dell'allarme. | `85` |
| `RAM_THRESHOLD` | Intero | Soglia percentuale di utilizzo RAM prima dell'allarme. | `90` |
| `LATENCY_THRESHOLD`| Float | Soglia massima di latenza I/O del disco (`await`) in ms. | `10.0` |
| `CONSECUTIVE_LIMIT`| Intero | Numero di controlli consecutivi prima dell'allarme. | `3` |
| `ALERT_COOLDOWN_MINUTES`| Intero | Tempo di cooldown tra allarmi email identici (default: 30). | `30` |

### Modello Configurazione Cluster DB (`cluster_db.conf`)
```ini
CLUSTER_NAME="cluster_db"
NODES=("node1" "node2" "node3" "node4" "node5")
SSH_USER="kvirtwatch"
CPU_THRESHOLD=85
RAM_THRESHOLD=90
LATENCY_THRESHOLD=10.0
CONSECUTIVE_LIMIT=3
ALERT_COOLDOWN_MINUTES=30
```

---

## ✉️ 2. Configurazione Notifiche SMTP (`/etc/kvirtio/mail.conf`)

Il file di configurazione globale delle email definisce i parametri di connessione al server SMTP utilizzati da `kvirtio-mail-alerter.py` per l'invio degli allarmi.

### Riferimento Parametri

| Parametro | Descrizione |
|---|---|
| `SMTP_SERVER` | Hostname o indirizzo IP del server SMTP. |
| `SMTP_PORT` | Porta del servizio SMTP (es. 25, 587, 465). |
| `SMTP_STARTTLS` | Impostare su `True` per abilitare l'upgrade sicuro STARTTLS. |
| `SMTP_USER` | Nome utente SMTP per autenticazione (vuoto per relay aperti). |
| `SMTP_PASSWORD` | Password SMTP per autenticazione. |
| `SMTP_FROM` | Indirizzo email del mittente nell'intestazione "From". |
| `SMTP_TO` | Indirizzo email del destinatario (team sysadmin o mailing list). |

### Modello Configurazione Mail (`mail.conf`)
```ini
SMTP_SERVER=smtp.example.com
SMTP_PORT=587
SMTP_STARTTLS=True
SMTP_USER=alerts@kvirtio.local
SMTP_PASSWORD=secretpassword
SMTP_FROM=alerts@kvirtio.local
SMTP_TO=sysadmins@example.com
```

---

## 🛡️ 3. Politica di Sicurezza Sudoers (`/etc/sudoers.d/kvirtwatch`)

Per rispettare il principio del minimo privilegio, il server di management si connette ai nodi di calcolo KVM utilizzando l'utente a bassi privilegi `kvirtwatch`. I comandi amministrativi specifici necessari per il monitoraggio e il provisioning delle VM vengono delegati tramite una configurazione sudoers dedicata.

### Comandi Richiesti sui Nodi KVM

Il file `/etc/sudoers.d/kvirtwatch` deve contenere le seguenti righe su ciascun host KVM:

```sudoers
# Monitoraggio del Cluster e Fencing
kvirtwatch ALL=(ALL) NOPASSWD: /usr/sbin/crm_mon --one-shot --output-as=xml, \
                                /usr/sbin/crm_attribute --node node[1-5] --name status-load --update overloaded, \
                                /usr/sbin/crm_attribute --node node[1-5] --name status-load --update healthy, \
                                /usr/bin/iostat -dx 1 2, \
                                /usr/sbin/stonith_admin --list-registered, \
                                /usr/sbin/corosync-quorumtool -s

# Monitoraggio Multipath (sola lettura)
kvirtwatch ALL=(ALL) NOPASSWD: /usr/sbin/multipath -ll

# Monitoraggio VM (sola lettura)
kvirtwatch ALL=(ALL) NOPASSWD: /usr/bin/virsh list --all, \
                                /usr/sbin/vgs -o vg_name\,vg_size\,vg_free --units G --nosuffix --noheadings, \
                                /usr/sbin/lvs -o lv_name\,vg_name\,lv_size --units G --nosuffix --noheadings

# Tracciamento Console delle VM
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh list --state-running --name
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh domdisplay *

# Gestione delle VM (Creazione e Migrazione)
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh define *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh start *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh autostart *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh migrate *
kvirtwatch ALL=(root) NOPASSWD: /usr/bin/virsh domstate *
kvirtwatch ALL=(root) NOPASSWD: /usr/sbin/virsh version --daemon
```

### Permessi di Sicurezza
Dopo aver copiato il file, impostare i permessi corretti sugli host computazionali KVM:
```bash
sudo chown root:root /etc/sudoers.d/kvirtwatch
sudo chmod 0440 /etc/sudoers.d/kvirtwatch
sudo visudo -c
```
