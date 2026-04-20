# bigmt-mediaserver

Self-hosted mediaserver running on **bigmt**, managed with Docker and Portainer.

## Architecture

```
[Internet] --> [Oracle Cloud (reverse proxy via Tailscale)] --> [bigmt (mediaserver)]
```

- **bigmt** runs all services via Docker/Portainer
- **Oracle Cloud** instance acts as a reverse proxy, connected over Tailscale
- **NVIDIA GPU** provides hardware transcoding (Jellyfin) and ML acceleration (Immich)

## Services

### Main Stack (`stacks/docker-compose.yml`)

| Service | Description | Port |
|---------|-------------|------|
| **Jellyfin** | Media server | host mode |
| **Radarr** | Movie management | 7878 |
| **Sonarr** | TV show management | 8989 |
| **Bazarr** | Subtitle management | 6767 |
| **Jellyseerr** | Media request management | 5055 |
| **Prowlarr** | Indexer management | 9696 |
| **qBittorrent** | Torrent client | 8080 |
| **HandBrake** | Video transcoding (web UI) | 5800 |
| **Pi-hole** | DNS ad blocker | host mode |

### Immich Stack (`stacks/immich.yml`)

| Service | Description | Port |
|---------|-------------|------|
| **Immich Server** | Photo/video management | 2283 |
| **Immich ML** | Machine learning (CUDA) | internal |
| **Redis (Valkey)** | Cache | internal |
| **PostgreSQL** | Database (vectorchord+pgvectors) | internal |

## Setup

1. Clone the repo:
   ```bash
   git clone https://github.com/<user>/bigmt-mediaserver.git
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
   ```

## Directory Structure

```
.
├── stacks/
│   ├── docker-compose.yml   # Main stack (Jellyfin, *arr, etc.)
│   └── immich.yml           # Immich photo management stack
├── .env.example             # Environment variable template
├── AGENTS.md                # Agent instructions for this project
└── README.md
```

## Notes

- Jellyfin and Pi-hole use `network_mode: host` for DLNA discovery and DNS respectively
- Radarr/Sonarr mount custom scripts (`extract-subs.sh`, `install-ffmpeg.sh`)
- Immich ML uses the CUDA variant for GPU-accelerated inference
- All service configs persist under `${CONFIGS}/`
- Media and downloads live under `${DATA}/`
