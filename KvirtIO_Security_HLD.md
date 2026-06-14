# KvirtIO: Security Architecture & Hardening Design
**Documento di Riferimento per la Sicurezza della Piattaforma di Virtualizzazione**

---

## 1. Principi di Sicurezza (Security Principles)

L'architettura **KvirtIO** gestisce carichi di lavoro mission-critical in ambienti multi-tenant. Di conseguenza, il modello di sicurezza non si affida alla sola protezione perimetrale, ma adotta un approccio **Zero-Trust** e **Defense-in-Depth**. 

Ogni componente (Host, Hypervisor, Network, Storage) assume che gli altri livelli possano essere compromessi e implementa protezioni autonome per confinare le minacce e prevenire i movimenti laterali (VM Escape e Lateral Movement). 

I pilastri della sicurezza KvirtIO sono:
* **Separazione dei Piani (Plane Segregation):** Management, Cluster Heartbeat, Live Migration e traffico Tenant sono fisicamente o logicamente isolati, senza possibilità di routing inter-VLAN a livello di hypervisor.
* **Privilegio Minimo (Least Privilege):** I demoni operano con i permessi minimi indispensabili. L'accesso amministrativo ai nodi è rigidamente controllato e monitorato.
* **Immutabilità Logica:** I nodi host non eseguono software di terze parti (es. agenti di backup in-guest), riducendo la superficie di attacco al solo stack di virtualizzazione SLES certificato.

---

## 2. Matrice dei Requisiti di Sicurezza (Security Reference)

La seguente tabella definisce la baseline architetturale obbligatoria per qualsiasi nodo o cluster KvirtIO. Non rappresenta una configurazione opzionale, ma uno standard inderogabile di progetto.

| Area | Requisito / Stato | Descrizione |
| :--- | :--- | :--- |
| **Root Login** | `Disabled` | Accesso diretto `root` via SSH disabilitato. Utilizzo esclusivo di utenze amministrative con `sudo` tracciato. |
| **SSH Password** | `Disabled` | Autenticazione consentita unicamente tramite chiavi crittografiche (Pubkey). |
| **SELinux / AppArmor** | `Enabled` | Mandatory Access Control (MAC) attivo in modalità *Enforcing* per isolare i processi QEMU. |
| **Secure Boot** | `Enabled` | Validazione crittografica della catena di boot dell'host per prevenire l'iniezione di rootkit. |
| **TPM 2.0** | `Recommended` | Utilizzato per l'attestazione hardware e la misurazione dell'integrità del nodo fisico. |
| **TLS Libvirt API** | `Mandatory` | Le comunicazioni dell'orchestratore verso le API di `libvirt` avvengono esclusivamente su canali cifrati con certificati X.509. |
| **FC SAN Zoning** | `Mandatory` | Single-Initiator / Single-Target zoning per isolare visivamente le LUN a livello di fabric. |
| **Auditd** | `Mandatory` | Registrazione di tutte le syscall critiche, variazioni di file system e sessioni amministrative. |

---

## 3. Host Hardening (SLES OS Level)

Il sistema operativo dell'host (SUSE Linux Enterprise Server) viene trattato come un'appliance chiusa e non come un server Linux general-purpose.

* **Riduzione della Superficie d'Attacco:** Vengono disinstallati tutti i demoni non strettamente necessari (es. server web, database locali, agenti di monitoraggio obsoleti). 
* **Hardening SSH:** Il servizio `sshd` è configurato per rifiutare l'autenticazione tramite password e il login di `root`. Inoltre, tramite la direttiva `AllowUsers`, l'accesso SSH è consentito unicamente dalla subnet della rete di Management.
* **Kernel & Sysctl:** Il kernel viene "indurito" contro attacchi di rete (MitM, IP Spoofing, TCP SYN Flood) e protetto dalla modifica di parametri a runtime non autorizzati.
* **Boot Chain:** L'utilizzo di UEFI Secure Boot garantisce che il kernel SLES e i moduli caricati (come `kvm` e `multipath`) siano crittograficamente firmati dal vendor, impedendo la persistenza di minacce a basso livello (Bootkit).

---

## 4. Hypervisor Security (KVM / QEMU / Libvirt)

Il livello di virtualizzazione è la prima linea di difesa contro una macchina virtuale compromessa. 

* **sVirt e AppArmor (Isolamento Processi):** KvirtIO fa un uso estensivo di **sVirt**. Ogni volta che una VM viene avviata, Libvirt genera dinamicamente un profilo AppArmor univoco. Questo garantisce che il processo QEMU della `VM_A` non possa fisicamente leggere o scrivere nella RAM o nei file disco della `VM_B`, bloccando sul nascere le vulnerabilità di "VM Escape".
* **Drop dei Privilegi:** I processi QEMU vengono de-privilegiati immediatamente dopo l'allocazione delle risorse di base (RAM/TAP) e girano sotto l'utente limitato `qemu` o `libvirt-qemu`, e non come `root`.
* **Protezione delle API di Libvirt:** Il demone `libvirtd` non espone socket TCP in chiaro. Tutta l'orchestrazione remota da parte del server KvirtIO Watcher/Management avviene sulla porta **16509 (TLS)**, con mutua autenticazione tramite certificati X.509.

---

## 5. Sicurezza delle Macchine Virtuali (VM Security)

L'Hypervisor deve proteggersi attivamente dal traffico generato internamente dalle macchine virtuali dei tenant.

* **Network Filter (Libvirt NWFilter):** Tutte le interfacce virtuali (vNIC) applicano il filtro `clean-traffic`. Questo impedisce alla VM di effettuare:
  * **MAC Spoofing:** Alterazione dell'indirizzo MAC sorgente.
  * **IP Spoofing:** Invio di pacchetti con un IP diverso da quello assegnato.
  * **ARP/ND Poisoning:** Tentativi di deviare il traffico di altre VM sullo stesso layer 2.
* **L2 Host Isolation:** I bridge Linux dell'host (`br-vlanX`) utilizzati per le reti dei tenant vengono privati dell'indirizzamento IP (`arp_ignore`, `disable_ipv6`). Viene inoltre applicata una policy `ebtables` che scarta (DROP) qualsiasi pacchetto di livello 2 destinato esplicitamente al MAC address fisico dell'host, rendendo l'hypervisor invisibile e inattaccabile dalla rete guest.
* **Blindaggio Console VNC:** Le porte VNC (5900+) sono esposte *esclusivamente* sull'IP della rete di management (o in `localhost` + tunnel) e filtrate tramite `firewalld`. L'accesso dei tenant avviene unicamente tramite il proxy WebSocket con autenticazione a token dinamico.

---

## 6. Sicurezza dello Storage (SAN & FC Security)

In un'architettura che sfrutta LVM Clusterizzato (`lvmlockd`) e Fibre Channel a 32Gb, la sicurezza del fabric di storage è fondamentale per evitare corruzioni incrociate o esfiltrazione di dati.

* **Strict FC Zoning:** La SAN Fibre Channel deve essere configurata secondo il principio del **Single-Initiator / Single-Target Zoning**. Un nodo KVM del Cluster A non ha alcuna visibilità a livello di fabric LUN (LUN Masking) sui dischi del Cluster B.
* **Witness LUN (SBD) Hardening:** La LUN da 100MB utilizzata per lo Storage-Based Death (Fencing) è un componente critico. Un attacco a questa LUN potrebbe spegnere l'intero cluster. Per questo motivo, la Witness LUN deve essere presentata **esclusivamente** ai WWPN (World Wide Port Name) dei nodi del cluster autorizzato. Nessun altro server o sistema nell'infrastruttura deve poter interagire o scrivere nelle mailbox di questa LUN.
* **Isolamento Lock LVM:** La gestione dei lock (`dlm`) viaggia esclusivamente sulla VLAN isolata dedicata a Corosync (VLAN 11), proteggendo le transazioni di metadata di LVM da intercettazioni o iniezioni.

---

## 7. Cluster Security (Pacemaker & Corosync)

Il "cervello" dell'Alta Affidabilità deve essere immune da attacchi di replay o manipolazione.

* **Corosync Authkey:** Le comunicazioni di heartbeat e scambio di stato tra i nodi sono firmate e cifrate tramite una chiave crittografica condivisa (Authkey basata su AES-256 e HMAC-SHA256). Questo impedisce l'aggiunta di "nodi ombra" non autorizzati al cluster per deviare la gestione delle risorse.
* **Isolamento della Rete di Cluster:** Il traffico Corosync è relegato a una VLAN dedicata (es. VLAN 11) priva di gateway (non instradabile), inaccessibile da qualsiasi altra rete aziendale o di tenant.
* **Fencing Out-of-Band Rigido:** I comandi di STONITH (es. `fence_idrac`) vengono inviati su una rete dedicata al management hardware, isolata fisicamente o logicamente dal resto dell'infrastruttura di rete dati.

---

## 8. Logging, Auditing e Tracciabilità

L'assenza di visibilità equivale all'assenza di sicurezza. Il framework di log di KvirtIO assicura la catena di custodia e l'impossibilità di alterazione post-compromissione.

* **Auditd Obligatorio:** Il demone `auditd` traccia tutte le chiamate di sistema sensibili, la modifica ai file di configurazione (`/etc/libvirt`, `/etc/corosync`), gli accessi alle shell e l'esecuzione di comandi privilegiati tramite `sudo` da parte dell'utenza `kvirtwatch` o degli amministratori.
* **Immutabilità Remota (Forwarding):** Tutti i log di sistema (Pacemaker, KVM, Libvirt, Auditd, Auth) non risiedono esclusivamente sull'host. Vengono immediatamente inviati via syslog (con regole di instradamento rsyslog) al Management Server esterno. Se un nodo host viene compromesso, l'attaccante non può cancellare le proprie tracce sul server di centralizzazione dei log.
* **Logrotate & Retention:** I log centralizzati sono sottoposti a policy rigide di rotazione e compressione (`logrotate`), garantendo l'archiviazione a lungo termine per scopi di analisi forense e rispetto delle normative di compliance (es. ISO 27001, GDPR).