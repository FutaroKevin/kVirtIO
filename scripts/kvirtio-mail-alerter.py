#!/usr/bin/env python3
# ==============================================================================
# Script: kvirtio-mail-alerter.py
# Descrizione: Utility Python per l'invio di notifiche e-mail per allarmi KvirtIO.
# Autore: KEvin Tafuro
# Progetto: KvirtIO Virtualization
# ==============================================================================

import os
import sys
import argparse
import smtplib
from email.message import EmailMessage
import syslog

# Configurazione predefinita
CONFIG_FILE = "/etc/kvirtio/mail.conf"

def log(msg, priority=syslog.LOG_INFO):
    """Scrive i log nel syslog di sistema."""
    syslog.openlog(ident="KvirtIO-Mail", logoption=syslog.LOG_PID, facility=syslog.LOG_USER)
    syslog.syslog(priority, msg)
    syslog.closelog()

def parse_config(filepath):
    """Analizza il file di configurazione shell-like per recuperare i parametri SMTP."""
    config = {}
    if not os.path.exists(filepath):
        log(f"ERROR: File di configurazione {filepath} non trovato.", syslog.LOG_ERR)
        return config
    
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            # Ignora righe vuote e commenti
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                config[key.strip()] = val.strip().strip('"').strip("'")
    return config

def main():
    parser = argparse.ArgumentParser(description="Invio notifiche email per il progetto KvirtIO")
    parser.add_argument("--subject", required=True, help="Oggetto dell'email")
    parser.add_argument("--body", required=True, help="Corpo del messaggio")
    args = parser.parse_args()

    # Legge la configurazione SMTP
    config = parse_config(CONFIG_FILE)
    if not config:
        log("ERROR: Configurazione SMTP assente o non valida. Allarme non inviato.", syslog.LOG_ERR)
        sys.exit(1)

    smtp_server = config.get("SMTP_SERVER")
    smtp_port = int(config.get("SMTP_PORT", 587))
    smtp_user = config.get("SMTP_USER")
    smtp_pass = config.get("SMTP_PASSWORD")
    smtp_from = config.get("SMTP_FROM")
    smtp_to = config.get("SMTP_TO")
    smtp_starttls = config.get("SMTP_STARTTLS", "True").lower() in ("true", "1", "yes")

    if not smtp_server or not smtp_to or not smtp_from:
        log("ERROR: SMTP_SERVER, SMTP_TO o SMTP_FROM mancanti nella configurazione.", syslog.LOG_ERR)
        sys.exit(1)

    # Crea il messaggio e-mail
    msg = EmailMessage()
    msg.set_content(args.body)
    msg["Subject"] = args.subject
    msg["From"] = smtp_from
    msg["To"] = smtp_to

    try:
        # Stabilisce la connessione SMTP
        if smtp_port == 465:
            server = smtplib.SMTP_SSL(smtp_server, smtp_port, timeout=10)
        else:
            server = smtplib.SMTP(smtp_server, smtp_port, timeout=10)
            if smtp_starttls:
                server.starttls()
        
        # Effettua l'autenticazione se configurata
        if smtp_user and smtp_pass:
            server.login(smtp_user, smtp_pass)
        
        # Invia il messaggio
        server.send_message(msg)
        server.quit()
        log(f"SUCCESS: Email inviata a {smtp_to} - Oggetto: '{args.subject}'")
    except Exception as e:
        log(f"ERROR: Invio email a {smtp_to} fallito: {str(e)}", syslog.LOG_ERR)
        sys.exit(1)

if __name__ == "__main__":
    main()
