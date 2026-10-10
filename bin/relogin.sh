#!/usr/bin/env bash
# Drives the login from Telegram.
#
#   1. types /login into the session
#   2. reads the authorization URL off the pane and sends it to you
#   3. waits for your reply, for RELOGIN_WINDOW_SECONDS and no longer
#   4. types the code back into the session and reports what happened
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
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Ignore anything said before now: an old message must not be replayed as a code.
baseline=$(tg_api getUpdates --get --data "offset=-1" |
    grep -o '"update_id":[0-9]*' | tail -1 | grep -o '[0-9]*' || true)
offset=$(( ${baseline:-0} + 1 ))

log "starting /login"
send_literal "/login"

# Wait for the authorization URL to appear on the pane.
#
# /login does not go straight to the link: it first asks which kind of account
# this is, with the subscription option already selected. Enter takes it, and
# only then does the URL show up. Set LOGIN_METHOD_KEYS in the config to pick a
# different entry, e.g. "Down Enter" for the Console account.
url=""
menu_answered=false

for _ in $(seq 1 30); do
    sleep 1
    pane=$(capture_pane)

    url=$(extract_oauth_url)
    if [ -n "$url" ] && url_looks_complete "$url"; then
        break
    fi
    url=""

    if [ "$menu_answered" = false ] && printf '%s' "$pane" | grep -q 'Select login method'; then
        # shellcheck disable=SC2086 # the keys are meant to split into arguments
        tmux send-keys -t "$TMUX_SESSION" ${LOGIN_METHOD_KEYS:-Enter}
        menu_answered=true
        log "login method menu answered"
    fi
done

if [ -z "$url" ]; then
    notify "⚠️ Ran /login but could not read a complete authorization link off the session. Sign in by hand:

  tmux attach -t $TMUX_SESSION"
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
    notify "⌛ No code arrived in time. The session is still waiting at the /login prompt:

  tmux attach -t $TMUX_SESSION"
    log "window closed with no code"
    exit 1
fi

log "code received, pasting"
send_literal "$code"
sleep 6

pane=$(capture_pane)

if printf '%s' "$pane" | grep -qE 'Login successful|Logged in|auth_success'; then
    rm -f "$STATE_DIR/warned"
    notify "✅ Signed in again. The session is back."
    log "login ok"
    exit 0
fi

if printf '%s' "$pane" | grep -qE "$EXPIRED_PATTERN"; then
    notify "❌ The code did not take — the session still says the login expired. Sign in by hand:

  tmux attach -t $TMUX_SESSION"
    log "login still expired"
    exit 1
fi

# Neither message: say so instead of claiming success.
notify "❓ Code sent, but the session says neither 'Login successful' nor that it expired. Worth a look:

  tmux attach -t $TMUX_SESSION"
log "unclear outcome"
