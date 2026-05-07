#!/usr/bin/env bash
# Installs role-specific cron jobs based on hostname (dns1 or dns2).

set -euo pipefail

REPO_DIR="/opt/homelab-dns"
CRON_FILE="/etc/cron.d/dns-sync"
LOG_DIR="/var/log/dns-sync"

log() { echo "[setup-cron] $(date '+%F %T') $*"; }

mkdir -p "$LOG_DIR"

CURRENT_HOSTNAME="$(hostname)"

case "$CURRENT_HOSTNAME" in
    dns1)
        log "Installiere Cron für dns1 (master)..."
        cat > "$CRON_FILE" <<EOF
# Naechtlicher Teleporter-Export um 03:00
0 3 * * * root ${REPO_DIR}/scripts/teleporter-export.sh >> ${LOG_DIR}/export.log 2>&1
# System-Status alle 5 Minuten aktualisieren
*/5 * * * * root ${REPO_DIR}/scripts/update-site-info.sh >> ${LOG_DIR}/site-info.log 2>&1
EOF
        ;;
    dns2)
        log "Installiere Cron für dns2 (follower)..."
        cat > "$CRON_FILE" <<EOF
# Naechtlicher Teleporter-Import um 03:30
30 3 * * * root ${REPO_DIR}/scripts/teleporter-import.sh >> ${LOG_DIR}/import.log 2>&1
# System-Status alle 5 Minuten aktualisieren
*/5 * * * * root ${REPO_DIR}/scripts/update-site-info.sh >> ${LOG_DIR}/site-info.log 2>&1
EOF
        ;;
    *)
        echo "FEHLER: Unbekannter Hostname '$CURRENT_HOSTNAME' (erwartet: dns1 oder dns2)"
        exit 1
        ;;
esac

chmod 0644 "$CRON_FILE"
log "Cron installiert: $CRON_FILE"
cat "$CRON_FILE"

if ! systemctl is-active --quiet cron; then
    systemctl enable --now cron
fi

log "Cron-Setup fertig"
