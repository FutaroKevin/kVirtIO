# Notification System Documentation: KvirtIO Mail Alerter

The **KvirtIO Mail Alerter** notification system allows for asynchronous sending of email alerts when hardware thresholds are exceeded or issues arise on Fibre Channel disks of hypervisor nodes.

---

## 📋 Functional Description
The system is based on a native Python script (`kvirtio-mail-alerter.py`) located on the management server and integrated with cluster watchers (`kvirtio-host-watcher.sh` and `kvirtio-io-watcher.sh`).

Whenever a critical state transition occurs (e.g., host overloaded for 3 consecutive checks or disk latency exceeding 10ms), the script is invoked in the background (`&`) to prevent blocking the watcher's main monitoring loop in case of SMTP server communication delays.

---

## ⚙️ SMTP Configuration (/etc/kvirtio/mail.conf)
SMTP configuration resides in a shell-like file located at `/etc/kvirtio/mail.conf` with the following structure:

```ini
# SMTP Server and Port
SMTP_SERVER=smtp.example.com
SMTP_PORT=587

# Enable STARTTLS (True/False)
SMTP_STARTTLS=True

# Authentication Credentials (Leave blank if login is not required)
SMTP_USER=alerts@kvirtio.local
SMTP_PASSWORD=secretpassword

# Sender and Recipient Addresses
SMTP_FROM=alerts@kvirtio.local
SMTP_TO=sysadmins@example.com
```

### Configuration Parameters:
*   `SMTP_SERVER`: Hostname or IP of the corporate SMTP server.
*   `SMTP_PORT`: Port of the SMTP service (typically `25` or `587` for standard/STARTTLS connections, `465` for direct SSL).
*   `SMTP_STARTTLS`: If set to `True` or `Yes`, the script upgrades the connection to encrypted TLS before authenticating.
*   `SMTP_USER` / `SMTP_PASSWORD`: Credentials used for SMTP authentication. If omitted or left empty, the script will attempt anonymous sending (authorized open-relay).
*   `SMTP_FROM`: The sender address visible in the sent emails.
*   `SMTP_TO`: The mailbox or mailing list of the system administrators designated to receive the alerts.

---

## 🛠️ Script Usage

The script supports two mandatory command-line arguments:
1.  `--subject`: The email subject line.
2.  `--body`: The email body text.

### Manual Invocation Example:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO Notification Test" \
    --body "This is a test message to validate the KvirtIO SMTP configuration."
```

### Automatic Invocation by Watcher Scripts:
When the state loader detects a problem, it calls the script asynchronously:
```bash
python3 /usr/local/bin/kvirtio-mail-alerter.py \
    --subject "KvirtIO ALERT: Host node1 OVERLOADED [cluster_db]" \
    --body "Node node1 in cluster cluster_db is in an overloaded state for 3 consecutive checks." &
```

---

## 🪵 Log Tracking (Syslog)
All email sending results are logged via the syslog daemon with the tag `KvirtIO-Mail`:

*   **Successful Send (Info)**:
    `SUCCESS: Email sent to sysadmins@example.com - Subject: 'KvirtIO ALERT: Host node1 OVERLOADED [cluster_db]'`
*   **Configuration Error (Error)**:
    `ERROR: SMTP_SERVER, SMTP_TO, or SMTP_FROM missing in configuration.`
*   **Network/Authentication Error (Error)**:
    `ERROR: Sending email to sysadmins@example.com failed: [Errno 111] Connection refused`
