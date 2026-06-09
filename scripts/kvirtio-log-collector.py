#!/usr/bin/env python3
# =============================================================================
# Script:      kvirtio-log-collector.py
# Descrizione: Raccoglie i log KvirtIO dal journal systemd e li scrive in un
#              file JSON rotante leggibile dalla UI. Mantiene solo le ultime
#              24 ore di eventi. Eseguito ogni 5 minuti via systemd timer.
# Autore:      Kevin Tafuro
# Progetto:    KvirtIO Virtualization
# =============================================================================


##### TODO CHECK PATH 



import json
import os
import re
import subprocess
import syslog
from datetime import datetime, timezone, timedelta
from time import sleep

# ---- Costanti ----------------------------------------------------------------
OUTPUT_DIR  = "/var/log/kvirtio/logs"
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "kvirtio-events.json")
LOG_TAG     = "KvirtIO-LogCollector"

SYSLOG_TAGS = [
    "KvirtIO-Host",
    "KvirtIO-IO",
    "KvirtIO-Cluster",
    "KvirtIO-Multipath",
    "KvirtIO-VM",
    "KvirtIO-Network",
    "KvirtIO-HTMLGen",
    "KvirtIO-LogCollector",
]

SINCE_MINUTES  = 30   # finestra di lettura dal journal
RETAIN_HOURS   = 24   # finestra di retention nel file JSON
MAX_EVENTS     = 5000 # cap assoluto per evitare file enormi

# Ordine di matching per derivazione del livello dal testo del messaggio
LEVEL_PATTERNS = [
    (re.compile(r'\bCRITICAL\b', re.IGNORECASE), "CRITICAL"),
    (re.compile(r'\bERROR\b',    re.IGNORECASE), "ERROR"),
    (re.compile(r'\bWARNING\b',  re.IGNORECASE), "WARNING"),
    (re.compile(r'\bSUCCESS\b',  re.IGNORECASE), "SUCCESS"),
    (re.compile(r'\bINFO\b',     re.IGNORECASE), "INFO"),
]

# ---- Logging -----------------------------------------------------------------
def _slog(priority: int, message: str) -> None:
    """Wrapper per syslog."""
    syslog.openlog(LOG_TAG, syslog.LOG_PID, syslog.LOG_DAEMON)
    syslog.syslog(priority, message)
    syslog.closelog()

def log_info(msg: str)    -> None: _slog(syslog.LOG_INFO,    f"INFO: {msg}")
def log_warning(msg: str) -> None: _slog(syslog.LOG_WARNING, f"WARNING: {msg}")
def log_error(msg: str)   -> None: _slog(syslog.LOG_ERR,     f"ERROR: {msg}")


# ---- Funzioni ----------------------------------------------------------------

def derive_level(message: str) -> str:
    """Deriva il livello dell'evento dal testo del messaggio."""
    for pattern, level in LEVEL_PATTERNS:
        if pattern.search(message):
            return level
    return "INFO"


def parse_journal_timestamp(realtime_usec: str) -> str:
    """
    Converte __REALTIME_TIMESTAMP (microsecondi epoch) in stringa ISO 8601 UTC.
    """
    try:
        ts_sec = int(realtime_usec) / 1_000_000
        dt = datetime.fromtimestamp(ts_sec, tz=timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%S")
    except (ValueError, TypeError):
        return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def collect_journal_events() -> list[dict]:
    """
    Interroga journalctl per i tag KvirtIO degli ultimi SINCE_MINUTES minuti.
    Restituisce una lista di dict con campi: timestamp, source, level, message.
    """
    tag_args = []
    for tag in SYSLOG_TAGS:
        tag_args += ["-t", tag]

    cmd = [
        "journalctl",
        *tag_args,
        "--since", f"{SINCE_MINUTES} minutes ago",
        "--output", "json",
        "--no-pager",
        "--quiet",
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        log_error("journalctl ha superato il timeout di 30s.")
        return []
    except FileNotFoundError:
        log_error("journalctl non trovato. Impossibile raccogliere log.")
        return []

    events = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        raw_ts  = entry.get("__REALTIME_TIMESTAMP", "")
        source  = entry.get("SYSLOG_IDENTIFIER", "KvirtIO-Unknown")
        message = entry.get("MESSAGE", "")

        # Normalizza message (può essere lista di int in alcune versioni di journal)
        if isinstance(message, list):
            try:
                message = bytes(message).decode("utf-8", errors="replace")
            except Exception:
                message = str(message)

        timestamp = parse_journal_timestamp(raw_ts)
        level     = derive_level(message)

        events.append({
            "timestamp": timestamp,
            "source":    source,
            "level":     level,
            "message":   message,
        })

    return events


def load_existing_events() -> list[dict]:
    """
    Carica gli eventi esistenti dal file JSON. Gestisce assenza o corruzione.
    """
    if not os.path.isfile(OUTPUT_FILE):
        return []
    try:
        with open(OUTPUT_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data.get("events", [])
    except (json.JSONDecodeError, KeyError, OSError) as exc:
        log_warning(f"File eventi esistente non leggibile ({exc}). Sarà ricreato.")
        return []


def filter_events_by_retention(events: list[dict]) -> list[dict]:
    """
    Mantiene solo gli eventi delle ultime RETAIN_HOURS ore.
    """
    cutoff = datetime.now(tz=timezone.utc) - timedelta(hours=RETAIN_HOURS)
    cutoff_str = cutoff.strftime("%Y-%m-%dT%H:%M:%S")

    retained = []
    for ev in events:
        ts = ev.get("timestamp", "")
        try:
            # Confronto lessicografico funziona per ISO 8601 UTC
            if ts >= cutoff_str:
                retained.append(ev)
        except Exception:
            retained.append(ev)
    return retained


def deduplicate_events(existing: list[dict], new_events: list[dict]) -> list[dict]:
    """
    Unisce eventi nuovi con quelli esistenti, evitando duplicati esatti.
    Ordina per timestamp decrescente (più recenti in cima).
    """
    existing_set = {
        (ev["timestamp"], ev["source"], ev["message"])
        for ev in existing
    }

    for ev in new_events:
        key = (ev["timestamp"], ev["source"], ev["message"])
        if key not in existing_set:
            existing.append(ev)
            existing_set.add(key)

    # Ordine decrescente (più recente prima)
    existing.sort(key=lambda e: e.get("timestamp", ""), reverse=True)

    # Cap assoluto
    return existing[:MAX_EVENTS]


def ensure_output_dir() -> bool:
    """Crea la directory di output se non esiste."""
    try:
        os.makedirs(OUTPUT_DIR, mode=0o755, exist_ok=True)
        return True
    except OSError as exc:
        log_error(f"Impossibile creare directory {OUTPUT_DIR}: {exc}")
        return False


def write_output(events: list[dict]) -> bool:
    """Scrive il file JSON di output."""
    generated_at = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    payload = {
        "generated_at": generated_at,
        "event_count":  len(events),
        "events":       events,
    }
    tmp_file = OUTPUT_FILE + ".tmp"
    try:
        with open(tmp_file, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        os.replace(tmp_file, OUTPUT_FILE)
        # Permessi leggibili da www-data (gruppo)
        os.chmod(OUTPUT_FILE, 0o644)
        return True
    except OSError as exc:
        log_error(f"Impossibile scrivere {OUTPUT_FILE}: {exc}")
        try:
            os.unlink(tmp_file)
        except OSError:
            pass
        return False


def main() -> None:
    log_info("Avvio raccolta log.")

    while 1:
        if not ensure_output_dir():
            return

        # Raccolta nuovi eventi dal journal
        new_events = collect_journal_events()
        log_info(f"Raccolti {len(new_events)} nuovi eventi dal journal.")

        # Carica eventi esistenti
        existing_events = load_existing_events()

        # Retention: rimuovi eventi troppo vecchi
        existing_events = filter_events_by_retention(existing_events)

        # Merge e deduplicazione
        all_events = deduplicate_events(existing_events, new_events)

        # Scrittura output
        if write_output(all_events):
            log_info(
                f"File eventi aggiornato: {len(all_events)} eventi totali "
                f"in {OUTPUT_FILE}."
            )
        else:
            log_error("Scrittura file eventi fallita.")
        time.sleep(5000) #harcodato 5 secondi di sleep prima di ricominciare il cliclo di lettura log


if __name__ == "__main__":
    main()