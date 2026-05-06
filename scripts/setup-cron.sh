#!/usr/bin/env bash
set -euo pipefail

# Install role-specific cron job for Teleporter sync.
# Idempotent: overwrites existing cron file on each run.

REPO_DIR="/opt/homelab-dns"
CRON_FILE="/etc/cron.d/pihole-sync"

log() { echo "[setup-cron] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

CURRENT_HOSTNAME="$(hostname)"

case "$CURRENT_HOSTNAME" in
    pihole-a)
        log "Configuring export cron for pihole-a (master)..."
        cat > "$CRON_FILE" <<EOF
# Nightly Teleporter export at 03:00
0 3 * * * root ${REPO_DIR}/scripts/teleporter-export.sh >> /var/log/pihole-sync/export.log 2>&1
# System status fuer Recovery-Site alle 5 Minuten aktualisieren
*/5 * * * * root ${REPO_DIR}/scripts/update-site-info.sh >> /var/log/pihole-sync/site-info.log 2>&1
EOF
        ;;
    pihole-b)
        log "Configuring import cron for pihole-b (follower)..."
        cat > "$CRON_FILE" <<EOF
# Nightly Teleporter import at 03:30
30 3 * * * root ${REPO_DIR}/scripts/teleporter-import.sh >> /var/log/pihole-sync/import.log 2>&1
# System status fuer Recovery-Site alle 5 Minuten aktualisieren
*/5 * * * * root ${REPO_DIR}/scripts/update-site-info.sh >> /var/log/pihole-sync/site-info.log 2>&1
EOF
        ;;
    *)
        echo "ERROR: Unknown hostname '${CURRENT_HOSTNAME}'. Expected 'pihole-a' or 'pihole-b'."
        exit 1
        ;;
esac

chmod 0644 "$CRON_FILE"

log "Cron job installed at ${CRON_FILE}:"
cat "$CRON_FILE"

if ! systemctl is-active --quiet cron; then
    log "Starting cron service..."
    systemctl enable cron
    systemctl start cron
fi

log "Cron setup complete."
