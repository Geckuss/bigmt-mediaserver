#!/usr/bin/env bash
set -euo pipefail

PRIMARY=/mnt/backup-12tb
REPO="$PRIMARY/restic-backrest"
UUID_FILE=/etc/backrest-disk.uuid
mode="${1:-start}"

fail() {
  echo "backrest-guard: $*" >&2
  exit 1
}

case "$mode" in
  start|check|status) ;;
  *) fail "usage: $0 [start|check|status]" ;;
esac

[[ -s "$UUID_FILE" ]] || fail "missing expected disk UUID in $UUID_FILE"
expected=$(cat "$UUID_FILE")
mountpoint -q "$PRIMARY" || fail "$PRIMARY is not mounted; refusing startup/deploy"
actual=$(findmnt -rn -M "$PRIMARY" -o UUID)
[[ "$actual" == "$expected" ]] || fail "$PRIMARY is the wrong filesystem"
options=$(findmnt -rn -M "$PRIMARY" -o OPTIONS)
[[ ",$options," == *,rw,* ]] || fail "$PRIMARY is read-only"
[[ -d "$REPO" && ! -L "$REPO" ]] || fail "$REPO must be a real directory on the disk"
[[ "$(findmnt -rn -T "$REPO" -o UUID)" == "$expected" ]] || fail "$REPO is on a different filesystem"
echo "backrest-guard: verified writable 12TB filesystem and repository directory"

[[ "$mode" == start ]] || exit 0
docker container inspect backrest >/dev/null 2>&1 || fail "deploy the Backrest stack in Komodo first"
source=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/repos/12tb"}}{{.Source}}{{end}}{{end}}' backrest)
[[ "$source" == "$REPO" ]] || fail "container has outdated mounts; deploy the updated stack in Komodo"
if [[ "$(docker inspect -f '{{.State.Running}}' backrest)" == true ]]; then
  echo "backrest-guard: already running"
else
  docker start backrest
fi
