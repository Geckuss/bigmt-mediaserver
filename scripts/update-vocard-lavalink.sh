#!/usr/bin/env bash
# update-vocard-lavalink.sh - update Lavalink plugins on bigmt to the newest versions.
#
# Checks Lavalink's Maven repo (maven.lavalink.dev) for newer versions of the
# youtube/lavasrc/lavalyscs/lavasearch plugins, bumps them in the server's
# application.yml, removes the stale JARs so Lavalink re-downloads them, restarts
# lavalink, waits for it to be ready, then restarts vocard (the bot does not
# auto-reconnect to Lavalink).
#
# Also keeps the local repo copy of application.yml in sync.
#
# Usage - source once (e.g. from ~/.bashrc):
#   source scripts/update-vocard-lavalink.sh
#   update-vocard            check for updates and apply them
#   update-vocard --dry-run  preview without changing anything
#
#   # or run directly:
#   bash scripts/update-vocard-lavalink.sh [--dry-run]

HOST=bigmt
SERVER_APP_YML=/data/backups/configs/vocard/lavalink/application.yml
SERVER_PLUGINS_DIR=/data/backups/configs/vocard/lavalink/plugins
LOCAL_APP_YML="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/configs/vocard/lavalink/application.yml"

# "groupId:artifactId|maven-path"
plugins=(
  "dev.lavalink.youtube:youtube-plugin|dev/lavalink/youtube/youtube-plugin"
  "com.github.topi314.lavasrc:lavasrc-plugin|com/github/topi314/lavasrc/lavasrc-plugin"
  "com.github.topi314.lavalyrics:lavalyrics-plugin|com/github/topi314/lavalyrics/lavalyrics-plugin"
  "com.github.topi314.lavasearch:lavasearch-plugin|com/github/topi314/lavasearch/lavasearch-plugin"
)

latest_version() {
    # $1 = maven path of artifact; prints newest version from maven-metadata.xml
    curl -sf "https://maven.lavalink.dev/releases/$1/maven-metadata.xml" \
        | sed -n 's:.*<latest>\([0-9][0-9.]*\)</latest>.*:\1:p' | head -1
}

current_version() {
    # $1 = groupId:artifactId; prints the version pinned in server application.yml
    # Returns the whole version token, which may be a commit-hash snapshot rather
    # than a dotted release number. The grep deliberately does not restrict
    # itself to `[0-9][0-9.]*`: that would truncate a commit hash to its leading
    # digit ("2be8e542..." -> "2") and the sed below would then rewrite the prefix
    # and leave the nonsense coordinate "1.18.2be8e542...".
    ssh "$HOST" "grep -o '$1:[^[:space:]\"]*' $SERVER_APP_YML | head -1" \
        | sed "s|$1:||" | head -1
}

update-vocard() {
    local sed_expr=() cmds=() gav mpath a cur new dry_run=0
    [[ "${1:-}" == "--dry-run" ]] && dry_run=1

    for p in "${plugins[@]}"; do
        gav="${p%%|*}"
        mpath="${p##*|}"
        a="${gav##*:}"
        cur="$(current_version "$gav")"
        new="$(latest_version "$mpath")"
        if [[ -z "$cur" ]]; then
            echo "!! $a: no version pinned in application.yml (skipping)"
            continue
        fi
        if [[ "$cur" =~ ^[0-9]+[0-9.]*$ ]]; then :; else
            # A commit-hash snapshot pin. Only a deliberate manual bump should
            # move these -- see the note on the youtube-plugin entry in
            # configs/vocard/lavalink/application.yml. Reverting it to whatever
            # release happens to be newest is exactly what broke playback on
            # 2026-09-28.
            echo "== $a: pinned to snapshot $cur (skipping, bump by hand)"
            continue
        fi
        if [[ -z "$new" ]]; then
            echo "!! $a: could not fetch latest version from Maven (skipping)"
            continue
        fi
        if [[ "$cur" == "$new" ]]; then
            echo "== $a: up to date ($cur)"
            continue
        fi
        echo ">> $a: $cur -> $new"
        sed_expr+=("-e" "s|${gav}:${cur}|${gav}:${new}|")
        cmds+=("rm -f $SERVER_PLUGINS_DIR/${a}-${cur}.jar")
    done

    if [[ ${#cmds[@]} -eq 0 ]]; then
        echo "Nothing to update."
        return 0
    fi

    if [[ "$dry_run" == 1 ]]; then
        echo "[dry-run] would update $SERVER_APP_YML, remove old JARs, restart lavalink + vocard"
        return 0
    fi

    echo "Updating $SERVER_APP_YML ..."
    ssh "$HOST" "sudo sed -i ${sed_expr[*]} $SERVER_APP_YML"
    ssh "$HOST" "${cmds[*]}"

    echo "Restarting lavalink ..."
    ssh "$HOST" "docker restart lavalink >/dev/null"
    started_at="$(ssh "$HOST" "docker inspect -f '{{.State.StartedAt}}' lavalink")"
    echo "Waiting for lavalink to be ready (started $started_at) ..."
    for i in $(seq 1 30); do
        sleep 5
        if ssh "$HOST" "docker logs lavalink --since '$started_at' 2>&1 | grep -q 'Lavalink is ready to accept connections'"; then
            echo "Lavalink ready after ~$((i*5))s"
            break
        fi
        [[ $i == 30 ]] && { echo "ERROR: lavalink did not become ready in time" >&2; exit 1; }
    done

    echo "Restarting vocard ..."
    ssh "$HOST" "docker restart vocard >/dev/null"

    if command -v sed >/dev/null 2>&1 && [[ -f "$LOCAL_APP_YML" ]]; then
        sed -i "${sed_expr[*]}" "$LOCAL_APP_YML"
        echo "Synced local $LOCAL_APP_YML"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    update-vocard "$@"
fi
