#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, never run on its own.

set -euo pipefail

CONFIG_FILE="${CLAUDE_LOGIN_WATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-login-watch/config}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "No config at $CONFIG_FILE — copy config.example there and fill it in." >&2
    exit 78 # EX_CONFIG
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${TELEGRAM_BOT_TOKEN:?missing in config}"
: "${TELEGRAM_CHAT_ID:?missing in config}"
: "${TMUX_SESSION:=claude}"
: "${RELOGIN_ENABLED:=false}"
: "${RELOGIN_WINDOW_SECONDS:=300}"
: "${CODE_PATTERN:=^[A-Za-z0-9_-]{16,200}(#[A-Za-z0-9_-]{4,100})?$}"
: "${STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/claude-login-watch}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

LOG_FILE="$STATE_DIR/watch.log"

# Never log the token, the chat id or the code: this file is plain text and
# ends up in bug reports.
log() {
    printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"
}

# Calls the Telegram API.
#
# The URL carries the bot token, and an argument to curl is readable by anyone
# who can list processes — `ps` shows it, and on a shared machine that is
# everyone. So the URL goes in through stdin as a curl config file instead,
# and the command line stays clean.
#
#   tg_api <method> [extra curl args...]
tg_api() {
    local method="$1"
    shift
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TELEGRAM_BOT_TOKEN" "$method" |
        curl -sS --max-time "${CURL_TIMEOUT:-20}" --config - "$@"
}

# Sends a message. The text is passed as a form field, so it needs no escaping.
notify() {
    local text="$1"
    tg_api sendMessage \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null || log "notify failed"
}

session_exists() {
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

# What the session currently shows. -p prints, -S -200 includes some scrollback,
# because the interesting line may have scrolled off.
capture_pane() {
    tmux capture-pane -p -S -200 -t "$TMUX_SESSION" 2>/dev/null || true
}

# Types text literally (-l), so nothing in it is read as a tmux key name.
send_literal() {
    tmux send-keys -t "$TMUX_SESSION" -l -- "$1"
    tmux send-keys -t "$TMUX_SESSION" Enter
}

# The strings Claude Code shows when the credential is gone. Kept in one place
# because they are the one thing likely to change upstream.
EXPIRED_PATTERN='Login expired|Please run /login|Anthropic profile login expired|authentication_failed'
