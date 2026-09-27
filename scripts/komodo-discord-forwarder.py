#!/usr/bin/env python3
"""
komodo-discord-forwarder

Sits between Komodo and a Discord webhook, adding a deep link to the stack
page so an update alert goes straight to the thing you need to click.

Why this exists: Discord webhooks cannot receive interactions, so a real button
is impossible without registering a Discord application and exposing an
interactions endpoint to the internet. Komodo's alerter config has no message
templating either (AlerterConfig carries only resource filters), so the link
has to be added here.

Payload shape, confirmed against a live TestAlerter on 2.3.3:

    {
      "ts": 1790538601060,
      "resolved": true,
      "level": "OK",
      "target": {"type": "Alerter", "id": "6ab..."},
      "data": {"type": "Test", "data": {"id": "...", "name": "discord-links"}},
      "resolved_ts": 1790538601060
    }

Note target.type is "Alerter" for a test but is the resource type ("Stack",
"Server", ...) for a real alert, and target.id is then the resource id. The
UI route is /stacks/<id>, so the id alone is enough to build the link.

Design notes:
  * Binds to the docker bridge only, so nothing on the LAN can post to it.
    Core is the only thing that needs to reach it.
  * Replies 200 before doing any work, so a slow Discord API can never make
    Komodo think an alert failed.
  * Logs the raw body of anything it cannot classify, so it can be tightened
    against real traffic rather than guessed at.
  * The webhook URL lives in a separate root-only file, not in this script.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BIND = "172.25.0.1"          # docker bridge for the komodo network only
PORT = 9911
WEBHOOK_FILE = "/data/backups/configs/komodo/discord-webhook"
UI_BASE = "https://komodo.bigmt.top"

# Fallback name -> id map, only used when target.id is missing.
STACK_IDS = {
    "mediastack":     "6ab906ddca74d25672a1c794",
    "infrastructure": "6ab90548ca74d25672a1c781",
    "backrest":       "6ab906dfca74d25672a1c796",
    "homepage":       "6ab8eb8dca74d25672a1c695",
    "immich":         "6ab8f2bcca74d25672a1c6da",
    "vocard":         "6ab9366cca74d25672a1c958",
    "vrising":        "6ab93200ca74d25672a1c926",
    "valheim":        "6ab93200ca74d25672a1c929",
}

RESOURCE_ROUTES = {"Stack": "stacks", "Server": "servers", "Host": "hosts"}


def pretty_alert_type(t):
    """StackUpdateAvailable -> 'Stack update available'."""
    if not isinstance(t, str) or not t:
        return "Update notification"
    words = re.sub(r"(?<!^)(?=[A-Z])", " ", t).replace("_", " ")
    return words[0].upper() + words[1:] if words else "Update notification"


def extract(payload):
    """Pull the useful bits out of Komodo's envelope."""
    target = payload.get("target") or {}
    body = payload.get("data") or {}
    inner = body.get("data") or {}
    if not isinstance(inner, dict):
        inner = {}

    rtype = target.get("type")
    rid = target.get("id")
    name = (inner.get("name") or inner.get("stack_name")
            or target.get("name") or rtype)
    alert_type = body.get("type")
    level = payload.get("level")
    resolved = bool(payload.get("resolved"))

    # Prefer the real id from target; fall back to the name map.
    if rtype == "Stack":
        sid = rid if (isinstance(rid, str) and re.fullmatch(r"[0-9a-f]{24}", rid or "")) \
            else STACK_IDS.get(name)
        if sid:
            return name, alert_type, level, resolved, "%s/stacks/%s" % (UI_BASE, sid)
    return name, alert_type, level, resolved, UI_BASE


def build_content(payload):
    name, alert_type, level, resolved, link = extract(payload)
    head = pretty_alert_type(alert_type)
    title = "✅ Resolved: %s" % head if resolved else "🔔 %s" % head

    lines = [title]
    if name and name != "Alerter":
        lines.append("**%s**" % name)
    if level and not resolved:
        lines.append("level: %s" % level)
    lines.append("[Open in Komodo](%s)" % link)
    return "\n".join(lines)[:1900], (name, alert_type, resolved)


def send_discord(content):
    try:
        with open(WEBHOOK_FILE) as f:
            url = f.read().strip()
    except OSError:
        print("FATAL: cannot read %s" % WEBHOOK_FILE, file=sys.stderr)
        return False
    if not url:
        print("FATAL: webhook file is empty", file=sys.stderr)
        return False
    req = urllib.request.Request(
        url,
        data=json.dumps({"content": content}).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            # Discord sits behind Cloudflare, which 403s the default
            # "Python-urllib/3.x" agent. A browser agent is definitely fine.
            "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                           "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            print("discord responded %s" % r.status)
            return True
    except urllib.error.HTTPError as e:
        # 404 usually means the webhook was deleted or rotated
        print("discord HTTP %s" % e.code, file=sys.stderr)
        return False
    except Exception as e:
        print("discord error: %s" % e, file=sys.stderr)
        return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body=b'{"ok":true}'):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", ""):
            self._reply(200)
        else:
            self._reply(404, b'{"error":"not found"}')

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        # ack immediately: Discord slowness must not look like alert failure
        self._reply(200)
        try:
            payload = json.loads(raw)
        except Exception:
            print("non-JSON body received:\n%s" % raw.decode("utf-8", "replace")[:2000])
            return
        if not isinstance(payload, dict) or "target" not in payload:
            print("UNRECOGNISED payload shape, raw body follows:\n%s"
                  % json.dumps(payload, indent=2)[:2000])
        content, meta = build_content(payload)
        print("forwarding %s: %r" % (meta, content))
        send_discord(content)

    def log_message(self, fmt, *a):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % a))


if __name__ == "__main__":
    if not os.path.exists(WEBHOOK_FILE):
        sys.exit("missing %s" % WEBHOOK_FILE)
    print("listening on %s:%d -> %s" % (BIND, PORT, WEBHOOK_FILE))
    HTTPServer((BIND, PORT), Handler).serve_forever()
