# KvirtIO: Security Architecture & Hardening Design
**Reference Document for the Security of the Virtualization Platform**

---

## 1. Security Principles

The **KvirtIO** architecture handles mission-critical workloads in multi-tenant environments. As a result, the security model does not rely on perimeter protection alone, but adopts a **Zero-Trust** and **Defense-in-Depth** approach.

Every component (Host, Hypervisor, Network, Storage) assumes that the other layers may be compromised and implements autonomous protections to contain threats and prevent lateral movement (VM Escape and Lateral Movement).

The pillars of KvirtIO security are:
* **Plane Segregation:** Management, Cluster Heartbeat, Live Migration, and Tenant traffic are physically or logically isolated, with no possibility of inter-VLAN routing at the hypervisor level.
* **Least Privilege:** Daemons operate with the minimum permissions strictly required. Administrative access to nodes is tightly controlled and monitored.
* **Logical Immutability:** Host nodes do not run third-party software (e.g., in-guest backup agents), reducing the attack surface to the certified SLES virtualization stack only.

---

## 2. Security Requirements Matrix (Security Reference)

The following table defines the mandatory architectural baseline for any KvirtIO node or cluster. It does not represent an optional configuration, but a non-negotiable project standard.

| Area | Requirement / Status | Description |
| :--- | :--- | :--- |
| **Root Login** | `Disabled` | Direct `root` access via SSH disabled. Exclusive use of administrative accounts with audited `sudo`. |
| **SSH Password** | `Disabled` | Authentication permitted only via cryptographic keys (Pubkey). |
| **SELinux / AppArmor** | `Enabled` | Mandatory Access Control (MAC) active in *Enforcing* mode to isolate QEMU processes. |
| **Secure Boot** | `Enabled` | Cryptographic validation of the host boot chain to prevent rootkit injection. |
| **TPM 2.0** | `Recommended` | Used for hardware attestation and integrity measurement of the physical node. |
| **TLS Libvirt API** | `Mandatory` | Orchestrator-to-`libvirt` API communications occur exclusively over channels encrypted with X.509 certificates. |
| **FC SAN Zoning** | `Mandatory` | Single-Initiator / Single-Target zoning to visually isolate LUNs at the fabric level. |
| **Auditd** | `Mandatory` | Logging of all critical syscalls, file system changes, and administrative sessions. |

---

## 3. Host Hardening (SLES OS Level)

The host operating system (SUSE Linux Enterprise Server) is treated as a closed appliance rather than a general-purpose Linux server.

* **Attack Surface Reduction:** All daemons not strictly necessary (e.g., web servers, local databases, obsolete monitoring agents) are uninstalled.
* **SSH Hardening:** The `sshd` service is configured to reject password authentication and `root` login. In addition, via the `AllowUsers` directive, SSH access is permitted only from the Management network subnet.
* **Kernel & Sysctl:** The kernel is hardened against network attacks (MitM, IP Spoofing, TCP SYN Flood) and protected from unauthorized runtime parameter changes.
* **Boot Chain:** The use of UEFI Secure Boot ensures that the SLES kernel and loaded modules (such as `kvm` and `multipath`) are cryptographically signed by the vendor, preventing the persistence of low-level threats (Bootkit).

---

## 4. Hypervisor Security (KVM / QEMU / Libvirt)

The virtualization layer is the first line of defense against a compromised virtual machine.

* **sVirt and AppArmor (Process Isolation):** KvirtIO makes extensive use of **sVirt**. Every time a VM is started, Libvirt dynamically generates a unique AppArmor profile. This ensures that the QEMU process of `VM_A` cannot physically read or write to the RAM or disk files of `VM_B`, nipping "VM Escape" vulnerabilities in the bud.
* **Privilege Dropping:** QEMU processes are de-privileged immediately after the allocation of basic resources (RAM/TAP) and run under the restricted `qemu` or `libvirt-qemu` user, not as `root`.
* **Libvirt API Protection:** The `libvirtd` daemon does not expose plaintext TCP sockets. All remote orchestration by the KvirtIO Watcher/Management server takes place on port **16509 (TLS)**, with mutual authentication via X.509 certificates.

---

## 5. Virtual Machine Security (VM Security)

The Hypervisor must actively protect itself from traffic generated internally by tenant virtual machines.

* **Network Filter (Libvirt NWFilter):** All virtual interfaces (vNICs) apply the `clean-traffic` filter. This prevents the VM from performing:
  * **MAC Spoofing:** Altering the source MAC address.
  * **IP Spoofing:** Sending packets with an IP different from the one assigned.
  * **ARP/ND Poisoning:** Attempts to divert traffic from other VMs on the same layer 2.
* **L2 Host Isolation:** The host's Linux bridges (`br-vlanX`) used for tenant networks are stripped of IP addressing (`arp_ignore`, `disable_ipv6`). An `ebtables` policy is also applied that drops any layer 2 packet explicitly destined for the host's physical MAC address, making the hypervisor invisible and unattackable from the guest network.
* **VNC Console Hardening:** VNC ports (5900+) are exposed *exclusively* on the management network IP (or on `localhost` + tunnel) and filtered via `firewalld`. Tenant access occurs solely through the WebSocket proxy with dynamic token authentication.

---

## 6. Storage Security (SAN & FC Security)

In an architecture leveraging Clustered LVM (`lvmlockd`) and 32Gb Fibre Channel, the security of the storage fabric is essential to avoid cross-cluster corruption or data exfiltration.

* **Strict FC Zoning:** The Fibre Channel SAN must be configured according to the **Single-Initiator / Single-Target Zoning** principle. A KVM node in Cluster A has no fabric-level visibility (LUN Masking) into the disks of Cluster B.
* **Witness LUN (SBD) Hardening:** The 100MB LUN used for Storage-Based Death (Fencing) is a critical component. An attack on this LUN could shut down the entire cluster. For this reason, the Witness LUN must be presented **exclusively** to the WWPNs (World Wide Port Names) of the authorized cluster nodes. No other server or system in the infrastructure must be able to interact with or write to the mailboxes of this LUN.
* **LVM Lock Isolation:** Lock management (`dlm`) travels exclusively over the isolated VLAN dedicated to Corosync (VLAN 11), protecting LVM metadata transactions from interception or injection.

---

## 7. Cluster Security (Pacemaker & Corosync)

The "brain" of High Availability must be immune to replay or manipulation attacks.

* **Corosync Authkey:** Heartbeat and state exchange communications between nodes are signed and encrypted using a shared cryptographic key (Authkey based on AES-256 and HMAC-SHA256). This prevents unauthorized "shadow nodes" from being added to the cluster to hijack resource management.
* **Cluster Network Isolation:** Corosync traffic is confined to a dedicated VLAN (e.g., VLAN 11) with no gateway (non-routable), inaccessible from any other corporate or tenant network.
* **Strict Out-of-Band Fencing:** STONITH commands (e.g., `fence_idrac`) are sent over a network dedicated to hardware management, physically or logically isolated from the rest of the data network infrastructure.

---

## 8. Logging, Auditing and Traceability

The absence of visibility equals the absence of security. The KvirtIO logging framework ensures the chain of custody and the impossibility of post-compromise alteration.

* **Mandatory Auditd:** The `auditd` daemon logs all sensitive system calls, configuration file changes (`/etc/libvirt`, `/etc/corosync`), shell access, and execution of privileged commands via `sudo` by the `kvirtwatch` user or administrators.
* **Remote Immutability (Forwarding):** All system logs (Pacemaker, KVM, Libvirt, Auditd, Auth) do not reside exclusively on the host. They are immediately sent via syslog (with rsyslog routing rules) to the external Management Server. If a host node is compromised, the attacker cannot erase their tracks on the central log server.
* **Logrotate & Retention:** Centralized logs are subject to strict rotation and compression policies (`logrotate`), ensuring long-term archiving for forensic analysis purposes and compliance with regulations (e.g., ISO 27001, GDPR).