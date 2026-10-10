"""Prepare the read cases whose base outputs are committed as fixtures."""

import json
from pathlib import Path
import sys
import subprocess


def prepare(root, state):
    box = Path(root) / "tmp/lane-mail/KEN-1"
    box.mkdir(parents=True, exist_ok=True)
    lane = [{"id": "answer", "kind": "answer", "re": "answered", "at": "2000-01-01T00:00:00Z"},
            {"id": "directive", "kind": "directive", "text": "First\nSecond", "at": "2000-01-01T00:00:00Z"},
            {"id": "halt", "kind": "directive", "halt": True, "at": "invalid"}]
    over = [{"id": "answered", "kind": "ask", "text": "Answered"},
            {"id": "notice", "kind": "notice", "text": "Notice"},
            {"id": "open", "kind": "ask", "to": "owner", "deadline": "2000-01-01T00:00:00Z"}]
    for name, rows in (("to-lane", lane), ("to-overseer", over)):
        raw = b"".join(json.dumps(row).encode() + b"\n" for row in rows[:1]) + b"invalid\n"
        raw += b"".join(json.dumps(row).encode() + b"\n" for row in rows[1:])
        if state == "broken":
            raw += b'{"id":"unfinished"}'
        (box / (name + ".jsonl")).write_bytes(raw)
        if state == "numbered":
            (box / (name + ".jsonl.numbering")).write_text(json.dumps(
                {"dropped": 5, "first": "original", "lines": [2, 4, 7, 8]}) + "\n")
    if state not in ("missed", "absent"):
        (box / "to-lane.cursor").write_text("1\n")
    if state != "absent":
        (box / "to-lane.cursor.lock").touch()


def reader_case(root, state, env, settings, spelling):
    """Build real Git roots for the owner's default, configured and linked reads."""
    root = Path(root)
    caller = root / "main\ncheckout" if spelling == "newline" else root
    caller.mkdir(parents=True, exist_ok=True)

    def git(*args):
        subprocess.run(["git", "-C", str(caller), *args], env=env,
                       capture_output=True, check=True, timeout=30)

    git("init", "-q", "-b", "main")
    git("config", "gc.auto", "0")
    git("config", "maintenance.auto", "false")
    prepare(caller, state)
    if spelling == "newline":
        git("config", "user.name", "Reader fixture")
        git("config", "user.email", "reader@example.com")
        git("config", "core.hooksPath", str(root / "no-hooks"))
        git("-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "fixture")
        target = root / "registered"
        git("worktree", "add", "-q", "-b", "ken-1", str(target))
        prepare(target, state)
    if settings:
        (caller / "kendex.settings.toml").write_text('[env]\nWORKTREE_BASE_DIR = "../custom-trees"\n')
    return caller


if __name__ == "__main__":
    prepare(*sys.argv[1:])
