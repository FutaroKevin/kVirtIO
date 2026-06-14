# Documentazione Script: KvirtIO JSON Indexer

Il **KvirtIO JSON Indexer** è uno script di supporto che scansiona la directory dei file di stato JSON generati dai watcher e crea un file di catalogo centralizzato `index.json`. L'interfaccia client-side della dashboard legge questo file per rilevare e caricare dinamicamente i file di stato dei cluster attivi.

---

## 📋 Descrizione Funzionale

Lo script `kvirtio-json-indexer.sh` è progettato per essere eseguito sul server di management esterno. Legge i file presenti in `/var/www/html/kvirtio/data/`, compila un elenco di tutti i file `.json` rilevati (escludendo il file di indice stesso), formatta l'elenco come un oggetto JSON strutturato insieme a un timestamp di generazione e lo scrive in modo atomico in `/var/www/html/kvirtio/index.json`.

---

## 📈 Logica di Esecuzione

1.  **Verifica della directory**: Controlla se la directory dei dati `/var/www/html/kvirtio/data` esiste. In caso contrario, esce senza errori.
2.  **Scansione dei file**: Attiva l'opzione `nullglob` di bash per gestire in sicurezza le directory vuote e scorre tutti i file con estensione `*.json`.
3.  **Filtro e Aggregazione**: Estrae il nome base di ciascun file (es. `cluster_cluster_db.json`, `network_cluster_db_node1.json`), saltando `index.json` se presente.
4.  **Generazione JSON**: Compone il payload JSON in memoria.
5.  **Sostituzione Atomica**: Scrive il payload generato in un file temporaneo (`mktemp`) ed effettua uno spostamento atomico (`mv`) verso `/var/www/html/kvirtio/index.json`. Infine imposta i permessi del file a `0644`.

---

## 📄 Schema di Output

**Percorso di output**: `/var/www/html/kvirtio/index.json`

**Esempio**:
```json
{
  "generated_at": "2026-06-10T14:35:00",
  "files": [
    "cluster_cluster_db.json",
    "console_cluster_db.json",
    "multipath_cluster_db_node1.json",
    "network_cluster_db_node1.json",
    "vm_cluster_db.json"
  ]
}
```

---

## ⚙️ Pianificazione ed Esecuzione

Lo script viene in genere invocato al termine del ciclo di esecuzione dei watcher, oppure tramite cron/timer systemd ogni 5 minuti (in combinazione con l'HTML generator).

Esempio di esecuzione manuale:
```bash
/usr/local/bin/kvirtio-json-indexer.sh
```
