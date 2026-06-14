# Script Documentation: KvirtIO JSON Indexer

The **KvirtIO JSON Indexer** is a helper script that scans the directory of JSON state files produced by the watchers and generates a central `index.json` catalog. The client-side dashboard UI reads this file to dynamically discover and download the active cluster status files.

---

## 📋 Functional Description

The script `kvirtio-json-indexer.sh` is designed to run on the external management server. It reads files from `/var/www/html/kvirtio/data/`, compiles a list of all present `.json` files (excluding the index file itself), formats the list as a structured JSON object along with a timestamp of generation, and writes it atomically to `/var/www/html/kvirtio/index.json`.

---

## 📈 Execution Logic

1.  **Directory Check**: Checks if the target data directory `/var/www/html/kvirtio/data` exists. If not, it exits gracefully.
2.  **Scan for Files**: Activates `nullglob` (bash option) to safely handle empty directories and loops over all `*.json` files.
3.  **Filter & Aggregate**: Extracts the file names (e.g. `cluster_cluster_db.json`, `network_cluster_db_node1.json`), skipping `index.json` if present in the target directory.
4.  **JSON Generation**: Formats the JSON array in memory.
5.  **Atomic Replacement**: Writes the generated payload to a temporary file (`mktemp`) and performs an atomic rename (`mv`) to `/var/www/html/kvirtio/index.json`. Finally, it sets permissions to `0644`.

---

## 📄 Output Schema

**Output path**: `/var/www/html/kvirtio/index.json`

**Example**:
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

## ⚙️ Cron or Systemd Execution

The script is typically invoked at the end of watcher cycles or run as a cron job or systemd timer every 5 minutes (along with the HTML generator).

Example manual run:
```bash
/usr/local/bin/kvirtio-json-indexer.sh
```
