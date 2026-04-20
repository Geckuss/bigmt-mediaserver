# bigmt-mediaserver

Self-hosted mediaserver running on **bigmt**, managed with Docker and Portainer.

## Architecture

```
[Internet] --> [Oracle Cloud / Caddy (reverse proxy)] --Tailscale--> [bigmt (mediaserver)]
```

- **bigmt** — main server running all services via Docker/Portainer
- **Oracle Cloud (oci)** — reverse proxy running Caddy, connected to bigmt over Tailscale
- **DNS** — `*.bigmt.dynv6.net` points to Oracle Cloud public IP; Caddy handles TLS and proxies to bigmt via Tailscale hostname `bigmt.tahr-fort.ts.net`

## Hardware

| Component | Spec |
|-----------|------|
| **CPU** | Intel Core i5-7400 @ 3.00GHz (4C/4T) |
| **RAM** | 16 GB |
| **GPU** | NVIDIA GeForce GTX 1070 (8 GB) |
| **Boot disk** | SanDisk 128 GB SSD (`/`) |
| **Data disk** | WD 12 TB HDD (`/data`) |
| **Backup disk** | Seagate 5 TB Expansion (`/mnt/backup-5tb`) |
| **Backup disk 2** | 1 TB (not always connected, `/mnt/backup-1tb`) |

## Services

### Main Stack (`stacks/docker-compose.yml`)

| Service | Description | Port |
|---------|-------------|------|
| **Jellyfin** | Media server | host mode (8096) |
| **Radarr** | Movie management | 7878 |
| **Sonarr** | TV show management | 8989 |
| **Bazarr** | Subtitle management | 6767 |
| **Jellyseerr** | Media request management | 5055 |
| **Prowlarr** | Indexer management | 9696 |
| **qBittorrent** | Torrent client | 8080 |
| **HandBrake** | Video transcoding (web UI) | 5800 |
| **Pi-hole** | DNS ad blocker | host mode (80, 8089) |
| **Backrest** | Backup management (restic) | 9898 |
| **Uptime Kuma** | Status monitoring | 3001 |

### Immich Stack (`stacks/immich.yml`)

| Service | Description | Port |
|---------|-------------|------|
| **Immich Server** | Photo/video management | 2283 |
| **Immich ML** | Machine learning (CUDA) | internal |
| **Redis (Valkey)** | Cache | internal |
| **PostgreSQL** | Database (vectorchord+pgvectors) | internal |

### Valheim Stack (`stacks/valheim.yml`)

| Service | Description | Port |
|---------|-------------|------|
| **Valheim** | Dedicated game server | 2456-2457/udp |

## Reverse Proxy

Caddy runs on the Oracle Cloud instance (`proxy/Caddyfile`). All subdomains under `*.bigmt.dynv6.net` are proxied through Tailscale to bigmt:

| Subdomain | Backend |
|-----------|---------|
| `bigmt.dynv6.net` / `jellyfin.*` | Jellyfin (:8096) |
| `sonarr.*` | Sonarr (:8989) |
| `radarr.*` | Radarr (:7878) |
| `bazarr.*` | Bazarr (:6767) |
| `jellyseerr.*` | Jellyseerr (:5055) |
| `prowlarr.*` | Prowlarr (:9696) |
| `qbittorrent.*` | qBittorrent (:8080) |
| `portainer.*` | Portainer (:9000) |
| `cockpit.*` | Cockpit (:9090) |
| `immich.*` | Immich (:2283) |
| `pihole.*` | Pi-hole (:80) |
| `backrest.*` | Backrest (:9898) |
| `uptime.*` | Uptime Kuma (:3001) |
| `bigmt.v6.rocks` | Jellyfin (:8096) |

Caddy auto-provisions TLS certificates via Let's Encrypt.

## Backup

**Backrest** manages backups via restic with Discord notifications on success/failure.

**Repositories:**
- `/mnt/backup-5tb` — primary (5 TB Seagate Expansion)
- `/mnt/backup-1tb` — secondary (1 TB, not always connected)

**Backup plans:**

| Plan | Sources | Retention |
|------|---------|-----------|
| **critical** | Service configs, Immich uploads | 3 weekly, 3 monthly |
| **media** | Media library (excludes Immich gallery) | 2 monthly |

## Custom Scripts

### `scripts/extract-subs.sh`
Custom post-import script for Radarr/Sonarr. Extracts ASS/SSA subtitle streams from media files and converts them to SRT format using ffmpeg. Triggered automatically when new media is imported.

### `scripts/install-ffmpeg.sh`
LinuxServer.io custom init script that installs ffmpeg into Radarr/Sonarr containers at startup (required by `extract-subs.sh`).

## Setup

1. Clone the repo:
   ```bash
   git clone https://github.com/Geckuss/bigmt-mediaserver.git
   cd bigmt-mediaserver
   ```

2. Copy and edit the environment file:
   ```bash
   cp .env.example .env
   # Edit .env with your actual values
   ```

3. Deploy stacks via Portainer, or manually:
   ```bash
   docker compose -f stacks/docker-compose.yml --env-file .env up -d
   docker compose -f stacks/immich.yml --env-file .env up -d
   docker compose -f stacks/valheim.yml --env-file .env up -d
   ```

4. Deploy the Caddyfile on the Oracle Cloud instance:
   ```bash
   scp proxy/Caddyfile oci:/etc/caddy/Caddyfile
   ssh oci "sudo systemctl reload caddy"
   ```

## Directory Structure

```
.
├── proxy/
│   └── Caddyfile              # Caddy reverse proxy config (runs on Oracle Cloud)
├── scripts/
│   ├── extract-subs.sh        # ASS/SSA to SRT subtitle extractor for Radarr/Sonarr
│   └── install-ffmpeg.sh      # ffmpeg installer for LinuxServer containers
├── stacks/
│   ├── docker-compose.yml     # Main stack (Jellyfin, *arr, backrest, etc.)
│   ├── immich.yml             # Immich photo management stack
│   └── valheim.yml            # Valheim game server
├── .env.example               # Environment variable template
├── AGENTS.md                  # Agent instructions for this project
└── README.md
```

## Notes

- Jellyfin and Pi-hole use `network_mode: host` for DLNA discovery and DNS respectively
- Radarr/Sonarr mount custom scripts from `${CONFIGS}/` — keep repo copies in `scripts/` as reference
- Immich ML uses the CUDA variant for GPU-accelerated inference
- All service configs persist under `${CONFIGS}/` (`/data/backups/configs`)
- Media and downloads live under `${DATA}/` (`/data`)
