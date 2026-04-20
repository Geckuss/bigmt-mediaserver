# Mediaserver - agents.md

## Access

- **SSH**: `ssh bigmt`
- **Management**: Portainer (Docker)

## Architecture

```
[Internet] → [Oracle Cloud (proxy via Tailscale)] → [bigmt (mediaserver)]
```

- **bigmt**: Main mediaserver running all services via Docker/Portainer
- **Oracle server**: Reverse proxy, connected to bigmt over Tailscale
- **GPU**: NVIDIA (used by Jellyfin, Immich for hardware transcoding/ML)

## Docker Stacks (Portainer)

### Main Stack

| Service      | Image                                      | Port        |
| ------------ | ------------------------------------------ | ----------- |
| Jellyfin     | jellyfin/jellyfin                          | host mode   |
| Radarr       | linuxserver/radarr                         | ${RADARR_PORT}:7878 |
| Sonarr       | linuxserver/sonarr                         | ${SONARR_PORT}:8989 |
| Bazarr       | linuxserver/bazarr                         | ${BAZARR_PORT}:6767 |
| Jellyseerr   | fallenbagel/jellyseerr                     | 5055:5055   |
| Prowlarr     | linuxserver/prowlarr                       | ${PROWLARR_PORT}:9696 |
| qBittorrent  | linuxserver/qbittorrent                    | ${QBITTORRENT_WEBUI}:8080 |
| HandBrake    | jlesage/handbrake                          | ${HANDBRAKE_WEBUI}:5800 |
| Pi-hole      | pihole/pihole                              | host mode   |

### Immich Stack

| Service              | Image                                       | Port        |
| -------------------- | ------------------------------------------- | ----------- |
| Immich Server        | immich-app/immich-server                    | 2283:2283   |
| Immich ML            | immich-app/immich-machine-learning (CUDA)   | internal    |
| Redis (Valkey)       | valkey/valkey:9                             | internal    |
| PostgreSQL           | immich-app/postgres (vectorchord+pgvectors) | internal    |

## Volumes / Paths

- `${DATA}` — root data directory (media, downloads)
- `${CONFIGS}` — persistent config for all services
- `${DATA}/media` — Jellyfin media library
- `${DATA}/downloads` — qBittorrent downloads, HandBrake I/O
- `${UPLOAD_LOCATION}` — Immich photo/video uploads
- `${DB_DATA_LOCATION}` — Immich PostgreSQL data

## Rules

- **Always ask for permission before running commands that move, modify, or delete files/data on the server.** Read-only commands (ls, df, lsblk, cat, docker ps, etc.) are fine without confirmation.

## Notes

- Jellyfin and Pi-hole use `network_mode: host`
- Radarr/Sonarr have custom scripts mounted: `extract-subs.sh`, `install-ffmpeg.sh`
- Immich ML uses the CUDA variant for GPU-accelerated machine learning
- Oracle proxy handles external access; internal services communicate over Tailscale
