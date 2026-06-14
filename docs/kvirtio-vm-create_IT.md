# Documentazione Script: KvirtIO VM Creator

Lo script **KvirtIO VM Creator** è un'utilità da riga di comando eseguita esclusivamente sul server di management esterno per definire, registrare e avviare una macchina virtuale su un nodo ipervisore KVM in un cluster specifico.

---

## 📋 Descrizione Funzionale

Lo script `kvirtio-vm-create.sh` gestisce il provisioning delle macchine virtuali direttamente dal control plane di management. Accetta parametri hardware, applica profili XML di Libvirt ottimizzati in base al tipo di carico di lavoro della VM (database transazionale o servizio generico), si connette tramite SSH all'ipervisore di destinazione, registra la definizione della VM via `virsh define`, avvia la VM e abilita l'autostart. Inoltre, invia notifiche SMTP sullo stato dell'operazione.

---

## 🛠️ Interfaccia a Riga di Comando e Utilizzo

### Parametri Obbligatori
*   `--cluster <nome>`: Cluster di destinazione (es. `cluster_db`).
*   `--node <nome>`: Nodo hypervisor di destinazione all'interno del cluster (es. `node1`).
*   `--vm-name <nome>`: Nome identificativo univoco della VM (es. `vm-db-prod-01`).
*   `--profile <nome>`: Profilo di ottimizzazione del carico: `iointensive` o `general`.
*   `--vcpu <n>`: Numero di vCPU da assegnare.
*   `--ram-gb <n>`: Quantità di RAM in Gigabytes da assegnare.
*   `--disk-lv <path>`: Percorso assoluto del Logical Volume LVM pre-creato (es. `/dev/vg_iointensive/lv_vm_db01`).

### Parametri Facoltativi
*   `--network <vlan>`: Tag VLAN per il bridge di rete (default: `30`).
*   `--help`: Mostra questo messaggio di aiuto.

### Esempio di Utilizzo
```bash
/usr/local/bin/kvirtio-vm-create.sh \
    --cluster cluster_db \
    --node node1 \
    --vm-name vm-db-prod-01 \
    --profile iointensive \
    --vcpu 32 \
    --ram-gb 256 \
    --disk-lv /dev/vg_iointensive/lv_vm_db01 \
    --network 30
```

---

## ⚙️ Dettagli dei Profili di Carico

### 1. Profilo `iointensive` (Ottimizzato per Database)
-   **Controller Disco**: Modello `virtio-scsi` con supporto multi-coda (il numero di code corrisponde alle vCPU assegnate) e `iothread` dedicato.
-   **Driver Disco**: Accesso raw ai blocchi del disco con `cache='none'` e `io='native'` per bypassare la cache e interfacciarsi direttamente con i volumi LVM fisici.
-   **Memoria**: Ballooning completamente disabilitato (`<memballoon model='none'/>`) per bloccare l'allocazione di memoria RAM sull'ipervisore.
-   **Tuning NUMA**: Configurazione del binding rigido della memoria (`<numatune><memory mode='strict' placement='auto'/></numatune>`).

### 2. Profilo `general` (General Purpose)
-   **Controller Disco**: Interfaccia standard diretta su bus `virtio`.
-   **Driver Disco**: Caching del disco impostato su `cache='writeback'` per sfruttare la page-cache dell'host.
-   **Memoria**: Driver standard VirtIO balloon abilitato con raccolta statistiche attiva (`period='10'`).

---

## 🚀 Flusso di Esecuzione

1.  **Validazione Argomenti**: Verifica che tutti i parametri obbligatori siano forniti e siano validi.
2.  **Verifica Configurazione**: Carica la configurazione del cluster di destinazione (`/etc/kvirtio/clusters/<cluster>.conf`) e verifica che il nodo appartenga al cluster.
3.  **Compilazione XML**: Genera la definizione del dominio XML di Libvirt (architettura q35) ereditando i parametri del profilo scelto.
4.  **Registrazione Remota**: Scrive il codice XML in un file temporaneo sul nodo ipervisore, esegue `sudo virsh define` ed elimina il file XML temporaneo.
5.  **Avvio e Autostart**: Avvia la macchina virtuale (`sudo virsh start`) e imposta il flag autostart di Libvirt (`sudo virsh autostart`).
6.  **Notifica**: Invia un'email di notifica sia in caso di successo che di fallimento.
