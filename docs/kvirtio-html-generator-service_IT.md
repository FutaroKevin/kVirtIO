# Documentazione Servizio: KvirtIO HTML Generator

Il servizio **KvirtIO HTML Generator** raccoglie le metriche da tutti i cluster configurati e genera un dashboard HTML interattivo e moderno servito dal server web Apache.

---

## 📋 Descrizione Funzionale
Il generatore scansiona tutti i file `.conf` all'interno della directory `/etc/kvirtio/clusters/` per raccogliere le informazioni dei nodi attivi. Rispetto ai classici sistemi di monitoraggio a agenti (come Prometheus), questo approccio adotta un design pull-based agentless centralizzato che:
1.  Viene eseguito ogni **5 minuti** tramite il Timer Systemd.
2.  Esegue un blocco unico di comandi aggregati via SSH su ciascun host per minimizzare la latenza di connessione.
3.  Elabora i dati e compila un dashboard HTML statico in `/var/www/html/kvirtio/index.html`.
4.  Consente agli amministratori di sistema di controllare lo stato dell'infrastruttura tramite un qualsiasi browser web puntando all'indirizzo del server di management.

---

## ⚙️ Parametri Rilevati e Visualizzati

Il dashboard mostra in tempo reale le seguenti sezioni per ciascun cluster:

### 1. Nodi Host (Ipervisori)
*   **Stato di salute**: ONLINE (Verde), OFFLINE (Rosso) in caso di mancata risposta SSH, o SOVRACCARICO (Arancione) se CPU/RAM superano le soglie del cluster.
*   **Percentuale CPU**: Carico reale complessivo ricavato da `/proc/stat`.
*   **Percentuale RAM**: Memoria fisica realmente utilizzata ricavata da `MemAvailable` in `/proc/meminfo`.
*   **Latenza I/O LUN FC**: Il picco massimo del tempo di attesa delle code multipath (`dm-*`) estratto dal comando `iostat` (espresso in millisecondi).

### 2. Condizione dello Storage Condiviso (LVM Volume Groups)
*   Dimensione totale e spazio libero di ciascun Volume Group clusterizzato (es. `vg_iointensive`).
*   Percentuale di spazio libero residuo (con allarme visivo se inferiore al 15%).

### 3. Spazio Dischi delle Virtual Machine (LVM Logical Volumes)
*   Mappatura di ogni singola VM (che corrisponde a un Logical Volume LVM).
*   Associazione al relativo Volume Group di cluster e dimensione fisica allocata (es. 16TB).

---

## 🏎️ Ottimizzazione delle Prestazioni: Connessione SSH Singola
Per massimizzare l'efficienza e ridurre a zero l'overhead sui nodi KVM di produzione, il generatore **non esegue interrogazioni SSH multiple** per ciascuna metrica. Al contrario, invia un unico script Bash aggregato via SSH che restituisce in stdout le informazioni concatenate, separate da token speciali (es. `===VGS===`, `===IOSTAT===`).

Il parsing di questo flusso combinato viene eseguito interamente in Python sul server di management esterno.

---

## 🌐 Configurazione e Hosting Apache

Per servire la pagina generata tramite il server web Apache nativo di SLES (`apache2`):

1.  **Creazione Directory Document Root**:
    ```bash
    sudo mkdir -p /var/www/html/kvirtio
    ```
2.  **Configurazione dei Permessi**:
    Affinché lo script Python eseguito dall'utente `kvirtwatch` possa scrivere il report HTML, la directory deve essere di sua proprietà, pur consentendo ad Apache (gruppo `www` o `wwwrun` su SLES) la lettura:
    ```bash
    sudo chown -R kvirtwatch:wwwrun /var/www/html/kvirtio
    ```
    ```bash
    sudo chmod 750 /var/www/html/kvirtio
    ```
3.  **Configurazione Apache Virtual Host (Opzionale ma consigliata)**:
    Creare il file `/etc/apache2/vhosts.d/kvirtio.conf` per limitare l'accesso alla rete interna:
    ```apache
    <VirtualHost *:80>
        DocumentRoot "/var/www/html/kvirtio"
        ServerName kvirtio-monitor.local
        
        <Directory "/var/www/html/kvirtio">
            Options Indexes FollowSymLinks
            AllowOverride None
            Require ip 10.0.0.0/8 192.168.0.0/16
        </Directory>
    </VirtualHost>
    ```
4.  **Avvio del Servizio Web**:
    ```bash
    sudo systemctl enable --now apache2
    ```
