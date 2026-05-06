#!/usr/bin/env bash
set -euo pipefail

# Generates recovery-site/system-status.json with current system metrics.
# Called by bootstrap and by cron every 5 minutes.

REPO_DIR="/opt/homelab-dns"
OUT_FILE="${REPO_DIR}/recovery-site/system-status.json"
ENV_FILE="${REPO_DIR}/compose/.env"
MARKER_FILE="/var/lib/pihole-sync/last-import"

# --- Hilfsfunktionen ---

container_status() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "not found"
}

container_health() {
    local h
    h="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo "unknown")"
    echo "$h"
}

# --- Systemdaten sammeln ---

HOSTNAME="$(hostname)"
ROLE="$(echo "$HOSTNAME" | grep -oP '[ab]$' || echo 'unknown')"
IP="$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127 | head -1)"
UPTIME_SEC="$(awk '{print int($1)}' /proc/uptime)"
UPTIME_HUMAN="$(uptime -p | sed 's/up //')"
LOAD="$(cat /proc/loadavg | awk '{print $1, $2, $3}')"

MEM_TOTAL="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
MEM_AVAIL="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
MEM_PERCENT=$(( MEM_USED * 100 / MEM_TOTAL ))

DISK_TOTAL="$(df -k / | awk 'NR==2{print $2}')"
DISK_USED="$(df -k / | awk 'NR==2{print $3}')"
DISK_PERCENT="$(df / | awk 'NR==2{print $5}' | tr -d '%')"

PIHOLE_STATUS="$(container_status pihole)"
PIHOLE_HEALTH="$(container_health pihole)"
RECOVERY_STATUS="$(container_status recovery-site)"

# DNS-Test
DNS_OK="false"
if dig +short +time=2 example.com @127.0.0.1 &>/dev/null; then
    DNS_OK="true"
fi

# Letzter Sync-Zeitstempel
LAST_SYNC=""
if [[ "$ROLE" == "a" ]]; then
    LAST_SYNC="$(cd "${REPO_DIR}" && git log --format='%ci' -1 -- backups/teleporter-latest.zip 2>/dev/null || echo '')"
elif [[ -f "$MARKER_FILE" ]]; then
    MARKER_TS="$(cat "$MARKER_FILE" | tr -d '[:space:]')"
    LAST_SYNC="$(date -d "@${MARKER_TS}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$MARKER_TS")"
fi

GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

# --- JSON schreiben ---

cat > "$OUT_FILE" <<EOF
{
  "hostname": "${HOSTNAME}",
  "ip": "${IP}",
  "role": "${ROLE}",
  "generated_at": "${GENERATED_AT}",
  "uptime": "${UPTIME_HUMAN}",
  "uptime_sec": ${UPTIME_SEC},
  "load": "${LOAD}",
  "memory": {
    "total_kb": ${MEM_TOTAL},
    "used_kb": ${MEM_USED},
    "percent": ${MEM_PERCENT}
  },
  "disk": {
    "total_kb": ${DISK_TOTAL},
    "used_kb": ${DISK_USED},
    "percent": ${DISK_PERCENT}
  },
  "containers": {
    "pihole": { "status": "${PIHOLE_STATUS}", "health": "${PIHOLE_HEALTH}" },
    "recovery_site": { "status": "${RECOVERY_STATUS}" }
  },
  "dns_ok": ${DNS_OK},
  "last_sync": "${LAST_SYNC}"
}
EOF
