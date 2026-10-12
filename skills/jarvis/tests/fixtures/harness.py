#!/usr/bin/env python3
"""CLI boundary fixture. The real SessionStart carrier writes the identity."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import select
import sys

harness = Path(sys.argv[0]).name
if sys.platform == "linux":
    ctypes.CDLL(None).prctl(15, harness.encode(), 0, 0, 0)
args = sys.argv[1:]
record_path = Path(os.environ["JARVIS_RECORD"])
record = json.loads(record_path.read_text())
identity = record["pending"].get("native_session_id")
if harness == "codex":
    identity = args[args.index("resume") + 1] if "resume" in args else "codex-native-" + os.environ["JARVIS_GENERATION"]
else:
    if harness == "pi" and "--session" in args:
        file = Path(args[args.index("--session") + 1])
        identity = json.loads(file.read_text().splitlines()[0])["id"]
    elif "--session-id" in args:
        assert args[args.index("--session-id") + 1] == identity
    elif any(arg.startswith("--session-id=") or arg.startswith("--resume=") for arg in args):
        assert next(arg.split("=", 1)[1] for arg in args if arg.startswith(("--session-id=", "--resume="))) == identity
    elif "--resume" in args:
        assert args[args.index("--resume") + 1] == identity
    else:
        raise AssertionError("the native identity flag is absent")
account_var = {"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME", "copilot": "COPILOT_HOME", "pi": "PI_CODING_AGENT_DIR"}[harness]
account = Path(os.environ[account_var])
fixture = json.loads(Path(".fixture.json").read_text())
rows = Path(fixture["rows"])
with rows.open("a") as stream:
    stream.write(json.dumps({"harness": harness, "id": identity, "argv": args, "cwd": os.getcwd(),
                             "account": str(account), "record": str(record_path), "pid": os.getpid()}) + "\n")
gate = Path(fixture["gate"])
if gate.exists():
    with gate.open() as stream:
        stream.read(1)
assert not select.select([sys.stdin], [], [], 0)[0], "a prompt preceded SessionStart"
file = account / "sessions" / (identity + ".jsonl")
if harness == "claude":
    header = {"cwd": os.getcwd(), "sessionId": identity}
elif harness == "codex":
    header = {"type": "session_meta", "payload": {"id": identity, "cwd": os.getcwd(), "source": "cli"}}
else:
    header = {"type": "session", "id": identity, "cwd": os.getcwd()}
if harness == "copilot":
    folder = account / "session-state" / identity
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "workspace.yaml").write_text("id: " + identity + "\ncwd: " + os.getcwd() + "\n")
    (folder / "events.jsonl").write_text('{"type":"session.start"}\n')
else:
    file.parent.mkdir(parents=True, exist_ok=True)
    if not file.exists():
        file.write_text(json.dumps(header) + "\n")
payload = {"session_id": identity}
if harness != "copilot":
    payload["transcript_path"] = str(file)
shell = 'source "$1/mailbox/scripts/lib/file-lock.sh"; source "$1/orch/scripts/lib/session-rows.sh"; SESSION_ROWS_WAIT=10; key="$(tmux display-message -p "#{pid} #{pane_id}")"; session_rows_jarvis_write "$JARVIS_RECORD" "$JARVIS_GENERATION" "$key"'
subprocess.run([fixture["bash"], "-c", shell, "fixture", fixture["skills"]],
               input=json.dumps(payload), text=True, check=True)
print("❯\u00a0", flush=True)
prompt = sys.stdin.readline()
with rows.open("a") as stream:
    stream.write(json.dumps({"prompt": prompt.strip(), "id": identity, "harness": harness}) + "\n")
if fixture.get("idle"):
    print("❯\u00a0", flush=True)
elif fixture.get("auth_failure"):
    print("Not logged in. Please run /login", flush=True)
else:
    print("Working to interrupt", flush=True)
sys.stdin.read()
