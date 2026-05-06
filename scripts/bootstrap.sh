#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a Debian 13 VM as Pi-hole A (master) or Pi-hole B (follower).
# Idempotent: can be run multiple times without breaking the system.
#
# Usage:
#   bootstrap.sh --role=a --ip=192.168.1.10 --gateway=192.168.1.1
#   bootstrap.sh --role=b --ip=192.168.1.11 --gateway=192.168.1.1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="/opt/homelab-dns"
LOG_DIR="/var/log/pihole-sync"
SYNC_STATE_DIR="/var/lib/pihole-sync"
GITHUB_TOKEN_FILE="/etc/pihole-sync/github.token"
DEPLOY_KEY_FILE="/root/.ssh/id_ed25519_homelab-dns"

# --- Argument Parsing ---

ROLE=""
IP=""
GATEWAY=""
IFACE="eth0"
CIDR="24"
REPO_URL=""

usage() {
    echo "Usage: $0 --role=a|b --ip=x.x.x.x --gateway=x.x.x.x [--iface=eth0] [--cidr=24] [--repo=<git-url>]"
    echo ""
    echo "  --role       a (master) or b (follower)"
    echo "  --ip         Static IP for this VM"
    echo "  --gateway    Default gateway (router IP)"
    echo "  --iface      Network interface (default: eth0)"
    echo "  --cidr       Subnet prefix length (default: 24)"
    echo "  --repo       Git repository URL (overrides auto-detection)"
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --role=*)   ROLE="${arg#*=}" ;;
        --ip=*)     IP="${arg#*=}" ;;
        --gateway=*) GATEWAY="${arg#*=}" ;;
        --iface=*)  IFACE="${arg#*=}" ;;
        --cidr=*)   CIDR="${arg#*=}" ;;
        --repo=*)   REPO_URL="${arg#*=}" ;;
        *)          echo "Unknown argument: $arg"; usage ;;
    esac
done

if [[ -z "$ROLE" || -z "$IP" || -z "$GATEWAY" ]]; then
    echo "ERROR: --role, --ip, and --gateway are required."
    usage
fi

if [[ "$ROLE" != "a" && "$ROLE" != "b" ]]; then
    echo "ERROR: --role must be 'a' or 'b'."
    usage
fi

log() { echo "[bootstrap] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

HOSTNAME="pihole-${ROLE}"

# --- Pre-flight: Secrets Check ---

if [[ "$ROLE" == "a" ]]; then
    if [[ ! -f "$GITHUB_TOKEN_FILE" ]]; then
        echo "ERROR: GitHub PAT not found at $GITHUB_TOKEN_FILE"
        echo ""
        echo "Before running this script, create the token file:"
        echo "  mkdir -p /etc/pihole-sync"
        echo "  echo 'ghp_your_token_here' > $GITHUB_TOKEN_FILE"
        echo "  chmod 0600 $GITHUB_TOKEN_FILE"
        echo "  chown root:root $GITHUB_TOKEN_FILE"
        exit 1
    fi
    if [[ ! -s "$GITHUB_TOKEN_FILE" ]]; then
        echo "ERROR: $GITHUB_TOKEN_FILE exists but is empty."
        exit 1
    fi
fi

if [[ "$ROLE" == "b" ]]; then
    if [[ ! -f "$DEPLOY_KEY_FILE" ]]; then
        echo "ERROR: SSH deploy key not found at $DEPLOY_KEY_FILE"
        echo ""
        echo "Before running this script, create the key file:"
        echo "  mkdir -p /root/.ssh && chmod 0700 /root/.ssh"
        echo "  <paste private key into $DEPLOY_KEY_FILE>"
        echo "  chmod 0600 $DEPLOY_KEY_FILE"
        echo ""
        echo "Also configure SSH for GitHub:"
        echo "  cat > /root/.ssh/config << 'EOF'"
        echo "Host github.com"
        echo "    IdentityFile $DEPLOY_KEY_FILE"
        echo "    IdentitiesOnly yes"
        echo "    StrictHostKeyChecking accept-new"
        echo "EOF"
        echo "  chmod 0600 /root/.ssh/config"
        exit 1
    fi
fi

# --- Step 1: Install minimal packages ---

log "Installing base packages..."
apt-get update
apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    gnupg \
    dnsutils \
    jq \
    cron \
    logrotate \
    unattended-upgrades \
    apt-listchanges

# --- Step 2: Disable systemd-resolved (free port 53) ---

log "Disabling systemd-resolved..."
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
fi

if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
fi

cat > /etc/resolv.conf <<EOF
nameserver ${GATEWAY}
nameserver 1.1.1.1
EOF

log "systemd-resolved disabled. Using gateway and 1.1.1.1 for bootstrap DNS."

# --- Step 3: Configure static IP via systemd-networkd ---

log "Configuring static IP ${IP}/${CIDR} on ${IFACE}..."

mkdir -p /etc/systemd/network

cat > "/etc/systemd/network/10-${IFACE}.network" <<EOF
[Match]
Name=${IFACE}

[Network]
Address=${IP}/${CIDR}
Gateway=${GATEWAY}
DNS=${GATEWAY}
DNS=1.1.1.1
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd

log "Waiting for network to stabilise..."
sleep 5

# --- Step 4: Set hostname ---

log "Setting hostname to ${HOSTNAME}..."
hostnamectl set-hostname "${HOSTNAME}"

if ! grep -q "${HOSTNAME}" /etc/hosts; then
    echo "${IP} ${HOSTNAME}" >> /etc/hosts
fi

# --- Step 5: Install Docker ---

log "Installing Docker..."
if [[ -f "${SCRIPT_DIR}/install-docker.sh" ]]; then
    bash "${SCRIPT_DIR}/install-docker.sh"
else
    # Strip leading "github.com/" from REPO_URL to build raw URL correctly
    RAW_REPO="${REPO_URL#*github.com/}"
    curl -fsSL "https://raw.githubusercontent.com/${RAW_REPO:-mrckch/homelab-dns}/main/scripts/install-docker.sh" \
        -o /tmp/install-docker.sh
    bash /tmp/install-docker.sh
    rm -f /tmp/install-docker.sh
fi

# --- Step 6: Clone repository ---

log "Setting up repository at ${REPO_DIR}..."
mkdir -p "${REPO_DIR}"

if [[ -d "${REPO_DIR}/.git" ]]; then
    log "Repository already exists, pulling latest changes..."
    cd "${REPO_DIR}"
    git pull
else
    if [[ "$ROLE" == "a" ]]; then
        PAT="$(cat "$GITHUB_TOKEN_FILE" | tr -d '[:space:]')"
        if [[ -n "$REPO_URL" ]]; then
            CLONE_URL="${REPO_URL}"
        else
            echo "ERROR: --repo is required for initial clone."
            echo "Usage: --repo=github.com/mrckch/homelab-dns"
            echo "The PAT will be injected automatically for HTTPS clone."
            exit 1
        fi
        HTTPS_URL="https://${PAT}@${REPO_URL#https://}"
        git clone "${HTTPS_URL}" "${REPO_DIR}"

        cd "${REPO_DIR}"
        git config user.name "pihole-sync"
        git config user.email "pihole-sync@homelab.local"

        CLEAN_URL="https://${REPO_URL#https://}"
        git remote set-url origin "${CLEAN_URL}"

        git config credential.helper store
        echo "https://pat:${PAT}@github.com" > /root/.git-credentials
        chmod 0600 /root/.git-credentials
    fi

    if [[ "$ROLE" == "b" ]]; then
        if [[ -n "$REPO_URL" ]]; then
            SSH_URL="git@github.com:${REPO_URL#*github.com/}"
            SSH_URL="${SSH_URL%.git}.git"
        else
            echo "ERROR: --repo is required for initial clone."
            echo "Usage: --repo=github.com/mrckch/homelab-dns"
            exit 1
        fi
        GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY_FILE} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
            git clone "${SSH_URL}" "${REPO_DIR}"

        cd "${REPO_DIR}"
        git config user.name "pihole-sync"
        git config user.email "pihole-sync@homelab.local"
        git config core.sshCommand "ssh -i ${DEPLOY_KEY_FILE} -o IdentitiesOnly=yes"
    fi
fi

# --- Step 7: Create .env from example ---

ENV_FILE="${REPO_DIR}/compose/.env"
ENV_EXAMPLE="${REPO_DIR}/compose/.env.example"

if [[ ! -f "$ENV_FILE" ]]; then
    log "Creating .env from .env.example..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"

    sed -i "s|^PIHOLE_HOSTNAME=.*|PIHOLE_HOSTNAME=${HOSTNAME}|" "$ENV_FILE"
    sed -i "s|^FTLCONF_LOCAL_IPV4=.*|FTLCONF_LOCAL_IPV4=${IP}|" "$ENV_FILE"

    chmod 0600 "$ENV_FILE"

    log "IMPORTANT: Edit ${ENV_FILE} and set FTLCONF_webserver_api_password!"
else
    log ".env already exists, skipping."
fi

# --- Step 8: Configure unattended-upgrades (security only) ---

log "Configuring unattended-upgrades..."
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

# --- Step 9: Setup cron and log directories ---

log "Setting up directories and cron..."
mkdir -p "$LOG_DIR"
mkdir -p "$SYNC_STATE_DIR"

if [[ -f "${REPO_DIR}/scripts/setup-cron.sh" ]]; then
    bash "${REPO_DIR}/scripts/setup-cron.sh"
fi

# --- Step 10: Setup logrotate for sync logs ---

cat > /etc/logrotate.d/pihole-sync <<'EOF'
/var/log/pihole-sync/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# --- Done ---

log "=========================================="
log "Bootstrap complete for ${HOSTNAME} (role=${ROLE})"
log "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit the .env file with your Pi-hole web password:"
echo "     nano ${REPO_DIR}/compose/.env"
echo ""
echo "  2. Start Pi-hole:"
echo "     cd ${REPO_DIR}/compose && docker compose up -d"
echo ""
echo "  3. Verify DNS is working:"
echo "     dig @127.0.0.1 example.com"
echo ""
echo "  4. Access Pi-hole Admin UI:"
echo "     http://${IP}/admin"
echo ""
echo "  5. Access Recovery Site:"
echo "     http://${IP}:8080"
echo ""
if [[ "$ROLE" == "a" ]]; then
    echo "  6. Configure your adlists, whitelist, and settings in the Admin UI."
    echo "     This is the MASTER instance — all changes go here."
    echo ""
    echo "  7. Test the export sync:"
    echo "     ${REPO_DIR}/scripts/teleporter-export.sh"
fi
if [[ "$ROLE" == "b" ]]; then
    echo "  6. The nightly import sync will run automatically at 03:30."
    echo "     To test manually:"
    echo "     ${REPO_DIR}/scripts/teleporter-import.sh"
fi
