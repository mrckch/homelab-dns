# homelab-dns

Redundantes Pi-hole-Setup fuer ein privates Heimnetz. Zwei unabhaengige Proxmox-Hosts
betreiben je eine Debian-12-VM mit Pi-hole v6 im Docker-Container. Die Konfiguration
wird naechtlich per Teleporter-API von Pi-hole A (Master) nach Pi-hole B (Follower)
ueber ein Git-Repository synchronisiert.

## Architektur

```
                        +-----------+
                        |  Internet |
                        +-----+-----+
                              |
                        +-----+-----+
                        |  UDM Pro  |
                        |  (DHCP)   |
                        | DNS1+DNS2 |
                        +--+-----+--+
                           |     |
              +------------+     +------------+
              |                               |
       +------+-------+              +-------+------+
       | Proxmox A    |              | Proxmox B    |
       |              |              |              |
       | +----------+ |              | +----------+ |
       | | pihole-a | |              | | pihole-b | |
       | | (Master) | |              | | (Follow) | |
       | | x.x.x.10 | |              | | x.x.x.11 | |
       | +----------+ |              | +----------+ |
       +--------------+              +--------------+

       Sync: A --[Teleporter-Export]--> Git --> [Teleporter-Import]--> B
```

Die UDM Pro verteilt beide Pi-hole-IPs als DNS-Server an alle Clients im LAN.
Bei Ausfall einer Instanz uebernimmt die andere automatisch (Client-seitiges Failover).

## Schnellstart

```bash
# Auf der frisch installierten Debian-12-VM (als root):
# 1. Secrets manuell hinterlegen (siehe docs/recovery.md)
# 2. Bootstrap ausfuehren:
curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/scripts/bootstrap.sh -o /tmp/bootstrap.sh
chmod +x /tmp/bootstrap.sh

# Pi-hole A (Master):
/tmp/bootstrap.sh --role=a --ip=192.168.1.10 --gateway=192.168.1.1

# Pi-hole B (Follower):
/tmp/bootstrap.sh --role=b --ip=192.168.1.11 --gateway=192.168.1.1
```

## Wichtige Befehle

| Aktion                     | Befehl                                                        |
|----------------------------|---------------------------------------------------------------|
| Pi-hole starten            | `cd /opt/homelab-dns/compose && docker compose up -d`         |
| Pi-hole stoppen            | `cd /opt/homelab-dns/compose && docker compose down`          |
| Logs ansehen               | `cd /opt/homelab-dns/compose && docker compose logs -f pihole`|
| Container-Status           | `docker ps`                                                   |
| DNS testen                 | `dig @127.0.0.1 example.com`                                 |
| Sync manuell (Master)      | `/opt/homelab-dns/scripts/teleporter-export.sh`               |
| Sync manuell (Follower)    | `/opt/homelab-dns/scripts/teleporter-import.sh`               |
| Update (siehe Runbook!)     | `cd /opt/homelab-dns/compose && docker compose pull && docker compose up -d` |

## Dokumentation

- [Architektur & Designentscheidungen](docs/architecture.md)
- [Recovery-Anleitung](docs/recovery.md)
- [Runbook (Betrieb & Updates)](docs/runbook.md)

## UDM-Pro-Konfiguration (manuell)

In den Netzwerkeinstellungen der UDM Pro unter dem Default-LAN:
- **DHCP Name Server**: Manual
- **DNS Server 1**: IP von pihole-a (z.B. 192.168.1.10)
- **DNS Server 2**: IP von pihole-b (z.B. 192.168.1.11)

Damit erhalten alle Clients im LAN beide Pi-hole-Instanzen als DNS-Server.
