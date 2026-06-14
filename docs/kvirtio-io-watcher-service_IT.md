# Documentazione Servizio: KvirtIO I/O Watcher

Il servizio **KvirtIO I/O Watcher** monitora la latenza dei dischi multipath (`dm-*`) associati alle macchine virtuali con profilo "IOIntensive" presenti sui nodi di tutti i cluster definiti in `/etc/kvirtio`.

---

## 📋 Descrizione Funzionale
Il watcher scansiona ciclicamente tutti i file `.conf` all'interno della directory `/etc/kvirtio/clusters/` ad ogni esecuzione (ogni **1 minuto**). Per ciascun cluster caricato, esegue l'interrogazione tramite `iostat` per individuare colli di bottiglia e latenze anomale sui percorsi Fibre Channel di storage.

### Flusso Logico di Controllo
1.  Lo script viene eseguito ogni minuto.
2.  Individua tutti i cluster configurati in `/etc/kvirtio/clusters/*.conf`.
3.  Carica i parametri del singolo cluster (lista dei nodi e soglia di latenza specifica `LATENCY_THRESHOLD`).
4.  Si collega via SSH a ciascun host.
5.  Esegue `sudo iostat -dx 1 2` e analizza l'output del secondo report per i dispositivi `dm-*` (multipath).
6.  Isola il valore massimo di latenza di risposta (`await`).
7.  Se la latenza supera la soglia del cluster (es. `10.0` ms per `cluster_db`), invia un log di WARNING contenente il tag specifico del cluster.

---

## 📈 Metodologia di Analisi dell'I/O (iostat & AWK)
L'analisi viene effettuata catturando l'output di `iostat` eseguito sul nodo ipervisore ed elaborandolo localmente sul server di management tramite una pipeline AWK ad alta efficienza. Questo previene inutili sprechi di cicli CPU sugli host ipervisori di produzione e garantisce la corretta conversione dei separatori decimali (es. virgole europee `,` convertite in punti `.`).

---

## 🪵 Tracciamento Log (Syslog)
I log inviati a syslog tramite `logger` includono il prefisso del cluster `[NOME_CLUSTER]` per permettere filtri selettivi:

*   **Avvio monitoraggio (Info)**:
    `INFO: Inizio monitoraggio I/O per il cluster: cluster_db (5 nodi).`
*   **Superamento Soglia (Warning)**:
    `WARNING: [cluster_db] Latenza I/O anomala sul nodo node2. Massimo await riscontrato su multipath: 14.52ms (Soglia: 10.0ms).`
*   **Errore di Esecuzione (Error)**:
    `ERROR: [cluster_db] Impossibile raccogliere metriche I/O da node5.`
