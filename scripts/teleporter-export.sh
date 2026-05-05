#!/usr/bin/env bash
set -euo pipefail

# Export Pi-hole configuration via Teleporter API (v6) and push to Git.
# Runs only on pihole-a (master). Called nightly via cron at 03:00.

REPO_DIR="/opt/homelab-dns"
BACKUP_DIR="${REPO_DIR}/backups"
BACKUP_FILE="${BACKUP_DIR}/teleporter-latest.zip"
LOG_DIR="/var/log/pihole-sync"
LOG_FILE="${LOG_DIR}/export.log"
GITHUB_TOKEN_FILE="/etc/pihole-sync/github.token"
PIHOLE_URL="http://localhost:80"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

log() {
    local msg="[export] $(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

# --- Pre-flight checks ---

CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" != "pihole-a" ]]; then
    error_exit "This script must run on pihole-a (current hostname: ${CURRENT_HOSTNAME})"
fi

if [[ ! -f "$GITHUB_TOKEN_FILE" ]]; then
    error_exit "GitHub token not found at ${GITHUB_TOKEN_FILE}"
fi

ENV_FILE="${REPO_DIR}/compose/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    error_exit ".env file not found at ${ENV_FILE}"
fi

PIHOLE_PASSWORD="$(grep '^FTLCONF_webserver_api_password=' "$ENV_FILE" | cut -d'=' -f2-)"
if [[ -z "$PIHOLE_PASSWORD" ]]; then
    error_exit "FTLCONF_webserver_api_password not set in ${ENV_FILE}"
fi

log "Starting Teleporter export..."

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

# --- Export Teleporter backup ---

log "Downloading Teleporter backup..."
HTTP_CODE="$(curl -sS -o "$BACKUP_FILE" -w '%{http_code}' \
    -H "sid: ${SID}" \
    "${PIHOLE_URL}/api/teleporter" 2>&1)" \
    || error_exit "Teleporter export request failed"

if [[ "$HTTP_CODE" != "200" ]]; then
    error_exit "Teleporter export returned HTTP ${HTTP_CODE}"
fi

if [[ ! -s "$BACKUP_FILE" ]]; then
    error_exit "Teleporter backup file is empty"
fi

BACKUP_SIZE="$(stat -c%s "$BACKUP_FILE")"
log "Backup downloaded: ${BACKUP_SIZE} bytes"

# --- Invalidate session ---

curl -sS -X DELETE \
    -H "sid: ${SID}" \
    "${PIHOLE_URL}/api/auth" >/dev/null 2>&1 || true

# --- Commit and push to Git ---

log "Committing and pushing to Git..."
cd "$REPO_DIR"

git add backups/teleporter-latest.zip

if git diff --cached --quiet; then
    log "No changes in Teleporter backup, skipping commit."
else
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M')"
    git commit -m "Teleporter export ${TIMESTAMP}" \
        || error_exit "git commit failed"

    git push origin main \
        || error_exit "git push failed — check PAT validity and network connectivity"

    log "Pushed to Git successfully."
fi

log "Teleporter export completed successfully."
