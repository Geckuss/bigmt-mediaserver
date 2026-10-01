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
- **Management**: Komodo (`https://komodo.example.com`, Tailscale only) — Portainer was removed 2026-09-28

## Deploys: git is the source of truth

Every stack is declared in this repo and deployed by **Komodo** from a git clone. There is no host-side compose file to edit any more.

| | |
|---|---|
| Komodo UI | `https://komodo.example.com` (Tailscale only, via Caddy `private_only`) |
| Compose files (cloned) | `/etc/komodo/stacks/<stack>/` — Periphery's `root_directory` is `/etc/komodo`, so anything outside it is invisible to Komodo |
| Resource declarations | `komodo/resources.toml`, applied by the `bigmt` Resource Sync |
| Web UI | `komodo.example.com`, admin creds in `${CONFIGS}/komodo/core.config.toml` (root-only) |

To change anything:

1. Edit the compose file in `stacks/`, or `komodo/resources.toml` for Komodo's own config.
2. `git push`.
3. In Komodo run **`DeployStackIfChanged`** on the stack. It diffs first, so a no-op costs nothing.

Never edit the files under `/etc/komodo/stacks/` by hand — the next deploy overwrites them. Never let a second compose manager touch a project Komodo owns; two managers on one compose project fight.

**Secrets** are not in git and not in `resources.toml`. The stacks reference `[[VARIABLE]]` names; the values live in Komodo as variables flagged secret, in the Mongo store under `${CONFIGS}/komodo`.

**Infrastructure identifiers are a separate problem from credentials, and two
files still hold the real values.** Hostnames, the tailnet name, and the host IPs
are needed by the tools that read them: the Resource Sync applies
`komodo/resources.toml` verbatim, and `scripts/komodo-discord-forwarder.py` is
installed as a systemd unit. Everywhere else the repo uses placeholders
(`example.com`, `<TAILSCALE_HOSTNAME>`, `<HOME_WAN_IP>`) and that should stay the
default — a real value in a doc or comment is pure leak, because nothing reads it.
The two exceptions are deliberate for now and are the known remaining leak in an
otherwise anonymized repo. To close them: move the `links` in `resources.toml` to
Komodo variables, and give the forwarder a `UI_BASE` env var in its unit file.

**Three gotchas that cost real time here:**

- **`DeployStackIfChanged` diffs against Komodo's record of the last deploy, not against the live containers.** Delete or stop a container out of band and it reports "no change" and does not bring it back. Use a full `DeployStack` to reconcile. Compose `up -d` is otherwise idempotent — it only recreates services whose config actually differs, so a full deploy is cheap.
- Compose does **not** remove a service you delete from the file. It prints `Found orphan containers (...)` and leaves them running. `mediastack` carries `extra_args = ["--remove-orphans"]` for exactly this reason.
- The Resource Sync is a **partial merge**. It rewrites any field `resources.toml` does not declare, using the schema default, and omitting a field does **not** clear it. Declare `auto_pull = false` explicitly on every stack; the default is `true`, and nearly every image here is a floating tag.

### Driving the Komodo API directly

When the UI is not an option (it is Tailscale-only), Core's API is on
`http://localhost:9120` from bigmt. Worth writing down, because none of this is
guessable and all of it cost time:

- **Get a token:** `POST /auth/login/LoginLocalUser` with `{username, password}`
  from `core.config.toml` (`init_admin_username` / `init_admin_password`). The JWT
  is **nested**: `{"type":"Jwt","data":{"jwt":"..."}}`, not at the top level.
- **Send it as `Authorization: Bearer <jwt>`.** The header is *not* `jwt:` and
  *not* `X-Api-Key` — those are the separate API-key schemes, and using them
  returns `{"error":"Invalid client credentials"}` with a 200.
- **The OpenAPI spec is embedded in the docs page**, not served as a file:
  `curl -s http://localhost:9120/docs` has it in a
  `<script id="api-reference" type="application/json">` block. `/openapi.yaml`
  and `/openapi.json` are both 404. Pulling the schema from there is far faster
  than guessing request bodies.
- **Execute calls take names, not id lists:** `RunSync` wants `{"sync":"bigmt"}`,
  `DeployStackIfChanged` wants `{"stack":"vocard"}`. Passing `{"ids":[...]}` gets
  `missing field 'sync'`.
- **A stack's environment block is `config.environment`,** not `config.env`. It
  holds the raw `NAME = [[NAME]]` links from `resources.toml`; the resolved
  values are only in the rendered `.env` on the host.
- **Creating a variable is not enough on its own.** `CreateVariable` makes the
  Komodo variable, but the stack only receives it after the Resource Sync runs,
  and the Sync reads `master` **on GitHub** — so an unpushed commit means the
  variable never reaches the stack. Order is: create variable, push, `RunSync`,
  then deploy.

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
- **That unit must not have `RemainAfterExit=yes`.** It did, and the consequence
  was a silent no-op: a `Type=oneshot` with `RemainAfterExit` latches into
  `active (exited)` after its *first ever* run and stays there, so every later
  `systemctl start` returns 0 without running anything. `SuccessExitStatus=0 1`
  (which must stay — an unplugged drive is normal and must not fail boot) also
  means a latched unit reports success whether or not it did anything, so there
  is no feedback either way. Removed 2026-09-29. The unit lives only on the host
  at `/etc/systemd/system/backrest-guard.service`, **not in this repo**, so
  nothing here will catch it being re-added — if `start` ever stops working
  again, check that line first. `daemon-reload` does not clear an existing latch
  either, so a fix needs `systemctl stop` before `start` will run it again.

The guard must be host-side: inside the container the bind mount looks mounted, and Docker auto-creates missing bind sources, so neither a mountpoint test nor a marker file works from in there. Without it, restic inits a brand new empty repo on the root SSD and reports every plan as successful.

**`configs/backrest/config.json` is a sanitized bootstrap copy, not the live
config.** It exists for `DISASTER-RECOVERY.md` and diverges from
`${CONFIGS}/backrest/config/config.json` on the host — that one also carries
real repo passwords, a Discord webhook URL, bcrypt hashes and an ed25519 host
key. **Never `cp` the repo file over the live one**; it would clobber all of
them. Edit the live file surgically instead.

**Put notification hooks on the repo only, never on a plan.** Backrest's
`TasksTriggeredByEvent` walks repo hooks *and then* plan hooks, both firing on
a match, so a plan hook overlapping a repo hook posts every event twice — and
that is exactly what was happening for `critical`. A repo hook already covers
every plan, so the plan-level hook bought nothing except duplicates. Add any
new condition (`CONDITION_PRUNE_SUCCESS` was the one) to the repo hook.

Two hook-template facts, both learned the hard way. `{{ .Summary }}` prints
`Total duration: 35704.901828028s` because `SnapshotStats.TotalDuration` is a
`float64`, not a duration — `.Duration` is a real `time.Duration`, so
`.FormatDuration` is what you want. And the template function set is *only*
`HookVars`' own methods: no Sprig, so `default`, `trim` and friends do not
exist. `{{ if .Plan.Id }}` with an `{{ else }}` is the fallback.

The template is verified by rendering it, not by reading it. Copy
`configs/backrest/config.json` to a scratch dir, render the `template` string
against a stub mirroring `HookVars`, and check no `{{` survives in the output.

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

## oci: hand-managed containers

oci is **not** Komodo-managed. Everything there is a plain `docker run --restart unless-stopped` or a systemd unit, so nothing in this repo deploys it. The `proxy/Caddyfile` on oci is the live copy of `proxy/Caddyfile` here — edit the repo one and copy it across; oci is the one place that is still a hand-managed host.

Containers: `valheim-udp` (the Valheim UDP relay, see the game-server section) and the Pterodactyl Wings container on 25567 (see `PTERODACTYL.md`).

**Docker ports on oci bypass ufw.** `DOCKER-USER` is empty, and Docker's published-port chains are evaluated ahead of ufw's rules, so `ufw default deny incoming` does **not** protect a `-p` published port. Only the OCI security list did: 9443 and 8000 stayed closed while 9000 was open to the internet. Treat the security list as the real firewall for anything published, and prefer not to publish at all.

**A second Portainer instance lived here until 2026-09-28.** The migration to Komodo removed the one on bigmt; this one on oci was missed and kept running for a day with `restart: always`, publishing its admin UI on 9000 to the whole internet. Removed. `portainer_data` (288K) is still on disk as a rollback copy — it holds `portainer.db`/`portainer.key` and an old `compose/3/stack.env` with a **plaintext Valheim server password**, so it is a candidate for `docker volume rm` rather than a file to keep.

**Also cleaned up:** the pre-move Valheim install at `/home/ubuntu/valheim` (exited 6 months, `tsxcloud/valheim-arm`, `compose.project=gamestack`, 1.8G — almost all of it the re-downloadable game install) and two exited Pterodactyl Wings containers. The world saves in there were the last copy of a world that never existed on bigmt; they were archived, then deleted on request. `/var/lib/pterodactyl/volumes/*` was deliberately left alone — those are live server files that Wings recreates containers around.

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

**Watch out — this is now a loud failure, not a silent one.** `stacks/valheim.yml` sets `SERVER_NAME` and `WORLD_NAME` with `${VALHEIM_SERVER_NAME:?...}` / `${VALHEIM_WORLD_NAME:?...}` — **no inline default**, on purpose. An older, abandoned world with a similar name still exists on the host, so a fallback would silently drop players on the wrong world. `${VAR:?}` makes compose refuse to render instead, and the values come from Komodo variables (`komodo/resources.toml` declares `VALHEIM_WORLD_NAME = [[VALHEIM_WORLD_NAME]]`). Losing the variable now stops the deploy loudly; it can no longer start the wrong world.


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
- Lavalink plugins: youtube-plugin `2be8e542` (a `main` **snapshot**, see below), lavasrc 4.8.3, lavasearch 1.0.0, lavalyrics 1.1.0
- Lavalink uses yt-cipher for external YouTube cipher resolution (`remoteCipher` in application.yml)
- Lavalink JVM tuning: `-Xmx512M -XX:+UseG1GC -XX:MaxGCPauseMillis=20`
- Vocard Dashboard accessible at `seraphine.example.com`
- Vocard translation keys in settings.json use flattened dot notation (e.g. `@@t_player.buttons.back@@`)
- V Rising's image is built locally from `configs/vrising/Dockerfile` and exists in no registry, so `auto_pull`/`auto_update` must stay off for that stack. `scripts/update-vocard-lavalink.sh` bumps the Lavalink plugin jars in `${CONFIGS}`.
- Game servers both have `stop_grace_period: 120s`: V Rising's world is 254MB and autosaves every few seconds, so a 10s default SIGTERM can land mid-write.

## Vocard: two independent 2026-09-28 outages

Both hit the same stack within hours of each other and neither was visible in the
Komodo UI, so they are written down here in full.

### 1. `vocard-db` could not start at all (mongo vs kernel 7.0)

`mongo:8` was a floating tag. Komodo pulled a build from 2026-09-16, and when the
container was next recreated, `mongod` refused to boot:

```
MongoDB cannot start: Linux kernel versions 6.19 and newer has a known
incompatibility with this version of MongoDB.  (SERVER-121912)
```

The host runs `7.0.0-31-generic`, so it crash-looped (233 restarts) and the bot
lost its database while still sitting there "Up" and gateway-connected.

**This is a false positive on this host, and the pin to `mongo:8.2.12` in
`stacks/vocard.yml` is deliberate rather than a rollback.** The real bug is a
TCMalloc/rseq ABI break in kernel 6.19, and the kernel-side fix (Gleixner's
"rseq: Revert to historical performance killing behaviour") is in Ubuntu
7.0.0-28+, so this x86_64 box already has it. MongoDB's startup check parses
`7.0.0-31` as `7.0.0`, sees it below 7.0.14, and refuses to start anyway. That is
MongoDB's own bug, **SERVER-131779**, fixed in **8.0.35 / 8.3.14 / 9.0.3** — and
8.3.14 was not published yet, so no image with the fix could be had. 8.2.12 is
the build that actually wrote `mongodb_data`, so the pin also means no version
migration in either direction.

**To get off this pin, put the host on a kernel below 6.19** — `linux-image-generic`
on noble is 6.8.0-142. NVIDIA is DKMS (580.178.04) and the box is headless
(`multi-user.target`), so the module rebuilds itself and only a reboot is needed.
Until then, do not "fix" this by moving to a newer mongo: every current 8.x exits on
kernel 6.19 through 7.0.13.

**The lesson is the tag, not MongoDB.** Any floating `:latest`-style tag on an
image whose owner can add a startup guard is a way to lose a service silently.
`mongo:8` and `mongo:8.2.12` differ only by that guard.

### 2. Nothing could play (youtube-plugin vs YouTube)

With the database back, the next layer showed: search and metadata worked, but
**every** track failed at stream resolution — 0 successful plays in 21 hours.

```
AllClientsFailedException: (yts.version: 1.18.2) All clients failed to load the item.
  TVHTML5             The page needs to be reloaded
  ANDROID_VR/MUSIC    This video requires login
  IOS                 Invalid status code for player api response: 400
  MWEB                Read timed out / 403
  WEB                 No supported audio streams available, available types:
  WEB_EMBEDDED_PLAYER This video is unavailable
```

`youtube-plugin` 1.18.2 (2026-07-27) was, and still is, the newest published
release. YouTube changed player behaviour after it; the `TVHTML5` playability fix
(youtube-source PR #233, issue #241) only ever landed on `main`. The maintainer's
standing advice is to use a remote cipher server, which `remoteCipher` already
does. The fix is therefore the `main` snapshot, pinned by commit hash so a restart
cannot silently pull different code.

Two things make this fail *quietly*, and both cost time here:

- **Search still succeeds.** `loadtracks` returns a perfectly good `loadType:
  search`/`track` because formats are resolved lazily, at play time. Checking the
  API "looks fine" while nothing can play. Confirm a real stream, not a search.
- **The bot does not report it well.** A failed play surfaces in Discord as a bare
  `Client [WEB_EMBEDDED_PLAYER] failed: This video is unavailable` with no hint
  that all seven clients died.

After changing the plugin, restart `lavalink` **and then `vocard`** — the bot does
not re-register with the node on its own. Removing the stale jar from
`${CONFIGS}/vocard/lavalink/plugins/` matters too, since that directory is
bind-mounted and Lavalink loads whatever is in it.

`scripts/update-vocard-lavalink.sh` now skips snapshot pins instead of reverting
them. It used to grep the version as `[0-9][0-9.]*`, which truncated
`2be8e542...` to `2` and would have rewritten the coordinate to
`1.18.2be8e542...` — i.e. running the updater is what would have re-broken it.

## Game servers: reaching them from the internet

Neither game server has a public IP. bigmt is `<BIGMT_LAN_IP>` behind the home
router, whose WAN address is `<HOME_WAN_IP>`, and the router forwards **no** game
ports — verified by sending UDP from oci to that WAN address on every game port
and confirming with `tcpdump` on bigmt that nothing arrives. So there is no route
in, and the two games solve this in completely different ways.

**V Rising needs nothing.** It is reached over **Steam's own relay (SDR)**, which
traverses the NAT, so it appears in the Steam community server list and works for
friends anywhere. There is no Caddy block, no DNS record, and no proxy for it.
Leave it that way. Its host ports are `9878`/`9879` (container `9876`/`9877`).

**Valheim cannot use that mechanism, so oci relays it.** Valheim's default Steam
backend advertises a bare IP, and the community browser A2S-queries that address,
so behind NAT the query fails and Steam drops the entry within ~5 minutes. The
official fix — `-crossplay`, which relays through PlayFab and explicitly needs no
port forwarding — is **unusable here because it is incompatible with BepInEx**,
and this server is modded. Enabling it would silently drop the whole mod stack.

So `proxy/nginx-stream.conf` runs on oci as the `valheim-udp` container and
forwards UDP `2456`/`2457` over the tailnet to `<BIGMT_TAILSCALE_IP>`.
`valheim.example.com` already resolves to oci, so no DNS change was needed.
Caddy cannot do this job: Valheim is UDP and Caddy speaks HTTP only.

**Consequences to remember:**

- **`SERVER_PUBLIC` must stay `false`** (it is a variable, `VALHEIM_SERVER_PUBLIC`).
  Setting it true registers the server, then Valve's A2S query to the router's WAN
  address fails and the entry disappears. It is a way to *confirm* the diagnosis,
  not a way to get a listing.
- Players join with **Join IP** → `valheim.example.com`, not the server browser.
- `proxy_timeout 300s` is deliberate. nginx's 10s default would kill an idle
  player long before Valheim's own keepalive.
- No `load_module` line for stream: in the official nginx image the core
  `ngx_stream_module` is compiled into the binary, so `load_module` fails with
  `dlopen() ... No such file or directory`. Only the geoip/js submodules are `.so`.
- oci's `ufw` needed `allow 2456/udp` and `allow 2457/udp` (its INPUT policy is
  DROP). The **OCI security list was already open** for them, so no console change
  was required — worth re-checking there if the relay ever stops working from
  outside.
- oci is not Komodo-managed, so the container is plain `docker run
  --restart unless-stopped` like the other hand-managed containers there.
- The tailnet has **no ACL file** (`PacketFilter: 0` rules = allow-all), which is
  why oci → bigmt on these ports needs no Tailscale policy change. Adding a
  restrictive ACL later would break the relay.

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
