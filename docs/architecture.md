# Architektur

## Ueberblick

Zwei voneinander unabhaengige Proxmox-Hosts betreiben je eine Debian-12-VM mit
Pi-hole v6 im Docker-Container. Die UDM Pro verteilt beide Pi-hole-IPs per DHCP
an alle Clients. Bei Ausfall einer Instanz nutzen Clients automatisch die andere
(Client-seitiges DNS-Failover).

## Komponenten

### Hardware

| Komponente  | Beschreibung                          |
|-------------|---------------------------------------|
| Proxmox A   | Erster Hypervisor, betreibt pihole-a  |
| Proxmox B   | Zweiter Hypervisor, betreibt pihole-b |
| UDM Pro     | Router, DHCP-Server, Gateway          |

Die beiden Proxmox-Hosts sind **kein Cluster**. Sie operieren unabhaengig, sodass
der Ausfall eines Hosts den anderen nicht beeinflusst.

### VMs

| VM       | Host      | OS          | Ressourcen             | IP (Beispiel)  |
|----------|-----------|-------------|------------------------|-----------------|
| pihole-a | Proxmox A | Debian 13   | 2 vCPU, 2 GB RAM, 16 GB | 192.168.1.10  |
| pihole-b | Proxmox B | Debian 13   | 2 vCPU, 2 GB RAM, 16 GB | 192.168.1.11  |

Statische IPs werden ausserhalb des DHCP-Pools vergeben und via systemd-networkd
in der VM konfiguriert (nicht ueber DHCP-Reservierung).

### Software-Stack

- **Docker CE** + docker-compose-plugin
- **Pi-hole v6** (offizielles Image, gepinnter Tag)
- **Caddy** (Alpine-Image) fuer die Recovery-Webseite
- **unattended-upgrades** fuer automatische Debian-Sicherheitsupdates

Bewusst **nicht** im Stack:
- Kein Unbound (DNS-Resolver) — reduziert Komplexitaet, Privacy-Kompromiss akzeptiert
- Kein Gravity Sync — ersetzt durch eigene Teleporter-basierte Loesung
- Kein Watchtower — Updates werden manuell und versetzt durchgefuehrt
- Kein Kubernetes/Portainer — Overhead fuer zwei Container nicht gerechtfertigt

## DNS-Architektur

### Upstream-Resolver

Beide Pi-holes verwenden identische Upstreams:
- **Cloudflare**: 1.1.1.1, 1.0.0.1
- **Quad9**: 9.9.9.9, 149.112.112.112

Durch parallele Nutzung beider Anbieter wird sowohl Geschwindigkeit (Cloudflare)
als auch Sicherheit (Quad9 mit Malware-Filter) kombiniert. DNSSEC ist aktiviert.

### DNS-Fluss

```
Client --> UDM Pro (DHCP: DNS1=pihole-a, DNS2=pihole-b)
              |
              +--> pihole-a --|
              |               |--> Cloudflare (1.1.1.1, 1.0.0.1)
              +--> pihole-b --|    Quad9     (9.9.9.9, 149.112.112.112)
```

Clients senden DNS-Anfragen an den primaeren DNS-Server (pihole-a). Ist dieser
nicht erreichbar, wechselt das Betriebssystem des Clients automatisch auf den
sekundaeren Server (pihole-b).

## Synchronisation (Master-Follower)

### Designentscheidung: Warum Master-Follower?

**Bidirektionale Synchronisation** (Gravity Sync o.ae.) birgt folgende Risiken:
- Merge-Konflikte bei gleichzeitigen Aenderungen auf beiden Instanzen
- Race Conditions bei zeitgleichen Imports
- Komplexere Konfliktloesung (welche Seite "gewinnt"?)
- Schwerer zu debuggen, da Zustand auf beiden Seiten divergieren kann

**Master-Follower** eliminiert diese Probleme:
- Genau ein Schreibpunkt (pihole-a), keine Konflikte moeglich
- Deterministischer Zustand: B ist immer eine Kopie von A
- Einfach zu debuggen: diff zwischen A und B zeigt Abweichungen
- Git-Historie dokumentiert jede Aenderung lueckenlos

### Synchronisations-Datenfluss

```
03:00 Uhr                                  03:30 Uhr
pihole-a                                   pihole-b
   |                                          |
   +-- Pi-hole v6 API: GET /api/teleporter    |
   |   (Session-Auth via /api/auth)           |
   |                                          |
   +-- Speichert: backups/teleporter-latest.zip
   |                                          |
   +-- git add, commit, push (via PAT)        |
   |                                          |
   +------- GitHub Repository --------+       |
                                      |       |
                                      +-- git pull (via Deploy-Key)
                                      |       |
                                      +-- Pruefe: ZIP neuer als letzter Import?
                                              |
                                              +-- Ja: POST /api/teleporter
                                              |   (Session-Auth via /api/auth)
                                              |
                                              +-- Aktualisiere Marker-Datei
```

### Secrets-Trennung

| Secret          | Speicherort                            | Zugriff   |
|-----------------|----------------------------------------|-----------|
| GitHub PAT      | /etc/pihole-sync/github.token (pihole-a) | root:root, 0600 |
| SSH Deploy-Key  | /root/.ssh/id_ed25519_homelab-dns (pihole-b) | root:root, 0600 |
| Pi-hole Passwort| .env auf jeder VM (nicht im Repo)      | root:root, 0600 |

Keine Secrets im Git-Repository. Bei Recovery werden alle Secrets manuell aus
dem Passwort-Manager neu hinterlegt.

## Netzwerk-Design

### Docker-Netzwerk

Die Container verwenden **Bridge-Netzwerk mit explizitem Port-Mapping** statt
`network_mode: host`.

Gruende:
- Klare Trennung: nur explizit freigegebene Ports sind erreichbar
- Einfacher zu verstehen: Port-Mapping ist im Compose-File dokumentiert
- Keine Interferenz mit Host-Firewall-Regeln
- Portabiler: funktioniert identisch auf verschiedenen Host-Konfigurationen

Gemappte Ports:
- 53/tcp + 53/udp (DNS)
- 80/tcp (Pi-hole Admin-UI)
- 8080/tcp (Recovery-Webseite)

### DHCP

DHCP bleibt auf der UDM Pro. Die Pi-holes agieren **nicht** als DHCP-Server.
Dies vermeidet DHCP-Konflikte und haelt die UDM als Single Source of Truth fuer
IP-Zuweisungen.

## Backup-Strategie

### Schicht 1: Teleporter-Sync (Pi-hole-Konfiguration)

Naechtlicher Export der Pi-hole-Konfiguration via Teleporter-API in das Git-Repo.
Die Git-Historie dient als Versionshistorie — im Repo wird nur die jeweils
aktuelle Version vorgehalten (`backups/teleporter-latest.zip`).

### Schicht 2: VM-Snapshots (gesamte VM)

Taegliche VM-Snapshots werden auf ein NAS gesichert. Dies ist ausserhalb dieses
Setups konfiguriert (Proxmox Backup oder manuell) und deckt den Fall ab, dass
die VM selbst beschaedigt wird.

## Trade-offs

| Entscheidung                      | Vorteil                          | Nachteil                              |
|-----------------------------------|----------------------------------|---------------------------------------|
| Kein Unbound                      | Weniger Komplexitaet, einfacher  | DNS-Anfragen gehen an externe Resolver|
| Master-Follower statt bidirektional| Keine Konflikte, deterministic  | Aenderungen nur auf A moeglich        |
| Kein Gravity Sync                 | Volle Kontrolle ueber Sync-Logik | Eigener Code muss gewartet werden     |
| Kein Watchtower                   | Kontrollierte, versetzte Updates | Manuelle Arbeit bei Updates           |
| Bridge statt Host-Netzwerk        | Klare Port-Isolation             | Minimal mehr Overhead                 |
| Kein DHCP auf Pi-hole             | Kein DHCP-Konflikt mit UDM       | Conditional Forwarding ggf. noetig    |
| Teleporter statt DB-Replikation   | Offiziell unterstuetzt, stabil   | Nur naechtliche Sync-Frequenz         |
