#!/usr/bin/env python3
# ==============================================================================
# Script: kvirtio-html-generator.py
# Descrizione: Raccoglie metriche da tutti i cluster KvirtIO e genera un
#              dashboard HTML moderno servito da Apache (/var/www/html/kvirtio/index.html).
# Autore: Kevin Tafuro
# Progetto: KvirtIO Virtualization
# ==============================================================================

import os
import sys
import subprocess
from datetime import datetime
import glob
import syslog

# Configurazioni
CONFIG_DIR = "/etc/kvirtio/clusters"
HTML_OUTPUT_DIR = "/var/www/html/kvirtio"
HTML_OUTPUT_FILE = os.path.join(HTML_OUTPUT_DIR, "index.html")

def log(msg, priority=syslog.LOG_INFO):
    syslog.openlog(ident="KvirtIO-HTMLGen", logoption=syslog.LOG_PID, facility=syslog.LOG_USER)
    syslog.syslog(priority, msg)
    syslog.closelog()

def parse_config(filepath):
    """Carica e parsa la configurazione di un cluster."""
    config = {
        "CLUSTER_NAME": "",
        "NODES": [],
        "SSH_USER": "kvirtwatch",
        "CPU_THRESHOLD": 85,
        "RAM_THRESHOLD": 90,
        "LATENCY_THRESHOLD": 10.0
    }
    
    if not os.path.exists(filepath):
        return None
        
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                if key == "CLUSTER_NAME":
                    config["CLUSTER_NAME"] = val
                elif key == "NODES":
                    # Converte la stringa dell'array bash in lista python
                    # Esempio: ("node1" "node2") -> ['node1', 'node2']
                    nodes_str = val.replace("(", "").replace(")", "")
                    config["NODES"] = [n.strip('"').strip("'") for n in nodes_str.split() if n]
                elif key == "SSH_USER":
                    config["SSH_USER"] = val
                elif key in ("CPU_THRESHOLD", "RAM_THRESHOLD"):
                    config[key] = int(val)
                elif key == "LATENCY_THRESHOLD":
                    config[key] = float(val)
    return config

def execute_remote_commands(node, user):
    """Esegue un blocco unico di comandi via SSH per raccogliere tutte le metriche."""
    ssh_opts = ["-o", "ConnectTimeout=4", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
    
    # Comandi aggregati in una sola connessione SSH per massimizzare la velocità
    remote_cmd = """
# CPU
read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
prev_idle=$((idle + iowait))
prev_non_idle=$((user + nice + system + irq + softirq + steal))
prev_total=$((prev_idle + prev_non_idle))
sleep 0.2
read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
idle=$((idle + iowait))
non_idle=$((user + nice + system + irq + softirq + steal))
total=$((idle + non_idle))
total_d=$((total - prev_total))
idle_d=$((idle - prev_idle))
cpu=$(( (total_d - idle_d) * 100 / (total_d > 0 ? total_d : 1) ))

# RAM
read -r _ mem_total _ < <(grep MemTotal /proc/meminfo)
read -r _ mem_avail _ < <(grep MemAvailable /proc/meminfo)
mem_used=$((mem_total - mem_avail))
ram=$((mem_used * 100 / mem_total))

echo "CPU:$cpu"
echo "RAM:$ram"

echo "===VGS==="
sudo /usr/sbin/vgs -o vg_name,vg_size,vg_free --units G --nosuffix --noheadings 2>/dev/null
echo "===LVS==="
sudo /usr/sbin/lvs -o lv_name,vg_name,lv_size --units G --nosuffix --noheadings 2>/dev/null
echo "===IOSTAT==="
sudo /usr/bin/iostat -dx 1 2 2>/dev/null
"""
    
    try:
        res = subprocess.run(
            ["ssh"] + ssh_opts + [f"{user}@{node}", remote_cmd],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10
        )
        if res.returncode == 0:
            return res.stdout
        else:
            return None
    except subprocess.TimeoutExpired:
        return None
    except Exception:
        return None

def parse_node_data(stdout):
    """Elabora le metriche testuali restituite dal nodo."""
    data = {
        "cpu": 0,
        "ram": 0,
        "vgs": [],
        "lvs": [],
        "await": 0.0
    }
    
    sections = {
        "main": True,
        "vgs": False,
        "lvs": False,
        "iostat": False
    }
    
    iostat_lines = []
    
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
            
        if line == "===VGS===":
            sections["main"] = False
            sections["vgs"] = True
            continue
        elif line == "===LVS===":
            sections["vgs"] = False
            sections["lvs"] = True
            continue
        elif line == "===IOSTAT===":
            sections["lvs"] = False
            sections["iostat"] = True
            continue
            
        if sections["main"]:
            if line.startswith("CPU:"):
                data["cpu"] = int(line.split(":")[1])
            elif line.startswith("RAM:"):
                data["ram"] = int(line.split(":")[1])
        
        elif sections["vgs"]:
            parts = line.split()
            if len(parts) >= 3:
                data["vgs"].append({
                    "name": parts[0],
                    "size": float(parts[1].replace(",", ".")),
                    "free": float(parts[2].replace(",", "."))
                })
        
        elif sections["lvs"]:
            parts = line.split()
            if len(parts) >= 3:
                data["lvs"].append({
                    "name": parts[0],
                    "vg": parts[1],
                    "size": float(parts[2].replace(",", "."))
                })
                
        elif sections["iostat"]:
            iostat_lines.append(line)
            
    # Parsing iostat
    if iostat_lines:
        report = 0
        await_cols = []
        max_await = 0.0
        for line in iostat_lines:
            if line.startswith("Device") or line.startswith("Device:"):
                report += 1
                await_cols = [idx for idx, col in enumerate(line.split()) if "await" in col]
                continue
            if report == 2 and line.startswith("dm-"):
                parts = line.split()
                for idx in await_cols:
                    if idx < len(parts):
                        try:
                            val = float(parts[idx].replace(",", "."))
                            if val > max_await:
                                max_await = val
                        except ValueError:
                            pass
        data["await"] = max_await
        
    return data

def generate_html(cluster_data):
    """Compila il dashboard HTML con stile dark-mode premium e moderno."""
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    html = """<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KvirtIO - Dashboard di Monitoraggio</title>
    <style>
        :root {
            --bg-color: #0b0f19;
            --card-bg: rgba(17, 24, 39, 0.7);
            --border-color: rgba(255, 255, 255, 0.08);
            --text-color: #e5e7eb;
            --text-muted: #9ca3af;
            --primary: #3b82f6;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
        }
        
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }
        
        body {
            background-color: var(--bg-color);
            color: var(--text-color);
            font-family: 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            padding: 20px;
            min-height: 100vh;
        }
        
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding-bottom: 20px;
            border-bottom: 1px solid var(--border-color);
            margin-bottom: 30px;
        }
        
        h1 {
            font-size: 1.8rem;
            font-weight: 600;
            background: linear-gradient(45deg, #3b82f6, #10b981);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        
        .timestamp {
            font-size: 0.9rem;
            color: var(--text-muted);
        }
        
        .cluster-section {
            margin-bottom: 40px;
        }
        
        .cluster-header {
            font-size: 1.4rem;
            font-weight: 500;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            gap: 10px;
            color: #3b82f6;
        }
        
        .cluster-badge {
            background-color: rgba(59, 130, 246, 0.15);
            border: 1px solid rgba(59, 130, 246, 0.3);
            color: #60a5fa;
            font-size: 0.8rem;
            padding: 2px 8px;
            border-radius: 12px;
        }
        
        .grid-hosts {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .card {
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 20px;
            backdrop-filter: blur(10px);
            transition: transform 0.2s, box-shadow 0.2s;
        }
        
        .card:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 20px rgba(0, 0, 0, 0.4);
        }
        
        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }
        
        .card-title {
            font-size: 1.1rem;
            font-weight: 600;
        }
        
        .status-dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            display: inline-block;
        }
        
        .status-online { background-color: var(--success); box-shadow: 0 0 8px var(--success); }
        .status-offline { background-color: var(--danger); box-shadow: 0 0 8px var(--danger); }
        .status-overloaded { background-color: var(--warning); box-shadow: 0 0 8px var(--warning); }
        
        .metric-row {
            margin-bottom: 12px;
        }
        
        .metric-info {
            display: flex;
            justify-content: space-between;
            font-size: 0.85rem;
            margin-bottom: 4px;
        }
        
        .progress-bar-container {
            width: 100%;
            height: 8px;
            background-color: rgba(255, 255, 255, 0.05);
            border-radius: 4px;
            overflow: hidden;
        }
        
        .progress-bar {
            height: 100%;
            border-radius: 4px;
            transition: width 0.3s;
        }
        
        .bg-primary { background-color: var(--primary); }
        .bg-success { background-color: var(--success); }
        .bg-warning { background-color: var(--warning); }
        .bg-danger { background-color: var(--danger); }
        
        .grid-storage {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        
        @media(max-width: 900px) {
            .grid-storage {
                grid-template-columns: 1fr;
            }
        }
        
        .table-container {
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            overflow: hidden;
            margin-bottom: 20px;
        }
        
        .table-title {
            padding: 15px 20px;
            font-size: 1rem;
            font-weight: 600;
            border-bottom: 1px solid var(--border-color);
            background-color: rgba(255, 255, 255, 0.02);
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9rem;
            text-align: left;
        }
        
        th, td {
            padding: 12px 20px;
            border-bottom: 1px solid var(--border-color);
        }
        
        th {
            color: var(--text-muted);
            font-weight: 500;
            background-color: rgba(255, 255, 255, 0.01);
        }
        
        tr:last-child td {
            border-bottom: none;
        }
        
        .badge {
            font-size: 0.75rem;
            padding: 2px 6px;
            border-radius: 4px;
            font-weight: bold;
        }
        
        .badge-warning { background-color: rgba(245, 158, 11, 0.2); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.4); }
        .badge-success { background-color: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.4); }
        
    </style>
</head>
<body>
    <header>
        <div>
            <h1>KvirtIO Virtualization Dashboard</h1>
            <p style="color: var(--text-muted); font-size: 0.95rem; margin-top: 4px;">Monitoraggio di Alto Livello dei Cluster Enterprise</p>
        </div>
        <div class="timestamp">Ultimo aggiornamento: <strong>""" + now_str + """</strong></div>
    </header>
    
    <main>
"""
    
    for cluster_name, nodes in cluster_data.items():
        html += f"""
        <section class="cluster-section">
            <div class="cluster-header">
                <h2>Cluster: {cluster_name}</h2>
                <span class="cluster-badge">Compute & Shared Storage</span>
            </div>
            
            <div class="grid-hosts">
"""
        # Creiamo le schede dei nodi
        vgs_all = {}
        lvs_all = {}
        
        for node_name, info in nodes.items():
            if info["status"] == "OFFLINE":
                card_status_class = "status-offline"
                status_text = "OFFLINE"
                cpu_bar = '<div class="progress-bar bg-danger" style="width: 0%"></div>'
                ram_bar = '<div class="progress-bar bg-danger" style="width: 0%"></div>'
                cpu_text = "N/D"
                ram_text = "N/D"
                latency_text = "N/D"
            else:
                status_text = "ONLINE"
                card_status_class = "status-online"
                
                # Controllo sovraccarico
                is_overloaded = info["cpu"] > info["thresholds"]["cpu"] or info["ram"] > info["thresholds"]["ram"]
                if is_overloaded:
                    card_status_class = "status-overloaded"
                    status_text = "SOVRACCARICO"
                    
                # Definisce il colore delle barre in base ai valori
                cpu_color = "bg-success" if info["cpu"] < info["thresholds"]["cpu"] else "bg-danger"
                ram_color = "bg-success" if info["ram"] < info["thresholds"]["ram"] else "bg-danger"
                
                cpu_bar = f'<div class="progress-bar {cpu_color}" style="width: {info["cpu"]}%"></div>'
                ram_bar = f'<div class="progress-bar {ram_color}" style="width: {info["ram"]}%"></div>'
                
                cpu_text = f"{info['cpu']}%"
                ram_text = f"{info['ram']}%"
                
                latency_color = "badge-success" if info["await"] <= info["thresholds"]["latency"] else "badge-warning"
                latency_text = f'<span class="badge {latency_color}">{info["await"]:.2f} ms</span>'
                
                # Raccoglie i dati degli LVM condivisi (prendendo quelli dell'ultimo nodo online scansionato)
                for vg in info["vgs"]:
                    vgs_all[vg["name"]] = vg
                for lv in info["lvs"]:
                    lvs_all[lv["name"]] = lv

            html += f"""
                <div class="card">
                    <div class="card-header">
                        <span class="card-title">{node_name}</span>
                        <div style="display: flex; align-items: center; gap: 8px;">
                            <span style="font-size: 0.8rem; color: var(--text-muted);">{status_text}</span>
                            <span class="status-dot {card_status_class}"></span>
                        </div>
                    </div>
                    
                    <div class="metric-row">
                        <div class="metric-info">
                            <span>Utilizzo CPU</span>
                            <span>{cpu_text}</span>
                        </div>
                        <div class="progress-bar-container">
                            {cpu_bar}
                        </div>
                    </div>
                    
                    <div class="metric-row">
                        <div class="metric-info">
                            <span>Utilizzo RAM</span>
                            <span>{ram_text}</span>
                        </div>
                        <div class="progress-bar-container">
                            {ram_bar}
                        </div>
                    </div>
                    
                    <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 15px; font-size: 0.85rem;">
                        <span style="color: var(--text-muted);">Max Await LUN FC</span>
                        <span>{latency_text}</span>
                    </div>
                </div>
"""
        html += """
            </div>
            
            <div class="grid-storage">
                <!-- Tabella LVM Volume Groups -->
                <div class="table-container">
                    <div class="table-title">Stato Storage LVM (Volume Groups Condivisi)</div>
                    <table>
                        <thead>
                            <tr>
                                <th>Nome Volume Group</th>
                                <th>Dimensione Totale</th>
                                <th>Spazio Libero</th>
                                <th>Percentuale Libera</th>
                            </tr>
                        </thead>
                        <tbody>
"""
        if vgs_all:
            for vg_name, vg in vgs_all.items():
                pct_free = (vg["free"] / vg["size"] * 100) if vg["size"] > 0 else 0
                pct_free_class = "badge-success" if pct_free > 15 else "badge-warning"
                html += f"""
                            <tr>
                                <td><strong>{vg_name}</strong></td>
                                <td>{vg["size"]:.1f} GB</td>
                                <td>{vg["free"]:.1f} GB</td>
                                <td><span class="badge {pct_free_class}">{pct_free:.1f}%</span></td>
                            </tr>
"""
        else:
            html += """
                            <tr>
                                <td colspan="4" style="text-align: center; color: var(--text-muted);">Nessun dato storage disponibile (tutti i nodi offline)</td>
                            </tr>
"""
        html += """
                        </tbody>
                    </table>
                </div>

                <!-- Tabella Logical Volumes (VM Disks) -->
                <div class="table-container">
                    <div class="table-title">Spazio Dischi Virtual Machine (Logical Volumes)</div>
                    <table>
                        <thead>
                            <tr>
                                <th>Nome VM (Logical Volume)</th>
                                <th>Volume Group</th>
                                <th>Dimensione LV</th>
                            </tr>
                        </thead>
                        <tbody>
"""
        if lvs_all:
            for lv_name, lv in lvs_all.items():
                html += f"""
                            <tr>
                                <td>{lv_name}</td>
                                <td>{lv["vg"]}</td>
                                <td>{lv["size"]:.1f} GB</td>
                            </tr>
"""
        else:
            html += """
                            <tr>
                                <td colspan="3" style="text-align: center; color: var(--text-muted);">Nessun disco VM rilevato</td>
                            </tr>
"""
        html += """
                        </tbody>
                    </table>
                </div>
            </div>
        </section>
"""
        
    html += """
    </main>
</body>
</html>
"""
    return html

def main():
    # Assicura l'esistenza della directory di output
    os.makedirs(HTML_OUTPUT_DIR, exist_ok=True)
    
    config_files = glob.glob(os.path.join(CONFIG_DIR, "*.conf"))
    if not config_files:
        log("ERROR: Nessun file di configurazione trovato in " + CONFIG_DIR, syslog.LOG_ERR)
        sys.exit(1)
        
    cluster_data = {}
    
    for config_file in config_files:
        config = parse_config(config_file)
        if not config:
            continue
            
        cluster_name = config["CLUSTER_NAME"]
        cluster_data[cluster_name] = {}
        
        log(f"Elaborazione del cluster: {cluster_name}...")
        
        for node in config["NODES"]:
            stdout = execute_remote_commands(node, config["SSH_USER"])
            
            if stdout is None:
                cluster_data[cluster_name][node] = {
                    "status": "OFFLINE",
                    "cpu": 0,
                    "ram": 0,
                    "vgs": [],
                    "lvs": [],
                    "await": 0.0,
                    "thresholds": config
                }
                log(f"Nodo {node} del cluster {cluster_name} risulta OFFLINE.", syslog.LOG_WARNING)
            else:
                node_metrics = parse_node_data(stdout)
                node_metrics["status"] = "ONLINE"
                node_metrics["thresholds"] = {
                    "cpu": config["CPU_THRESHOLD"],
                    "ram": config["RAM_THRESHOLD"],
                    "latency": config["LATENCY_THRESHOLD"]
                }
                cluster_data[cluster_name][node] = node_metrics
                
    # Genera l'HTML e lo scrive nel file di output
    html_content = generate_html(cluster_data)
    
    try:
        with open(HTML_OUTPUT_FILE, "w", encoding="utf-8") as f:
            f.write(html_content)
        log("SUCCESS: Dashboard HTML aggiornato correttamente.")
    except Exception as e:
        log(f"ERROR: Scrittura del file HTML fallita: {str(e)}", syslog.LOG_ERR)
        sys.exit(1)

if __name__ == "__main__":
    main()
