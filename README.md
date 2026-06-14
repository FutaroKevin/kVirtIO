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

### 2. Monitoring, Watchers & Management (External Control Plane)
These scripts reside on the external management server and query the KVM nodes via SSH using the `kvirtwatch` user.
* 📜 **[kvirtio-cluster-watcher.sh](scripts/kvirtio-cluster-watcher.sh)**: Pacemaker/Corosync cluster and fencing status watcher.
* 📜 **[kvirtio-console-tracker.sh](scripts/kvirtio-console-tracker.sh)**: Daemon aligning Websockify VNC token maps with active VM targets.
* 📜 **[kvirtio-host-watcher.sh](scripts/kvirtio-host-watcher.sh)**: CPU/RAM load monitoring script with `crm_attribute` integration.
* 📜 **[kvirtio-html-generator.py](scripts/kvirtio-html-generator.py)**: Python engine compiling telemetry into the HTML dashboard.
* 📜 **[kvirtio-io-watcher.sh](scripts/kvirtio-io-watcher.sh)**: Script analyzing Fibre Channel multipath I/O `await` latency.
* 📜 **[kvirtio-json-indexer.sh](scripts/kvirtio-json-indexer.sh)**: Helper compiling JSON state files catalog for dashboard consumption.
* 📜 **[kvirtio-log-collector.py](scripts/kvirtio-log-collector.py)**: Centralizes and filters KvirtIO systemd journal logs into structured JSON.
* 📜 **[kvirtio-mail-alerter.py](scripts/kvirtio-mail-alerter.py)**: Python SMTP alerter sending asynchronous notifications.
* 📜 **[kvirtio-multipath-watcher.sh](scripts/kvirtio-multipath-watcher.sh)**: Watcher monitoring health of active FC multipath paths per node.
* 📜 **[kvirtio-network-watcher.sh](scripts/kvirtio-network-watcher.sh)**: Watcher monitoring bond slaves health and RX/TX network bandwidth.
* 📜 **[kvirtio-setup-rsyslog-generator.sh](scripts/kvirtio-setup-rsyslog-generator.sh)**: Dynamic Rsyslog receiver rule compiler mapping nodes to clusters.
* 📜 **[kvirtio-vm-create.sh](scripts/kvirtio-vm-create.sh)**: VM deployment engine applying tuned hardware profiles (e.g., `iointensive`).
* 📜 **[kvirtio-vm-migrate.sh](scripts/kvirtio-vm-migrate.sh)**: VM live peer-to-peer migration orchestrator.
* 📜 **[kvirtio-vm-watcher.sh](scripts/kvirtio-vm-watcher.sh)**: Watcher correlating running VMs Libvirt states with Pacemaker HA resource statuses.

### 3. Systemd Configurations (Services & Timers)
* ⚙️ **[kvirtio-cluster-watcher.service](systemd/kvirtio-cluster-watcher.service)** / **[Timer](systemd/kvirtio-cluster-watcher.timer)**: Run cluster watcher every 60 seconds.
* ⚙️ **[kvirtio-console-tracker.service](systemd/kvirtio-console-tracker.service)**: Run VNC console tracker daemon.
* ⚙️ **[kvirtio-host-watcher.service](systemd/kvirtio-host-watcher.service)** / **[Timer](systemd/kvirtio-host-watcher.timer)**: Run host resource watcher every 5 minutes.
* ⚙️ **[kvirtio-html-generator.service](systemd/kvirtio-html-generator.service)** / **[Timer](systemd/kvirtio-html-generator.timer)**: Run HTML dashboard builder every 5 minutes.
* ⚙️ **[kvirtio-io-watcher.service](systemd/kvirtio-io-watcher.service)** / **[Timer](systemd/kvirtio-io-watcher.timer)**: Run I/O latency watcher every minute.
* ⚙️ **[kvirtio-log-collector.service](systemd/kvirtio-log-collector.service)**: Run centralized log aggregator daemon.
* ⚙️ **[kvirtio-multipath-watcher.service](systemd/kvirtio-multipath-watcher.service)** / **[Timer](systemd/kvirtio-multipath-watcher.timer)**: Run multipath path watcher every 2 minutes.
* ⚙️ **[kvirtio-vm-watcher.service](systemd/kvirtio-vm-watcher.service)** / **[Timer](systemd/kvirtio-vm-watcher.timer)**: Run VM HA status watcher every 2 minutes.

### 4. Security & Configuration Templates
* 🛡️ **[kvirtwatch (Sudoers)](sudoers/kvirtwatch)**: Least-privilege sudo configuration template for hypervisor nodes.
* ⚙️ **[mail.conf](etc/kvirtio/mail.conf)**: Global SMTP notifier configurations file template.
* ⚙️ **[cluster_db.conf](etc/kvirtio/clusters/cluster_db.conf)**: Database cluster specific configurations example.
* ⚙️ **[cluster_web.conf](etc/kvirtio/clusters/cluster_web.conf)**: Web/General cluster specific configurations example.

### 5. Guides and Operational Instructions
* 📘 **[Watcher Deployment Guide](docs/deployment.md)**: Main step-by-step deployment guide.
* 📘 **[Configuration Guide](docs/kvirtio-configuration-guide.md)**: Detailed configuration templates and security policy details.
* 📘 **[Cluster Watcher Service Detail](docs/kvirtio-cluster-watcher-service.md)**: Pacemaker and Corosync cluster monitoring algorithms.
* 📘 **[Host Watcher Service Detail](docs/kvirtio-host-watcher-service.md)**: CPU/RAM calculation algorithm and state transitions.
* 📘 **[I/O Watcher Service Detail](docs/kvirtio-io-watcher-service.md)**: FC disk I/O metrics parsing using `iostat`.
* 📘 **[Multipath Watcher Service Detail](docs/kvirtio-multipath-watcher-service.md)**: FC multipath degradation and failover paths monitoring.
* 📘 **[Network Watcher Service Detail](docs/kvirtio-network-watcher-service.md)**: Bond interfaces status and throughput monitor.
* 📘 **[VM Watcher Service Detail](docs/kvirtio-vm-watcher-service.md)**: HA VirtualDomain resources and Libvirt domain correlation.
* 📘 **[HTML Generator Service Detail](docs/kvirtio-html-generator-service.md)**: Dashboard building details and Apache configuration.
* 📘 **[Log Collector Service Detail](docs/kvirtio-log-collector-service.md)**: Central syslog/journalctl event collector details.
* 📘 **[Console Tracker Service Detail](docs/kvirtio-console-tracker-service.md)**: noVNC proxy token sync details.
* 📘 **[JSON Indexer Script Detail](docs/kvirtio-json-indexer.md)**: Dynamic state catalog generator.
* 📘 **[Rsyslog Generator Script Detail](docs/kvirtio-setup-rsyslog-generator.md)**: Remote rsyslog rules generator.
* 📘 **[VM Create Script Detail](docs/kvirtio-vm-create.md)**: Parameterized VM creation engine.
* 📘 **[VM Migrate Script Detail](docs/kvirtio-vm-migrate.md)**: Virtual machine live migration operations.
* 📘 **[VM XML Templates Guide](docs/kvirtio-vm-xml-templates.md)**: Optimized Libvirt XML templates for DB, App, and Domain Controller workloads.
* 📘 **[Alerter Detail](docs/kvirtio-mail-alerter.md)**: SMTP alert notifier mechanism details.

### Example monitoring UI
![image info](ui-sample.png)