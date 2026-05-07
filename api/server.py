"""DNS Homelab Management API.

Runs as a systemd service on the host. Listens on 127.0.0.1:8088.
Caddy in the recovery-site container proxies /api/* to this service.

Auth: optional HTTP Basic. If RECOVERY_PASSWORD_HASH is set in .env,
all endpoints (except /api/auth/status) require valid credentials.
The set-password endpoint accepts the current password in the request
body so a brand-new VM can configure auth via the UI.
"""

from __future__ import annotations

import os
import re
import socket
import subprocess
from pathlib import Path
from typing import Any, Optional

import bcrypt
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from pydantic import BaseModel

# ── Paths ──
REPO_DIR = Path("/opt/homelab-dns")
COMPOSE_DIR = REPO_DIR / "compose"
ENV_FILE = Path(os.environ.get("ENV_FILE", str(COMPOSE_DIR / ".env")))
AUTH_SNIPPET = COMPOSE_DIR / "auth.snippet"

# ── App ──
app = FastAPI(title="DNS Homelab API", version="1.0")
security = HTTPBasic(auto_error=False)


# ────────────────── Helpers ──────────────────

def read_env(key: str) -> Optional[str]:
    if not ENV_FILE.exists():
        return None
    pat = re.compile(rf"^{re.escape(key)}=(.*)$")
    for line in ENV_FILE.read_text().splitlines():
        m = pat.match(line)
        if m:
            return m.group(1)
    return None


def write_env(key: str, value: str) -> None:
    pat = re.compile(rf"^{re.escape(key)}=")
    lines = ENV_FILE.read_text().splitlines() if ENV_FILE.exists() else []
    found = False
    for i, line in enumerate(lines):
        if pat.match(line):
            lines[i] = f"{key}={value}"
            found = True
    if not found:
        lines.append(f"{key}={value}")
    ENV_FILE.write_text("\n".join(lines) + "\n")
    ENV_FILE.chmod(0o600)


def auth_enabled() -> bool:
    h = read_env("RECOVERY_PASSWORD_HASH") or ""
    return bool(h.strip())


def verify_password(plain: str) -> bool:
    stored = read_env("RECOVERY_PASSWORD_HASH") or ""
    if not stored.strip():
        return False
    try:
        return bcrypt.checkpw(plain.encode(), stored.encode())
    except Exception:
        return False


def require_auth(creds: Optional[HTTPBasicCredentials] = Depends(security)) -> None:
    if not auth_enabled():
        return
    if creds is None or not verify_password(creds.password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Basic"},
        )


def run_cmd(cmd, cwd: Optional[str] = None, timeout: int = 60, shell: bool = False) -> dict:
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            cwd=cwd, shell=shell,
        )
        return {
            "ok": proc.returncode == 0,
            "code": proc.returncode,
            "stdout": (proc.stdout or "")[-6000:],
            "stderr": (proc.stderr or "")[-6000:],
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "code": -1, "stdout": "", "stderr": f"Timeout nach {timeout}s"}
    except Exception as e:
        return {"ok": False, "code": -1, "stdout": "", "stderr": str(e)}


# ────────────────── Action catalog ──────────────────

ACTIONS: dict[str, dict[str, Any]] = {
    "restart-pihole": {
        "label": "Pi-hole neu starten",
        "category": "container",
        "cmd": ["docker", "compose", "restart", "pihole"],
        "cwd": str(COMPOSE_DIR),
        "timeout": 60,
    },
    "restart-recovery": {
        "label": "Recovery-Site neu starten",
        "category": "container",
        "cmd": ["docker", "compose", "restart", "recovery-site"],
        "cwd": str(COMPOSE_DIR),
        "timeout": 30,
    },
    "restart-all": {
        "label": "Alle Container neu starten",
        "category": "container",
        "cmd": ["docker", "compose", "restart"],
        "cwd": str(COMPOSE_DIR),
        "timeout": 120,
    },
    "recreate-all": {
        "label": "Alle Container neu erzeugen",
        "category": "container",
        "cmd": ["docker", "compose", "up", "-d", "--force-recreate"],
        "cwd": str(COMPOSE_DIR),
        "timeout": 240,
    },
    "pull-images": {
        "label": "Container-Images aktualisieren",
        "category": "container",
        "cmd": ["sh", "-c", "docker compose pull && docker compose up -d"],
        "cwd": str(COMPOSE_DIR),
        "timeout": 600,
    },
    "update-gravity": {
        "label": "Pi-hole Gravity aktualisieren",
        "category": "pihole",
        "cmd": ["docker", "exec", "pihole", "pihole", "-g"],
        "timeout": 600,
    },
    "run-sync": {
        "label": "Sync jetzt ausfuehren",
        "category": "sync",
        "dynamic": True,
        "timeout": 120,
    },
    "git-pull": {
        "label": "Repo aktualisieren",
        "category": "system",
        "cmd": ["git", "pull", "--ff-only"],
        "cwd": str(REPO_DIR),
        "timeout": 60,
    },
    "refresh-status": {
        "label": "Status-Daten neu berechnen",
        "category": "system",
        "cmd": [str(REPO_DIR / "scripts" / "update-site-info.sh")],
        "timeout": 60,
    },
    "apt-list-upgradable": {
        "label": "Verfuegbare Updates anzeigen",
        "category": "debian",
        "cmd": ["sh", "-c", "apt-get update -qq && apt list --upgradable 2>/dev/null"],
        "timeout": 180,
    },
    "apt-upgrade-security": {
        "label": "Debian: Sicherheits-Updates installieren",
        "category": "debian",
        "cmd": ["sh", "-c",
                "DEBIAN_FRONTEND=noninteractive apt-get update -qq && "
                "DEBIAN_FRONTEND=noninteractive unattended-upgrade -v"],
        "timeout": 1800,
    },
    "apt-upgrade-all": {
        "label": "Debian: Alle Updates installieren",
        "category": "debian",
        "cmd": ["sh", "-c",
                "DEBIAN_FRONTEND=noninteractive apt-get update -qq && "
                "DEBIAN_FRONTEND=noninteractive apt-get -y "
                "-o Dpkg::Options::='--force-confold' upgrade"],
        "timeout": 1800,
    },
    "apt-autoremove": {
        "label": "Debian: Nicht mehr benoetigte Pakete entfernen",
        "category": "debian",
        "cmd": ["sh", "-c", "DEBIAN_FRONTEND=noninteractive apt-get -y autoremove"],
        "timeout": 300,
    },
    "reboot": {
        "label": "VM neu starten",
        "category": "system-danger",
        "cmd": ["sh", "-c", "(sleep 3 && systemctl reboot) &"],
        "timeout": 10,
    },
}


def resolve_dynamic_cmd(name: str) -> tuple[list, Optional[str]]:
    if name == "run-sync":
        host = socket.gethostname()
        if host == "dns1":
            return ([str(REPO_DIR / "scripts" / "teleporter-export.sh")], None)
        if host == "dns2":
            return ([str(REPO_DIR / "scripts" / "teleporter-import.sh")], None)
        raise HTTPException(500, f"Unbekannter Hostname '{host}' fuer run-sync")
    raise HTTPException(500, f"Keine dynamische cmd-Aufloesung fuer '{name}'")


# ────────────────── Endpoints ──────────────────

@app.get("/api/health")
def health():
    return {
        "status": "ok",
        "auth_enabled": auth_enabled(),
        "hostname": socket.gethostname(),
    }


@app.get("/api/auth/status")
def auth_status():
    return {"enabled": auth_enabled()}


@app.post("/api/auth/check")
def auth_check(_: None = Depends(require_auth)):
    return {"ok": True}


class SetPasswordRequest(BaseModel):
    new: str
    current: Optional[str] = None


@app.post("/api/auth/set-password")
def auth_set_password(payload: SetPasswordRequest):
    if not payload.new or len(payload.new) < 6:
        raise HTTPException(400, "Passwort zu kurz (min. 6 Zeichen)")

    # Wenn Auth bereits aktiv: aktuelles Passwort verifizieren
    if auth_enabled():
        if not payload.current or not verify_password(payload.current):
            raise HTTPException(401, "Aktuelles Passwort ungueltig")

    # Neuen bcrypt-Hash erzeugen (kompatibel mit Caddy)
    hashed = bcrypt.hashpw(payload.new.encode(), bcrypt.gensalt(rounds=10)).decode()

    # In .env schreiben
    write_env("RECOVERY_PASSWORD_HASH", hashed)

    # Caddy auth.snippet regenerieren
    AUTH_SNIPPET.write_text(
        f"# auto-generated by API set-password\n"
        f"basic_auth /* {{\n\tadmin {hashed}\n}}\n"
    )

    # Caddy live reload
    reload_result = run_cmd(
        ["docker", "exec", "recovery-site", "caddy", "reload",
         "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"],
        timeout=30,
    )

    return {"ok": True, "reload": reload_result}


class DisablePasswordRequest(BaseModel):
    current: str


@app.post("/api/auth/disable")
def auth_disable(payload: DisablePasswordRequest):
    if not auth_enabled():
        return {"ok": True, "noop": True}
    if not verify_password(payload.current):
        raise HTTPException(401, "Aktuelles Passwort ungueltig")

    write_env("RECOVERY_PASSWORD_HASH", "")
    AUTH_SNIPPET.write_text(
        "# auth disabled\n"
    )
    reload_result = run_cmd(
        ["docker", "exec", "recovery-site", "caddy", "reload",
         "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"],
        timeout=30,
    )
    return {"ok": True, "reload": reload_result}


@app.get("/api/actions")
def list_actions(_: None = Depends(require_auth)):
    return {
        name: {"label": meta["label"], "category": meta.get("category", "misc")}
        for name, meta in ACTIONS.items()
    }


@app.post("/api/actions/{name}")
def run_action(name: str, _: None = Depends(require_auth)):
    if name not in ACTIONS:
        raise HTTPException(404, f"Unbekannte Aktion: {name}")

    meta = ACTIONS[name]

    if meta.get("dynamic"):
        cmd, cwd = resolve_dynamic_cmd(name)
    else:
        cmd = meta["cmd"]
        cwd = meta.get("cwd")

    return {
        "action": name,
        "label": meta["label"],
        **run_cmd(cmd, cwd=cwd, timeout=meta.get("timeout", 60)),
    }
