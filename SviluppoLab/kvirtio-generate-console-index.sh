#!/usr/bin/env bash
#
# kvirtio-generate-console-index.sh
#
# Genera una pagina HTML statica con i link alle console noVNC
# di tutte le VM presenti nella directory dei token KvirtIO.
#
# Uso:
#   ./kvirtio-generate-console-index.sh
#
# Pensato per essere lanciato:
#   - a mano dopo un refresh dei token
#   - da kvirtio-console-index.path (systemd, osserva TOKEN_DIR)
#   - da un timer/cron come fallback
#
# Installazione consigliata:
#   install -m 0755 kvirtio-generate-console-index.sh /usr/local/bin/
#   install -m 0644 kvirtio-console-index.service /etc/systemd/system/
#   install -m 0644 kvirtio-console-index.path    /etc/systemd/system/
#   systemctl daemon-reload
#   systemctl enable --now kvirtio-console-index.path

set -euo pipefail

# --- Configurazione ---------------------------------------------------
TOKEN_DIR="/var/lib/kvirtio/novnc/tokens"
OUTPUT_HTML="/srv/www/htdocs/consoles.html"
NOVNC_PATH="/novnc/vnc.html"      # percorso relativo: indipendente da IP/host/https
WEB_USER="wwwrun"
WEB_GROUP="www"
CHECK_STATUS="true"               # true = verifica raggiungibilità porta VNC (1s timeout/VM)
# -----------------------------------------------------------------------

if [[ ! -d "${TOKEN_DIR}" ]]; then
    echo "ERRORE: directory token non trovata: ${TOKEN_DIR}" >&2
    exit 1
fi

TMP_HTML="$(mktemp "${OUTPUT_HTML}.XXXXXX")"
trap 'rm -f "${TMP_HTML}"' EXIT

# --- Helper -------------------------------------------------------------

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# urlencode puro bash (nessuna dipendenza da python/perl)
urlencode() {
    local string="${1}" strlen encoded c o i
    strlen=${#string}
    encoded=""
    for (( i = 0; i < strlen; i++ )); do
        c="${string:i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) o="${c}" ;;
            *) printf -v o '%%%02X' "'${c}" ;;
        esac
        encoded+="${o}"
    done
    printf '%s' "${encoded}"
}

check_status() {
    local ip="$1" port="$2"
    if [[ "${CHECK_STATUS}" != "true" ]]; then
        echo "unknown"
        return
    fi
    if timeout 1 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null; then
        echo "up"
    else
        echo "down"
    fi
}

# --- Metadati cluster -----------------------------------------------------

CLUSTER_NAME="$(grep -h -m1 -oP '(?<=Cluster:\s)\S+' "${TOKEN_DIR}"/* 2>/dev/null || true)"
CLUSTER_NAME="${CLUSTER_NAME:-sconosciuto}"
GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S %z')"

# --- Estrazione voci --------------------------------------------------------
# righe valide: "vm-name: ip:port"  (ignora commenti e righe vuote)
mapfile -t ENTRIES < <(grep -h -vE '^[[:space:]]*#|^[[:space:]]*$' "${TOKEN_DIR}"/* 2>/dev/null | sort -f)

# --- Scrittura HTML ----------------------------------------------------------

cat > "${TMP_HTML}" <<HEADER
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Console VM — ${CLUSTER_NAME}</title>
<style>
  :root{
    --bg:#0a0c10; --panel:#12151b; --border:#232830;
    --text:#d7dce2; --text-dim:#7d8590;
    --accent:#f2a93b; --up:#3fb950; --down:#f85149; --unknown:#7d8590;
  }
  *{box-sizing:border-box;}
  body{
    margin:0; padding:2.5rem 1.5rem 4rem;
    background:var(--bg); color:var(--text);
    font-family:'JetBrains Mono','SFMono-Regular',Consolas,'Liberation Mono',monospace;
    font-size:14px; line-height:1.5;
  }
  header{max-width:1100px; margin:0 auto 2.5rem;}
  .prompt{color:var(--text-dim); font-size:13px; margin:0 0 .4rem;}
  h1{
    margin:0; font-size:1.6rem; font-weight:600; letter-spacing:-0.02em;
    color:var(--text); display:flex; align-items:baseline; gap:.5rem;
  }
  .cursor{
    display:inline-block; width:.55em; height:1.05em; background:var(--accent);
    animation:blink 1.1s steps(1) infinite; transform:translateY(2px);
  }
  @media (prefers-reduced-motion: reduce){ .cursor{animation:none; opacity:.8;} }
  @keyframes blink{50%{opacity:0;}}
  .meta{color:var(--text-dim); font-size:12.5px; margin-top:.6rem;}
  .meta b{color:var(--text);}
  main{max-width:1100px; margin:0 auto;}
  .grid{
    display:grid; grid-template-columns:repeat(auto-fill, minmax(280px,1fr));
    gap:.85rem;
  }
  .vm-card{
    display:flex; flex-direction:column; gap:.5rem;
    background:var(--panel); border:1px solid var(--border); border-radius:6px;
    padding:1rem 1.1rem; text-decoration:none; color:var(--text);
    transition:border-color .15s ease, transform .15s ease;
  }
  .vm-card:hover, .vm-card:focus-visible{
    border-color:var(--accent); transform:translateY(-1px);
  }
  .vm-card:focus-visible{outline:2px solid var(--accent); outline-offset:2px;}
  .vm-top{display:flex; align-items:center; gap:.55rem;}
  .vm-dot{width:8px; height:8px; border-radius:50%; flex:none; background:var(--unknown);}
  .vm-dot.up{background:var(--up);}
  .vm-dot.down{background:var(--down);}
  .vm-name{font-weight:600; font-size:14.5px; word-break:break-all;}
  .vm-target{color:var(--text-dim); font-size:12.5px;}
  .vm-action{
    margin-top:.25rem; font-size:12.5px; color:var(--accent);
    opacity:.75;
  }
  .vm-card:hover .vm-action{opacity:1;}
  .empty{color:var(--text-dim); padding:2rem 0;}
  footer{max-width:1100px; margin:3rem auto 0; color:var(--text-dim); font-size:12px;}
</style>
</head>
<body>
<header>
  <p class="prompt">kvirtio@${CLUSTER_NAME}:~\$</p>
  <h1>Console VM<span class="cursor"></span></h1>
  <p class="meta">Cluster: <b>${CLUSTER_NAME}</b> · Generato il <b>${GENERATED_AT}</b> · <b>${#ENTRIES[@]}</b> VM registrate</p>
</header>
<main>
<div class="grid">
HEADER

if [[ "${#ENTRIES[@]}" -eq 0 ]]; then
    cat >> "${TMP_HTML}" <<'EMPTY'
  <p class="empty">Nessun token trovato in TOKEN_DIR. Verifica che kvirtio-console-tracker sia in esecuzione.</p>
EMPTY
else
    for line in "${ENTRIES[@]}"; do
        if [[ "${line}" =~ ^[[:space:]]*([^:[:space:]][^:]*):[[:space:]]*([0-9A-Za-z_.-]+):([0-9]+)[[:space:]]*$ ]]; then
            token="${BASH_REMATCH[1]}"
            target_ip="${BASH_REMATCH[2]}"
            target_port="${BASH_REMATCH[3]}"
        else
            echo "AVVISO: riga non riconosciuta, salto: ${line}" >&2
            continue
        fi

        status="$(check_status "${target_ip}" "${target_port}")"
        safe_token="$(printf '%s' "${token}" | html_escape)"
        inner_path="?token=${token}"
        encoded_path="$(urlencode "${inner_path}")"
        console_url="${NOVNC_PATH}?autoconnect=true&path=${encoded_path}"

        printf '  <a class="vm-card" href="%s" target="_blank" rel="noopener">\n' "${console_url}" >> "${TMP_HTML}"
        printf '    <div class="vm-top"><span class="vm-dot %s"></span><span class="vm-name">%s</span></div>\n' "${status}" "${safe_token}" >> "${TMP_HTML}"
        printf '    <span class="vm-target">%s:%s</span>\n' "${target_ip}" "${target_port}" >> "${TMP_HTML}"
        printf '    <span class="vm-action">apri console &rarr;</span>\n' >> "${TMP_HTML}"
        printf '  </a>\n' >> "${TMP_HTML}"
    done
fi

cat >> "${TMP_HTML}" <<FOOTER
</div>
</main>
<footer>Pallino verde = porta VNC raggiungibile al momento della generazione · pallino grigio = verifica disattivata · pallino rosso = non raggiungibile.</footer>
</body>
</html>
FOOTER

mv "${TMP_HTML}" "${OUTPUT_HTML}"
chmod 0644 "${OUTPUT_HTML}"
chown "${WEB_USER}:${WEB_GROUP}" "${OUTPUT_HTML}" 2>/dev/null || true

echo "OK: pagina generata in ${OUTPUT_HTML} (${#ENTRIES[@]} VM)"
