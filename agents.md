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
- **DNS**: `*.example.com` → Oracle Cloud public IP → Caddy → bigmt via Tailscale

## Docker Stacks (Portainer)

### Main Stack

| Service | Port |
|---------|------|
| Jellyfin | host mode (8096) |
| Radarr | 7878 |
| Sonarr | 8989 |
| Bazarr | 6767 |
| Jellyseerr | 5055 |
| Prowlarr | 9696 |
| qBittorrent | 8080 |
| HandBrake | 5800 |
| Pi-hole | host mode (80, 8089) |
| Backrest | 9898 |
| Seafile | 8082 |
| Seafile MariaDB | internal |
| Seafile Memcached | internal (alias: `memcached`) |
| Uptime Kuma | 3001 |
| Homepage | 3000 |

### Vocard Stack

| Service | Port |
|---------|------|
| Vocard (Discord bot) | internal |
| Lavalink | 2333 (internal) |
| yt-cipher | 8001 (internal) |
| Spotify Tokener | 49152 (internal) |
| Vocard Dashboard | 8050 → 8000 |
| Vocard MongoDB | 27017 (internal) |

### Immich Stack

| Service | Port |
|---------|------|
| Immich Server | 2283 |
| Immich ML (CUDA) | internal |
| Redis (Valkey) | internal |
| PostgreSQL | internal |

## Paths

- `${DATA}` = `/data` — root data directory
- `${CONFIGS}` = `/data/backups/configs` — persistent config for all services
- `/data/media/movies` — Radarr root folder
- `/data/media/shows` — Sonarr root folder
- `/data/media/gallery` — Immich uploads
- `${CONFIGS}/seafile-data` — Seafile shared data
- `${CONFIGS}/seafile-mysql` — Seafile MariaDB data
- `${CONFIGS}/vocard/` — Vocard bot, Lavalink, and dashboard configs
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
- Pi-hole uses Cloudflare (1.1.1.1), Google (8.8.8.8), and Quad9 (9.9.9.9, 149.112.112.112) as upstream DNS
- Backrest backs up configs + Immich uploads (3 weekly, 3 monthly) and media (2 monthly) to 5TB drive
- Backrest API credentials stored in `/etc/backrest-api-credentials` (root-only)
- Both Radarr and Sonarr use qBittorrent as download client
- Seafile uses MariaDB + Memcached; config requires `CSRF_TRUSTED_ORIGINS` and `https://` URLs in `seahub_settings.py` for reverse proxy
- Seafile Memcached container has `memcached` network alias so seahub_settings.py can reference `memcached:11211`
- Vocard uses the **beta branch** (`v2.7.3b3`) built locally as `vocard:beta` — required for Lavalink 4.2.x `channelId` fix
- Vocard stack uses `pull_policy: never` for the bot image (local build only)
- Lavalink plugins: youtube-plugin 1.18.0, lavasrc 4.8.1, lavasearch 1.0.0, lavalyrics 1.0.0
- Lavalink uses yt-cipher for external YouTube cipher resolution (`remoteCipher` in application.yml)
- Lavalink JVM tuning: `-Xmx512M -XX:+UseG1GC -XX:MaxGCPauseMillis=20`
- Vocard Dashboard accessible at `seraphine.example.com`
- Vocard translation keys in settings.json use flattened dot notation (e.g. `@@t_player.buttons.back@@`)
