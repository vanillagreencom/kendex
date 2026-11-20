#!/usr/bin/env python3
"""CLI boundary fixture: a Claude Code stand-in its native launcher names.

It takes `--session-id ID` or `--resume ID`, draws Claude Code's composer,
and records each line it reads as one user turn in a session file of Claude
Code's shape under CLAUDE_CONFIG_DIR (`projects/<cwd slug>/<id>.jsonl`), as
agent-runtime's session reader reads it. An account `.fixture.json` lists
under `unsigned` answers every turn with Claude Code's login wall; one it
lists under `mute` never draws its composer. It launches no model."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

COMPOSER = "❯ \n  ? for shortcuts"
# Claude Code's login wall below a turn (agent-runtime observe.rs AUTH_FAILURE).
LOGIN_WALL = "  ⎿  Not logged in · Please run /login\n"


@contextmanager
def native_launcher():
    if not shutil.which("python3"):
        raise RuntimeError("native-fixture: dependency=python3")
    supplied = os.environ.get("JARVIS_TEST_NATIVE")
    if supplied:
        path = Path(supplied)
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError("native-fixture: dependency=launcher")
        yield path
        return
    compiler = shutil.which("rustc")
    if not compiler:
        raise RuntimeError("native-fixture: dependency=rustc")
    with tempfile.TemporaryDirectory() as allocation:
        path = Path(allocation).resolve() / "harness-launcher"
        result = subprocess.run([compiler, "--edition=2021", "-D", "warnings",
                                 str(Path(__file__).resolve().with_name("harness_launcher.rs")), "-o", str(path)],
                                cwd=path.parent, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError("native-fixture: compile-failed " + json.dumps(
                {"returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}))
        yield path


def main():
    fixture = json.loads(Path(".fixture.json").read_text())
    args = sys.argv[1:]
    session = None
    for flag in ("--session-id", "--resume"):
        if flag in args:
            session = args[args.index(flag) + 1]
    session = session or "fixture-" + str(os.getpid())
    account = os.environ["CLAUDE_CONFIG_DIR"]
    cwd = os.getcwd()
    rows = Path(fixture["rows"])
    with rows.open("a") as stream:
        stream.write(json.dumps({"argv": args, "id": session, "account": account, "cwd": cwd, "pid": os.getpid(),
                                 "display": [os.environ.get("WAYLAND_DISPLAY"), os.environ.get("DISPLAY")]}) + "\n")
    if account in fixture.get("mute", []):
        sys.stdin.read()
        return
    file = Path(account) / "projects" / re.sub(r"[/.]", "-", cwd) / (session + ".jsonl")
    file.parent.mkdir(parents=True, exist_ok=True)
    if not file.exists():
        file.write_text(json.dumps({"type": "permission-mode", "permissionMode": "default", "sessionId": session}) + "\n")
    print(COMPOSER, flush=True)
    for line in sys.stdin:
        prompt = line.rstrip("\n")
        with file.open("a") as stream:
            stream.write(json.dumps({"parentUuid": None, "isSidechain": False, "type": "user",
                                     "message": {"role": "user", "content": prompt},
                                     "uuid": session + "-" + str(time.monotonic_ns()),
                                     "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
                                     "sessionId": session, "cwd": cwd}) + "\n")
        with rows.open("a") as stream:
            stream.write(json.dumps({"prompt": prompt, "id": session, "account": account}) + "\n")
        print("❯ " + prompt, flush=True)
        # The list is read at each turn, so a row can sign an account out
        # after the session on it started.
        if account in json.loads(Path(".fixture.json").read_text()).get("unsigned", []):
            print(LOGIN_WALL, flush=True)
        print(COMPOSER, flush=True)


if __name__ == "__main__":
    main()
