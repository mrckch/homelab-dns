# Recovery-Anleitung

## Voraussetzungen

Fuer jedes Recovery-Szenario werden folgende Informationen benoetigt:
- Zugang zum Passwort-Manager (Pi-hole Webpasswort, GitHub PAT, SSH Deploy-Key)
- SSH-Zugang zum betroffenen Host oder zur VM
- Zugang zur Proxmox-Weboberflaeche des betroffenen Hosts

## Szenario 1: Pi-hole-Container kaputt, VM laeuft

**Symptom**: Pi-hole-Admin-UI nicht erreichbar, aber SSH zur VM funktioniert.

**Erwartete Dauer**: 2-5 Minuten

### Schritt-fuer-Schritt

```bash
# 1. Auf der betroffenen VM einloggen
ssh root@<VM-IP>

# 2. Container-Status pruefen
cd /opt/homelab-dns/compose
docker compose ps
docker compose logs --tail=50 pihole

# 3. Container neu starten
docker compose down
docker compose up -d

# 4. Warten bis Healthcheck gruen ist (ca. 30 Sekunden)
sleep 30
docker compose ps

# 5. DNS testen
dig @127.0.0.1 example.com

# 6. Admin-UI pruefen
# Im Browser: http://<VM-IP>/admin
```

### Falls der Container nicht startet

```bash
# Logs auf Fehler pruefen
docker compose logs pihole

# Haeufige Ursachen:
# - Port 53 belegt: lsof -i :53
# - Volume-Berechtigungen: ls -la /opt/homelab-dns/compose/etc-pihole/
# - Image korrupt: docker compose pull && docker compose up -d
```

---

## Szenario 2: VM kaputt, Host laeuft

**Symptom**: VM nicht erreichbar, Proxmox-Host reagiert aber normal.

**Erwartete Dauer**: 10-30 Minuten

### Option A: VM aus NAS-Snapshot wiederherstellen

```bash
# 1. Auf dem Proxmox-Host einloggen (Webinterface oder SSH)

# 2. Defekte VM entfernen (ID anpassen)
qm destroy <VM-ID> --purge

# 3. Snapshot vom NAS wiederherstellen
# (Befehl abhaengig von der Backup-Loesung, z.B. PBS oder manuell)
# Beispiel fuer PBS:
qmrestore <BACKUP-PFAD> <VM-ID>

# 4. VM starten
qm start <VM-ID>

# 5. SSH-Zugang testen
ssh root@<VM-IP>

# 6. Pi-hole-Container pruefen
cd /opt/homelab-dns/compose
docker compose ps
dig @127.0.0.1 example.com
```

### Option B: VM komplett neu aufsetzen

Wenn kein Snapshot verfuegbar ist oder der Snapshot zu alt ist:

```bash
# 1. Neue Debian-12-VM in Proxmox erstellen
#    - 2 vCPU, 2 GB RAM, 16 GB Disk
#    - Netzwerk: Default Bridge (vmbr0)
#    - Debian 13 Minimal installieren

# 2. Nach Installation: per SSH einloggen
ssh root@<VM-IP>

# 3. Secrets hinterlegen (siehe Abschnitt unten)

# 4. Bootstrap ausfuehren
curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/scripts/bootstrap.sh \
  -o /tmp/bootstrap.sh
chmod +x /tmp/bootstrap.sh

# Fuer Pi-hole A (Master):
/tmp/bootstrap.sh --role=a --ip=192.168.1.10 --gateway=192.168.1.1

# Fuer Pi-hole B (Follower):
/tmp/bootstrap.sh --role=b --ip=192.168.1.11 --gateway=192.168.1.1

# 5. .env-Datei ergaenzen
cd /opt/homelab-dns/compose
nano .env
# FTLCONF_webserver_api_password aus Passwort-Manager eintragen
# IP-Adressen pruefen

# 6. Pi-hole starten
docker compose up -d

# 7. Sanity-Checks durchfuehren (siehe unten)
```

---

## Szenario 3: Host komplett tot

**Symptom**: Gesamter Proxmox-Host nicht erreichbar (Hardware-Defekt, Stromausfall).

**Erwartete Dauer**: 30-60 Minuten (nach Hardware-Verfuegbarkeit)

### Sofort-Massnahme

Der zweite Pi-hole uebernimmt automatisch alle DNS-Anfragen. Die UDM verteilt
beide IPs per DHCP — Clients wechseln nach DNS-Timeout (je nach OS 1-30 Sekunden)
auf den verbleibenden Server. **Kein manueller Eingriff noetig fuer DNS-Betrieb.**

### Wiederherstellung

```bash
# 1. Neuen Proxmox-Host aufsetzen oder Hardware reparieren

# 2. Neue Debian-12-VM erstellen
#    - 2 vCPU, 2 GB RAM, 16 GB Disk
#    - Gleiche IP-Adresse wie zuvor verwenden

# 3. Secrets hinterlegen (siehe Abschnitt unten)

# 4. Bootstrap ausfuehren (wie Szenario 2, Option B, ab Schritt 4)

# 5. Falls Pi-hole A (Master) betroffen:
#    - Nach erfolgreichem Bootstrap: Teleporter-Import von B manuell anstossen
#      (einmalig umgekehrt), ODER
#    - Letztes Backup aus Git manuell importieren:
cd /opt/homelab-dns
git pull
cd compose
docker compose up -d
# Warten bis Container laeuft, dann:
/opt/homelab-dns/scripts/teleporter-import.sh
# Hinweis: teleporter-import.sh prueft normalerweise den Hostname.
# Fuer einmaliges Recovery auf A: Hostname temporaer auf pihole-b setzen
# ODER das ZIP manuell ueber die Admin-UI importieren:
# Admin-UI -> Settings -> Teleporter -> Import

# 6. Falls Pi-hole B (Follower) betroffen:
#    - Bootstrap ausfuehren, Container starten
#    - Sync laueft in der naechsten Nacht automatisch, oder manuell:
/opt/homelab-dns/scripts/teleporter-import.sh
```

---

## Secrets neu hinterlegen

### Pi-hole A (Master)

```bash
# 1. GitHub Personal Access Token (PAT) hinterlegen
mkdir -p /etc/pihole-sync
# PAT aus Passwort-Manager kopieren
cat > /etc/pihole-sync/github.token << 'TOKENEOF'
ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TOKENEOF
chmod 0600 /etc/pihole-sync/github.token
chown root:root /etc/pihole-sync/github.token

# 2. Git-Konfiguration fuer PAT-Nutzung
git config --global credential.helper store
# Der PAT wird im Export-Skript direkt als URL-Token verwendet
```

### Pi-hole B (Follower)

```bash
# 1. SSH Deploy-Key hinterlegen
mkdir -p /root/.ssh
chmod 0700 /root/.ssh

# Deploy-Key aus Passwort-Manager kopieren (privater Schluessel)
cat > /root/.ssh/id_ed25519_homelab-dns << 'KEYEOF'
-----BEGIN OPENSSH PRIVATE KEY-----
<Schluessel aus Passwort-Manager einfuegen>
-----END OPENSSH PRIVATE KEY-----
KEYEOF
chmod 0600 /root/.ssh/id_ed25519_homelab-dns
chown root:root /root/.ssh/id_ed25519_homelab-dns

# 2. SSH-Konfiguration fuer GitHub
cat > /root/.ssh/config << 'SSHEOF'
Host github.com
    IdentityFile /root/.ssh/id_ed25519_homelab-dns
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
SSHEOF
chmod 0600 /root/.ssh/config
```

### Beide VMs

```bash
# Pi-hole Webpasswort in .env setzen
cd /opt/homelab-dns/compose
nano .env
# FTLCONF_webserver_api_password=<Passwort aus Passwort-Manager>
```

---

## Sanity-Checks nach Recovery

Nach jeder Wiederherstellung folgende Checks durchfuehren:

```bash
# 1. Container-Status
cd /opt/homelab-dns/compose
docker compose ps
# Erwartung: pihole "healthy", recovery-site "running"

# 2. DNS-Aufloesung lokal
dig @127.0.0.1 example.com
# Erwartung: NOERROR, Antwort mit IP-Adresse

# 3. DNS-Aufloesung von einem Client
# Auf einem Geraet im LAN:
nslookup example.com <PI-HOLE-IP>
# Erwartung: Antwort mit IP-Adresse

# 4. Admin-UI erreichbar
# Im Browser: http://<VM-IP>/admin
# Erwartung: Login-Seite von Pi-hole

# 5. Recovery-Site erreichbar
# Im Browser: http://<VM-IP>:8080
# Erwartung: Recovery-Seite mit Hostname und Befehlen

# 6. Upstream-DNS funktioniert
dig @127.0.0.1 example.com +trace
# Erwartung: Aufloesung ueber Cloudflare/Quad9

# 7. Blocking funktioniert
dig @127.0.0.1 ads.google.com
# Erwartung: 0.0.0.0 oder NXDOMAIN (je nach Pi-hole-Konfiguration)

# 8. Cron-Job installiert
cat /etc/cron.d/pihole-sync
# Erwartung: Export-Job (auf A) oder Import-Job (auf B)

# 9. Git-Verbindung testen
cd /opt/homelab-dns
git fetch
# Erwartung: Kein Fehler

# 10. Sync testen (manuell)
# Auf A: /opt/homelab-dns/scripts/teleporter-export.sh
# Auf B: /opt/homelab-dns/scripts/teleporter-import.sh
# Erwartung: Kein Fehler, Logs pruefen unter /var/log/pihole-sync/
```
