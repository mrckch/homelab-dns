# Runbook

## Regelmaessige Tasks

### Taeglich (automatisiert)

- **03:00**: Teleporter-Export auf Pi-hole A (Cron)
- **03:30**: Teleporter-Import auf Pi-hole B (Cron)
- **unattended-upgrades**: Debian-Sicherheitsupdates auf beiden VMs

Diese Jobs laufen automatisch. Fehler werden in `/var/log/pihole-sync/` protokolliert.

### Woechentlich (manuell empfohlen)

```bash
# Auf beiden VMs: Sync-Logs pruefen
tail -20 /var/log/pihole-sync/export.log  # auf A
tail -20 /var/log/pihole-sync/import.log  # auf B

# Docker-Zustand pruefen
cd /opt/homelab-dns/compose
docker compose ps

# DNS-Funktion testen
dig @127.0.0.1 example.com
dig @127.0.0.1 ads.google.com  # Sollte geblockt werden
```

### Monatlich (manuell)

```bash
# Disk-Usage pruefen
df -h
docker system df

# Alte Docker-Images aufraeumen
docker image prune -f

# Git-Repository-Groesse pruefen
du -sh /opt/homelab-dns/.git

# Debian-Updates pruefen (sollten automatisch laufen)
cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -30

# VM-Snapshots auf NAS verifizieren (ausserhalb dieses Setups)
```

---

## Update-Prozedur

Updates werden **versetzt** durchgefuehrt: erst Pi-hole B, 24-48 Stunden beobachten,
dann Pi-hole A.

### Schritt 1: Pi-hole B updaten (Follower)

```bash
# 1. Auf Pi-hole B einloggen
ssh root@<PIHOLE-B-IP>
cd /opt/homelab-dns/compose

# 2. Aktuellen Zustand dokumentieren
docker compose ps
pihole_tag=$(docker inspect pihole | grep -oP '"Image": "pihole/pihole:\K[^"]+')
echo "Aktuelles Image-Tag: $pihole_tag"

# 3. docker-compose.yml aktualisieren: neues Tag setzen
nano docker-compose.yml
# image: pihole/pihole:<NEUES-TAG>

# 4. Neues Image ziehen und Container neu starten
docker compose pull
docker compose up -d

# 5. Healthcheck abwarten
sleep 30
docker compose ps
# Erwartung: pihole "healthy"

# 6. DNS testen
dig @127.0.0.1 example.com
dig @127.0.0.1 ads.google.com

# 7. Admin-UI pruefen: http://<PIHOLE-B-IP>/admin
# Query Log, Blocking, Settings auf Funktion pruefen
```

### Schritt 2: 24-48 Stunden beobachten

- DNS-Aufloesung im Netz funktioniert?
- Keine Anomalien im Pi-hole-Dashboard?
- Sync-Import laeuft fehlerfrei?

### Schritt 3: Pi-hole A updaten (Master)

```bash
# 1. Auf Pi-hole A einloggen
ssh root@<PIHOLE-A-IP>
cd /opt/homelab-dns/compose

# 2. Vor dem Update: Manuellen Teleporter-Export durchfuehren
/opt/homelab-dns/scripts/teleporter-export.sh

# 3. docker-compose.yml aktualisieren: gleiches Tag wie B
nano docker-compose.yml

# 4. Update durchfuehren
docker compose pull
docker compose up -d

# 5. Healthcheck und Tests (wie bei B)
sleep 30
docker compose ps
dig @127.0.0.1 example.com

# 6. Admin-UI pruefen: http://<PIHOLE-A-IP>/admin
```

### Schritt 4: Compose-Datei im Repo aktualisieren

```bash
# Auf Pi-hole A:
cd /opt/homelab-dns
git add compose/docker-compose.yml
git commit -m "Update Pi-hole to <NEUES-TAG>"
git push
```

### Rollback (falls noetig)

```bash
# Altes Tag in docker-compose.yml zuruecksetzen
cd /opt/homelab-dns/compose
nano docker-compose.yml
# image: pihole/pihole:<ALTES-TAG>

docker compose pull
docker compose up -d
```

---

## Konfigurationsaenderungen

### Wichtig: Aenderungen NUR auf Pi-hole A (Master)!

Alle Aenderungen an Adlists, Whitelist, Blacklist, Custom DNS Records und
sonstigen Einstellungen werden **ausschliesslich** auf Pi-hole A vorgenommen.
Die Synchronisation nach B erfolgt automatisch in der naechsten Nacht.

### Adlists verwalten

```
1. Admin-UI von Pi-hole A oeffnen: http://<PIHOLE-A-IP>/admin
2. Adlists -> Neue Liste hinzufuegen
3. URL der Adlist eingeben, "Add" klicken
4. Tools -> Update Gravity (oder warten bis naechster Gravity-Lauf)
```

Nach der naechsten naechtlichen Synchronisation hat Pi-hole B die gleichen Listen.

### Whitelist / Blacklist

```
1. Admin-UI von Pi-hole A oeffnen
2. Domains -> Whitelist / Blacklist
3. Domain eingeben, "Add to Whitelist/Blacklist" klicken
```

Alternativ per CLI auf Pi-hole A:

```bash
# Whitelist
docker exec pihole pihole -w example.com

# Blacklist
docker exec pihole pihole -b example.com
```

### Custom DNS Records (Local DNS)

```
1. Admin-UI von Pi-hole A oeffnen
2. Local DNS -> DNS Records
3. Domain und IP eintragen, "Add" klicken
```

### Manuelle Synchronisation anstossen

Falls eine Aenderung sofort auf B verfuegbar sein soll:

```bash
# Auf Pi-hole A: Export anstossen
/opt/homelab-dns/scripts/teleporter-export.sh

# Auf Pi-hole B: Import anstossen
/opt/homelab-dns/scripts/teleporter-import.sh
```

---

## Sync-Status pruefen

### Letzter Export (Pi-hole A)

```bash
# Log pruefen
tail -10 /var/log/pihole-sync/export.log

# Letzter Git-Commit im Repo
cd /opt/homelab-dns
git log --oneline -5

# Alter des Backups
ls -la /opt/homelab-dns/backups/teleporter-latest.zip
```

### Letzter Import (Pi-hole B)

```bash
# Log pruefen
tail -10 /var/log/pihole-sync/import.log

# Marker-Datei pruefen
cat /var/lib/pihole-sync/last-import
# Zeigt Timestamp des letzten erfolgreichen Imports

# Vergleich: Git-Stand
cd /opt/homelab-dns
git log --oneline -1
```

### Sync-Differenz erkennen

```bash
# Auf Pi-hole A: Anzahl blockierter Domains
docker exec pihole pihole status

# Auf Pi-hole B: Anzahl blockierter Domains
docker exec pihole pihole status

# Beide sollten identische Zahlen zeigen
# (kleine Abweichungen bei Query-Counts sind normal)
```

---

## Troubleshooting

### Problem: DNS-Aufloesung funktioniert nicht

```bash
# 1. Container laeuft?
docker compose ps

# 2. Port 53 erreichbar?
ss -tlnp | grep :53
dig @127.0.0.1 example.com

# 3. Upstream erreichbar?
dig @1.1.1.1 example.com
dig @9.9.9.9 example.com

# 4. systemd-resolved blockiert Port 53?
ss -tlnp | grep :53
# Falls systemd-resolved laeuft:
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf
```

### Problem: Export-Skript schlaegt fehl

```bash
# Log pruefen
cat /var/log/pihole-sync/export.log

# Pi-hole API erreichbar?
curl -s http://localhost:80/api/info | head

# Git push moeglich?
cd /opt/homelab-dns
git status
git remote -v
# PAT noch gueltig? Token pruefen:
cat /etc/pihole-sync/github.token

# Manueller Push-Test
git push --dry-run
```

### Problem: Import-Skript schlaegt fehl

```bash
# Log pruefen
cat /var/log/pihole-sync/import.log

# Git pull moeglich?
cd /opt/homelab-dns
git pull

# SSH-Key funktioniert?
ssh -T git@github.com

# Pi-hole API erreichbar?
curl -s http://localhost:80/api/info | head

# Backup-Datei vorhanden?
ls -la /opt/homelab-dns/backups/teleporter-latest.zip

# Marker-Datei pruefen
cat /var/lib/pihole-sync/last-import
```

### Problem: Container startet nicht

```bash
# Detaillierte Logs
docker compose logs pihole

# Haeufige Ursachen:
# 1. Port 53 belegt
lsof -i :53
# -> systemd-resolved deaktivieren (siehe oben)

# 2. Nicht genug Speicher
free -m
df -h

# 3. Image nicht vorhanden
docker images | grep pihole
docker compose pull

# 4. Volume-Berechtigungen
ls -la /opt/homelab-dns/compose/etc-pihole/
chown -R 999:999 /opt/homelab-dns/compose/etc-pihole/
```

### Problem: Recovery-Site nicht erreichbar

```bash
# Container-Status
docker compose ps recovery-site
docker compose logs recovery-site

# Port 8080 belegt?
ss -tlnp | grep :8080

# Container neu starten
docker compose restart recovery-site
```

### Problem: Cron-Job laeuft nicht

```bash
# Cron-Datei vorhanden?
cat /etc/cron.d/pihole-sync

# Cron-Service laeuft?
systemctl status cron

# Manuell ausfuehren zum Testen
/opt/homelab-dns/scripts/teleporter-export.sh   # auf A
/opt/homelab-dns/scripts/teleporter-import.sh   # auf B
```
