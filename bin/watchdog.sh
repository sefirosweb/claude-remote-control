#!/usr/bin/env bash
# Backstop for the hook.
#
# The StopFailure hook fires when a turn fails, which needs a turn to be
# running. An unattended session that expires while idle sits there quietly
# until someone asks it for something. This looks at the pane on a timer and
# catches that case.
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
    echo "Re-login:    $RELOGIN_ENABLED"
    echo "State:       $STATE_DIR"
    echo
    echo "Last lines of the pane:"
    capture_pane | grep -v '^$' | tail -5 | sed 's/^/  | /'
    echo
    notify "✅ Test message from the Claude Code login watcher on $(hostname). If you can read this, the channel works."
    echo "Test message sent. Check Telegram."
    exit 0
fi

if ! session_exists; then
    log "session '$TMUX_SESSION' not running"
    exit 0
fi

if capture_pane | grep -qE "$EXPIRED_PATTERN"; then
    log "watchdog saw an expired login"
    exec "$HERE/on-auth-failure.sh"
fi

# Healthy again: forget the warning so the next incident is reported.
if [ -f "$STATE_DIR/warned" ]; then
    rm -f "$STATE_DIR/warned"
    log "session healthy again, warning cleared"
fi
