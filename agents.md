# Mediaserver - agents.md

## Secrets (this repo is PUBLIC)

`Geckuss/bigmt-mediaserver` is a **public, anonymized** repo. Nothing that reaches `master` may contain a real credential.

**The contract:**

- **In git:** variable *names* and obvious placeholders only. `.env.example` is the authoritative list of names. Committed configs under `configs/` are templates using placeholders (`YOUR_BOT_TOKEN`, `<RESTIC_REPO_PASSWORD>`).
- **On the host:** real values live in **Komodo Variables** flagged `is_secret`, in the Mongo store under `${CONFIGS}/komodo`. Komodo renders them into `/etc/komodo/stacks/<stack>/.env` (`600 root:root`) at deploy time. There is no `${CONFIGS}/secrets/` directory and no `additional_env_files` — that was an earlier idea, never built. Komodo Core's own credentials (jwt/webhook/admin/db) are in the root-only `chmod 600` `${CONFIGS}/komodo/core.config.toml`, and values Core needs at runtime go in its `[secrets]` block. `${CONFIGS}` is covered by Backrest either way.
- **Never** commit a working credential "temporarily", and never paste one into a compose file to test something.

**Enforcement (all three layers):**

1. `.githooks/pre-commit` — built-in scan, zero dependencies. Enable with `git config core.hooksPath .githooks` (once, locally).
2. `.gitleaks.toml` — broader rule set, used by CI and by the hook if `gitleaks` is installed locally.
3. `.github/workflows/secret-scan.yml` — runs gitleaks over full history on every push to `master`, plus a compose parse check.

**Adding an exception:** a value can only be allowlisted if it is worthless or rotated. Add the exact value to `ALLOW_VALUES` in `.githooks/pre-commit` **and** to `.gitleaks.toml`, with a comment justifying why it is safe to publish. Keep the list minimal.

**Also enable in GitHub** (Settings → Code security, one-time, not a file): *Secret scanning* and *Push protection* — both free on public repos. These catch secrets pushed from machines other than this one, which the local hook cannot.

## Access

- **SSH bigmt**: `ssh bigmt`
- **SSH oci**: `ssh oci`
- **Management**: Komodo (`https://komodo.bigmt.top`, Tailscale only) — Portainer was removed 2026-09-28

## Deploys: git is the source of truth

Every stack is declared in this repo and deployed by **Komodo** from a git clone. There is no host-side compose file to edit any more.

| | |
|---|---|
| Komodo UI | `https://komodo.bigmt.top` (Tailscale only, via Caddy `private_only`) |
| Compose files (cloned) | `/etc/komodo/stacks/<stack>/` — Periphery's `root_directory` is `/etc/komodo`, so anything outside it is invisible to Komodo |
| Resource declarations | `komodo/resources.toml`, applied by the `bigmt` Resource Sync |
| Web UI | `komodo.bigmt.top`, admin creds in `${CONFIGS}/komodo/core.config.toml` (root-only) |

To change anything:

1. Edit the compose file in `stacks/`, or `komodo/resources.toml` for Komodo's own config.
2. `git push`.
3. In Komodo run **`DeployStackIfChanged`** on the stack. It diffs first, so a no-op costs nothing.

Never edit the files under `/etc/komodo/stacks/` by hand — the next deploy overwrites them. Never let a second compose manager touch a project Komodo owns; two managers on one compose project fight.

**Secrets** are not in git and not in `resources.toml`. The stacks reference `[[VARIABLE]]` names; the values live in Komodo as variables flagged secret, in the Mongo store under `${CONFIGS}/komodo`.

**Three gotchas that cost real time here:**

- **`DeployStackIfChanged` diffs against Komodo's record of the last deploy, not against the live containers.** Delete or stop a container out of band and it reports "no change" and does not bring it back. Use a full `DeployStack` to reconcile. Compose `up -d` is otherwise idempotent — it only recreates services whose config actually differs, so a full deploy is cheap.
- Compose does **not** remove a service you delete from the file. It prints `Found orphan containers (...)` and leaves them running. `mediastack` carries `extra_args = ["--remove-orphans"]` for exactly this reason.
- The Resource Sync is a **partial merge**. It rewrites any field `resources.toml` does not declare, using the schema default, and omitting a field does **not** clear it. Declare `auto_pull = false` explicitly on every stack; the default is `true`, and nearly every image here is a floating tag.

## Architecture

```
[Internet] --> [Oracle Cloud / Caddy] --Tailscale--> [bigmt (mediaserver)]
```

- **bigmt**: Main mediaserver running all services via Docker, managed by Komodo
- **oci (Oracle Cloud)**: Reverse proxy running Caddy, connected to bigmt over Tailscale
- **GPU**: NVIDIA GTX 1070 (used by Jellyfin for transcoding, Immich for ML)
- **DNS**: `*.example.com` → Oracle Cloud public IP → Caddy → bigmt via Tailscale

## Docker Stacks

Nine Komodo stacks, each one compose project. They are split so a workload deploy cannot take out LAN DNS, monitoring, or the backup net.

### mediastack (8)

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

These reach each other over published host ports, not compose service DNS, which is what makes the group splittable at all.

### seafile (3) — own project

| Service | Port |
|---------|------|
| Seafile | 8082 |
| Seafile MariaDB | internal (`DB_HOST=seafile-mysql`) |
| Seafile Memcached | internal (alias: `memcached`) |

Split out of mediastack: nothing outside the trio ever used compose service DNS, so it was only a guest there. Its `seafileltd/seafile-mc:latest` tag is floating, and one bad pull should not be able to take Radarr and Sonarr down with it.

The three stay together and must stay in `stacks/seafile.yml` — they are coupled by name (`DB_HOST`, the `memcached` alias referenced from `seahub_settings.py`). Moving them to different projects would mean publishing those ports and pointing the config at a host.

**Cutover order is not optional:** all three have a fixed `container_name`, so the new project cannot start while the old containers exist. Deploy `mediastack` first (its `--remove-orphans` reaps them), then `seafile`. State is in bind mounts under `${CONFIGS}` and survives; expect ~1min down.

### infrastructure (3)

| Service | Port |
|---------|------|
| Pi-hole | host mode (80, 8089) |
| Uptime Kuma | 3001 |
| Scrutiny | 8079 |

Out of mediastack on purpose: Pi-hole going down kills LAN DNS *including for whatever is being deployed*, and losing monitoring at the same time as what it monitors hides the breakage.

### backrest (1) — own project, gated

Backrest is alone because its drives are only plugged in when needed, and the host-side guard has to own its lifecycle:

- `restart: "no"` — Docker never auto-starts it, not even at boot
- `backrest-guard.service` runs `/usr/local/sbin/backrest-guard.sh`, which checks `mountpoint -q /mnt/backup-5tb` and starts it only if real
- after plugging a drive in: `sudo systemctl start backrest-guard`

The guard must be host-side: inside the container the bind mount looks mounted, and Docker auto-creates missing bind sources, so neither a mountpoint test nor a marker file works from in there. Without it, restic inits a brand new empty repo on the root SSD and reports every plan as successful.

### homepage (2)

| Service | Port |
|---------|------|
| Homepage | 3000 |
| Glances | host mode (61208) |

- Homepage is the landing page at `bigmt.*` — app links + service API widgets + system metrics.
- Glances is the metrics backend. Homepage reads its REST API at `http://host.docker.internal:61208` (Homepage has `host.docker.internal:host-gateway`; Glances runs `network_mode: host`).
- Glances runs the **official `nicolargo/glances:4.5.7-full` image** (musl/Alpine). It used to be a locally built glibc rebuild, so the NVIDIA runtime's glibc `libnvidia-ml.so` would load (`dlvsym: symbol not found` on musl) to feed a GPU tile. That tile no longer exists, so the rebuild was dropped — it measured identical on every metric the dashboard actually uses (cpu, memory, `fs:/data`, CPU temp, network, disk), and it was a hand-built image in no registry, which is exactly what made `docker compose pull` fail on this stack. `configs/glances/glances.conf` is still mounted and still does the real work: Host-header allowlist plus no CORS.
- `key: <PLACEHOLDER>` in `services.yaml` is the repo's sanitized form; the live values live only at `${CONFIGS}/homepage-config/services.yaml`.

### vocard (6)

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
- `${CONFIGS}/komodo/` — Komodo Core: state DB, keys, backups, and the root-only `core.config.toml`
- `${CONFIGS}/vrising/modded/` — V Rising modded server, world saves, and mod plugins
- `${CONFIGS}/valheim/` — Valheim config, worlds, and BepInEx plugins (see the Valheim section)
- `/data/media/recorded` — manually recorded content
- `/data/downloads` — qBittorrent downloads, HandBrake I/O
- `/mnt/backup-5tb` — primary backup drive (not always connected)
- `/mnt/backup-1tb` — secondary backup drive (not always connected)

## Valheim: mods

Mods are managed on the Windows box in Gale, then **copied to the server by hand**. `configs/valheim/modmanifest.json` is the record of which versions the server is meant to be running; nothing here consumes it automatically.

Copying wins over a download-based installer for one specific reason: the tuned mod **config** files live only in the Gale profile. An installer that re-downloads the mods gives you default configs and silently loses them.

**Never copy `BepInEx/core/`.** The client profile ships its own BepInEx core; the server's core is installed and self-updated by the container image. Copying it across means two owners, and the image will overwrite it or break its doorstop setup. Copy **`plugins/`, `patchers/` and `config/` only** — and not `cache/`, `logs/` or `DumpedAssemblies/`.

To change mods:

1. Change them in Gale, then export the profile and commit it to `configs/valheim/modmanifest.json` (strip the profile name and description first — this repo is public).
2. From PowerShell, copy the three directories across (one line, no temp files):

   ```powershell
   $b = "$env:APPDATA\com.kesomannen.gale\valheim\profiles\<profile>\BepInEx"
   tar -cf - -C $b plugins patchers config |
     ssh bigmt "sudo tar -xf - -C /data/backups/configs/valheim/config/bepinex"
   ```

3. Restart the stack **through Komodo** (`RestartStack` on `valheim`), not `docker compose`, so the `stop_grace_period: 120s` applies and the world saves cleanly.

Copying merges rather than replaces, so a mod you *removed* in Gale stays on the server until you delete its folder by hand.

Gale cannot drive the server: it is a GUI app, its CLI only does `-i` (install a local zip) and `-l` (launch), and its "profile sync" is cloud sharing between players, not a file sync.

**The mod sources are split, not migrated.** The Azumatt suite, `Smoothbrain-TargetPortal` and a couple of others now only exist on **Hexium**; the rest are still **Thunderstore**-only. A manifest that ignores this will resolve ~15 of its pins to older versions or fail outright, so check which site a new pin belongs to before assuming Thunderstore.

**Why the versions matter here:** the container self-updates the Valheim build itself every ~15 minutes, unattended. A new game build can therefore break server-side plugins with nobody watching. The `valheim-updater` lines in the container log are the source of truth for "is there a new build" — not the image badge. The image itself only carries the wrapper (entrypoint, supervisord, steamcmd, updater scripts); world, mods, config and the game install are all bind mounts, so an image update never touches your data.

**Watch out:** `stacks/valheim.yml` defaults `WORLD_NAME` to an older, abandoned world name that still exists on disk, while `resources.toml` pins the world actually in use. If that variable is ever lost, the server would silently start players on the wrong world.


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
- Vocard uses the published `ghcr.io/chocomeow/vocard:v2.7.3` (pinned). It was briefly a local build of `v2.7.3b3` to get a Voicelink fix for Lavalink 4.2.x ahead of a stable tag; `v2.7.3` shipped 2026-05-09 with the Voicelink refactor, so the local build is gone. Lavalink runs as a **separate service**, which is what 2.7.3 expects — that release dropped the bundled Docker-based Lavalink setup.
- **Vocard waits on `lavalink: service_healthy`, not `service_started`.** Lavalink needs ~4s to finish booting its plugins; v2.7.3 opens its node connection immediately and does *not* retry, so starting them together leaves a bot that looks perfectly healthy but cannot play anything. The healthcheck uses `bash /dev/tcp` because the Lavalink image has no netcat — `nc -z` would pin it at unhealthy and deadlock the stack.
- `logging.max-history` in `settings.json` was renamed to `max_history` in v2.7.3; the live file has been updated.
- Lavalink plugins: youtube-plugin 1.18.2, lavasrc 4.8.3, lavasearch 1.0.0, lavalyrics 1.1.0
- Lavalink uses yt-cipher for external YouTube cipher resolution (`remoteCipher` in application.yml)
- Lavalink JVM tuning: `-Xmx512M -XX:+UseG1GC -XX:MaxGCPauseMillis=20`
- Vocard Dashboard accessible at `seraphine.example.com`
- Vocard translation keys in settings.json use flattened dot notation (e.g. `@@t_player.buttons.back@@`)
- V Rising's image is built locally from `configs/vrising/Dockerfile` and exists in no registry, so `auto_pull`/`auto_update` must stay off for that stack. `scripts/update-vocard-lavalink.sh` bumps the Lavalink plugin jars in `${CONFIGS}`.
- Game servers both have `stop_grace_period: 120s`: V Rising's world is 254MB and autosaves every few seconds, so a 10s default SIGTERM can land mid-write.

## Alerting: deep-linked Discord notifications

`komodo-discord-forwarder.service` sits between Komodo and Discord so every alert
carries a link to the stack it came from.

**Why it exists.** A Discord webhook is one-way: it cannot receive interactions,
so a real "Update" *button* is impossible without registering a Discord
application and exposing an interactions endpoint to the internet — a new public
attack surface on the box that holds everything. Komodo cannot help either:
`AlerterConfig` only carries resource filters (`resources`,
`except_resources`), with no message template, and every endpoint type is just a
`url`. So the link has to be added in a middlebox. The result is a link, not a
button: you land on the stack page and click Deploy yourself, which is the right
trade since the deploy stays authenticated and deliberate.

**Alerters.** `discord-links` (Custom → the forwarder) is live. The original
`discord` alerter is **disabled, not deleted**, so it is one toggle to go back.

**Payload.** The Custom endpoint receives a nested envelope; the resource lives
in `target`, and `target.id` is the Komodo resource id. The UI route is
`/stacks/<id>`, so the id alone is enough to build the link:

```json
{"ts":…,"resolved":false,"level":"OK",
 "target":{"type":"Stack","id":"6ab8f2bcca74d25672a1c6da"},
 "data":{"type":"StackUpdateAvailable","data":{"id":"…","name":"immich"}}}
```

`target.type` is `Alerter` for a *Test*, and the real resource type otherwise.
`resolved: true` marks a resolution and is rendered as ✅ rather than dropped, so
nothing Komodo tells you is silently discarded. Anything unrecognised is logged
verbatim to journald so the parser can be tightened against real traffic.

**Gotchas that cost time here:**

- **Discord 403s `Python-urllib/3.x`.** Cloudflare fronts the webhook endpoint
  and rejects the default agent. A browser `User-Agent` is required; `curl` is
  accepted, which is why a curl probe works while the Python service 403s.
- **`ExecStart` needs `python3 -u`.** Without it stdout is block-buffered under
  systemd and the service looks like it is doing nothing at all.
- **It binds to `172.25.0.1:9911`**, the docker bridge, so nothing on the LAN
  can post to it. Do not "fix" this to `0.0.0.0`.
- **It replies 200 before posting to Discord**, so a slow Discord can never make
  Komodo think an alert failed.
- **Komodo's read API strips `_id`.** `ListStacks` and `ListAlerters` return
  objects with no id, so anything addressed by id (`UpdateAlerter`) cannot be
  driven purely through those. The collection is `Alerter`, capital A.
- **Alerter config nests as** `{enabled, endpoint:{type, params:{url}}}`.
  A flat `{type, url}` silently creates a *disabled* alerter instead of erroring.
  `UpdateAlerter` requires `id` and rejects a name.
