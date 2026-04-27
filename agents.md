# Mediaserver - agents.md

## Access

- **SSH bigmt**: `ssh bigmt`
- **SSH oci**: `ssh oci`
- **Management**: Portainer (Docker)

## Architecture

```
[Internet] --> [Oracle Cloud / Caddy] --Tailscale--> [bigmt (mediaserver)]
```

- **bigmt**: Main mediaserver running all services via Docker/Portainer
- **oci (Oracle Cloud)**: Reverse proxy running Caddy, connected to bigmt over Tailscale
- **GPU**: NVIDIA GTX 1070 (used by Jellyfin for transcoding, Immich for ML)
- **DNS**: `*.bigmt.dynv6.net` → Oracle Cloud public IP → Caddy → bigmt via `<TAILSCALE_HOSTNAME>`

## Docker Stacks (Portainer)

### Main Stack

| Service | Port |
|---------|------|
| Jellyfin | host mode (8096) |
| Radarr | 7878 |
| Sonarr | 8989 |
| Bazarr | 6767 |
| Lidarr | 8686 |
| Jellyseerr | 5055 |
| Prowlarr | 9696 |
| qBittorrent | 8080 |
| HandBrake | 5800 |
| Pi-hole | host mode (80, 8089) |
| Backrest | 9898 |
| Seafile | 8082 |
| Seafile MariaDB | internal |
| Seafile Memcached | internal |
| Uptime Kuma | 3001 |
| Homepage | 3000 |

### Immich Stack

| Service | Port |
|---------|------|
| Immich Server | 2283 |
| Immich ML (CUDA) | internal |
| Redis (Valkey) | internal |
| PostgreSQL | internal |

### Valheim Stack

| Service | Port |
|---------|------|
| Valheim | 2456-2457/udp |

## Paths

- `${DATA}` = `/data` — root data directory
- `${CONFIGS}` = `/data/backups/configs` — persistent config for all services
- `/data/media/movies` — Radarr root folder
- `/data/media/shows` — Sonarr root folder
- `/data/media/music` — Lidarr root folder
- `/data/media/gallery` — Immich uploads
- `${CONFIGS}/seafile-data` — Seafile shared data
- `${CONFIGS}/seafile-mysql` — Seafile MariaDB data
- `/data/media/recorded` — manually recorded content
- `/data/downloads` — qBittorrent downloads, HandBrake I/O
- `/mnt/backup-5tb` — primary backup drive
- `/mnt/backup-1tb` — secondary backup drive (not always connected)

## Rules

- **Always ask for permission before running commands that move, modify, or delete files/data on the server.** Read-only commands (ls, df, lsblk, cat, docker ps, etc.) are fine without confirmation.

## Notes

- Jellyfin and Pi-hole use `network_mode: host`
- Radarr/Sonarr have custom scripts mounted: `extract-subs.sh` (ASS/SSA→SRT), `install-ffmpeg.sh`
- Immich ML uses the CUDA variant for GPU-accelerated machine learning
- Pi-hole uses Cloudflare (1.1.1.1) and Google (8.8.8.8) as upstream DNS
- Backrest backs up configs + Immich uploads (3 weekly, 3 monthly) and media (2 monthly) to 5TB drive
- Auto-backup: udev rule triggers backup on drive plug, with cooldowns (critical: 30d, media: 90d)
- Backrest API credentials stored in `/etc/backrest-api-credentials` (root-only)
- Both Radarr and Sonarr use qBittorrent as download client
- Lidarr uses qBittorrent as download client
- Seafile uses MariaDB + Memcached; config requires `CSRF_TRUSTED_ORIGINS` and `https://` URLs in `seahub_settings.py` for reverse proxy
