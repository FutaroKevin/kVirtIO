#!/usr/bin/env bash
# ==============================================================================
# Script: kvirtio-json-indexer.sh
# Descrizione: Scansiona la directory dei JSON generati dai watcher e crea
#              un file index.json che il frontend Javascript può leggere per
#              sapere quali file scaricare.
# Autore: Kevin Tafuro
# Progetto: KvirtIO Virtualization
# ==============================================================================

set -o nounset
set -o pipefail

DATA_DIR="/var/www/html/kvirtio/data"
INDEX_FILE="/var/www/html/kvirtio/index.json"

# Se la directory non esiste, esci senza errori
if [ ! -d "$DATA_DIR" ]; then
    exit 0
fi

# Costruisce il JSON usando una stringa in memoria per non sovrascrivere file vuoti o corrotti in caso di errore
JSON_OUT="{"
JSON_OUT+="\n  \"generated_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%S")\","
JSON_OUT+="\n  \"files\": ["

first=1
# Disabilita errori se glob vuoto
shopt -s nullglob
for file in "$DATA_DIR"/*.json; do
    basename=$(basename "$file")
    # Escludi l'eventuale presenza di index.json all'interno di data/ (anche se è in var/www/html/kvirtio)
    [ "$basename" == "index.json" ] && continue
    
    if [ "$first" -eq 0 ]; then
        JSON_OUT+=","
    fi
    JSON_OUT+="\n    \"$basename\""
    first=0
done

JSON_OUT+="\n  ]"
JSON_OUT+="\n}"

# Scrive il file atomicamente
TMP_FILE=$(mktemp)
echo -e "$JSON_OUT" > "$TMP_FILE"
mv "$TMP_FILE" "$INDEX_FILE"
chmod 644 "$INDEX_FILE"
