#!/usr/bin/env bash
# Teleporter export (master): pulls Pi-hole config via API, commits to git.
# Runs only on dns1 (master). Triggered nightly via cron at 03:00.

set -euo pipefail

REPO_DIR="/opt/homelab-dns"
BACKUP_DIR="${REPO_DIR}/backups"
BACKUP_FILE="${BACKUP_DIR}/teleporter-latest.zip"
LOG_DIR="/var/log/dns-sync"
LOG_FILE="${LOG_DIR}/export.log"
GITHUB_TOKEN_FILE="/etc/dns-sync/github.token"
PIHOLE_URL="http://localhost:80"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

log()    { echo "[export] $(date '+%F %T') $*" | tee -a "$LOG_FILE"; }
die()    { log "ERROR: $*"; exit 1; }

# ── Pre-flight ──
[[ "$(hostname)" == "dns1" ]] || die "Dieses Skript muss auf dns1 laufen (aktuell: $(hostname))"
[[ -f "$GITHUB_TOKEN_FILE" ]] || die "GitHub-Token fehlt: $GITHUB_TOKEN_FILE"

ENV_FILE="${REPO_DIR}/compose/.env"
[[ -f "$ENV_FILE" ]] || die ".env fehlt: $ENV_FILE"

PIHOLE_PASSWORD="$(grep '^FTLCONF_webserver_api_password=' "$ENV_FILE" | cut -d'=' -f2-)"
[[ -n "$PIHOLE_PASSWORD" ]] || die "FTLCONF_webserver_api_password nicht in $ENV_FILE gesetzt"

log "Starte Teleporter-Export..."

# ── Auth ──
log "Authentifiziere bei Pi-hole API..."
AUTH_RESPONSE=$(curl -sS --fail-with-body \
    -X POST -H "Content-Type: application/json" \
    -d "{\"password\":\"${PIHOLE_PASSWORD}\"}" \
    "${PIHOLE_URL}/api/auth" 2>&1) || die "Auth fehlgeschlagen: $AUTH_RESPONSE"

SID=$(echo "$AUTH_RESPONSE" | jq -r '.session.sid // empty')
[[ -n "$SID" ]] || die "Konnte Session-ID nicht extrahieren: $AUTH_RESPONSE"

# ── Export ──
log "Lade Teleporter-Backup..."
HTTP_CODE=$(curl -sS -o "$BACKUP_FILE" -w '%{http_code}' \
    -H "sid: ${SID}" "${PIHOLE_URL}/api/teleporter") \
    || die "Export-Request fehlgeschlagen"

[[ "$HTTP_CODE" == "200" ]] || die "Export HTTP $HTTP_CODE"
[[ -s "$BACKUP_FILE" ]] || die "Backup-Datei ist leer"
log "Backup heruntergeladen: $(stat -c%s "$BACKUP_FILE") bytes"

# ── Session schliessen ──
curl -sS -X DELETE -H "sid: ${SID}" "${PIHOLE_URL}/api/auth" >/dev/null 2>&1 || true

# ── Git commit & push ──
cd "$REPO_DIR"
git add backups/teleporter-latest.zip

if git diff --cached --quiet; then
    log "Keine Aenderungen — kein Commit"
else
    git commit -m "Teleporter export $(date '+%Y-%m-%d %H:%M')" || die "git commit fehlgeschlagen"
    git push origin main || die "git push fehlgeschlagen"
    log "Push erfolgreich"
fi

log "Teleporter-Export abgeschlossen"
