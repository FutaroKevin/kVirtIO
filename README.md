# KvirtIO: Enterprise Virtualization Platform

**KvirtIO** è un'architettura di virtualizzazione enterprise di classe Service Provider concepita per scenari ad elevata densità di I/O e alta affidabilità (HA), basata interamente su tecnologie native e open-source distribuite da **SUSE Linux Enterprise Server (SLES)**.

---

## 🚀 Obiettivi del Progetto
*   **Prestazioni deterministiche**: Esclusione totale dello swap host e ottimizzazione dell'allocazione di RAM (Hugepages) e CPU (pinning NUMA).
*   **I/O ottimizzato per Database ("IOIntensive")**: Parallelizzazione delle code SCSI del kernel (`lun_queue_depth`) tramite strategie Multi-LUN Striped e architettura `blk-mq`.
*   **Alta Affidabilità e Fencing multilivello**: Integrazione stretta tra Pacemaker, Corosync, Cluster LVM (`lvmlockd` + `dlm`) e meccanismi STONITH fisici (`fence_idrac`) e storage-based (`sbd` su Witness LUN con watchdog hardware).
*   **Disaccoppiamento del Control Plane**: Isolamento delle logiche di monitoraggio, telemetria e bilanciamento dei carichi all'esterno del cluster KVM di produzione.

---

## 📂 Struttura del Repository

### 1. Documenti di Architettura e Design
*   📄 **[KvirtIO High-Level Design (HLD)](KvirtIO_HLD.md)**: Il documento di architettura di alto livello.

### 2. Monitoraggio & Watcher (Control Plane Esterno)
Questi script risiedono sul server di management esterno ed interrogano i nodi KVM tramite l'utente `kvirtwatch` via SSH.
*   📜 **[kvirtio-host-watcher.sh](scripts/kvirtio-host-watcher.sh)**: Script di monitoraggio di carico CPU/RAM con integrazione `crm_attribute`.
*   📜 **[kvirtio-io-watcher.sh](scripts/kvirtio-io-watcher.sh)**: Script per l'analisi della latenza `await` sui dischi multipath.
*   📜 **[kvirtio-vm-migrate.sh](scripts/kvirtio-vm-migrate.sh)**: Script per l'esecuzione della Live Migration a caldo di una VM da un nodo sorgente a un nodo di destinazione.
*   📜 **[kvirtio-vm-create.sh](scripts/kvirtio-vm-create.sh)**: Script per la creazione della VM partendo dal cluster di management. 
*   📜 **[kvirtio-html-generator.py](scripts/kvirtio-html-generator.py)**: Script per il monitoraggio dell'infrastruttura tramite pagina web


### 3. Configurazioni Systemd (Timer)
*   ⚙️ **[kvirtio-host-watcher.service](systemd/kvirtio-host-watcher.service)** / **[Timer](systemd/kvirtio-host-watcher.timer)** (Esecuzione ogni 5 minuti).
*   ⚙️ **[kvirtio-io-watcher.service](systemd/kvirtio-io-watcher.service)** / **[Timer](systemd/kvirtio-io-watcher.timer)** (Esecuzione ogni minuto).
*   ⚙️ **[kvirtio-html-generator.service](systemd/kvirtio-html-generator.service)** / **[Timer](systemd/kvirtio-html-generator.timer)** (Esecuzione ogni 5 minuti).

### 4. Configurazione di Sicurezza (Nodi Compute)
*   🛡️ **[kvirtwatch (Sudoers)](sudoers/kvirtwatch)**: Privilegi sudo minimi necessari da configurare sui nodi KVM per `crm_attribute` e `iostat`.

### 5. Guide ed Istruzioni Operative
*   📘 **[Guida al Deployment dei Watcher](docs/deployment.md)**: Istruzioni passo-passo per l'installazione di SSH, script, timers e permessi sudo.
*   📘 **[Dettaglio Host Watcher Service](docs/kvirtio-host-watcher-service.md)**: Analisi dell'algoritmo di calcolo CPU/RAM e delle transizioni di stato.
*   📘 **[Dettaglio I/O Watcher Service](docs/kvirtio-io-watcher-service.md)**: Analisi delle metriche `await` estratte tramite `iostat`.
*   📘 **[Dettaglio HTML Generator Service](docs/kvirtio-html-generator-service.md)**: Pagina di monitoraggio dello stato dell'infrastruttura.
*   📘 **[Dettaglio Alerter](docs/kvirtio-mail-alerter.md)**: Dettaglio sistema di alerting tramite mail.


