# KvirtIO: Enterprise Virtualization Platform

**KvirtIO** is an enterprise, Service Provider-class virtualization architecture designed for high I/O density and High Availability (HA) scenarios. It is based entirely on native and open-source technologies running on **SUSE Linux Enterprise Server (SLES)**. We do not intend **KvirtIO** to be a native hypervisor, but rather, as previously mentioned, an architecture composed of open-source solutions.

This project is not intended to be associated to virtIO library
---

## 🚀 Project Goals
* **Deterministic Performance**: Total exclusion of host swap and optimization of RAM allocation (Hugepages) and CPU (NUMA pinning).
* **I/O Optimized for Databases ("IOIntensive")**: Parallelization of kernel SCSI queues (`lun_queue_depth`) through Multi-LUN Striped strategies and `blk-mq` architecture.
* **High Availability and Multilevel Fencing**: Tight integration among Pacemaker, Corosync, Cluster LVM (`lvmlockd` + `dlm`), and physical STONITH mechanisms (`fence_idrac`) as well as storage-based ones (`sbd` on Witness LUN with hardware watchdog).
* **Control Plane Decoupling**: Isolation of monitoring, telemetry, and load balancing logic outside the production KVM cluster.

---

## 📂 Repository Structure

### 1. Architecture and Design Documents
* 📄 **[KvirtIO High-Level Design (HLD)](KvirtIO_HLD.md)**: The high-level architecture document.

### 2. Monitoring & Watcher (External Control Plane)
These scripts reside on the external management server and query the KVM nodes via SSH using the `kvirtwatch` user.
* 📜 **[kvirtio-host-watcher.sh](scripts/kvirtio-host-watcher.sh)**: CPU/RAM load monitoring script with `crm_attribute` integration.
* 📜 **[kvirtio-io-watcher.sh](scripts/kvirtio-io-watcher.sh)**: Script for analyzing `await` latency on multipath disks.
* 📜 **[kvirtio-vm-migrate.sh](scripts/kvirtio-vm-migrate.sh)**: Script for executing a hot Live Migration of a VM from a source node to a destination node.
* 📜 **[kvirtio-vm-create.sh](scripts/kvirtio-vm-create.sh)**: Script for creating a VM from the management cluster.
* 📜 **[kvirtio-html-generator.py](scripts/kvirtio-html-generator.py)**: Script for infrastructure monitoring via a web page.

### 3. Systemd Configurations (Timers)
* ⚙️ **[kvirtio-host-watcher.service](systemd/kvirtio-host-watcher.service)** / **[Timer](systemd/kvirtio-host-watcher.timer)** (Execution every 5 minutes).
* ⚙️ **[kvirtio-io-watcher.service](systemd/kvirtio-io-watcher.service)** / **[Timer](systemd/kvirtio-io-watcher.timer)** (Execution every minute).
* ⚙️ **[kvirtio-html-generator.service](systemd/kvirtio-html-generator.service)** / **[Timer](systemd/kvirtio-html-generator.timer)** (Execution every 5 minutes).

### 4. Security Configuration (Compute Nodes)
* 🛡️ **[kvirtwatch (Sudoers)](sudoers/kvirtwatch)**: Minimum required sudo privileges to be configured on KVM nodes for `crm_attribute` and `iostat`.

### 5. Guides and Operational Instructions
* 📘 **[Watcher Deployment Guide](docs/deployment.md)**: Step-by-step instructions for installing SSH, scripts, timers, and sudo permissions.
* 📘 **[Host Watcher Service Detail](docs/kvirtio-host-watcher-service.md)**: Analysis of the CPU/RAM calculation algorithm and state transitions.
* 📘 **[I/O Watcher Service Detail](docs/kvirtio-io-watcher-service.md)**: Analysis of the `await` metrics extracted via `iostat`.
* 📘 **[HTML Generator Service Detail](docs/kvirtio-html-generator-service.md)**: Infrastructure status monitoring page.
* 📘 **[Alerter Detail](docs/kvirtio-mail-alerter.md)**: Detail of the email alerting system.