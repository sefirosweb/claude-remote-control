#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, never run on its own.
# bot.py sources it too (through bash), so the configuration, its defaults and
# every tmux, systemd and claude call live here once.

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
# systemd user units do not have ~/.local/bin on PATH, so name the binary.
: "${CLAUDE_BIN:=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
: "${REMOTE_SERVICE:=claude-remote.service}"
: "${LOGIN_FLAGS:=--claudeai}"
# Bad checks in a row before the watchdog raises the alarm.
: "${FAIL_THRESHOLD:=2}"
# Where `claude auth login` runs. Never the watched session: that one runs
# `claude remote-control`, which is not a REPL and ignores a typed /login.
LOGIN_SESSION="${TMUX_SESSION}-login"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

LOG_FILE="$STATE_DIR/watch.log"
# Written by bot.py while it runs. The scripts read it to know whether an
# incident goes to the bot (you answer with /login) or is handled here.
BOT_PID_FILE="$STATE_DIR/bot.pid"

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

bot_running() {
    local pid
    pid=$(cat "$BOT_PID_FILE" 2>/dev/null) || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# --- The watched session ------------------------------------------------
# Every helper takes an optional session name and defaults to TMUX_SESSION.

session_exists() {
    tmux has-session -t "${1:-$TMUX_SESSION}" 2>/dev/null
}

# What the session currently shows. -p prints, -S -200 includes some scrollback
# because the interesting line may have scrolled off, and -J rejoins lines the
# terminal wrapped — without it a long URL arrives cut in half.
capture_pane() {
    tmux capture-pane -p -J -S -200 -t "${1:-$TMUX_SESSION}" 2>/dev/null || true
}

# Types text literally (-l), so nothing in it is read as a tmux key name.
#   send_literal <text> [session]
send_literal() {
    local target="${2:-$TMUX_SESSION}"
    tmux send-keys -t "$target" -l -- "$1"
    tmux send-keys -t "$target" Enter
}

# Pulls the authorization link off the pane.
#
# The link does not arrive on one line: the TUI prints it across several, and
# tmux only rejoins what it wrapped itself. Grepping gets you the first chunk
# and a URL that fails with "missing state parameter". So: start at the scheme,
# keep taking lines while they still look like a continuation (no spaces), and
# stop at the first blank or prose line.
extract_oauth_url() {
    capture_pane "${1:-$TMUX_SESSION}" | awk '
        !collecting && /https:\/\/[^ ]*oauth/ {
            line = $0
            sub(/.*https:\/\//, "https://", line)
            gsub(/[ \t]+$/, "", line)
            url = line
            collecting = 1
            next
        }
        collecting {
            line = $0
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == "" || line ~ /[ \t]/) exit
            url = url line
        }
        END { print url }
    '
}

# An authorization link without these is a link that will not work. Better to
# say so than to send it and have the browser refuse it.
url_looks_complete() {
    printf '%s' "$1" | grep -q 'state=' && printf '%s' "$1" | grep -q 'code_challenge='
}

# The strings Claude Code shows when the credential is gone. Kept in one place
# because they are the one thing likely to change upstream.
EXPIRED_PATTERN='Login expired|Please run /login|Please use `/login`|Anthropic profile login expired|authentication_failed'

# What `claude auth login` prints once the pasted code is accepted or refused.
LOGIN_OK_PATTERN='Login successful'
LOGIN_FAIL_PATTERN='Invalid code|OAuth error|Authentication failed'

# The pane can lie in both directions: an old error stays in the scrollback,
# and `remote-control` keeps saying "Connected" with no credential behind it.
# This asks the CLI itself.
is_logged_in() {
    # Captured first: piping into grep -q under pipefail can fail on SIGPIPE.
    local status
    status=$("$CLAUDE_BIN" auth status 2>/dev/null || true)
    printf '%s' "$status" | grep -qE '"loggedIn":[[:space:]]*true'
}

# --- The login session --------------------------------------------------
# relogin.sh and bot.py drive the same four steps, so they live here.

# Starts `claude auth login` in LOGIN_SESSION, replacing a previous one. The
# window is wide so the link is not wrapped, and the sleep keeps the pane
# around after the command ends, long enough to read what it said.
start_login_session() {
    end_login_session
    tmux new-session -d -s "$LOGIN_SESSION" -x 400 -y 50 \
        "\"$CLAUDE_BIN\" auth login $LOGIN_FLAGS; sleep 30"
}

end_login_session() {
    tmux kill-session -t "$LOGIN_SESSION" 2>/dev/null || true
}

# Prints the authorization link once it is on the pane. Gives up after 30
# seconds, printing nothing and returning non-zero.
wait_for_oauth_url() {
    local url
    for _ in $(seq 1 30); do
        sleep 1
        url=$(extract_oauth_url "$LOGIN_SESSION")
        if [ -n "$url" ] && url_looks_complete "$url"; then
            printf '%s\n' "$url"
            return 0
        fi
    done
    return 1
}

# Waits for `claude auth login` to say whether the pasted code was taken.
# Prints "ok" or "failed", or "unclear" when it said neither in 20 seconds
# and the credential is not there either.
login_outcome() {
    local pane
    for _ in $(seq 1 20); do
        sleep 1
        pane=$(capture_pane "$LOGIN_SESSION")
        if printf '%s' "$pane" | grep -qE "$LOGIN_OK_PATTERN"; then
            echo ok
            return 0
        fi
        if printf '%s' "$pane" | grep -qE "$LOGIN_FAIL_PATTERN"; then
            echo failed
            return 0
        fi
    done
    if is_logged_in; then echo ok; else echo unclear; fi
}

# --- The service --------------------------------------------------------

restart_remote_service() {
    systemctl --user restart "$REMOTE_SERVICE"
}

# How many times systemd has restarted the service on its own since it was
# last started by hand. Growing between checks means it keeps dying.
service_restarts() {
    local restarts
    restarts=$(systemctl --user show -p NRestarts --value "$REMOTE_SERVICE" 2>/dev/null || true)
    printf '%s\n' "${restarts:-0}"
}

# One line about REMOTE_SERVICE, e.g. "active (running), 3 restarts".
service_summary() {
    local state sub
    state=$(systemctl --user show -p ActiveState --value "$REMOTE_SERVICE" 2>/dev/null || true)
    sub=$(systemctl --user show -p SubState --value "$REMOTE_SERVICE" 2>/dev/null || true)
    printf '%s (%s), %s restarts\n' "${state:-unknown}" "${sub:-unknown}" "$(service_restarts)"
}

# --- Versions -----------------------------------------------------------

installed_version() {
    "$CLAUDE_BIN" --version 2>/dev/null | awk '{print $1}'
}

# The newest release on npm, which is what `claude update` installs. Prints
# nothing when the registry cannot be reached.
latest_version() {
    curl -sS --max-time 10 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null |
        python3 -c 'import json, sys; print(json.load(sys.stdin).get("version", ""))' 2>/dev/null || true
}
