#!/usr/bin/env bash
# Entry point for Claude Code's StopFailure hook (matcher: authentication_failed)
# and for the watchdog timer.
#
# It warns once per incident and, when RELOGIN_ENABLED is true, hands over to
# relogin.sh. The hook may fire on every failed turn, so the marker file is what
# keeps a dead session from sending a message a minute.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

MARKER="$STATE_DIR/warned"

# A second warning is only worth sending after this long without the session
# coming back (6 hours).
REWARN_AFTER=21600

now=$(date +%s)

if [ -f "$MARKER" ]; then
    warned_at=$(cat "$MARKER" 2>/dev/null || echo 0)
    if [ $((now - warned_at)) -lt "$REWARN_AFTER" ]; then
        log "already warned $((now - warned_at))s ago, staying quiet"
        exit 0
    fi
fi

printf '%s' "$now" >"$MARKER"
log "auth failure detected"

host="$(hostname)"

if [ "$RELOGIN_ENABLED" = "true" ]; then
    notify "🔑 Claude Code ($host) has lost its login. Starting /login — the authorization link follows."
    exec "$HERE/relogin.sh"
fi

notify "🔑 Claude Code ($host) has lost its login.

The session is stopped until someone signs in: open the tmux session and run /login.

  tmux attach -t $TMUX_SESSION"
