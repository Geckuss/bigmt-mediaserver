#!/usr/bin/env bash
# Install the Komodo -> Discord forwarder on bigmt.
#
# The Discord webhook URL is a credential. It is written to a root-only file
# that the service reads; the service reads nothing else from ${CONFIGS}, and
# the URL never appears in this script or anywhere in git.
#
#   sudo ./scripts/install-komodo-discord-forwarder.sh '<discord-webhook-url>'
#
# Note -u on ExecStart matters: without it python block-buffers stdout under
# systemd and the service looks like it is doing nothing.
set -euo pipefail

KOMODO_CONFIGS=${KOMODO_CONFIGS:-/data/backups/configs}
K="$KOMODO_CONFIGS/komodo"
WEBHOOK_URL="$1"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -z "$WEBHOOK_URL" ]; then
  echo "usage: $0 <discord-webhook-url>" >&2
  exit 1
fi
if ! [[ "$WEBHOOK_URL" =~ ^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/ ]]; then
  echo "refusing: '$WEBHOOK_URL' does not look like a Discord webhook URL" >&2
  exit 1
fi

sudo install -d -m 700 -o root -g root "$K"
sudo install -m 755 -o root -g root "$HERE/komodo-discord-forwarder.py" \
  /usr/local/sbin/komodo-discord-forwarder.py

printf '%s' "$WEBHOOK_URL" | sudo tee "$K/discord-webhook" >/dev/null
sudo chmod 600 "$K/discord-webhook"
sudo chown root:root "$K/discord-webhook"

sudo install -m 644 -o root -g root "$HERE/systemd/komodo-discord-forwarder.service" \
  /etc/systemd/system/komodo-discord-forwarder.service

sudo systemctl daemon-reload
sudo systemctl enable --now komodo-discord-forwarder.service
sleep 2

echo "active : $(systemctl is-active komodo-discord-forwarder.service)"
echo "enabled: $(systemctl is-enabled komodo-discord-forwarder.service)"
echo
echo "listening (must be the docker bridge only, not 0.0.0.0):"
ss -ltnp 2>/dev/null | grep 9911 | sed 's/^/  /'
echo
echo "health : $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://172.25.0.1:9911/health)"
echo
echo "Now point the 'discord-links' Alerter at:"
echo "  http://172.25.0.1:9911/hook"
