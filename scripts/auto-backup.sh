#!/bin/bash
# auto-backup.sh — Triggered by udev when backup drive is connected.
# Mounts the drive, triggers Backrest backup plans (with cooldown), waits, then unmounts.

set -euo pipefail

MOUNT_POINT="/mnt/backup-5tb"
LABEL="backup-5tb"
CREDS_FILE="/etc/backrest-api-credentials"
BACKREST_URL="http://localhost:9898"
LOG_TAG="auto-backup"

# Cooldown periods in seconds
declare -A PLAN_COOLDOWNS=(
    ["critical"]=2592000   # 30 days
    ["media"]=7776000      # 90 days
)

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Send a Discord notification
# Usage: discord_notify "title" "message" color
# Colors: 3066993=green, 15158332=red, 16776960=yellow
discord_notify() {
    local title="$1"
    local message="$2"
    local color="${3:-3066993}"

    if [[ -z "${DISCORD_WEBHOOK:-}" ]]; then
        log "WARNING: DISCORD_WEBHOOK not set, skipping notification"
        return
    fi

    curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
        -H 'Content-Type: application/json' \
        --data "{
            \"embeds\": [{
                \"title\": \"${title}\",
                \"description\": \"${message}\",
                \"color\": ${color},
                \"footer\": {\"text\": \"auto-backup · $(hostname)\"},
                \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
            }]
        }" --max-time 10 || true
}

COLOR_GREEN=3066993
COLOR_RED=15158332
COLOR_YELLOW=16776960

# Read credentials
if [[ ! -f "$CREDS_FILE" ]]; then
    log "ERROR: Credentials file $CREDS_FILE not found"
    exit 1
fi
source "$CREDS_FILE"
# Expects BACKREST_USER, BACKREST_PASS, DISCORD_WEBHOOK

# Get the last successful backup timestamp (in ms) for a plan
get_last_backup_ms() {
    local plan="$1"
    curl -s -X POST "${BACKREST_URL}/v1.Backrest/GetOperations" \
        --data "{\"selector\":{\"planId\":\"${plan}\"}}" \
        -H 'Content-Type: application/json' \
        --basic -u "${BACKREST_USER}:${BACKREST_PASS}" \
        --max-time 30 \
    | python3 -c "
import sys, json
ops = json.load(sys.stdin).get('operations', [])
# Find the latest successful backup operation
ts = 0
for op in ops:
    if op.get('status') == 'STATUS_SUCCESS' and 'operationBackup' in op:
        end = int(op.get('unixTimeEndMs', 0))
        if end > ts:
            ts = end
print(ts)
" 2>/dev/null || echo "0"
}

# Check if a plan's cooldown has elapsed
should_run_plan() {
    local plan="$1"
    local cooldown="${PLAN_COOLDOWNS[$plan]}"
    local now_ms=$(date +%s%3N)

    local last_ms
    last_ms=$(get_last_backup_ms "$plan")

    if [[ "$last_ms" == "0" ]]; then
        log "Plan '$plan': no previous backup found, will run"
        return 0
    fi

    local elapsed_s=$(( (now_ms - last_ms) / 1000 ))
    local remaining_s=$(( cooldown - elapsed_s ))

    if [[ "$elapsed_s" -ge "$cooldown" ]]; then
        log "Plan '$plan': last backup was ${elapsed_s}s ago (cooldown: ${cooldown}s), will run"
        return 0
    else
        local remaining_d=$(( remaining_s / 86400 ))
        log "Plan '$plan': last backup was ${elapsed_s}s ago (cooldown: ${cooldown}s), skipping (${remaining_d}d remaining)"
        return 1
    fi
}

# Determine which plans to run
PLANS_TO_RUN=()
PLANS_SKIPPED=()
for plan in "${!PLAN_COOLDOWNS[@]}"; do
    if should_run_plan "$plan"; then
        PLANS_TO_RUN+=("$plan")
    else
        PLANS_SKIPPED+=("$plan")
    fi
done

if [[ ${#PLANS_TO_RUN[@]} -eq 0 ]]; then
    log "All plans within cooldown period, nothing to do"
    discord_notify "Backup drive connected" "All plans within cooldown period, nothing to do.\\n\\nSkipped: ${PLANS_SKIPPED[*]}" "$COLOR_YELLOW"
    exit 0
fi

# Mount the drive if not already mounted
if ! mountpoint -q "$MOUNT_POINT"; then
    log "Mounting $LABEL to $MOUNT_POINT"
    mkdir -p "$MOUNT_POINT"
    mount /dev/disk/by-label/"$LABEL" "$MOUNT_POINT"
    log "Mounted successfully"
else
    log "Drive already mounted at $MOUNT_POINT"
fi

# Wait a moment for Backrest to see the mounted drive
sleep 5

discord_notify "Backup started" "Drive mounted. Running plans: ${PLANS_TO_RUN[*]}\\nSkipped (cooldown): ${PLANS_SKIPPED[*]:-none}" "$COLOR_YELLOW"

# Trigger each backup plan and wait for completion
# Run critical first, then media
FAILED=0
RESULTS=""
for plan in "critical" "media"; do
    # Skip if not in our run list
    if [[ ! " ${PLANS_TO_RUN[*]} " =~ " ${plan} " ]]; then
        continue
    fi

    log "Triggering backup plan: $plan"
    START_TIME=$(date +%s)

    HTTP_CODE=$(curl -s -o /tmp/backrest-response-$plan.json -w '%{http_code}' \
        -X POST "${BACKREST_URL}/v1.Backrest/Backup" \
        --data "{\"value\": \"${plan}\"}" \
        -H 'Content-Type: application/json' \
        --basic -u "${BACKREST_USER}:${BACKREST_PASS}" \
        --max-time 14400)  # 4 hour timeout per plan

    DURATION=$(( $(date +%s) - START_TIME ))
    DURATION_MIN=$(( DURATION / 60 ))

    if [[ "$HTTP_CODE" == "200" ]]; then
        log "Backup plan '$plan' completed successfully (${DURATION_MIN}m)"
        RESULTS="${RESULTS}\\n✓ **${plan}** — completed in ${DURATION_MIN}m"
    else
        log "ERROR: Backup plan '$plan' failed with HTTP $HTTP_CODE"
        cat /tmp/backrest-response-$plan.json | logger -t "$LOG_TAG"
        RESULTS="${RESULTS}\\n✗ **${plan}** — failed (HTTP ${HTTP_CODE})"
        FAILED=1
    fi
done

# Unmount and power off the drive
log "Unmounting $MOUNT_POINT"
sync
umount "$MOUNT_POINT"
log "Unmounted successfully"

# Power off the USB drive to spin down and cut power
BLOCK_DEVICE=$(blkid -L "$LABEL" | sed 's/[0-9]*$//')
if [[ -n "$BLOCK_DEVICE" ]]; then
    log "Powering off $BLOCK_DEVICE"
    udisksctl power-off -b "$BLOCK_DEVICE" --no-user-interaction 2>&1 | logger -t "$LOG_TAG" || true
    log "Drive powered off"
else
    log "WARNING: Could not determine block device for power-off"
fi

if [[ "$FAILED" -eq 1 ]]; then
    discord_notify "Backup completed with errors" "One or more plans failed. Drive powered off.${RESULTS}" "$COLOR_RED"
    log "WARNING: One or more backup plans failed. Check Backrest UI for details."
    exit 1
fi

discord_notify "Backup completed successfully" "All plans finished. Drive powered off.${RESULTS}" "$COLOR_GREEN"
log "All backup plans completed successfully. Drive powered off."
