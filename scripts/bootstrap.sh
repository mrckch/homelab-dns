#!/usr/bin/env bash
# DNS Homelab Bootstrap
#
# Two-phase bootstrap for a Debian 13 VM running DNS (Pi-hole) in Docker.
#
# Phase 1: TUI (whiptail) collects config, applies network. If IP changes,
#          a systemd oneshot service auto-runs Phase 2 after the network
#          comes back up. User just reconnects to the new IP.
#
# Phase 2: Fully non-interactive. Reads config from /etc/dns-bootstrap.conf,
#          installs Docker, clones repo, writes .env, starts containers,
#          configures cron, generates initial system status.
#
# Usage:
#   bootstrap.sh                  # interactive Phase 1, auto Phase 2
#   bootstrap.sh phase2           # run Phase 2 (used by systemd resume)
#
# Idempotent: every phase can be re-run without breaking anything.

set -euo pipefail

# ────────────────────────────── Constants ──────────────────────────────

readonly CONF_FILE="/etc/dns-bootstrap.conf"
readonly LOG_FILE="/var/log/dns-bootstrap.log"
readonly REPO_DIR="/opt/homelab-dns"
readonly LOCAL_BIN="/usr/local/sbin/dns-bootstrap"
readonly RESUME_SERVICE="/etc/systemd/system/dns-bootstrap-resume.service"

readonly SYNC_TOKEN_DIR="/etc/dns-sync"
readonly SYNC_TOKEN_FILE="${SYNC_TOKEN_DIR}/github.token"
readonly SYNC_LOG_DIR="/var/log/dns-sync"
readonly SYNC_STATE_DIR="/var/lib/dns-sync"
readonly DEPLOY_KEY_FILE="/root/.ssh/id_ed25519_homelab-dns"

# Legacy paths (migrated automatically if found)
readonly LEGACY_TOKEN_FILE="/etc/pihole-sync/github.token"
readonly LEGACY_LOG_DIR="/var/log/pihole-sync"
readonly LEGACY_STATE_DIR="/var/lib/pihole-sync"

# ────────────────────────────── Logging ──────────────────────────────

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%F %T')] $*"; }
die()  { echo "FEHLER: $*" >&2; exit 1; }

# ────────────────────────────── Pre-flight ──────────────────────────────

[[ $EUID -eq 0 ]] || die "Bitte als root ausfuehren: sudo $0 $*"

ensure_tools() {
    local need=()
    command -v whiptail >/dev/null || need+=(whiptail)
    command -v tmux     >/dev/null || need+=(tmux)
    command -v curl     >/dev/null || need+=(curl)
    command -v git      >/dev/null || need+=(git)
    command -v dig      >/dev/null || need+=(dnsutils)
    command -v jq       >/dev/null || need+=(jq)

    if [[ ${#need[@]} -gt 0 ]]; then
        log "Installiere benoetigte Pakete: ${need[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
    fi
}

migrate_legacy_paths() {
    if [[ -f "$LEGACY_TOKEN_FILE" && ! -f "$SYNC_TOKEN_FILE" ]]; then
        log "Migriere $LEGACY_TOKEN_FILE -> $SYNC_TOKEN_FILE"
        mkdir -p "$SYNC_TOKEN_DIR"
        mv "$LEGACY_TOKEN_FILE" "$SYNC_TOKEN_FILE"
        chmod 0600 "$SYNC_TOKEN_FILE"
    fi
    if [[ -d "$LEGACY_LOG_DIR" && ! -d "$SYNC_LOG_DIR" ]]; then
        log "Migriere $LEGACY_LOG_DIR -> $SYNC_LOG_DIR"
        mv "$LEGACY_LOG_DIR" "$SYNC_LOG_DIR"
    fi
    if [[ -d "$LEGACY_STATE_DIR" && ! -d "$SYNC_STATE_DIR" ]]; then
        log "Migriere $LEGACY_STATE_DIR -> $SYNC_STATE_DIR"
        mv "$LEGACY_STATE_DIR" "$SYNC_STATE_DIR"
    fi
    [[ -d "$LEGACY_TOKEN_FILE" ]] && rmdir "$(dirname "$LEGACY_TOKEN_FILE")" 2>/dev/null || true
}

# ────────────────────────────── Phase 1: TUI ──────────────────────────────

tui_welcome() {
    whiptail --backtitle "DNS Homelab Bootstrap" --title "Willkommen" --msgbox \
"Dieser Assistent richtet diese VM als DNS-Server (Pi-hole) ein.

Ablauf:
  Phase 1  Konfiguration & Netzwerk (jetzt, interaktiv)
  Phase 2  Installation & Setup (automatisch)

Bei IP-Wechsel laeuft Phase 2 nach dem Netzwerk-Switch
automatisch im Hintergrund weiter (systemd).

Voraussetzung:
  - Master:    GitHub PAT (haendisch oder hier eingeben)
  - Follower:  SSH Deploy-Key unter
               $DEPLOY_KEY_FILE
" 18 70
}

detect_existing_setup() {
    EXISTING_HOSTNAME="$(hostname 2>/dev/null || echo '')"
    EXISTING_PIHOLE_PW=""
    EXISTING_REPO_URL=""

    local env_file="$REPO_DIR/compose/.env"
    if [[ -f "$env_file" ]]; then
        EXISTING_PIHOLE_PW="$(grep '^FTLCONF_webserver_api_password=' "$env_file" 2>/dev/null \
            | head -1 | cut -d'=' -f2- || true)"
    fi

    if [[ -d "$REPO_DIR/.git" ]]; then
        EXISTING_REPO_URL="$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null \
            | sed -E 's|^https://[^@]*@||; s|^git@github.com:|github.com/|; s|\.git$||' \
            || true)"
    fi
}

tui_collect_config() {
    detect_existing_setup

    # ── Rolle (Default aus altem Hostnamen wenn moeglich) ──
    local role_default="master"
    case "$EXISTING_HOSTNAME" in
        pihole-a|dns1) role_default="master" ;;
        pihole-b|dns2) role_default="follower" ;;
    esac

    if [[ "$role_default" == "master" ]]; then
        ROLE=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "Rolle" \
            --notags --menu "Welche Rolle hat diese VM?\n\n(erkannt: $EXISTING_HOSTNAME)" 14 70 2 \
            "master"   "DNS1 - Schreib-Master (Quelle der Wahrheit)" \
            "follower" "DNS2 - Read-Only Follower" \
            3>&1 1>&2 2>&3) || die "Abgebrochen."
    else
        ROLE=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "Rolle" \
            --notags --menu "Welche Rolle hat diese VM?\n\n(erkannt: $EXISTING_HOSTNAME)" 14 70 2 \
            "follower" "DNS2 - Read-Only Follower" \
            "master"   "DNS1 - Schreib-Master (Quelle der Wahrheit)" \
            3>&1 1>&2 2>&3) || die "Abgebrochen."
    fi

    case "$ROLE" in
        master)   HOSTNAME="dns1" ;;
        follower) HOSTNAME="dns2" ;;
    esac

    # Migration-Hinweis bei alten Hostnames
    if [[ "$EXISTING_HOSTNAME" =~ ^pihole-[ab]$ ]]; then
        whiptail --backtitle "DNS Homelab Bootstrap" --title "Migration erkannt" --msgbox \
"Diese VM hat einen alten Hostnamen:
  $EXISTING_HOSTNAME  →  $HOSTNAME

Der Bootstrap migriert automatisch:
  - Hostname auf $HOSTNAME
  - .env-Variable PIHOLE_HOSTNAME auf DNS_HOSTNAME
  - Pfade /etc/pihole-sync → /etc/dns-sync
  - Container wird neu erzeugt (Daten bleiben erhalten)
" 16 70
    fi

    # ── Erkennung aktueller Werte ──
    local cur_ip cur_gw cur_iface
    cur_ip=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {print $2}' | head -1 | cut -d/ -f1)
    cur_gw=$(ip route | awk '/^default/{print $3; exit}')
    cur_iface=$(ip route | awk '/^default/{print $5; exit}')

    # ── IP ──
    IP=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "Statische IP" \
        --inputbox "Statische IP fuer ${HOSTNAME}\n\nAktuelle IP: ${cur_ip:-keine}" 12 70 \
        "${cur_ip:-192.168.1.10}" 3>&1 1>&2 2>&3) || die "Abgebrochen."

    # ── Gateway ──
    GATEWAY=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "Gateway" \
        --inputbox "Gateway (Router-IP):" 10 60 "${cur_gw:-192.168.1.1}" \
        3>&1 1>&2 2>&3) || die "Abgebrochen."

    # ── Interface ──
    IFACE=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "Netzwerk-Interface" \
        --inputbox "Netzwerk-Interface:" 10 60 "${cur_iface:-ens18}" \
        3>&1 1>&2 2>&3) || die "Abgebrochen."

    CIDR="24"

    # ── Repo ──
    REPO_URL=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "GitHub Repo" \
        --inputbox "Repository (Form: github.com/<user>/<repo>):" 10 70 \
        "${EXISTING_REPO_URL:-github.com/mrckch/homelab-dns}" 3>&1 1>&2 2>&3) || die "Abgebrochen."

    # ── Pi-hole Webpasswort ──
    if [[ -n "$EXISTING_PIHOLE_PW" && "$EXISTING_PIHOLE_PW" != "CHANGE_ME" ]]; then
        if whiptail --backtitle "DNS Homelab Bootstrap" --title "Pi-hole Passwort" \
            --yesno "Bestehendes Passwort in .env gefunden.\n\nUebernehmen oder neu setzen?" 10 70 \
            --yes-button "Uebernehmen" --no-button "Neu setzen"; then
            PIHOLE_PASSWORD="$EXISTING_PIHOLE_PW"
        else
            EXISTING_PIHOLE_PW=""
        fi
    fi
    while [[ -z "${PIHOLE_PASSWORD:-}" ]]; do
        local pw1 pw2
        pw1=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "Pi-hole Passwort" \
            --passwordbox "Web-Admin-Passwort fuer Pi-hole:\n(im Passwort-Manager speichern!)" 10 70 \
            3>&1 1>&2 2>&3) || die "Abgebrochen."
        pw2=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "Pi-hole Passwort" \
            --passwordbox "Passwort wiederholen:" 10 70 3>&1 1>&2 2>&3) || die "Abgebrochen."
        if [[ "$pw1" == "$pw2" && -n "$pw1" ]]; then
            PIHOLE_PASSWORD="$pw1"
        else
            whiptail --backtitle "DNS Homelab Bootstrap" --title "Fehler" \
                --msgbox "Passwoerter stimmen nicht ueberein oder leer." 8 60
        fi
    done

    # ── Master: PAT ──
    if [[ "$ROLE" == "master" ]]; then
        if [[ -s "$SYNC_TOKEN_FILE" ]]; then
            whiptail --backtitle "DNS Homelab Bootstrap" --title "GitHub PAT" \
                --msgbox "PAT bereits vorhanden unter\n${SYNC_TOKEN_FILE}\n\nWird wiederverwendet." 10 70
            GITHUB_PAT="$(tr -d '[:space:]' < "$SYNC_TOKEN_FILE")"
        else
            GITHUB_PAT=$(whiptail --backtitle "DNS Homelab Bootstrap" --title "GitHub PAT" \
                --passwordbox "Personal Access Token (Contents: Read+Write fuer das Repo):\n\nWird unter ${SYNC_TOKEN_FILE} (mode 0600) gespeichert." 12 70 \
                3>&1 1>&2 2>&3) || die "Abgebrochen."
            [[ -n "$GITHUB_PAT" ]] || die "PAT darf nicht leer sein."
        fi
    fi

    # ── Follower: Deploy-Key ──
    if [[ "$ROLE" == "follower" ]]; then
        if [[ ! -f "$DEPLOY_KEY_FILE" ]]; then
            whiptail --backtitle "DNS Homelab Bootstrap" --title "FEHLER" --msgbox \
"SSH Deploy-Key nicht gefunden:
  $DEPLOY_KEY_FILE

Bitte vor dem Start dort hinterlegen:

  mkdir -p /root/.ssh && chmod 0700 /root/.ssh
  nano $DEPLOY_KEY_FILE
  chmod 0600 $DEPLOY_KEY_FILE

Anschliessend bootstrap.sh erneut starten." 18 70
            exit 1
        fi
    fi

    # ── Bestaetigung ──
    whiptail --backtitle "DNS Homelab Bootstrap" --title "Bestaetigung" --yesno \
"Mit dieser Konfiguration fortfahren?

  Rolle:     $ROLE  ($HOSTNAME)
  IP:        $IP/$CIDR
  Gateway:   $GATEWAY
  Interface: $IFACE
  Repo:      $REPO_URL
" 16 70 || die "Abgebrochen."

    save_config
}

save_config() {
    umask 077
    cat > "$CONF_FILE" <<EOF
# Auto-generated by bootstrap.sh — DO NOT COMMIT
ROLE=$ROLE
HOSTNAME=$HOSTNAME
IP=$IP
GATEWAY=$GATEWAY
IFACE=$IFACE
CIDR=$CIDR
REPO_URL=$REPO_URL
PIHOLE_PASSWORD=$(printf '%q' "$PIHOLE_PASSWORD")
GITHUB_PAT=$(printf '%q' "${GITHUB_PAT:-}")
PHASE=1
EOF
    chmod 0600 "$CONF_FILE"
    log "Konfiguration gespeichert: $CONF_FILE"
}

# ────────────────────────────── Network ──────────────────────────────

apply_network() {
    log "Konfiguriere Netzwerk: $IP/$CIDR auf $IFACE, GW=$GATEWAY"

    # systemd-resolved deaktivieren (Port 53 freigeben)
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
    fi

    # dhcpcd deaktivieren falls aktiv
    if systemctl is-active --quiet dhcpcd 2>/dev/null; then
        systemctl stop dhcpcd
        systemctl disable dhcpcd
    fi

    # Statische resolv.conf
    [[ -e /etc/resolv.conf ]] && rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver $GATEWAY
nameserver 1.1.1.1
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # systemd-networkd config
    mkdir -p /etc/systemd/network
    local network_file="/etc/systemd/network/10-${IFACE}.network"
    local network_content
    network_content="[Match]
Name=${IFACE}

[Network]
Address=${IP}/${CIDR}
Gateway=${GATEWAY}
DNS=${GATEWAY}
DNS=1.1.1.1"

    if [[ ! -f "$network_file" ]] || [[ "$(cat "$network_file")" != "$network_content" ]]; then
        echo "$network_content" > "$network_file"
        systemctl enable systemd-networkd
        systemctl restart systemd-networkd
        log "systemd-networkd neu gestartet"
    else
        log "Netzwerk-Config unveraendert"
    fi
}

wait_for_dns() {
    local i=0 max=24
    log "Warte auf DNS-Verfuegbarkeit..."
    until dig +short +time=2 github.com @1.1.1.1 &>/dev/null; do
        if (( i >= max )); then
            die "DNS nach $((max * 5))s nicht erreichbar"
        fi
        sleep 5
        ((i++))
    done
    log "DNS bereit (nach $((i * 5))s)"
}

# ────────────────────────────── Resume Service ──────────────────────────────

install_resume_service() {
    # Skript an persistenten Ort kopieren
    install -m 0755 "${BASH_SOURCE[0]}" "$LOCAL_BIN"

    cat > "$RESUME_SERVICE" <<EOF
[Unit]
Description=DNS Homelab Bootstrap - Phase 2 Resume
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$LOCAL_BIN phase2
ExecStartPost=/bin/systemctl disable dns-bootstrap-resume.service
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
RemainAfterExit=no
TimeoutStartSec=20min

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dns-bootstrap-resume.service
    log "Resume-Service installiert: dns-bootstrap-resume.service"
}

# ────────────────────────────── Phase 2 Steps ──────────────────────────────

step_install_packages() {
    log "Installiere Basis-Pakete..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates gnupg dnsutils jq cron logrotate \
        unattended-upgrades apt-listchanges
}

step_set_hostname() {
    log "Setze Hostname auf $HOSTNAME"
    hostnamectl set-hostname "$HOSTNAME"
    if ! grep -qE "^[0-9.]+\s+$HOSTNAME(\s|$)" /etc/hosts; then
        echo "$IP $HOSTNAME" >> /etc/hosts
    fi
}

step_install_docker() {
    if command -v docker >/dev/null && docker info &>/dev/null; then
        log "Docker bereits installiert"
        return 0
    fi
    log "Installiere Docker CE..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    local arch codename
    arch=$(dpkg --print-architecture)
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable
EOF

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    systemctl enable --now docker
    log "Docker $(docker --version) installiert"
}

step_save_secrets() {
    # PAT (master)
    if [[ "$ROLE" == "master" && -n "${GITHUB_PAT:-}" ]]; then
        mkdir -p "$SYNC_TOKEN_DIR"
        printf '%s\n' "$GITHUB_PAT" > "$SYNC_TOKEN_FILE"
        chmod 0600 "$SYNC_TOKEN_FILE"
        chown root:root "$SYNC_TOKEN_FILE"
    fi

    # SSH config (follower)
    if [[ "$ROLE" == "follower" ]]; then
        mkdir -p /root/.ssh
        chmod 0700 /root/.ssh
        if [[ ! -f /root/.ssh/config ]] || ! grep -q "homelab-dns" /root/.ssh/config; then
            cat > /root/.ssh/config <<EOF
Host github.com
    IdentityFile $DEPLOY_KEY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
            chmod 0600 /root/.ssh/config
        fi
    fi
}

step_clone_repo() {
    mkdir -p "$REPO_DIR"

    if [[ -d "$REPO_DIR/.git" ]]; then
        log "Repo existiert, ziehe aktuelle Aenderungen..."
        cd "$REPO_DIR"
        git_with_retry reset --hard HEAD
        git_with_retry pull --ff-only
        return 0
    fi

    log "Klone Repository..."
    if [[ "$ROLE" == "master" ]]; then
        local pat clean_repo https_url clean_url
        pat="$(tr -d '[:space:]' < "$SYNC_TOKEN_FILE")"
        clean_repo="${REPO_URL#https://}"
        clean_repo="${clean_repo#http://}"
        https_url="https://${pat}@${clean_repo}.git"
        clean_url="https://${clean_repo}.git"

        git clone "$https_url" "$REPO_DIR"
        cd "$REPO_DIR"
        git config user.name "dns-sync"
        git config user.email "dns-sync@homelab.local"
        git remote set-url origin "$clean_url"
        git config credential.helper store
        echo "https://pat:${pat}@github.com" > /root/.git-credentials
        chmod 0600 /root/.git-credentials
    else
        local ssh_url
        ssh_url="git@github.com:${REPO_URL#*github.com/}.git"
        ssh_url="${ssh_url%.git.git}.git"
        GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
            git clone "$ssh_url" "$REPO_DIR"
        cd "$REPO_DIR"
        git config user.name "dns-sync"
        git config user.email "dns-sync@homelab.local"
        git config core.sshCommand "ssh -i $DEPLOY_KEY_FILE -o IdentitiesOnly=yes"
    fi
}

git_with_retry() {
    local i=0 max=5
    until git "$@"; do
        if (( i >= max )); then
            die "git $* nach $max Versuchen fehlgeschlagen"
        fi
        log "git $* fehlgeschlagen — warte 5s (${i}/${max})"
        sleep 5
        ((i++))
    done
}

step_write_env() {
    local env_file="$REPO_DIR/compose/.env"
    local env_example="$REPO_DIR/compose/.env.example"

    [[ -f "$env_example" ]] || die "Vorlage fehlt: $env_example"

    cp "$env_example" "$env_file"
    sed -i "s|^DNS_HOSTNAME=.*|DNS_HOSTNAME=${HOSTNAME}|"           "$env_file"
    sed -i "s|^FTLCONF_LOCAL_IPV4=.*|FTLCONF_LOCAL_IPV4=${IP}|"     "$env_file"
    # Passwort safe escapen via env-style
    {
        grep -v '^FTLCONF_webserver_api_password=' "$env_file"
        printf 'FTLCONF_webserver_api_password=%s\n' "$PIHOLE_PASSWORD"
    } > "${env_file}.tmp" && mv "${env_file}.tmp" "$env_file"
    chmod 0600 "$env_file"
    log ".env geschrieben"
}

step_setup_unattended() {
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

step_setup_dirs_cron() {
    mkdir -p "$SYNC_LOG_DIR" "$SYNC_STATE_DIR"
    if [[ -f "$REPO_DIR/scripts/setup-cron.sh" ]]; then
        bash "$REPO_DIR/scripts/setup-cron.sh"
    fi

    cat > /etc/logrotate.d/dns-sync <<EOF
$SYNC_LOG_DIR/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
}

step_start_containers() {
    log "Starte Docker-Container..."
    cd "$REPO_DIR/compose"

    # Bei vorhandenem Container pruefen ob Hostname-Aenderung -> recreate
    local existing_host=""
    if docker ps -a --format '{{.Names}}' | grep -q '^pihole$'; then
        existing_host="$(docker inspect --format '{{.Config.Hostname}}' pihole 2>/dev/null || echo '')"
    fi

    if [[ -n "$existing_host" && "$existing_host" != "$HOSTNAME" ]]; then
        log "Container-Hostname '$existing_host' != gewuenscht '$HOSTNAME' — recreate"
        docker compose up -d --force-recreate
    else
        docker compose up -d
    fi
}

step_initial_status() {
    if [[ -x "$REPO_DIR/scripts/update-site-info.sh" ]]; then
        log "Generiere initiale Statusdaten..."
        "$REPO_DIR/scripts/update-site-info.sh" || true
    fi
}

step_verify_dns() {
    log "Pruefe DNS-Aufloesung..."
    sleep 10
    if dig @127.0.0.1 example.com +short +time=3 &>/dev/null; then
        log "DNS funktioniert"
    else
        log "WARNUNG: DNS-Test fehlgeschlagen — docker compose logs pihole pruefen"
    fi
}

# ────────────────────────────── Phase 2 ──────────────────────────────

run_phase2() {
    [[ -f "$CONF_FILE" ]] || die "Konfiguration fehlt: $CONF_FILE"
    # shellcheck source=/dev/null
    source "$CONF_FILE"

    log "════════════════════════════════════════════"
    log "Phase 2: Setup für $HOSTNAME (Rolle: $ROLE)"
    log "════════════════════════════════════════════"

    wait_for_dns
    step_install_packages
    step_set_hostname
    step_install_docker
    step_save_secrets
    step_clone_repo
    step_write_env
    step_setup_unattended
    step_setup_dirs_cron
    step_start_containers
    step_initial_status
    step_verify_dns

    # Conf bereinigen — Passwort/PAT sollen nicht dauerhaft auf Disk liegen
    rm -f "$CONF_FILE"
    rm -f "$RESUME_SERVICE" 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true

    show_completion
}

show_completion() {
    local tui_or_log
    if [[ -t 0 ]] && command -v whiptail >/dev/null; then
        local sync_cmd
        if [[ "$ROLE" == "master" ]]; then
            sync_cmd="$REPO_DIR/scripts/teleporter-export.sh"
        else
            sync_cmd="$REPO_DIR/scripts/teleporter-import.sh"
        fi
        whiptail --backtitle "DNS Homelab Bootstrap" --title "Fertig!" --msgbox \
"Setup abgeschlossen — $HOSTNAME laeuft.

Admin-UI:        http://$IP/admin
Dashboard:       http://$IP:8080
Operations:      http://$IP:8080/ops.html

Sync manuell:    $sync_cmd
Logs:            tail -f $LOG_FILE
" 18 70
    fi

    log "════════════════════════════════════════════"
    log "Bootstrap abgeschlossen — $HOSTNAME laeuft"
    log "  Admin-UI:  http://$IP/admin"
    log "  Dashboard: http://$IP:8080"
    log "════════════════════════════════════════════"
}

# ────────────────────────────── Phase 1 ──────────────────────────────

run_phase1() {
    ensure_tools
    migrate_legacy_paths
    tui_welcome
    tui_collect_config

    local cur_ip
    cur_ip=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {print $2}' | head -1 | cut -d/ -f1)

    apply_network

    if [[ "$cur_ip" != "$IP" ]]; then
        # IP wechselt — Resume-Service aufsetzen
        sed -i 's/^PHASE=.*/PHASE=2/' "$CONF_FILE"
        install_resume_service

        whiptail --backtitle "DNS Homelab Bootstrap" --title "IP-Wechsel" --msgbox \
"Die IP wechselt von $cur_ip nach $IP.

Phase 2 laeuft NACH dem IP-Wechsel automatisch
weiter (systemd-Service: dns-bootstrap-resume).

Naechste Schritte:
  1. Diese SSH-Session schliessen
  2. Ca. 30 Sekunden warten
  3. Per SSH zur neuen IP verbinden:  ssh root@$IP
  4. Logs verfolgen:  tail -f $LOG_FILE

Nach ~3 Min sollte $HOSTNAME komplett laufen.
" 20 70

        log "Phase 1 fertig — IP wechselt, Phase 2 via systemd"
        # Trigger network change
        systemctl restart systemd-networkd
        exit 0
    fi

    # IP unveraendert — Phase 2 inline ausfuehren
    sed -i 's/^PHASE=.*/PHASE=2/' "$CONF_FILE"
    whiptail --backtitle "DNS Homelab Bootstrap" --title "Phase 2" \
        --msgbox "IP unveraendert.\nPhase 2 startet jetzt direkt." 8 60
    run_phase2
}

# ────────────────────────────── Main ──────────────────────────────

case "${1:-}" in
    phase2)
        run_phase2
        ;;
    "")
        # Detect: laufender resume-Service oder erste Ausfuehrung?
        if [[ -f "$CONF_FILE" ]]; then
            # shellcheck source=/dev/null
            source "$CONF_FILE"
            if [[ "${PHASE:-1}" == "2" ]]; then
                log "Vorhandene Phase-2-Konfiguration erkannt — fahre fort."
                run_phase2
                exit 0
            fi
        fi
        run_phase1
        ;;
    *)
        die "Unbekanntes Argument: $1 (erlaubt: phase2)"
        ;;
esac
