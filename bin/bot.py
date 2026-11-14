#!/usr/bin/env python3
"""Telegram command bot for the Claude Code login watcher.

Long-polls Telegram and answers a fixed set of commands from one chat:

  /status   login, version, service and session state
  /login    runs `claude auth login`, sends you the link, types back your code
  /restart  restarts the remote-control service
  /update   runs `claude update`, restarts the service if the version changed
  /logs     last lines of the session and of the service journal
  /cancel   forgets a pending /login
  /help     the list

Nothing listens on a port: the bot asks Telegram, Telegram does not reach in.
Only TELEGRAM_CHAT_ID is read and answered, and the only text ever typed into
a terminal is a reply matching CODE_PATTERN while a /login is pending.

The configuration and every tmux, systemd and claude call live in common.sh,
so this file is the Telegram side only. Standard library, Python 3.8+.
"""

import atexit
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
COMMON = os.path.join(HERE, "common.sh")

COMMANDS = [
    ("status", "Login, version, service and session"),
    ("login", "Run claude auth login and send me the link"),
    ("restart", "Restart the remote-control service"),
    ("update", "Update Claude Code and restart the service"),
    ("logs", "Last lines of the session and the service journal"),
    ("cancel", "Forget a pending /login"),
    ("help", "List the commands"),
]

# Telegram rejects longer messages; logs get cut to fit.
MAX_TEXT = 4000

# Terminal colour codes, stripped from command output before it is sent.
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def load_config():
    """Sources common.sh under `set -a`, so the config and every default it
    fills in come back through the environment. No second parser."""
    result = subprocess.run(
        ["bash", "-c", 'set -a; . "$0"; env -0', COMMON], capture_output=True
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode(errors="replace"))
        sys.exit(result.returncode)
    config = {}
    for item in result.stdout.split(b"\0"):
        key, sep, value = item.partition(b"=")
        if sep:
            config[key.decode(errors="replace")] = value.decode(errors="replace")
    return config


CFG = load_config()
TOKEN = CFG["TELEGRAM_BOT_TOKEN"]
CHAT_ID = CFG["TELEGRAM_CHAT_ID"]
STATE_DIR = CFG["STATE_DIR"]
LOGIN_SESSION = CFG["LOGIN_SESSION"]
REMOTE_SERVICE = CFG["REMOTE_SERVICE"]
CLAUDE_BIN = CFG["CLAUDE_BIN"]
CODE_PATTERN = re.compile(CFG["CODE_PATTERN"])
CODE_WINDOW = int(CFG["RELOGIN_WINDOW_SECONDS"])
PID_FILE = CFG["BOT_PID_FILE"]
LOG_FILE = os.path.join(STATE_DIR, "bot.log")
HOST = os.uname().nodename


def log(message):
    """To stderr (the journal) and to bot.log. Never the token or a code."""
    line = time.strftime("%Y-%m-%dT%H:%M:%S%z") + " " + message
    print(line, file=sys.stderr, flush=True)
    try:
        with open(LOG_FILE, "a") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


def sh(function, *args):
    """Runs one helper from common.sh. Returns (succeeded, stdout)."""
    result = subprocess.run(
        ["bash", "-c", '. "$0" && "$@"', COMMON, function, *args],
        capture_output=True,
        text=True,
        errors="replace",
    )
    return result.returncode == 0, result.stdout.strip()


def tail(text, count):
    """The last non-blank lines, trimmed and without colour codes."""
    lines = [ANSI.sub("", line).strip() for line in text.splitlines()]
    return [line for line in lines if line][-count:]


def tg(method, params, timeout=20):
    """One Telegram API call. The token is in the URL and nowhere else: not
    on a command line, not in a log."""
    data = urllib.parse.urlencode(params).encode()
    request = urllib.request.Request(
        "https://api.telegram.org/bot%s/%s" % (TOKEN, method), data=data
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def notify(text):
    if len(text) > MAX_TEXT:
        text = text[:MAX_TEXT] + "\n[…]"
    try:
        tg(
            "sendMessage",
            {"chat_id": CHAT_ID, "text": text, "disable_web_page_preview": "true"},
        )
    except (urllib.error.URLError, OSError, ValueError) as error:
        log("notify failed: %s" % error)


class Bot:
    def __init__(self):
        self.offset = 0
        # Set while a /login waits for its code; None otherwise.
        self.code_deadline = None

    # --- commands -------------------------------------------------------

    def cmd_help(self):
        lines = ["Claude Code login watcher on %s." % HOST, ""]
        lines += ["/%s — %s" % (name, text) for name, text in COMMANDS]
        return "\n".join(lines)

    def cmd_status(self):
        logged_in, _ = sh("is_logged_in")
        session, _ = sh("session_exists")
        _, service = sh("service_summary")
        _, installed = sh("installed_version")
        _, latest = sh("latest_version")
        _, pane = sh("capture_pane")

        installed = installed or "?"
        if not latest:
            version = "%s (could not check for updates)" % installed
        elif latest == installed:
            version = "%s, up to date" % installed
        else:
            version = "%s — %s available, send /update" % (installed, latest)

        lines = [
            "🖥 %s" % HOST,
            "Login:    %s" % ("ok" if logged_in else "LOGGED OUT — send /login"),
            "Version:  %s" % version,
            "Service:  %s (%s)" % (service, REMOTE_SERVICE),
            "Session:  %s"
            % ("running" if session else "NOT RUNNING — send /logs or /restart"),
        ]
        if self.code_deadline is not None:
            minutes = max(0, int((self.code_deadline - time.time()) / 60))
            lines.append("Pending:  /login waiting for your code, %d min left" % minutes)
        last = tail(pane, 3)
        if last:
            lines += ["", "Last lines of the session:"] + ["  " + line for line in last]
        return "\n".join(lines)

    def cmd_login(self):
        self.code_deadline = None
        started, _ = sh("start_login_session")
        if not started:
            return "⚠️ Could not start 'claude auth login' in tmux. Send /logs."
        found, url = sh("wait_for_oauth_url")
        if not found or not url:
            _, pane = sh("capture_pane", LOGIN_SESSION)
            sh("end_login_session")
            return (
                "⚠️ Ran 'claude auth login' but no complete authorization link "
                "appeared. It said:\n\n" + "\n".join(tail(pane, 5))
            )
        self.code_deadline = time.time() + CODE_WINDOW
        log("login started, link sent")
        return (
            "🔗 Open this, approve access, and send me back the code as a plain "
            "message:\n\n%s\n\nI will wait %d minutes. /cancel to stop."
            % (url, CODE_WINDOW // 60)
        )

    def paste_code(self, code):
        self.code_deadline = None
        log("code received, pasting")
        sh("send_literal", code, LOGIN_SESSION)
        _, outcome = sh("login_outcome")
        _, pane = sh("capture_pane", LOGIN_SESSION)
        sh("end_login_session")
        if outcome != "ok":
            log("login %s after the code" % outcome)
            return (
                "❌ The code did not take (%s). The session said:\n\n%s\n\n"
                "Send /login for a fresh link." % (outcome, "\n".join(tail(pane, 5)))
            )
        self.clear_incident()
        log("login ok, restarting %s" % REMOTE_SERVICE)
        restarted, _ = sh("restart_remote_service")
        if restarted:
            return "✅ Signed in again and %s restarted. Remote Control is back." % REMOTE_SERVICE
        return "⚠️ Signed in, but restarting %s failed. Send /restart." % REMOTE_SERVICE

    def cmd_cancel(self):
        if self.code_deadline is None:
            return "No /login pending."
        self.code_deadline = None
        sh("end_login_session")
        log("login cancelled")
        return "Cancelled. Nothing was typed."

    def cmd_restart(self):
        log("restart requested")
        restarted, _ = sh("restart_remote_service")
        time.sleep(5)
        _, service = sh("service_summary")
        session, _ = sh("session_exists")
        if restarted and session:
            return "🔄 %s restarted: %s. Session running." % (REMOTE_SERVICE, service)
        return "❌ %s did not come back: %s. Send /logs." % (REMOTE_SERVICE, service)

    def cmd_update(self):
        log("update requested")
        _, before = sh("installed_version")
        try:
            result = subprocess.run(
                [CLAUDE_BIN, "update"],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=600,
            )
            output = "\n".join(tail(result.stdout + "\n" + result.stderr, 8))
        except subprocess.TimeoutExpired:
            return "❌ 'claude update' did not finish in 10 minutes."
        _, after = sh("installed_version")
        if after and after != before:
            log("updated %s -> %s" % (before, after))
            restarted, _ = sh("restart_remote_service")
            if restarted:
                note = "%s restarted with it." % REMOTE_SERVICE
            else:
                note = "Restarting %s failed, send /restart." % REMOTE_SERVICE
            return "⬆️ Updated %s → %s. %s\n\n%s" % (before, after, note, output)
        return "Claude Code is still %s.\n\n%s" % (before or "?", output)

    def cmd_logs(self):
        _, pane = sh("capture_pane")
        journal = subprocess.run(
            ["journalctl", "--user", "-u", REMOTE_SERVICE, "-n", "12", "--no-pager", "-o", "short-iso"],
            capture_output=True,
            text=True,
            errors="replace",
        ).stdout
        lines = ["Session (last 15 lines):"]
        lines += ["  " + line for line in tail(pane, 15)] or ["  (session not running)"]
        lines += ["", "Journal of %s (last 12):" % REMOTE_SERVICE]
        lines += ["  " + line for line in tail(journal, 12)] or ["  (nothing)"]
        return "\n".join(lines)

    # --- plumbing -------------------------------------------------------

    def clear_incident(self):
        """Forgets the watchdog's markers after a login the bot has already
        announced: otherwise it would announce the recovery again, or stay
        quiet on the next incident for six hours."""
        for name in ("warned", "failures"):
            try:
                os.remove(os.path.join(STATE_DIR, name))
            except FileNotFoundError:
                pass

    def handle(self, text):
        if text.startswith("/"):
            parts = text[1:].split()
            command = parts[0].split("@")[0].lower() if parts else ""
            if command == "start":
                command = "help"
            if command not in dict(COMMANDS):
                notify("Unknown command. /help lists them.")
                return
            log("/" + command)
            notify(getattr(self, "cmd_" + command)())
            return
        if self.code_deadline is None:
            notify("Not a command. /help lists them.")
            return
        if CODE_PATTERN.match(text):
            notify(self.paste_code(text))
            return
        log("reply ignored: does not look like a code")
        notify("That does not look like a code, so I have not typed it. Send just the code, or /cancel.")

    def expire_login(self):
        if self.code_deadline is None or time.time() < self.code_deadline:
            return
        self.code_deadline = None
        sh("end_login_session")
        log("window closed with no code")
        notify("⌛ No code arrived in time. Send /login again for a fresh link.")

    def skip_backlog(self):
        """Anything sent while the bot was down is not acted on: a /restart
        from last night should not fire now, and an old code is never typed."""
        try:
            updates = tg("getUpdates", {"offset": -1}).get("result", [])
            self.offset = updates[-1]["update_id"] + 1 if updates else 0
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            log("could not read the backlog: %s" % error)

    def remove_pid(self):
        try:
            os.remove(PID_FILE)
        except OSError:
            pass

    def run(self):
        with open(PID_FILE, "w") as handle:
            handle.write(str(os.getpid()))
        atexit.register(self.remove_pid)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

        # So Telegram shows the "/" menu with these.
        try:
            tg("setMyCommands", {"commands": json.dumps(
                [{"command": name, "description": text} for name, text in COMMANDS]
            )})
        except (urllib.error.URLError, OSError, ValueError) as error:
            log("setMyCommands failed: %s" % error)

        self.skip_backlog()
        log("bot started")

        while True:
            try:
                # Long polling: Telegram holds the request open until something
                # arrives, so the socket waits longer than the usual call.
                response = tg(
                    "getUpdates",
                    {"offset": self.offset, "timeout": 25, "allowed_updates": '["message"]'},
                    timeout=40,
                )
            except urllib.error.HTTPError as error:
                if error.code == 409:
                    log("another process is reading this bot's updates (relogin.sh?); waiting")
                else:
                    log("telegram error %s" % error.code)
                time.sleep(10)
                continue
            except (urllib.error.URLError, OSError, ValueError) as error:
                log("telegram unreachable: %s" % error)
                time.sleep(10)
                continue

            for update in response.get("result", []):
                self.offset = update["update_id"] + 1
                message = update.get("message") or {}
                chat = str((message.get("chat") or {}).get("id"))
                text = (message.get("text") or "").strip()
                if chat != CHAT_ID:
                    log("ignored a message from another chat")
                    continue
                if text:
                    self.handle(text)

            self.expire_login()


if __name__ == "__main__":
    Bot().run()
