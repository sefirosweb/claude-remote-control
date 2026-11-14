#!/usr/bin/env bash
# Entry point for Claude Code's StopFailure hook (matcher: authentication_failed)
# and for the watchdog timer.
#
# It warns once per incident and decides who deals with it: the Telegram bot
# when it is running (you answer with /login or /restart), relogin.sh when
# RELOGIN_ENABLED is true, or you, by hand. The hook may fire on every failed
# turn, so the marker file is what keeps a dead session from sending a message
# a minute.
#
#   on-auth-failure.sh [auth|down]     the hook passes nothing, which is auth

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

reason="${1:-auth}"
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
log "incident: $reason"

host="$(hostname)"

# The bot owns the Telegram updates while it runs, so relogin.sh cannot poll
# alongside it. It also makes the automatic login unnecessary: you ask for
# the link when you are at the phone, not at three in the morning.
if bot_running; then
    case "$reason" in
        down)
            notify "🔴 Claude Code ($host): Remote Control is not running — $REMOTE_SERVICE is $(service_summary).

Send /logs to see why, /restart to start it again, or /login if it is the login."
            ;;
        *)
            notify "🔑 Claude Code ($host) has lost its login.

Send /login and I will give you the link."
            ;;
    esac
    exit 0
fi

if [ "$reason" = auth ] && [ "$RELOGIN_ENABLED" = "true" ]; then
    notify "🔑 Claude Code ($host) has lost its login. Starting the login — the authorization link follows."
    exec "$HERE/relogin.sh"
fi

case "$reason" in
    down)
        notify "🔴 Claude Code ($host): Remote Control is not running — $REMOTE_SERVICE is $(service_summary).

  journalctl --user -u $REMOTE_SERVICE -n 50
  systemctl --user restart $REMOTE_SERVICE"
        ;;
    *)
        notify "🔑 Claude Code ($host) has lost its login.

The session is stopped until someone signs in:

  claude auth login && systemctl --user restart $REMOTE_SERVICE"
        ;;
esac
