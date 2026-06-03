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

1.  **Creazione della Struttura di Configurazione**:
    ```bash
    sudo mkdir -p /etc/kvirtio/clusters
    ```

2.  **Posizionamento dei file di configurazione**:
    *   Creare i file di configurazione per ciascun cluster in `/etc/kvirtio/clusters/` prendendo spunto dai seguenti modelli:
        *   [etc/kvirtio/clusters/cluster_db.conf](../etc/kvirtio/clusters/cluster_db.conf): Configurazione per il cluster database con soglie prestazionali restrittive.
        *   [etc/kvirtio/clusters/cluster_web.conf](../etc/kvirtio/clusters/cluster_web.conf): Configurazione per il cluster generico/web.
    *   Assegnare la proprietà all'utente di gestione:
        ```bash
        sudo chown -R kvirtwatch:kvirtwatch /etc/kvirtio
        sudo chmod 750 /etc/kvirtio
        sudo chmod 640 /etc/kvirtio/clusters/*.conf
        ```

3.  **Posizionamento degli script**:
    *   Copiare lo script [kvirtio-host-watcher.sh](../scripts/kvirtio-host-watcher.sh) in `/usr/local/bin/kvirtio-host-watcher.sh`.
    *   Copiare lo script [kvirtio-io-watcher.sh](../scripts/kvirtio-io-watcher.sh) in `/usr/local/bin/kvirtio-io-watcher.sh`.
    *   Assegnare i permessi di esecuzione:
        ```bash
        sudo chmod +x /usr/local/bin/kvirtio-host-watcher.sh
        sudo chmod +x /usr/local/bin/kvirtio-io-watcher.sh
        sudo chown kvirtwatch:kvirtwatch /usr/local/bin/kvirtio-host-watcher.sh
        sudo chown kvirtwatch:kvirtwatch /usr/local/bin/kvirtio-io-watcher.sh
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

5.  **Abilitazione e Avvio dei Timer**:
    *   Abilitare e avviare il timer per il monitoraggio host:
        ```bash
        sudo systemctl enable --now kvirtio-host-watcher.timer
        ```
    *   Abilitare e avviare il timer per il monitoraggio I/O:
        ```bash
        sudo systemctl enable --now kvirtio-io-watcher.timer
        ```

---

## 🔍 Step 3: Verifica e Monitoraggio

### Stato dei Timer
Verificare la corretta pianificazione e lo stato di attivazione dei timer di Systemd:
```bash
systemctl list-timers --all | grep kvirtio
```

### Esecuzione di Test Manuale
È possibile forzare l'esecuzione dei servizi per convalidare il caricamento delle configurazioni ed escludere errori di sintassi:
```bash
sudo systemctl start kvirtio-host-watcher.service
sudo systemctl start kvirtio-io-watcher.service
```

### Ispezione Log Multi-Cluster
I log in syslog riporteranno l'indicazione esplicita del cluster in fase di elaborazione (es. `[cluster_db]`, `[cluster_web]`):
*   Per visualizzare l'output del watcher host:
    ```bash
    journalctl -t KvirtIO-Host -f
    ```
*   Per visualizzare l'output del watcher I/O:
    ```bash
    journalctl -t KvirtIO-IO -f
    ```
*   Per filtrare gli eventi critici di un cluster specifico (es. `cluster_db`):
    ```bash
    journalctl -t KvirtIO-Host | grep '\[cluster_db\]'
    ```

## 📜 Step 4: Logging e Centralizzazione Log dei (KVM, Pacemaker, Audit)

Gestione del logging verso il cluster di watcher. 

Per rispettare la naming convention richiesta (`[servizio]-[cluster]-[nodo].log`), la configurazione sul server ricevente viene generata dinamicamente leggendo i file del progetto in `/etc/kvirtio/clusters/*.conf`, in modo da mappare correttamente ogni nodo al proprio cluster di appartenenza.

---

### 1. Configurazione sui Nodi KVM (Client)

Sui nodi computazionali, `rsyslog` viene istruito per inoltrare i flussi specifici al Virtual IP (o IP dedicato) del server Watcher, mentre `auditd` viene configurato per inviare i propri eventi a syslog.

#### 1.1 Forwarding Rsyslog (`/etc/rsyslog.d/10-kvirtio-forward.conf`)
Creare il file su ogni nodo KVM per inoltrare i servizi target:


#### 1.2 Inoltro log di Pacemaker / Cluster Manager
 ```bash
if $programname == ['pacemakerd','crmd','pengine','corosync'] then @[IP_SERVER_WATCHER]:514
t = string
 ```

#### 1.3 Inoltro log di KVM / QEMU / Libvirt
 ```bash
if $programname == ['libvirtd','qemu','qemu-kvm','qemu-system-x86_64'] then @[IP_SERVER_WATCHER]:514
t = string
 ```

#### 1.4 Inoltro log di Auditd
 ```bash
if $programname == ['audisp-syslog','auditd'] then @[IP_SERVER_WATCHER]:514
t = string
```

#### 1.5  Configurazione di auditd sui nodi
*   Modificare la configurazione del plugin di audit (il percorso standard per SLES è /etc/audisp/plugins.d/syslog.conf o /etc/audit/plugins.d/syslog.conf a seconda della release):
    ```bash
    active = yes
    direction = out
    path = /sbin/audisp-syslog
    type = always
    args = LOG_WARNING
    format = string
    ```

#### 1.6 Restart dei servizi sui nodi
 ```bash
systemctl restart auditd rsyslog
```


### 2. Configurazione sul Cluster Watcher

* Poiché rsyslog non è nativamente a conoscenza della variabile "Cluster" ma riceve solo l'hostname, utilizziamo uno script generatore che legge la topologia di kVirtIO (/etc/kvirtio/clusters/*.conf) e costruisce le regole di routing esatte per ogni nodo.

### 2.1 Preparazione delle directory
* per ogni nodo di Watcher generare i seguenti comandi:
```bash
mkdir -p /var/log/kvirtio/
chown syslog:kvirtwatch /var/log/kvirtio/
chmod 755 /var/log/kvirtio/
```

### 2.2 Script Generatore Configurazione Rsyslog
* Creare lo script /usr/local/bin/kvirtio-rsyslog-generator.sh sul server Watcher. Questo script mapperà ogni nodo per salvare i log secondo il formato: /var/log/kvirtio/[servizio]-[cluster]-[nodo].log.

📜 **[kvirtio-rsyslog-generator.sh](../scripts/kvirtio-rsyslog-generator.sh)**:

### 2.3 Esecuzione e Riavvio
* Rendere eseguibile lo script e generare la configurazione di rsyslog:

```bash
chmod +x /usr/local/bin/kvirtio-rsyslog-generator.sh
/usr/local/bin/kvirtio-rsyslog-generator.sh
```
*Verificare che il file /etc/rsyslog.d/30-kvirtio-receiver.conf sia stato popolato correttamente e riavviare il demone sul Watcher:
```bash
systemctl restart rsyslog
```
** (Nota Operativa: Ogni volta che un nuovo nodo o un nuovo cluster viene aggiunto in /etc/kvirtio/clusters/*.conf, basterà lanciare nuovamente /usr/local/bin/kvirtio-rsyslog-generator.sh e ricaricare rsyslog).
