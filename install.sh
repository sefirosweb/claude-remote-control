#!/usr/bin/env bash
# Installs the watcher for the current user. No root, nothing outside $HOME.
#
#   ./install.sh            copy scripts, create the config from the example
#   ./install.sh --timer    also enable the 10-minute backstop timer
#
# The Claude Code hook is NOT installed automatically: it edits a settings file
# you may already have set up, so the README shows the snippet to paste.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/claude-login-watch"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-login-watch"
UNIT_DIR="$HOME/.config/systemd/user"

echo "Installing to $DEST"
mkdir -p "$DEST/bin" "$CONFIG_DIR"
install -m 755 "$SRC/bin/"*.sh "$DEST/bin/"

if [ -f "$CONFIG_DIR/config" ]; then
    echo "Config already exists, left untouched: $CONFIG_DIR/config"
else
    install -m 600 "$SRC/config.example" "$CONFIG_DIR/config"
    echo "Config created at $CONFIG_DIR/config — fill in the bot token and chat id."
fi

if [ "${1:-}" = "--timer" ]; then
    mkdir -p "$UNIT_DIR"
    install -m 644 "$SRC/systemd/"*.service "$SRC/systemd/"*.timer "$UNIT_DIR/"
    systemctl --user daemon-reload
    systemctl --user enable --now claude-login-watch.timer
    echo "Timer enabled. Next runs:"
    systemctl --user list-timers claude-login-watch.timer --no-pager | sed -n '1,2p'
fi

cat <<EOF

Done. Next:

  1. Edit $CONFIG_DIR/config
  2. Check it end to end:   $DEST/bin/watchdog.sh --test
  3. Add the hook to your Claude Code settings (see the README)

EOF
