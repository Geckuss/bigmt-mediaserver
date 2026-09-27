# Portainer → Komodo

Plan to replace Portainer CE on **bigmt** with [Komodo](https://komo.do) (GPL-3.0, no feature gating), and to use Komodo's git-driven / declarative features instead of hot-editing compose files on the host.

Decisions taken: **Core on bigmt (tailnet-only)**, **git repo + TOML Resource Sync as source of truth**, **run both in parallel, cut over after full migration**. Entry point / scope of the first pass is TBD — see [Phase 2](#phase-2--adopt-stacks).

---

## 1. Current state (verified on bigmt)

Docker 29.8.1, Ubuntu 24.04, x86_64, `git` 2.43 present, NVIDIA GPU.

| Portainer stack | Compose project name | Services | Config files on host |
|---|---|---|---|
| 1 | `mediastack` | 15 | `portainer_data/_data/compose/1/docker-compose.yml` + `/data/compose/1/…` |
| 16 | `immich` | 4 | `portainer_data/_data/compose/16/docker-compose.yml` |
| 26 | `vocard` | 6 | `portainer_data/_data/compose/26/docker-compose.yml` |
| 27 | `homepage` | 2 | `portainer_data/_data/compose/27/docker-compose.yml` |
| 31 | `v_rising` | 1 | `portainer_data/_data/compose/31/docker-compose.yml` |
| 32 | `valheim` | 1 | `portainer_data/_data/compose/32/docker-compose.yml` |

- Secrets live in Portainer's `stack.env` next to each stack, and the shared `/data/.env`.
- Repo `Geckuss/bigmt-mediaserver` is **public** and holds only sanitized configs (`YOUR_BOT_TOKEN`, `<RESTIC_REPO_PASSWORD>`, …) — verified, so it is safe to use as a git source for Komodo without a token.
- Pterodactyl (Panel + Wings) runs on **oci**, not Portainer, and is out of scope.
- Glances uses a locally built image `glances-gpu:local` → Komodo can run `docker compose build` via `run_build` (Portainer couldn't from a host path).

### 1.1 Container inventory (32 containers, 6 projects)

| Project | Containers | Actual coupling |
|---|---|---|
| `mediastack` | 15: jellyfin, radarr, sonarr, prowlarr, bazarr, jellyseerr, qbittorrent, handbrake, pihole, backrest, uptime-kuma, scrutiny, seafile, seafile-mysql, seafile-memcached | **mostly none** — the `*arr` chain talks over published *host* ports, not compose DNS. Only the seafile trio uses internal DNS (`DB_HOST=seafile-mysql`, `memcached` alias). |
| `immich` | immich_server, immich_machine_learning, immich_postgres, immich_redis | tight (`depends_on`, shared DB creds) |
| `vocard` | vocard, vocard-db, lavalink, yt-cipher, spotify-tokener, vocard-dashboard | tight (internal net, `depends_on: service_healthy`) |
| `homepage` | homepage, glances | **none** — homepage reaches Glances via `host.docker.internal:61208` (host network) |
| `valheim` | valheim | standalone |
| `v_rising` | vrising-modded | standalone |

### 1.2 Landmines found during the audit

- **`v_rising` in git is stale and would destroy the modded server.** The live stack 31 is a *modded* server: service/container `vrising-modded`, image `vrising-castlelink:latest` built locally on the host, `pull_policy: never`, ports 9878/9879, world dir `configs/vrising/modded/`. `stacks/vrising.yml` in this repo describes the *vanilla* server (`trueosiris/vrising`, container `vrising`, ports 9876/9877, `configs/vrising/`). A `DeployStackIfChanged` sourced from git would silently replace the modded world with a vanilla one. The `vrising-castlelink` Dockerfile is not in the repo either.
- **`valheim` (stack 32) is not in this repo.** Its compose file lives only in `portainer_data/_data/compose/32/docker-compose.yml`. It cannot be git-driven until exported to `stacks/valheim.yml`.
- **Anonymous volumes** (only two, both disposable, but worth pinning): `handbrake` → `/trash` and `vocard-db` → `/data/configdb`, both declared by the *image* not by compose. Recreating those containers orphans them. Convert to explicit bind mounts under `${CONFIGS}` while touching those stacks.
- `mediastack` and `vocard` both sit on CPU hard (`vrising-modded` ~120%, `valheim` ~18%) — irrelevant to the migration, but `stop_grace_period: 120s` on valheim means a stop can take two minutes.

## 2. Target architecture

```
Internet → oci (Caddy, TLS) ──Tailscale──→ bigmt
                                            ├── komodo-core   :9120   (UI/API/webhooks/state)
                                            ├── mongo                    (Komodo state DB)
                                            └── komodo-periphery :8120   (systemd, executes everything)
```

- **Outbound Periphery.** Periphery dials Core (`PERIPHERY_CORE_ADDRESS=https://komodo.example.com`) over Tailscale. No inbound port, no `allowed_ips` juggling. Auth is a Noise handshake with auto-rotated ed25519 keys — no shared tokens to leak.
- **Core binds only to the tailnet.** Caddy on oci proxies `komodo.example.com` → `http://<TAILSCALE_HOSTNAME>:9120` with `X-Forwarded-Host` (Caddy sets it by default).
- **Komodo's own stack is not managed by Komodo.** It is a plain `docker compose -p komodo` project, version-controlled in this repo, bind-mounted under `${CONFIGS}/komodo/…` so Backrest already covers it.
- **Periphery runs as a systemd service, not a container** — containerized Periphery drops your terminals into the Periphery container instead of the host, and its network stats are wrong unless it is `network_mode: host` (komodo#1479).

## 3. Gotchas that decide the plan

| # | Gotcha | Consequence for us |
|---|---|---|
| 1 | Komodo **adopts** a running project only if the compose project name matches the Stack name; otherwise `compose up` recreates the project and orphans named volumes | Name every Stack exactly `mediastack`, `immich`, `vocard`, `homepage`, `v_rising`, `valheim`, or set `project_name` explicitly. Never rename a Stack without setting `project_name`. |
| 2 | Periphery is confined to `root_directory` (default `/etc/komodo`): "all your compose files and repos need to be inside this directory" | Do **not** point Periphery at `/data`. Git-based stacks clone under the root dir, so the `/data/.../compose/<id>/` files become dead weight. |
| 3 | `StopAllContainers` / `RestartAllContainers` / `PruneSystem` hit **every** container on the host, including Komodo itself | Never use them. Label mongo/core/periphery with `komodo.skip:` (Komodo's own compose does). Only `PruneImages` is safe to schedule. |
| 4 | **CVE-2026-82267** (≤ 2.3.2): `/execute` writes audit entries before permission checks and leaks internal resource IDs | Pin `ghcr.io/moghtech/komodo-core:2.3.3` (or `:2`). Never 2.3.2. |
| 5 | `init: true` is required on Core and Periphery in v2, else zombies accumulate | Set it. |
| 6 | Git tokens are written **in cleartext** to `<root>/stacks/<stack>/.git/config` (komodo#1537) | Repo is public → clone anonymously, leave `git_account` empty. Never put a PAT in Komodo for this repo. |
| 7 | GitHub cannot reach a tailnet-only Core, so webhooks will never arrive | Drive redeploys from **schedules** (`DeployStackIfChanged` on a cron), not webhooks. See [Phase 3](#phase-3--make-it-git-driven). |
| 8 | Komodo's own docs: variables/secrets "may not fill enterprise level secret management requirements", and env/secret values can persist in Update records | Keep secrets in a root-only `${CONFIGS}/komodo/core.config.toml` `[secrets]` block, back up the Mongo volume, and accept that stack env values are visible to admins in the audit trail. Don't reuse the Pi-hole / Seafile / DB creds anywhere you wouldn't. |
| 9 | v2 images are Debian Bookworm / OpenSSL 3; `latest` tag is deprecated | Track `:2` or `:2.3.3`. Periphery binaries need glibc ≥ 2.36 — Ubuntu 24.04 is fine. |
| 10 | No Portainer importer exists (maintainer-confirmed) | Adoption is manual, one stack at a time. Community tool `komodo-import` (FoxxMD) is worth a look but not needed at 6 stacks. |
| 11 | Swarm is 6 months old and rough; Kubernetes is unsupported | Stay on plain Compose. Komodo is still the right call unless K8s lands on the roadmap. |

## 4. Phases

### Phase 0 — Repo prep (no server changes)

1. `stacks/komodo.yml` — Core + mongo (+ optional Periphery for a second host later). Bind mounts:
   - `mongo-data` → `${CONFIGS}/komodo/mongo/data`
   - `keys` → `${CONFIGS}/komodo/keys`
   - `${CONFIGS}/komodo/backups` → `/backups`
   - `${CONFIGS}/komodo/core.config.toml` → `/config/config.toml` (root-only, **not** in git)
   - `komodo.skip:` labels on all three services, `init: true` on core/periphery
2. `komodo/resources.toml` — the declarative source of truth (sketch in §5).
3. `komodo/variables.toml` — non-secret variables only, `[[VAR]]`-interpolated by the sync.
4. `proxy/Caddyfile` — add a `komodo.example.com` block (phase 4, after Core is up).
5. `.gitignore` — add `komodo/*.local.toml`, `*.env` under `komodo/`.

### Phase 1 — Stand up Core + Periphery (Portainer untouched)

1. Copy `stacks/komodo.yml` → bigmt, create `${CONFIGS}/komodo/`, `chmod 600 core.config.toml`.
2. Generate secrets: `KOMODO_JWT_SECRET`, `KOMODO_WEBHOOK_SECRET`, `KOMODO_DATABASE_PASSWORD`, admin password.
3. Harden auth in the env file:
   - `KOMODO_DISABLE_USER_REGISTRATION=true`
   - `KOMODO_ENABLE_NEW_USERS=false`
   - `KOMODO_DISABLE_NON_ADMIN_CREATE=true`
   - `KOMODO_MONITORING_INTERVAL=30-sec`, `PERIPHERY_INCLUDE_DISK_MOUNTS=/etc/hostname,/data,/mnt/backup-5tb,/mnt/backup-1tb`
4. `docker compose -p komodo up -d` (outside Komodo, deliberately).
5. Install Periphery via the systemd script with `--core-address=https://komodo.example.com --connect-as=bigmt --onboarding-key=O-…`, then `systemctl enable periphery`.
6. Add the Caddy block on **oci** and reload; verify UI + `/docs` (OpenAPI) + `/schema/resources.json`.
7. Confirm in the UI: server `bigmt` is **OK**, disk mounts show up, terminals open a *host* shell.

Exit criteria: Komodo UI reachable over Tailscale; `bigmt` server OK; **no workload touched**.

### Phase 2 — Adopt stacks

Portainer stays up throughout. Before adopting anything, fix the two drift bugs in §1.2: rewrite `stacks/vrising.yml` to match the live modded server (and commit the `vrising-castlelink` Dockerfile), and export `stacks/valheim.yml` from stack 32.

For each stack, create a Komodo Stack with the config in §5/§6, then **Deploy → `DeployStackIfChanged`** (not `DeployStack`) and watch the diff. Adopt in ascending blast radius; the exact first pick is TBD:

| Order | Stack | Why |
|---|---|---|
| 1 | `v_rising`, `valheim` | 1 container, no database, UDP ports, trivial rollback |
| 2 | `homepage` | 2 containers; also validates the `glances-gpu:local` build path |
| 3 | `vocard` | Local image + `pull_policy: never` → proves `run_build` and `post_deploy` |
| 4 | `immich` | Stateful (Postgres); back up `/data/backups` first |
| 5 | `mediastack` | 15 services, 4 databases, GPU, host networking — last, with a maintenance window |

Per-stack checklist:
- Stack name == project name (§3 #1).
- Move that stack's secrets from `stack.env` into Komodo variables (mark secret) or the Core `[secrets]` block; verify the generated `.env` renders `${DATA}`/`${CONFIGS}` correctly.
- First deploy must be `DeployStackIfChanged`; if it wants to recreate a container, stop and fix the diff.
- Confirm `docker compose ls` still shows the same project name and the same container IDs afterwards (or a clean recreate with intact volumes).

### Phase 3 — Make it git-driven

1. Every Stack gets `repo = "Geckuss/bigmt-mediaserver"`, `branch = "master"`, `git_provider = "github.com"`, **no `git_account`** (public repo, anonymous clone).
2. `file_paths = ["stacks/immich.yml"]` — relative to the clone; `run_directory` stays at the default clone dir.
3. Import the current on-host env into the Stack `environment` block so the repo is genuinely self-sufficient.
4. Add `config_files` for the extra files you want editable/diffable in the UI (e.g. `configs/vocard/lavalink/application.yml`, `configs/homepage-config/*`) — they also feed the `DeployStackIfChanged` diff.
5. Create the Resource Sync pointing at `komodo/resources.toml`, `resource_path = ["resources.toml", "variables.toml"]`.
   - Keep `delete_unmatched = false` for the whole migration; flip on only after everything is stable.
   - `ui_write_disabled = true` once the TOML is authoritative, so the UI can't drift from git.
6. Because webhooks can't reach a tailnet Core (§3 #7), schedule redeploys:
   - A `Procedure` "sync-and-redeploy" with a **6-field cron** (seconds required), e.g. `0 */10 * * * ?`, stage 1 `RunSync` on the sync, stage 2 `BatchDeployStackIfChanged` with `pattern = "*"` and tag filter.
   - Same for an overnight `BatchPullStack` + `BatchDeployStackIfChanged` (see §7 for why not `auto_update`).
7. Enable `send_alerts` per stack and configure an Alerter (ntfy or Discord, `Custom` type) with a resource whitelist + a maintenance window for the 03:00–05:00 redeploy slot.

### Phase 4 — Cut over

1. Stop all Portainer stacks, then remove the Portainer container and its `portainer_data` volume (keep a tar of `compose/*/docker-compose.yml` + `stack.env` for reference).
2. Drop the `portainer.example.com` block from `Caddyfile`; add `komodo.example.com`; `caddy reload` on **oci**.
3. Rewrite the "Portainer Stack Files & Hot Deploys" section of `agents.md` → Komodo workflow (git push → sync → deploy; no more `sudo` edits under `portainer_data`).
4. Update `README.md` architecture diagram: Portainer → Komodo Core/Periphery.
5. Verify Backrest has a recent plan including `${CONFIGS}/komodo` and that `Backup Core Database` (Komodo's default daily procedure) is writing into `${CONFIGS}/komodo/backups`.
6. Add a Komodo card to Homepage (`services.yaml`) — a `Custom` API widget against `/api` with an API key, since Homepage has no native Komodo widget.
7. Run one full `DISASTER-RECOVERY.md` dry run from the Komodo-managed state.

Rollback: re-import the Portainer volume backup, `docker compose -p mediastack up -d` with the saved `stack.env`. Komodo never mutates data volumes, so rollback is a project re-create at most.

### Phase 5 — Restructure `mediastack` (do this *after* the cutover settles)

Do not restructure before migrating. Splitting first means 15 recreates under Portainer with no drift-aware deploy tool, then 15 more under Komodo. Adopt `mediastack` as one project, let Komodo prove itself for a week, then split — at that point every recreate is previewed by a `DeployStackIfChanged` diff.

A stack is a compose project, and its only real benefits are one shared `.env`, one project-scoped lifecycle command, and one private bridge network with DNS. It provides **no isolation** — no separate restart blast radius, no per-stack update cadence, no per-stack alerting, no resource accounting.

Target layout (15 services → 6 projects):

| New project | Services | Rationale |
|---|---|---|
| `downloads` | qbittorrent, radarr, sonarr, prowlarr, bazarr, jellyseerr, handbrake | One coupling unit: shared `${DATA}`, PUID/PGID/TZ, the `extract-subs.sh` + `install-ffmpeg.sh` mounts, and qBittorrent as the shared download client. They reach each other over published host ports, so this grouping is about *reconfiguration cadence*, not networking. |
| `jellyfin` | jellyfin | Host networking + GPU + the most user-visible service. Its own project means a Jellyfin reconfigure or rescan can never touch the `*arr` chain. |
| `pihole` | pihole | Fully independent. A pihole restart mid-deploy kills LAN DNS resolution *including for the deploy itself*. Keep it out of every other project. |
| `seafile` | seafile, seafile-mysql, seafile-memcached | Inseparable: `depends_on`, `DB_HOST=seafile-mysql`, the `memcached` network alias. Do not split. |
| `backrest` | backrest | The safety net must not be restartable by a workload deploy. |
| `observability` | uptime-kuma, scrutiny, **glances** (moved from `homepage`) | Your monitoring must not go down in the same `up -d` as what it monitors. Glances moves here — Homepage reaches it via `host.docker.internal:61208`, not compose DNS, so the coupling is already nil. |

**Do not** split further. One container per stack is just Portainer's container view with extra steps: it multiplies env namespaces, `.env` files, networks, and `project_name` values that can silently recreate a project. Keep `immich` (4), `vocard` (6), `valheim`, `vrising`, and `homepage` as they are.

Safety verified: every `mediastack` service is bind-mounted, and the only anonymous volumes in the whole box are `handbrake:/trash` and `vocard-db:/data/configdb`, both disposable. The split is 15 recreates with no data risk.

Steps:
1. Add `stacks/downloads.yml`, `stacks/jellyfin.yml`, `stacks/pihole.yml`, `stacks/seafile.yml`, `stacks/backrest.yml`, `stacks/observability.yml` to the repo; strip `mediastack` down or delete `stacks/docker-compose.yml` once the split is verified.
2. Pin the two anonymous volumes to bind mounts under `${CONFIGS}` while you're in there (`handbrake:/trash`, `vocard-db:/data/configdb`).
3. Create the 6 new Stacks, `project_name` = Stack name (new projects, so nothing to adopt — expect full container recreates, that's intended).
4. Order the cutover so the observers go up **first**: `observability`, then `downloads`, `jellyfin`, `seafile`, then `backrest` last, then destroy the old `mediastack` project.
5. Watch pihole: expect a few seconds of DNS interruption. Do it from a session that uses a raw IP, not a hostname.
6. `homepage` loses `glances` — remove the `network_mode: host` service and confirm the Glances tile in `configs/homepage-config/widgets.yaml` still points at `host.docker.internal:61208`.

## 5. `komodo/resources.toml` sketch

```toml
# non-secret variables (secrets live in the root-only core.config.toml [secrets] block)
[[variable]]
name = "DATA"
value = "/data"

[[variable]]
name = "CONFIGS"
value = "/data/backups/configs"

[[server]]
name = "bigmt"
description = "main mediaserver"
tags = ["prod"]
enabled = true
  [server.config]
  address = "https://komodo.example.com"
  region = "Helsinki"
  tags = ["prod"]

[[stack]]
name = "immich"
description = "Immich server + ML + valkey + postgres"
tags = ["prod", "media"]
deploy = false                     # never let a sync redeploy on its own
  [stack.config]
  server = "bigmt"
  repo = "Geckuss/bigmt-mediaserver"
  branch = "master"
  file_paths = ["stacks/immich.yml"]
  poll_for_updates = true          # indicator only; redeploys stay deliberate
  ignore_services = []
  links = ["https://immich.example.com"]

[[stack]]
name = "vocard"
tags = ["prod", "bot"]
  [stack.config]
  server = "bigmt"
  repo = "Geckuss/bigmt-mediaserver"
  branch = "master"
  file_paths = ["stacks/vocard.yml"]
  run_build = true                 # builds vocard:beta locally; pull_policy: never
  poll_for_updates = false         # local image, nothing to poll
  post_deploy.command = "/data/backups/configs/komodo/scripts/update-vocard-lavalink.sh"

[[procedure]]
name = "overnight-redeploy"
schedule_format = "Cron"
schedule_timezone = "Europe/Helsinki"
schedule_enabled = true
  [procedure.config.stage]
  name = "pull"
  executions = [ { execution.type = "BatchPullStack", execution.params.pattern = "*", execution.params.tags = ["prod"] } ]
  [procedure.config.stage]
  name = "deploy changed"
  executions = [ { execution.type = "BatchDeployStackIfChanged", execution.params.pattern = "*", execution.params.tags = ["prod"] } ]
```

A `[[resource_sync]]` pointing at `["resources.toml", "variables.toml"]` completes it. Point VS Code at `https://komodo.example.com/schema/resources.json` for autocomplete, and enable **Managed Mode** for the write-back path once we're happy editing in the UI.

## 6. Stack → Komodo config mapping

Common to all: `server = "bigmt"`, `repo = "Geckuss/bigmt-mediaserver"`, `branch = "master"`, no `git_account`.

| Stack | `file_paths` | Notable settings |
|---|---|---|
| `mediastack` | `stacks/docker-compose.yml` | 15 services, 4 databases, GPU, host networking — last, with a maintenance window. Adopt **as-is**; the split is Phase 5. |
| `immich` | `stacks/immich.yml` | `ignore_services = []`; `config_files = ["configs/…"]` if you want the Immich env editable. |
| `vocard` | `stacks/vocard.yml` | `run_build = true`, `build_extra_args = ["--build-arg", "…"]`; `post_deploy` replaces the manual `scripts/update-vocard-lavalink.sh`; `auto_update` **off** (local image). |
| `homepage` | `stacks/homepage.yml` | `run_build = true` for `glances-gpu:local` (or keep the prebuilt-image comment as-is). |
| `v_rising` | `stacks/vrising.yml` — **must be rewritten first**, see §1.2 | Live stack is the *modded* server (`vrising-modded`, `vrising-castlelink:latest`, `pull_policy: never`). Keep `auto_pull`/`auto_update` **off**. |
| `valheim` | `stacks/valheim.yml` — **must be created first**, see §1.2 | Export from `compose/32/docker-compose.yml`. Keep `stop_grace_period: 120s`. |

`network_mode: host` (jellyfin, pihole, glances) passes through untouched. GPU `runtime: nvidia` + `deploy.resources` also pass through. The only cosmetic difference: host-network containers show `-` for IPv4 in Komodo's container table.

## 7. Komodo features worth actually using

1. **`DeployStackIfChanged` everywhere.** Diffs the compose file, the env file, and any `config_files` first. This alone removes most of the "redeploy and pray" behaviour that Portainer forces.
2. **Resource Sync (TOML).** Terraform-shaped: computed diff before apply, `after = [...]` for cross-stack ordering (e.g. `mediastack` after `immich`), tag-filtered per-project syncs, `delete_unmatched` for pruning, and `ui_write_disabled` to make git the only write path.
3. **Procedures + schedules** replace every ad-hoc "hot deploy" in `agents.md`. Stages run in sequence, executions within a stage in parallel. ⚠️ Cron is **6-field** — `0 0 3 * * ?`, not 5-field.
4. **Actions (TypeScript in Deno)** replace shell scripts where logic is real. A pre-initialized `komodo` client means no API keys; `komodo.execute_server_terminal({...}, { onLine })` streams host command output. `update-vocard-lavalink.sh` and `dock-hdd.sh` are good first candidates — a TypeScript action is diffable in git, unlike a heredoc in the UI.
5. **Update polling without surprise restarts.** `poll_for_updates = true` shows a per-stack update badge; redeploy stays a scheduled/manual step. `auto_update_skip_services` excludes services you never want auto-moved. This is strictly better than running Watchtower next to Portainer.
6. **Alerters + state-change alerts + maintenance windows.** `send_alerts` per stack, Slack/Discord/Ntfy/Pushover built in, `Custom` (HTTP) for anything else, and a maintenance window so the overnight redeploy doesn't page you.
7. **Persistent terminals.** Named sessions, multiple viewers, 1 MiB scrollback, and scriptable from Actions — a better replacement for SSH-and-paste. They're child processes of Periphery, so they die if Periphery restarts (systemd + `restart: unless-stopped` makes that rare).
8. **Free RBAC.** `Read`/`Execute`/`Write` plus per-resource **regex** targets, OIDC/GitHub OAuth, TOTP 2FA, and a real audit trail via per-resource Updates. Portainer CE charges for this. Worth turning on if anyone else ever touches the box; otherwise set `KOMODO_DISABLE_NON_ADMIN_CREATE=true` and leave it.
9. **`pre_deploy` / `post_deploy` hooks** for the few things that must happen around a deploy (Lavalink plugin bump, `docker image prune -f --filter dangling`).
10. **`RunStackService`** (`docker compose run` against one service) — handy for one-off DB migrations on `immich_postgres` or `seafile-mysql` without hand-typing a compose command over SSH.
11. **Variable interpolation `[[VAR]]`** flows into the stack `.env` for `${DATA}`-style compose vars, so `.env.example` in the repo documents the same names Komodo fills in.
12. **Self-hosted DB backup** (`Backup Core Database`, daily by default, keeps 14) — but wire the volume under `${CONFIGS}` so Backrest covers it too. Don't rely on Komodo alone.
13. **`ignore_services`** for init/one-shot services so a stack reads healthy.

Deliberately **not** adopting: Kubernetes (unsupported), Portainer app templates (don't exist), Traefik/ingress label UI (you run Caddy on oci — irrelevant), `auto_update` on `:latest`/`release` tags (would make the running state diverge from git on a schedule you don't control), any bulk `*AllContainers` execution, `PruneVolumes` (your `/data` and backup mounts matter more than the disk), and global auto-update for `vocard:beta`.

## 8. Risks

| Risk | Mitigation |
|---|---|
| `project_name` mismatch silently recreates a project | Stack names identical to `docker compose ls` output; first deploy is always `DeployStackIfChanged`; verify container/volume state after each |
| Secret leak via git token in `.git/config` | Public repo, no `git_account`; never add a PAT for this repo |
| Komodo v2 UI flakiness right after a deploy | Don't cut over on the same day; keep Portainer for a stability week |
| `StopAllContainers` foot-gun | `komodo.skip` labels; never grant Execute on that execution to anything but yourself |
| Komodo state DB loss = lost resource definitions | Bind-mount under `${CONFIGS}/komodo` (Backrest), plus `km database backup` on schedule |
| Single-maintainer upstream risk | Version-pin, read release notes before upgrading, keep the repo TOML as the escape hatch — you can always `docker compose` by hand from git |
| Webhooks never firing | Don't design around them; schedules are the primary mechanism |
| Credentials visible in the audit trail | Acceptable for a single-admin homelab; don't reuse those creds elsewhere |

## 9. Open items

- Which stack to adopt first (`v_rising`/`valheim` recommended).
- Rewrite `stacks/vrising.yml` to the live modded server + commit the `vrising-castlelink` Dockerfile (**blocking** for that stack).
- Export `stacks/valheim.yml` from stack 32 (**blocking** for that stack).
- Confirm the `mediastack` split in Phase 5 is still wanted once things are stable — the analysis says yes, but it is the one piece of this plan that is pure churn with no functional requirement behind it.
- Whether to pin all `:latest` tags to explicit versions and drive bumps with Renovate (recommended) or leave them floating with `poll_for_updates` only.
- Alerter target: ntfy, Discord, or something else.
