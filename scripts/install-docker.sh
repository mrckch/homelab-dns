#!/usr/bin/env bash
set -euo pipefail

# Install Docker CE and docker-compose-plugin from the official Docker repository.
# Idempotent: skips installation if Docker is already present and functional.

log() { echo "[install-docker] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

if command -v docker &>/dev/null && docker info &>/dev/null; then
    log "Docker is already installed and running."
    docker --version
    docker compose version
    exit 0
fi

log "Installing prerequisites..."
apt-get update
apt-get install -y ca-certificates curl gnupg

log "Adding Docker GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

log "Adding Docker APT repository..."
arch=$(dpkg --print-architecture)
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable
EOF

log "Installing Docker CE and compose plugin..."
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

log "Configuring Docker daemon (log rotation)..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
EOF

log "Enabling and starting Docker..."
systemctl enable docker
systemctl start docker

log "Docker installation complete."
docker --version
docker compose version
