# Disaster Recovery Runbook

## Scenario 1: bigmt (mediaserver) full rebuild

### Prerequisites

- Ubuntu 24.04 LTS installer USB
- Access to a verified backup drive: the new 12 TB repo (`/mnt/backup-12tb/restic-backrest`) or the legacy 5 TB repo (`/mnt/backup-5tb`)
- The restic repository password (stored in Backrest config / password manager)
- This git repo

### Step 1: Install Ubuntu

1. Install Ubuntu 24.04 LTS (Desktop minimal or Server)
2. Partitioning: use the 128 GB SSD as boot/root with LVM
   - `/boot/efi` — 1 GB (EFI System Partition)
   - `/boot` — 2 GB (ext4)
   - `/` — remaining ~116 GB (ext4 on LVM: `ubuntu-vg/ubuntu-lv`)
3. Create user `mobius` (UID 1000, GID 1000)
4. Set hostname to `bigmt`

### Step 2: Post-install base setup

```bash
# Passwordless sudo
echo "mobius ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/mobius

# Update system
sudo apt update && sudo apt upgrade -y

# Essential packages
sudo apt install -y curl ca-certificates git tmux btop lm-sensors smartmontools \
    net-tools iperf3 iptables-persistent screen wireguard pipx
```

### Step 3: Mount data drive

The 12 TB WD HDD labeled `data` is now a backup disk, not the live data disk.
Live `/data` is a ZFS pool on two 8 TB disks. Do not mount the old `data` label
at `/data` or format that disk: it contains old files and the new backup target.
Recover/import the ZFS pool, or prepare replacement data storage at `/data`,
before proceeding. The following historical ext4 commands are only for a
replacement **data** disk, with a different label:

```bash
# Verify the drive
sudo blkid

# Add to fstab
echo 'LABEL=data-replacement /data ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /data
sudo mount -a
```

If the data drive is dead/replaced, format it first:

```bash
sudo mkfs.ext4 -L data-replacement /dev/sdX1
```

### Step 4: Mount backup drive

Plug in the 5 TB Seagate Expansion and mount it:

For the new 12 TB repository instead, mount the verified UUID at
`/mnt/backup-12tb` and use `/mnt/backup-12tb/restic-backrest` as the bootstrap
container's `/repos/12tb` binding below. Keep existing disk contents.
Select `backup-12tb` and the `critical-12tb` / `media-12tb` plans when restoring.
See README's [mount safety instructions](README.md#mount-and-startup-safety).

```bash
sudo mkdir -p /mnt/backup-5tb
sudo mount /dev/disk/by-label/backup-5tb /mnt/backup-5tb
```

### Step 5: Install NVIDIA drivers

```bash
# Install driver (version 570 series)
sudo apt install -y nvidia-driver-570

# Reboot to load the driver
sudo reboot

# Verify after reboot
nvidia-smi
```

### Step 6: Install Docker

```bash
# Add Docker's official GPG key and repo
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add user to docker group
sudo usermod -aG docker mobius

# Configure Docker to use /data/docker and NVIDIA runtime
sudo mkdir -p /data/docker
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "data-root": "/data/docker",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

sudo systemctl restart docker
```

### Step 7: Install NVIDIA Container Toolkit

```bash
# Add NVIDIA container toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install -y nvidia-container-toolkit

# Restart Docker
sudo systemctl restart docker

# Verify GPU is visible to Docker
docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

### Step 8: Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Authenticate via the URL provided
# The machine should appear as "bigmt" in your Tailscale admin console
```

### Step 9: Restore from backup using Backrest

Bootstrap Backrest with the sanitized config from this repo, then restore everything via its web UI.

```bash
# Create Backrest directory structure
sudo mkdir -p /data/backups/configs/backrest/{config,data,cache}

# Copy the sanitized config template from the repo
# (you'll need to get this file from the repo — scp, git clone, or copy manually)
sudo cp configs/backrest/config.json /data/backups/configs/backrest/config/config.json
sudo chown -R mobius:mobius /data/backups/configs/backrest

# Create placeholder directories that Backrest expects to mount
sudo mkdir -p /data/media/gallery /data/downloads

# Start Backrest standalone (before the full stack is deployed)
docker run -d --name backrest-bootstrap \
  -p 9898:9898 \
  --tmpfs /repos:ro,size=1m \
  -v /data/backups/configs/backrest/data:/data \
  -v /data/backups/configs/backrest/config:/config \
  -v /data/backups/configs/backrest/cache:/cache \
  -v /mnt/backup-5tb:/repos/primary \
  -v /data/backups/configs:/userdata/configs \
  -v /data/media/gallery:/userdata/immich-uploads \
  -v /data/media:/userdata/media \
  -e BACKREST_DATA=/data \
  -e BACKREST_CONFIG=/config/config.json \
  -e XDG_CACHE_HOME=/cache \
  garethgeorge/backrest:latest
```

The template includes legacy repos/plans plus the new 12 TB repo and plans.
It is a bootstrap template, not a replacement for the live config. Only `primary-5tb`
is mounted by the bootstrap `docker run` above, so `secondary-1tb` and
`tertiary-1tb` (and their two `critical-*` plans) will show as unavailable
until you add `-v /mnt/backup-1tb:/repos/secondary` or just ignore them —
nothing is lost either way, since `DISASTER-RECOVERY.md` restores from
`primary-5tb`.

**Two fields are deliberately absent, and adding them back with placeholders
would break bootstrap.** Backrest validates its config at startup and refuses
to run if it fails, so a plausible-looking placeholder is worse than nothing:

- **No `auth` block.** Live holds bcrypt hashes; the copy omits the block
  entirely so the UI prompts for first-run account creation. A
  `"passwordBcrypt": "<BCRYPT_HASH>"` stub validates fine but makes login
  impossible, and the setup prompt never appears — you would be locked out.
- **No `sync` block.** Live holds a real ed25519 host private key.
  `cryptoutil.NewPrivateKey` requires base64 that decodes to a 32-byte seed
  *and* a matching public key, so any placeholder makes startup fail outright.
  Omitting it lets Backrest generate a fresh identity via
  `PopulateRequiredFields`.

Uninitialized template repos carry `"autoInitialize": true` instead of a `guid`.
When restoring an existing repo, enter its actual password before running any
operation, and do not initialize a new empty repo if your intended backup is
missing. Verify the host mount and repository contents first.
`validateRepo` requires a `guid` to be exactly 64 hex characters, and a
placeholder would both fail that check and imply a restic repo that does not
exist yet.

Then in the Backrest web UI (`http://<server-ip>:9898`):

1. **Create an account** — Backrest will prompt for initial user setup on first launch (the sanitized config has no `auth` block, which is what makes this prompt appear)
2. **Edit the repo** `primary-5tb` — fill in the real restic repo password (from your password manager)
3. **(Optional)** Update the Discord webhook URL if you want notifications
4. **Browse snapshots** for each plan and restore:
   - `critical` plan → restore `/userdata/configs` (writes to `/data/backups/configs`)
   - `critical` plan → restore `/userdata/immich-uploads` (writes to `/data/media/gallery`)
   - `media` plan → restore `/userdata/media` (writes to `/data/media/`, only if data drive was lost)
5. **Stop the bootstrap container** once restores are complete:

```bash
docker stop backrest-bootstrap && docker rm backrest-bootstrap

# Fix ownership
sudo chown -R mobius:mobius /data/media /data/backups/configs
```

> **Note:** When the full stack is deployed later (Step 11), Backrest will start with the now-complete config including all restored data.

### Step 10: Stand up Komodo

Komodo replaces Portainer as the thing that deploys the stacks. It is a compose project of
its own that Komodo does **not** manage — bring it up by hand, once:

```bash
git clone https://github.com/Geckuss/bigmt-mediaserver.git /tmp/bigmt-mediaserver
cd /tmp/bigmt-mediaserver
# generate KOMODO_JWT_SECRET / KOMODO_WEBHOOK_SECRET / KOMODO_DATABASE_PASSWORD /
# an admin password, then write them into the root-only config:
sudo mkdir -p /data/backups/configs/komodo
sudo cp stacks/komodo.yml /data/backups/configs/komodo-bootstrap.yml
sudo chmod 600 /data/backups/configs/komodo/core.config.toml
docker compose -p komodo -f /data/backups/configs/komodo-bootstrap.yml up -d
```

Then install Periphery as a systemd service and point it at Core:

```bash
sudo systemctl enable --now periphery
```

### Step 11: Deploy stacks

Each file in `stacks/` is a **Komodo Stack**; `komodo/resources.toml` declares all of them
and is the source of truth. In the Komodo UI, import the resource sync, then create the
Stacks it declares and deploy each with **`DeployStackIfChanged`**.

> **Warning:** A Stack's **name must equal its compose project name** (e.g. the `mediastack`
> Stack uses `stacks/docker-compose.yml`), or the first deploy silently recreates the whole
> project. If `DeployStackIfChanged` wants to recreate a container you did not touch, stop
> and fix the diff.

> ⚠️ `DeployStackIfChanged` diffs against Komodo's record of the last deploy, **not** against
> the live containers. After any out-of-band change (or a restore), use a full `DeployStack`
> to reconcile.

### Step 12: Install Cockpit

```bash
sudo apt install -y cockpit
sudo systemctl enable --now cockpit.socket
```

Accessible at `https://bigmt:9090`.

### Step 13: Post-restore verification

- [ ] `nvidia-smi` shows GTX 1070
- [ ] `docker ps` shows all containers running
- [ ] Jellyfin: media libraries visible at `:8096`
- [ ] Radarr: config intact, download client connected at `:7878`
- [ ] Sonarr: config intact, download client connected at `:8989`
- [ ] Lidarr: config intact, download client connected at `:8686`
- [ ] Bazarr: subtitle providers configured at `:6767`
- [ ] Prowlarr: indexers configured at `:9696`
- [ ] Jellyseerr: request management at `:5055`
- [ ] Immich: photos accessible at `:2283`
- [ ] Pi-hole: DNS resolving, web UI at `:8089`
- [ ] Backrest: backup plans visible at `:9898`
- [ ] qBittorrent: web UI accessible at `:8080`
- [ ] HandBrake: web UI accessible at `:5800`
- [ ] Seafile: web UI accessible at `:8082`
- [ ] Uptime Kuma: monitors loaded at `:3001`
- [ ] Tailscale: `tailscale status` shows connected peers

---

## Scenario 2: oci (Oracle Cloud proxy) rebuild

The Oracle Cloud instance is stateless — it only runs Caddy and Tailscale.

### Step 1: Provision new instance

1. Create an Oracle Cloud free-tier instance (Ubuntu 24.04)
2. Ensure security list allows inbound: TCP 22, 80, 443 and UDP 41641

### Step 2: Configure firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 41641/udp
sudo ufw enable
```

### Step 3: Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Authenticate and verify bigmt is reachable:
ping <TAILSCALE_HOSTNAME>
```

### Step 4: Install Caddy

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

### Step 5: Deploy Caddyfile

From your local machine:

```bash
scp proxy/Caddyfile oci:/tmp/Caddyfile
ssh oci "sudo mv /tmp/Caddyfile /etc/caddy/Caddyfile && sudo systemctl restart caddy"
```

> **Note:** The repo's Caddyfile has a sanitized email placeholder (`<EMAIL>`). Update it with your real email for Let's Encrypt before deploying.

### Step 6: Update DNS

Ensure `*.example.com` points to the new Oracle Cloud instance's public IP.

### Step 7: Verify

- [ ] `curl -I https://bigmt.example.com` returns 200
- [ ] All subdomains resolve and proxy correctly
- [ ] TLS certificates are auto-provisioned

---

## Key information reference

| Item                     | Value                                            |
| ------------------------ | ------------------------------------------------ |
| bigmt OS                 | Ubuntu 24.04 LTS                                 |
| bigmt kernel             | 6.17.0-20-generic (HWE)                          |
| NVIDIA driver            | 570.211.01                                       |
| NVIDIA Container Toolkit | 1.19.0                                           |
| Docker                   | 29.2.0                                           |
| Docker Compose           | v5.0.2                                           |
| Docker data root         | `/data/docker`                                   |
| Tailscale                | 1.96.4                                           |
| Komodo                   | 2.3.3 (`ghcr.io/moghtech/komodo-core`)           |
| Cockpit                  | 352                                              |
| User                     | mobius (UID 1000, GID 1000, sudo NOPASSWD)       |
| Data drive               | WD 12TB, LABEL=data, mounted at `/data`          |
| Backup drive             | Seagate 5TB, LABEL=backup-5tb, `/mnt/backup-5tb` |
| oci OS                   | Ubuntu 24.04 LTS                                 |
| oci Caddy                | v2.11.2                                          |
| oci Tailscale            | 1.96.4                                           |
