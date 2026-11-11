#!/usr/bin/env bash
# ---
# name: claude-attention
# event: Notification
# matcher: permission_prompt
# description: Advisory reader for Claude permission prompts and the claude-question-attention companion. Requires Claude Code 2.1.246 or newer, Python 3.8+ and tmux. Uses native terminalSequence BEL only when no attached client views the source pane and a client attaches to its session, with a shared user-wide 10-second cooldown. Controls only its own emissions; consumers wanting one channel select preferredNotifChannel=notifications_disabled themselves. Native terminal output is ignored headlessly. Not run on codex: its events do not provide Claude terminalSequence output. Not run on opencode: its events do not provide Claude terminalSequence output. Not run on cursor: its events do not provide Claude terminalSequence output. Not run on pi: its notification extension owns terminal delivery. Not run on gemini: its events do not provide Claude terminalSequence output. Not run on copilot: its events do not provide Claude terminalSequence output. Not run on antigravity: its events do not provide Claude terminalSequence output.
# summary: Rings the terminal bell when Claude needs permission in an inactive tmux pane. Requires Python 3 and limits this bundle to one alert per 10 seconds.
# safety: Advisory reader. Reads the hook payload and inherited tmux identifiers, then makes two bounded tmux queries. Writes one locked timestamp under the user cache directory. Expected absence and lock contention are silent; payload, query or state errors give a keyed notice at exit 0. Native terminalSequence JSON is the only stdout output.
# timeout: 5
# harnesses: [claude]
# ---
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  printf 'claude-attention: missing-tools=python3\n' >&2
  exit 0
fi

exec python3 -c '
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

try:
    import fcntl
except ImportError:
    print("claude-attention: missing-tools=fcntl", file=sys.stderr)
    sys.exit(0)


def notice(key, value):
    print("claude-attention: " + key + "=" + value, file=sys.stderr)


def query(tmux, args):
    try:
        result = subprocess.run([tmux] + args, capture_output=True, text=True,
                                timeout=1, check=False)
    except subprocess.TimeoutExpired:
        notice("query", "timeout")
        return None
    except (OSError, UnicodeError):
        notice("query", "unreadable")
        return None
    if result.returncode:
        # A source pane can disappear between the event and this lookup.
        if args[0] != "display-message":
            notice("query", "failed")
        return None
    return result.stdout


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError, UnicodeError):
        notice("payload", "unreadable")
        return
    if not isinstance(payload, dict):
        notice("payload", "invalid-object")
        return
    event = payload.get("hook_event_name")
    if not ((event == "Notification" and payload.get("notification_type") == "permission_prompt")
            or (event == "PreToolUse" and payload.get("tool_name") == "AskUserQuestion")):
        return

    pane = os.environ.get("TMUX_PANE", "")
    if not os.environ.get("TMUX") or not re.fullmatch(r"%[0-9]+", pane):
        return
    tmux = shutil.which("tmux")
    if tmux is None:
        return
    source = query(tmux, ["display-message", "-p", "-t", pane,
                          "#{pane_id}\t#{session_id}"])
    if source is None:
        return
    source_rows = source.splitlines()
    if len(source_rows) != 1:
        notice("query", "invalid-source")
        return
    source_fields = source_rows[0].split("\t")
    if len(source_fields) != 2 or source_fields[0] != pane or not re.fullmatch(r"\$[0-9]+", source_fields[1]):
        notice("query", "invalid-source")
        return
    session = source_fields[1]
    clients = query(tmux, ["list-clients", "-F", "#{session_id}\t#{pane_id}"])
    if clients is None:
        return
    attached = False
    viewed = False
    for row in clients.splitlines():
        fields = row.split("\t")
        if (len(fields) != 2 or not re.fullmatch(r"\$[0-9]+", fields[0])
                or not re.fullmatch(r"%[0-9]+", fields[1])):
            notice("query", "invalid-clients")
            return
        attached = attached or fields[0] == session
        viewed = viewed or fields[1] == pane
    if viewed or not attached:
        return

    cache = os.environ.get("XDG_CACHE_HOME")
    if not cache:
        home = os.environ.get("HOME")
        if not home:
            notice("state", "missing-home")
            return
        cache = os.path.join(home, ".cache")
    try:
        directory = Path(cache) / "kendex"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Every invocation locks this inode. Replacing it would split the lock.
        fd = os.open(str(directory / "claude-attention"), os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(fd, "r+", encoding="ascii") as state:
            try:
                fcntl.flock(state.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            saved = state.read()
            last = float(saved) if saved else None
            if last is not None and not math.isfinite(last):
                raise ValueError("nonfinite timestamp")
            now = time.time()
            # A wall-clock rollback starts a new cooldown epoch.
            if last is not None and 0 <= now - last < 10:
                return
            state.seek(0)
            state.write(str(now))
            state.truncate()
            state.flush()
            print(json.dumps({"terminalSequence": "\u0007"}))
    except (OSError, ValueError, UnicodeError):
        notice("state", "unavailable")


main()
'
