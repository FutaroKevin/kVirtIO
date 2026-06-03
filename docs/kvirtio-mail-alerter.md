# Documentazione Sistema di Notifica: KvirtIO Mail Alerter

Il sistema di notifica **KvirtIO Mail Alerter** consente l'invio asincrono di allarmi e-mail in caso di superamento delle soglie hardware o di problemi sui dischi Fibre Channel dei nodi ipervisori.

---

## 📋 Descrizione Funzionale
Il sistema si basa su uno script Python nativo (`kvirtio-mail-alerter.py`) posizionato sul server di management ed integrato direttamente con i watcher di cluster (`kvirtio-host-watcher.sh` e `kvirtio-io-watcher.sh`). 

Ogni volta che si verifica una transizione di stato critica (es. host sovraccarico per 3 controlli consecutivi o latenza disco superiore a 10ms), lo script viene invocato in background (`&`) per evitare di bloccare il ciclo di monitoraggio principale del watcher in caso di ritardi nella comunicazione con il server SMTP.

---

## ⚙️ Configurazione SMTP (/etc/kvirtio/mail.conf)
La configurazione SMTP risiede in un file shell-like situato in `/etc/kvirtio/mail.conf` ed ha la seguente struttura:

```ini
# Server SMTP e Porta
SMTP_SERVER=smtp.example.com
SMTP_PORT=587

# Abilita STARTTLS (True/False)
SMTP_STARTTLS=True

# Credenziali di Autenticazione (Lasciare vuote se non richiesto login)
SMTP_USER=alerts@kvirtio.local
SMTP_PASSWORD=secretpassword

# Indirizzi Mittente e Destinatario
SMTP_FROM=alerts@kvirtio.local
SMTP_TO=sysadmins@example.com
```

### Parametri della Configurazione:
*   `SMTP_SERVER`: Hostname o IP del server SMTP aziendale.
*   `SMTP_PORT`: Porta del servizio SMTP (di solito `25` o `587` per connessioni standard/STARTTLS, `465` per SSL diretto).
*   `SMTP_STARTTLS`: Se impostato a `True` o `Yes`, lo script esegue l'upgrade della connessione in TLS cifrato prima dell'autenticazione.
*   `SMTP_USER` / `SMTP_PASSWORD`: Credenziali utilizzate per l'autenticazione SMTP. Se omesse o lasciate vuote, lo script tenterà un invio anonimo (open-relay autorizzato).
*   `SMTP_FROM`: L'indirizzo mittente visibile nelle email inviate.
*   `SMTP_TO`: La casella postale o la mailing-list degli amministratori di sistema incaricati di ricevere gli allarmi.

---

## 🛠️ Modalità di Utilizzo dello Script

Lo script supporta due argomenti obbligatori passati da riga di comando:
1.  `--subject`: L'oggetto dell'e-mail.
2.  `--body`: Il corpo del testo dell'e-mail.

### Esempio di Invocazione manuale:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "Test Notifica KvirtIO" \
    --body "Questo è un messaggio di test per convalidare la configurazione SMTP di KvirtIO."
```

### Invocazione Automatica dagli Script Watcher:
Quando il caricatore di stato rileva un problema, richiama lo script in modalità asincrona:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO ALERT: Host node1 OVERLOADED [cluster_db]" \
    --body "Il nodo node1 del cluster cluster_db e' in stato di sovraccarico da 3 controlli consecutivi." &
```

---

## 🪵 Tracciamento Log (Syslog)
Tutti gli esiti dell'invio e-mail vengono loggati tramite il demone syslog con il tag `KvirtIO-Mail`:

*   **Invio Riuscito (Info)**:
    `SUCCESS: Email inviata a sysadmins@example.com - Oggetto: 'KvirtIO ALERT: Host node1 OVERLOADED [cluster_db]'`
*   **Errore di Configurazione (Error)**:
    `ERROR: SMTP_SERVER, SMTP_TO o SMTP_FROM mancanti nella configurazione.`
*   **Errore di Rete/Autenticazione (Error)**:
    `ERROR: Invio email a sysadmins@example.com fallito: [Errno 111] Connection refused`
