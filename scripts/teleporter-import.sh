#!/usr/bin/env bash
set -euo pipefail

# Import Pi-hole configuration via Teleporter API (v6) from Git.
# Runs only on pihole-b (follower). Called nightly via cron at 03:30.

REPO_DIR="/opt/homelab-dns"
BACKUP_DIR="${REPO_DIR}/backups"
BACKUP_FILE="${BACKUP_DIR}/teleporter-latest.zip"
LOG_DIR="/var/log/pihole-sync"
LOG_FILE="${LOG_DIR}/import.log"
MARKER_DIR="/var/lib/pihole-sync"
MARKER_FILE="${MARKER_DIR}/last-import"
PIHOLE_URL="http://localhost:80"

mkdir -p "$LOG_DIR" "$MARKER_DIR"

log() {
    local msg="[import] $(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

# --- Pre-flight checks ---

CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" != "pihole-b" ]]; then
    error_exit "This script must run on pihole-b (current hostname: ${CURRENT_HOSTNAME})"
fi

ENV_FILE="${REPO_DIR}/compose/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    error_exit ".env file not found at ${ENV_FILE}"
fi

PIHOLE_PASSWORD="$(grep '^FTLCONF_webserver_api_password=' "$ENV_FILE" | cut -d'=' -f2-)"
if [[ -z "$PIHOLE_PASSWORD" ]]; then
    error_exit "FTLCONF_webserver_api_password not set in ${ENV_FILE}"
fi

log "Starting Teleporter import..."

# --- Pull latest from Git ---

log "Pulling latest changes from Git..."
cd "$REPO_DIR"
git pull --ff-only \
    || error_exit "git pull failed — check SSH deploy key and network connectivity"

# --- Check if backup is newer than last import ---

if [[ ! -f "$BACKUP_FILE" ]]; then
    error_exit "Backup file not found at ${BACKUP_FILE}"
fi

BACKUP_MTIME="$(stat -c%Y "$BACKUP_FILE")"

if [[ -f "$MARKER_FILE" ]]; then
    LAST_IMPORT="$(cat "$MARKER_FILE" | tr -d '[:space:]')"
    if [[ "$BACKUP_MTIME" -le "$LAST_IMPORT" ]]; then
        log "Backup has not changed since last import (backup: ${BACKUP_MTIME}, last import: ${LAST_IMPORT}). Skipping."
        exit 0
    fi
fi

BACKUP_SIZE="$(stat -c%s "$BACKUP_FILE")"
log "New backup found: ${BACKUP_SIZE} bytes, mtime ${BACKUP_MTIME}"

# --- Authenticate with Pi-hole v6 API ---

log "Authenticating with Pi-hole API..."
AUTH_RESPONSE="$(curl -sS --fail-with-body \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"${PIHOLE_PASSWORD}\"}" \
    "${PIHOLE_URL}/api/auth" 2>&1)" \
    || error_exit "API authentication failed: ${AUTH_RESPONSE}"

SID="$(echo "$AUTH_RESPONSE" | jq -r '.session.sid // empty')"
if [[ -z "$SID" ]]; then
    error_exit "Failed to extract session ID from auth response: ${AUTH_RESPONSE}"
fi

log "Authenticated successfully."

# --- Import Teleporter backup ---

log "Importing Teleporter backup..."
IMPORT_RESPONSE="$(curl -sS --fail-with-body \
    -X POST \
    -H "sid: ${SID}" \
    -F "file=@${BACKUP_FILE}" \
    "${PIHOLE_URL}/api/teleporter" 2>&1)" \
    || error_exit "Teleporter import request failed: ${IMPORT_RESPONSE}"

log "Import API response: ${IMPORT_RESPONSE}"

# --- Invalidate session ---

curl -sS -X DELETE \
    -H "sid: ${SID}" \
    "${PIHOLE_URL}/api/auth" >/dev/null 2>&1 || true

# --- Update marker file ---

echo "$BACKUP_MTIME" > "$MARKER_FILE"
log "Updated import marker to ${BACKUP_MTIME}"

log "Teleporter import completed successfully."
