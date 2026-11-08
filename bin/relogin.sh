#!/usr/bin/env bash
# Drives the login from Telegram.
#
#   1. starts `claude auth login` in its own tmux session (LOGIN_SESSION)
#   2. reads the authorization URL off that pane and sends it to you
#   3. waits for your reply, for RELOGIN_WINDOW_SECONDS and no longer
#   4. types the code into it, checks `claude auth status`, and restarts
#      REMOTE_SERVICE so remote-control picks up the new credential
#
# Typing /login into the watched session does not work: it runs
# `claude remote-control`, which has no prompt to type into.
#
# Only the configured chat is read, only replies newer than step 1 count, and
# only text matching CODE_PATTERN is ever typed. Nothing listens on a port:
# this asks Telegram, Telegram does not reach in.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

LOCK="$STATE_DIR/relogin.lock"

if ! session_exists; then
    notify "⚠️ Cannot re-login: tmux session '$TMUX_SESSION' is not running."
    log "no tmux session"
    exit 1
fi

# One login at a time. The lock is a directory because mkdir is atomic.
if ! mkdir "$LOCK" 2>/dev/null; then
    log "another re-login is in progress"
    exit 0
fi
trap 'tmux kill-session -t "$LOGIN_SESSION" 2>/dev/null || true; rmdir "$LOCK" 2>/dev/null || true' EXIT

# Ignore anything said before now: an old message must not be replayed as a code.
baseline=$(tg_api getUpdates --get --data "offset=-1" |
    grep -o '"update_id":[0-9]*' | tail -1 | grep -o '[0-9]*' || true)
offset=$(( ${baseline:-0} + 1 ))

log "starting claude auth login in $LOGIN_SESSION"
tmux kill-session -t "$LOGIN_SESSION" 2>/dev/null || true
# Wide window so the URL is not wrapped; LOGIN_FLAGS picks the account kind
# (--claudeai, --console, --sso).
tmux new-session -d -s "$LOGIN_SESSION" -x 400 -y 50 \
    "\"$CLAUDE_BIN\" auth login ${LOGIN_FLAGS:---claudeai}; sleep 30"

url=""
for _ in $(seq 1 30); do
    sleep 1
    url=$(extract_oauth_url "$LOGIN_SESSION")
    if [ -n "$url" ] && url_looks_complete "$url"; then
        break
    fi
    url=""
done

if [ -z "$url" ]; then
    notify "⚠️ Ran 'claude auth login' but could not read a complete authorization link. Sign in by hand:

  claude auth login && systemctl --user restart $REMOTE_SERVICE"
    log "no complete url on pane"
    exit 1
fi

notify "🔗 Open this, approve access, and send me back the code as a plain message:

$url

I will listen for $((RELOGIN_WINDOW_SECONDS / 60)) minutes."
log "url sent, waiting for the code"

deadline=$(( $(date +%s) + RELOGIN_WINDOW_SECONDS ))
code=""

while [ "$(date +%s)" -lt "$deadline" ]; do
    # Long polling: Telegram holds the request open until something arrives,
    # so curl waits longer than the usual call.
    response=$(CURL_TIMEOUT=40 tg_api getUpdates --get \
        --data "offset=${offset}" \
        --data "timeout=25" \
        --data-urlencode 'allowed_updates=["message"]' || true)

    [ -z "$response" ] && continue

    last_id=$(printf '%s' "$response" | grep -o '"update_id":[0-9]*' | tail -1 | grep -o '[0-9]*' || true)
    [ -n "$last_id" ] && offset=$(( last_id + 1 ))

    # Take the text of messages from the configured chat only.
    candidate=$(printf '%s' "$response" | python3 -c '
import json,sys
chat_id = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for update in data.get("result", []):
    message = update.get("message") or {}
    if str((message.get("chat") or {}).get("id")) != chat_id:
        continue
    text = (message.get("text") or "").strip()
    if text:
        print(text)
' "$TELEGRAM_CHAT_ID" | tail -1 || true)

    [ -z "$candidate" ] && continue

    if printf '%s' "$candidate" | grep -qE "$CODE_PATTERN"; then
        code="$candidate"
        break
    fi

    log "reply ignored: does not look like a code"
    notify "That does not look like a code, so I have not typed it. Send just the code."
done

if [ -z "$code" ]; then
    notify "⌛ No code arrived in time. Sign in by hand:

  claude auth login && systemctl --user restart $REMOTE_SERVICE"
    log "window closed with no code"
    exit 1
fi

log "code received, pasting"
send_literal "$code" "$LOGIN_SESSION"

# `auth login` exchanges the code and writes the credential; give it a moment.
for _ in $(seq 1 20); do
    sleep 1
    is_logged_in && break
done

if ! is_logged_in; then
    notify "❌ The code did not take — 'claude auth status' still says logged out. Sign in by hand:

  claude auth login && systemctl --user restart $REMOTE_SERVICE"
    log "login still failing after code"
    exit 1
fi

log "login ok, restarting $REMOTE_SERVICE"
rm -f "$STATE_DIR/warned"

if systemctl --user restart "$REMOTE_SERVICE"; then
    notify "✅ Signed in again and $REMOTE_SERVICE restarted. Remote Control is back."
    log "service restarted"
    exit 0
fi

notify "⚠️ Signed in, but restarting $REMOTE_SERVICE failed. Restart it by hand:

  systemctl --user restart $REMOTE_SERVICE"
log "service restart failed"
exit 1
