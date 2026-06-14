# Guida al Deployment dei Watcher di Monitoraggio: KvirtIO

Questo documento fornisce le istruzioni dettagliate per installare, configurare e verificare i watcher di monitoraggio del progetto **KvirtIO** con supporto multi-cluster nativo.

---

## 🛠️ Architettura dei Watcher e Configurazione

Il monitoraggio adotta un design completamente disaccoppiato basato su file di configurazione modulari:
*   **Directory di configurazione**: `/etc/kvirtio/clusters/`
*   **File di configurazione**: Ogni cluster è definito da un file `.conf` indipendente (es. `cluster_db.conf`, `cluster_web.conf`), permettendo di differenziare i nodi target, l'utente SSH e le soglie di allarme per ciascun cluster gestito.
*   **Watcher (Server di Management)**: Eseguono la scansione dinamica della cartella di configurazione e iterano sui nodi di tutti i cluster rilevati.

---

## 📋 Requisiti Preliminari

1.  **Utente ed SSH (su tutti i nodi KVM e sul Server di Management)**:
    *   Creare l'utente dedicato `kvirtwatch` su tutte le macchine (il server di management e gli host KVM di tutti i cluster):
        ```bash
        sudo useradd -m -s /bin/bash kvirtwatch
        ```
    *   Generare la chiave SSH dell'utente `kvirtwatch` sul server di management senza passphrase:
        ```bash
        sudo -u kvirtwatch ssh-keygen -t ed25519 -N "" -f /home/kvirtwatch/.ssh/id_ed25519
        ```
    *   Distribuire la chiave pubblica su tutti i nodi ipervisori di tutti i cluster (es. per il cluster DB):
        ```bash
        sudo -u kvirtwatch ssh-copy-id -i /home/kvirtwatch/.ssh/id_ed25519.pub kvirtwatch@node1
        # Ripetere per tutti i nodi definiti nei file di configurazione
        ```
    *   Verificare che la connessione avvenga senza richiesta di password:
        ```bash
        sudo -u kvirtwatch ssh -o StrictHostKeyChecking=accept-new kvirtwatch@node1 "hostname"
        ```

2.  **Pacchetti sui nodi KVM (SLES)**:
    *   Assicurarsi che il pacchetto `sysstat` sia installato su tutti gli host KVM:
        ```bash
        sudo zypper install sysstat
        ```

---

## 🚀 Step 1: Configurazione dei Nodi KVM (Compute Host)

Su ciascun nodo ipervisore di tutti i cluster gestiti:

1.  Creare il file di configurazione sudoers per permettere l'elevazione dei privilegi controllata dell'utente `kvirtwatch`:
    *   Copiare il contenuto del file logico di configurazione [kvirtwatch (sudoers)](../sudoers/kvirtwatch) in `/etc/sudoers.d/kvirtwatch`.
2.  Impostare i permessi di sicurezza corretti:
    ```bash
    sudo chmod 0440 /etc/sudoers.d/kvirtwatch
    sudo chown root:root /etc/sudoers.d/kvirtwatch
    ```
3.  Verificare la validità della sintassi:
    ```bash
    sudo visudo -c
    ```

---

## 🚀 Step 2: Configurazione del Server di Management

Sul Server di Management esterno:

1.  **Creazione della Struttura di Configurazione e Directory di Log**:
    ```bash
    sudo mkdir -p /etc/kvirtio/clusters
    sudo mkdir -p /var/lib/kvirtio/logs
    sudo mkdir -p /var/lib/kvirtio/novnc/tokens
    sudo mkdir -p /var/www/html/kvirtio/data
    ```

2.  **Posizionamento dei file di configurazione**:
    *   Creare i file di configurazione per ciascun cluster in `/etc/kvirtio/clusters/` prendendo spunto dai modelli disponibili:
        *   [etc/kvirtio/clusters/cluster_db.conf](../etc/kvirtio/clusters/cluster_db.conf): Configurazione per il cluster database con soglie prestazionali restrittive.
        *   [etc/kvirtio/clusters/cluster_web.conf](../etc/kvirtio/clusters/cluster_web.conf): Configurazione per il cluster generico/web.
    *   Configurare i parametri SMTP nel file globale `/etc/kvirtio/mail.conf` (vedere [kvirtio-mail-config.md](kvirtio-mail-config_IT.md)).
    *   Assegnare la proprietà all'utente di gestione:
        ```bash
        sudo chown -R kvirtwatch:kvirtwatch /etc/kvirtio
        sudo chmod 750 /etc/kvirtio
        sudo chmod 640 /etc/kvirtio/clusters/*.conf
        sudo chmod 640 /etc/kvirtio/mail.conf
        ```
    *   Assegnare i permessi per la cartella dei log al gruppo del web server (`wwwrun` o `www-data` a seconda di SLES/Apache):
        ```bash
        sudo chown -R kvirtwatch:wwwrun /var/lib/kvirtio
        sudo chmod -R 770 /var/lib/kvirtio
        ```

3.  **Posizionamento degli script**:
    *   Copiare tutti gli script in `/usr/local/bin/`:
        ```bash
        sudo cp scripts/kvirtio-* /usr/local/bin/
        sudo chmod 750 /usr/local/bin/kvirtio-*
        sudo chown root:kvirtwatch /usr/local/bin/kvirtio-*
        ```

4.  **Configurazione dei Servizi Systemd**:
    *   Copiare i file di servizio e timer da [systemd/](../systemd/) in `/etc/systemd/system/`:
        ```bash
        sudo cp systemd/kvirtio-*.service /etc/systemd/system/
        sudo cp systemd/kvirtio-*.timer /etc/systemd/system/
        ```
    *   Ricaricare il demone di Systemd:
        ```bash
        sudo systemctl daemon-reload
        ```

5.  **Abilitazione e Avvio dei Timer e dei Servizi a lungo termine**:
    *   Abilitare e avviare i timer systemd per i watcher periodici:
        ```bash
        sudo systemctl enable --now kvirtio-host-watcher.timer
        sudo systemctl enable --now kvirtio-io-watcher.timer
        sudo systemctl enable --now kvirtio-cluster-watcher.timer
        sudo systemctl enable --now kvirtio-multipath-watcher.timer
        sudo systemctl enable --now kvirtio-vm-watcher.timer
        sudo systemctl enable --now kvirtio-html-generator.timer
        ```
    *   Abilitare e avviare i servizi continui (demoni):
        ```bash
        sudo systemctl enable --now kvirtio-console-tracker.service
        sudo systemctl enable --now kvirtio-log-collector.service
        ```

---

## 🔍 Step 3: Verifica e Monitoraggio

### Stato dei Timer e Servizi
Verificare la corretta pianificazione e lo stato di attivazione dei timer di Systemd:
```bash
systemctl list-timers --all | grep kvirtio
```
Verificare lo stato dei demoni attivi:
```bash
systemctl status kvirtio-console-tracker.service
systemctl status kvirtio-log-collector.service
```

### Esecuzione di Test Manuale
È possibile forzare l'esecuzione dei servizi one-shot per convalidare il caricamento delle configurazioni ed escludere errori di sintassi:
```bash
sudo systemctl start kvirtio-host-watcher.service
sudo systemctl start kvirtio-io-watcher.service
sudo systemctl start kvirtio-cluster-watcher.service
sudo systemctl start kvirtio-multipath-watcher.service
sudo systemctl start kvirtio-vm-watcher.service
sudo systemctl start kvirtio-html-generator.service
```

### Ispezione Log Multi-Cluster
I log in syslog riporteranno l'indicazione esplicita del cluster in fase di elaborazione:
*   **Watcher Host**: `journalctl -t KvirtIO-Host -f`
*   **Watcher I/O**: `journalctl -t KvirtIO-IO -f`
*   **Watcher Cluster HA**: `journalctl -t KvirtIO-Cluster -f`
*   **Watcher Multipath**: `journalctl -t KvirtIO-Multipath -f`
*   **Watcher VM**: `journalctl -t KvirtIO-VM -f`
*   **Log Collector**: `journalctl -t KvirtIO-LogCollector -f`

---

## 📜 Step 4: Logging e Centralizzazione Log (KVM, Pacemaker, Audit)

Per rispettare la naming convention richiesta (`[servizio]-[cluster]-[nodo].log`), la configurazione sul server ricevente viene generata dinamicamente leggendo i file del progetto in `/etc/kvirtio/clusters/*.conf`, in modo da mappare correttamente ogni nodo al proprio cluster di appartenenza.

### 1. Configurazione sui Nodi KVM (Client)

Sui nodi computazionali, `rsyslog` viene istruito per inoltrare i flussi specifici al Virtual IP (o IP dedicato) del server Watcher, mentre `auditd` viene configurato per inviare i propri eventi a syslog.

#### 1.1 Forwarding Rsyslog (`/etc/rsyslog.d/10-kvirtio-forward.conf`)
Creare il file su ogni nodo KVM per inoltrare i servizi target all'IP del server Watcher (es. `10.10.10.100`):

```rsyslog
# Inoltro log Pacemaker / Corosync
if $programname == ['pacemakerd','crmd','pengine','corosync'] then @10.10.10.100:514

# Inoltro log KVM / QEMU / Libvirt
if $programname == ['libvirtd','qemu','qemu-kvm','qemu-system-x86_64'] then @10.10.10.100:514

# Inoltro log Auditd
if $programname == ['audisp-syslog','auditd'] then @10.10.10.100:514
```

#### 1.2 Configurazione di auditd sui nodi
Modificare il file `/etc/audit/plugins.d/syslog.conf` (o `/etc/audisp/plugins.d/syslog.conf` su versioni SLES precedenti):
```ini
active = yes
direction = out
path = /sbin/audisp-syslog
type = always
args = LOG_WARNING
format = string
```

#### 1.3 Riavvio dei servizi sui nodi
```bash
sudo systemctl restart auditd
sudo systemctl restart rsyslog
```

---

### 2. Configurazione sul Server Watcher

Poiché rsyslog non è nativamente a conoscenza della variabile "Cluster", utilizziamo lo script generatore che legge la topologia di kVirtIO e costruisce le regole di routing per ogni nodo.

#### 2.1 Preparazione delle directory
Sul server Watcher:
```bash
sudo mkdir -p /var/log/kvirtio/
sudo chown syslog:kvirtwatch /var/log/kvirtio/
sudo chmod 755 /var/log/kvirtio/
```

#### 2.2 Generazione Configurazione Rsyslog
Eseguire lo script generatore per mappare ciascun nodo:
```bash
sudo chmod +x /usr/local/bin/kvirtio-setup-rsyslog-generator.sh
sudo /usr/local/bin/kvirtio-setup-rsyslog-generator.sh
```
Questo creerà `/etc/rsyslog.d/30-kvirtio-receiver.conf` smistando i log in `/var/log/kvirtio/[servizio]-[cluster]-[nodo].log`.

#### 2.3 Riavvio Rsyslog
```bash
sudo systemctl restart rsyslog
```

*(Nota Operativa: Ogni volta che si aggiunge o rimuove un nodo/cluster in `/etc/kvirtio/clusters/*.conf`, è sufficiente rieseguire lo script generatore e riavviare rsyslog).*
