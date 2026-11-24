#!/usr/bin/env bash
# Backstop for the hook.
#
# The StopFailure hook fires when a turn fails, which needs a turn to be
# running. An unattended session that expires while idle sits there quietly
# until someone asks it for something. This looks at the session on a timer
# and catches that case, and the one the hook can never see: there is no
# session at all because the service keeps dying.
#
# One bad reading is not an incident. The access token expires every few
# hours and `claude auth status` says "logged out" until remote-control has
# refreshed it, which takes a few minutes. Only FAIL_THRESHOLD bad readings
# in a row raise the alarm.
#
# Run it from the systemd timer, or by hand with --test to check the setup
# without touching the session.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

if [ "${1:-}" = "--test" ]; then
    echo "Config:      $CONFIG_FILE"
    echo "Session:     $TMUX_SESSION"
    if session_exists; then
        echo "tmux:        found"
    else
        echo "tmux:        NOT FOUND — check TMUX_SESSION against 'tmux ls'"
    fi
    echo "Service:     $REMOTE_SERVICE — $(service_summary)"
    echo "Re-login:    $RELOGIN_ENABLED"
    if bot_running; then
        echo "Bot:         running"
    else
        echo "Bot:         not running (./install.sh --bot)"
    fi
    echo "Claude:      $CLAUDE_BIN ($(installed_version))"
    if is_logged_in; then
        echo "Auth:        logged in"
    else
        echo "Auth:        LOGGED OUT"
    fi
    echo "State:       $STATE_DIR"
    echo
    echo "Last lines of the pane:"
    capture_pane | grep -v '^$' | tail -5 | sed 's/^/  | /'
    echo
    notify "✅ Test message from the Claude Code login watcher on $(hostname). If you can read this, the channel works."
    echo "Test message sent. Check Telegram."
    exit 0
fi

# Reads a counter file; a missing or empty file is 0.
counter() {
    local value
    value=$(cat "$STATE_DIR/$1" 2>/dev/null || true)
    printf '%s\n' "${value:-0}"
}

# What a counter was at the last check, and records today's value for the
# next one. With nothing recorded yet, today's value is the baseline: the
# first run after installing must not mistake history for news.
#   previous <name> <value now>
previous() {
    local before
    if [ -f "$STATE_DIR/$1" ]; then
        before=$(counter "$1")
    else
        before="$2"
    fi
    printf '%s' "$2" >"$STATE_DIR/$1"
    printf '%s\n' "$before"
}

# Two things are counted rather than just looked at, because only growth
# means news: an error line stays in the scrollback long after the login is
# back, and a restart counter above zero may be last week's.
errors_now=0
if session_exists; then
    errors_now=$(capture_pane | grep -cE "$EXPIRED_PATTERN" || true)
fi
errors_before=$(previous pane-errors "$errors_now")

restarts_now=$(service_restarts)
restarts_before=$(previous restarts "$restarts_now")

reason=""
if ! session_exists; then
    reason=down
elif [ "$restarts_now" -gt "$restarts_before" ]; then
    reason=down
elif ! is_logged_in; then
    reason=auth
elif [ "$errors_now" -gt "$errors_before" ]; then
    reason=auth
fi

if [ -z "$reason" ]; then
    rm -f "$STATE_DIR/failures"
    # Healthy again: forget the warning so the next incident is reported.
    if [ -f "$STATE_DIR/warned" ]; then
        rm -f "$STATE_DIR/warned"
        log "session healthy again, warning cleared"
        notify "✅ Claude Code ($(hostname)) is back: logged in and the session is running."
    fi
    exit 0
fi

failures=$(( $(counter failures) + 1 ))
printf '%s' "$failures" >"$STATE_DIR/failures"
log "check failed: $reason ($failures/$FAIL_THRESHOLD)"

if [ "$failures" -lt "$FAIL_THRESHOLD" ]; then
    exit 0
fi

exec "$HERE/on-auth-failure.sh" "$reason"
