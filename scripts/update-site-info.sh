#!/usr/bin/env bash
# Generates recovery-site/system-status.json with current system metrics.
# Called by bootstrap and by cron every 5 minutes.

set -euo pipefail

REPO_DIR="/opt/homelab-dns"
OUT_FILE="${REPO_DIR}/recovery-site/system-status.json"
HISTORY_FILE="${REPO_DIR}/recovery-site/metrics-history.json"
ENV_FILE="${REPO_DIR}/compose/.env"
MARKER_FILE="/var/lib/dns-sync/last-import"
HISTORY_POINTS=288   # 24h bei 5-min Intervall

container_status() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "not found"
}
container_health() {
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$1" 2>/dev/null || echo "unknown"
}
container_image() {
    docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null || echo "-"
}
container_started() {
    docker inspect --format '{{.State.StartedAt}}' "$1" 2>/dev/null || echo "-"
}
container_restarts() {
    docker inspect --format '{{.RestartCount}}' "$1" 2>/dev/null || echo "0"
}

# ── System ──
HOSTNAME="$(hostname)"
case "$HOSTNAME" in
    dns1) ROLE="master" ;;
    dns2) ROLE="follower" ;;
    *)    ROLE="unknown" ;;
esac

IP=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {print $2}' | head -1 | cut -d/ -f1)
KERNEL=$(uname -r)
OS_INFO=$(. /etc/os-release && echo "$PRETTY_NAME")
CPU_CORES=$(nproc)
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
UPTIME_HUMAN=$(uptime -p | sed 's/up //')
LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg)

MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))

DISK_TOTAL=$(df -k / | awk 'NR==2{print $2}')
DISK_USED=$(df -k / | awk 'NR==2{print $3}')
DISK_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')

# ── Container ──
PIHOLE_STATUS=$(container_status pihole)
PIHOLE_HEALTH=$(container_health pihole)
PIHOLE_IMAGE=$(container_image pihole)
PIHOLE_STARTED=$(container_started pihole)
PIHOLE_RESTARTS=$(container_restarts pihole)

RECOVERY_STATUS=$(container_status recovery-site)
RECOVERY_IMAGE=$(container_image recovery-site)
RECOVERY_RESTARTS=$(container_restarts recovery-site)

# ── DNS Tests ──
DNS_LOCAL="false"
DNS_LOCAL_TIME=""
T0=$(date +%s%N)
if dig +short +time=2 example.com @127.0.0.1 &>/dev/null; then
    DNS_LOCAL="true"
fi
DNS_LOCAL_TIME=$(awk -v t0="$T0" -v t1="$(date +%s%N)" 'BEGIN{printf "%d", (t1-t0)/1000000}')

UP_CLOUDFLARE="false"
if dig +short +time=2 example.com @1.1.1.1 &>/dev/null; then UP_CLOUDFLARE="true"; fi
UP_QUAD9="false"
if dig +short +time=2 example.com @9.9.9.9 &>/dev/null; then UP_QUAD9="true"; fi

# ── Pi-hole API stats (best-effort) ──
QUERIES_TOTAL="0"
QUERIES_BLOCKED="0"
BLOCK_PERCENT="0"
DOMAINS_BLOCKED="0"
GRAVITY_LAST=""

if [[ -f "$ENV_FILE" ]] && [[ "$PIHOLE_STATUS" == "running" ]]; then
    PHPW="$(grep '^FTLCONF_webserver_api_password=' "$ENV_FILE" | cut -d'=' -f2-)"
    if [[ -n "$PHPW" ]]; then
        AUTH=$(curl -s --max-time 3 -X POST -H "Content-Type: application/json" \
            -d "{\"password\":\"${PHPW}\"}" "http://127.0.0.1/api/auth" 2>/dev/null || echo "")
        SID=$(echo "$AUTH" | jq -r '.session.sid // empty' 2>/dev/null || echo "")
        if [[ -n "$SID" ]]; then
            STATS=$(curl -s --max-time 3 -H "sid: $SID" "http://127.0.0.1/api/stats/summary" 2>/dev/null || echo "{}")
            QUERIES_TOTAL=$(echo   "$STATS" | jq -r '.queries.total           // 0' 2>/dev/null || echo 0)
            QUERIES_BLOCKED=$(echo "$STATS" | jq -r '.queries.blocked         // 0' 2>/dev/null || echo 0)
            BLOCK_PERCENT=$(echo   "$STATS" | jq -r '.queries.percent_blocked // 0' 2>/dev/null || echo 0)
            DOMAINS_BLOCKED=$(echo "$STATS" | jq -r '.gravity.domains_being_blocked // 0' 2>/dev/null || echo 0)
            GRAVITY=$(curl -s --max-time 3 -H "sid: $SID" "http://127.0.0.1/api/info/gravity" 2>/dev/null || echo "{}")
            GRAVITY_LAST=$(echo "$GRAVITY" | jq -r '.gravity.last_update // empty' 2>/dev/null || echo "")
            curl -s --max-time 2 -X DELETE -H "sid: $SID" "http://127.0.0.1/api/auth" >/dev/null 2>&1 || true
        fi
    fi
fi

# ── Sync ──
LAST_SYNC=""
LAST_SYNC_HASH=""
if [[ "$ROLE" == "master" && -d "$REPO_DIR/.git" ]]; then
    LAST_SYNC=$(cd "$REPO_DIR" && git log --format='%ci' -1 -- backups/teleporter-latest.zip 2>/dev/null || echo "")
    LAST_SYNC_HASH=$(cd "$REPO_DIR" && git log --format='%h' -1 -- backups/teleporter-latest.zip 2>/dev/null || echo "")
elif [[ -f "$MARKER_FILE" ]]; then
    MARKER_TS=$(tr -d '[:space:]' < "$MARKER_FILE")
    LAST_SYNC=$(date -d "@${MARKER_TS}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$MARKER_TS")
fi

# ── Git status ──
GIT_BRANCH=""
GIT_HEAD=""
GIT_BEHIND=0
if [[ -d "$REPO_DIR/.git" ]]; then
    GIT_BRANCH=$(cd "$REPO_DIR" && git branch --show-current 2>/dev/null || echo "")
    GIT_HEAD=$(cd "$REPO_DIR" && git log -1 --format='%h %s' 2>/dev/null || echo "")
fi

# ── Recent log ──
RECENT_LOG=""
if [[ "$ROLE" == "master" && -f /var/log/dns-sync/export.log ]]; then
    RECENT_LOG=$(tail -8 /var/log/dns-sync/export.log 2>/dev/null | jq -Rs . || echo '""')
elif [[ "$ROLE" == "follower" && -f /var/log/dns-sync/import.log ]]; then
    RECENT_LOG=$(tail -8 /var/log/dns-sync/import.log 2>/dev/null | jq -Rs . || echo '""')
else
    RECENT_LOG='""'
fi

GENERATED_AT=$(date '+%F %T')
GENERATED_EPOCH=$(date +%s)

# ── Load (1-min als Float) ──
LOAD1=$(awk '{print $1}' /proc/loadavg)

# ── History anhaengen (rolling window) ──
mkdir -p "$(dirname "$HISTORY_FILE")"
NEW_POINT=$(printf '{"t":%d,"mem":%d,"disk":%d,"load":%s,"queries":%d,"blocked":%d}' \
    "$GENERATED_EPOCH" "$MEM_PCT" "$DISK_PCT" "$LOAD1" \
    "${QUERIES_TOTAL:-0}" "${QUERIES_BLOCKED:-0}")

if [[ -f "$HISTORY_FILE" ]] && jq empty "$HISTORY_FILE" 2>/dev/null; then
    jq --argjson p "$NEW_POINT" --argjson n "$HISTORY_POINTS" \
        '. + [$p] | .[-$n:]' "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" \
        && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
else
    echo "[$NEW_POINT]" > "$HISTORY_FILE"
fi

# ── JSON ──
mkdir -p "$(dirname "$OUT_FILE")"
cat > "$OUT_FILE" <<EOF
{
  "hostname": "${HOSTNAME}",
  "ip": "${IP}",
  "role": "${ROLE}",
  "os": "${OS_INFO}",
  "kernel": "${KERNEL}",
  "cpu_cores": ${CPU_CORES},
  "generated_at": "${GENERATED_AT}",
  "generated_epoch": ${GENERATED_EPOCH},
  "uptime": "${UPTIME_HUMAN}",
  "uptime_sec": ${UPTIME_SEC},
  "load": "${LOAD}",
  "memory":   { "total_kb": ${MEM_TOTAL},  "used_kb": ${MEM_USED},  "percent": ${MEM_PCT} },
  "disk":     { "total_kb": ${DISK_TOTAL}, "used_kb": ${DISK_USED}, "percent": ${DISK_PCT} },
  "containers": {
    "pihole":        { "status": "${PIHOLE_STATUS}",   "health": "${PIHOLE_HEALTH}", "image": "${PIHOLE_IMAGE}", "started_at": "${PIHOLE_STARTED}", "restarts": ${PIHOLE_RESTARTS} },
    "recovery_site": { "status": "${RECOVERY_STATUS}", "image": "${RECOVERY_IMAGE}", "restarts": ${RECOVERY_RESTARTS} }
  },
  "dns": {
    "local_ok":        ${DNS_LOCAL},
    "local_ms":        ${DNS_LOCAL_TIME:-0},
    "upstream_cloudflare": ${UP_CLOUDFLARE},
    "upstream_quad9":      ${UP_QUAD9}
  },
  "pihole": {
    "queries_total":        ${QUERIES_TOTAL:-0},
    "queries_blocked":      ${QUERIES_BLOCKED:-0},
    "block_percent":        ${BLOCK_PERCENT:-0},
    "domains_blocked":      ${DOMAINS_BLOCKED:-0},
    "gravity_last_updated": "${GRAVITY_LAST}"
  },
  "sync": {
    "last_sync":      "${LAST_SYNC}",
    "last_sync_hash": "${LAST_SYNC_HASH}",
    "git_branch":     "${GIT_BRANCH}",
    "git_head":       "${GIT_HEAD}"
  },
  "recent_log": ${RECENT_LOG}
}
EOF
