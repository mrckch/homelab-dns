#!/usr/bin/env bash
# Teleporter import (follower): pulls latest backup from git, imports via API.
# Runs only on dns2 (follower). Triggered nightly via cron at 03:30.

set -euo pipefail

REPO_DIR="/opt/homelab-dns"
BACKUP_DIR="${REPO_DIR}/backups"
BACKUP_FILE="${BACKUP_DIR}/teleporter-latest.zip"
LOG_DIR="/var/log/dns-sync"
LOG_FILE="${LOG_DIR}/import.log"
MARKER_DIR="/var/lib/dns-sync"
MARKER_FILE="${MARKER_DIR}/last-import"
PIHOLE_URL="http://localhost:80"

mkdir -p "$LOG_DIR" "$MARKER_DIR"

log() { echo "[import] $(date '+%F %T') $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# ── Pre-flight ──
[[ "$(hostname)" == "dns2" ]] || die "Dieses Skript muss auf dns2 laufen (aktuell: $(hostname))"

ENV_FILE="${REPO_DIR}/compose/.env"
[[ -f "$ENV_FILE" ]] || die ".env fehlt: $ENV_FILE"

PIHOLE_PASSWORD="$(grep '^FTLCONF_webserver_api_password=' "$ENV_FILE" | cut -d'=' -f2-)"
[[ -n "$PIHOLE_PASSWORD" ]] || die "FTLCONF_webserver_api_password nicht in $ENV_FILE gesetzt"

log "Starte Teleporter-Import..."

# ── Git pull ──
cd "$REPO_DIR"
git pull --ff-only || die "git pull fehlgeschlagen"

[[ -f "$BACKUP_FILE" ]] || die "Backup nicht gefunden: $BACKUP_FILE"

# ── Marker pruefen ──
BACKUP_MTIME=$(stat -c%Y "$BACKUP_FILE")
if [[ -f "$MARKER_FILE" ]]; then
    LAST_IMPORT=$(tr -d '[:space:]' < "$MARKER_FILE")
    if [[ "$BACKUP_MTIME" -le "$LAST_IMPORT" ]]; then
        log "Backup unveraendert seit letztem Import (mtime $BACKUP_MTIME <= $LAST_IMPORT) — skip"
        exit 0
    fi
fi
log "Neues Backup erkannt: $(stat -c%s "$BACKUP_FILE") bytes, mtime $BACKUP_MTIME"

# ── Auth ──
AUTH_RESPONSE=$(curl -sS --fail-with-body \
    -X POST -H "Content-Type: application/json" \
    -d "{\"password\":\"${PIHOLE_PASSWORD}\"}" \
    "${PIHOLE_URL}/api/auth" 2>&1) || die "Auth fehlgeschlagen: $AUTH_RESPONSE"

SID=$(echo "$AUTH_RESPONSE" | jq -r '.session.sid // empty')
[[ -n "$SID" ]] || die "Konnte Session-ID nicht extrahieren: $AUTH_RESPONSE"

# ── Import ──
log "Importiere Teleporter-Backup..."
IMPORT_RESPONSE=$(curl -sS --fail-with-body \
    -X POST -H "sid: ${SID}" \
    -F "file=@${BACKUP_FILE}" \
    "${PIHOLE_URL}/api/teleporter" 2>&1) || die "Import fehlgeschlagen: $IMPORT_RESPONSE"

log "API-Antwort: $IMPORT_RESPONSE"

# ── Session schliessen ──
curl -sS -X DELETE -H "sid: ${SID}" "${PIHOLE_URL}/api/auth" >/dev/null 2>&1 || true

# ── Marker aktualisieren ──
echo "$BACKUP_MTIME" > "$MARKER_FILE"
log "Marker aktualisiert: $BACKUP_MTIME"

log "Teleporter-Import abgeschlossen"
