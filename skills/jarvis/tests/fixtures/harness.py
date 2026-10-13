#!/usr/bin/env python3
"""CLI boundary fixture. The real SessionStart carrier writes the identity."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import select
import sys
import shutil
import tempfile

# Native errors and turn markers exercised by orch/tests/lane-state-auth.sh.
AUTH_MESSAGES = {
    "claude": "  ⎿ \u00a0Login expired · Please run /login",
    "codex": "■ Your access token could not be refreshed because your refresh token has expired.",
    "copilot": " ✗ You must be logged in to send messages. Please run /login",
}


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
                                 str(Path(__file__).with_name("harness_launcher.rs")), "-o", str(path)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError("native-fixture: compile-failed\n" + result.stderr)
        yield path

def native_header(harness, identity, cwd):
    if harness == "claude":
        return {"cwd": cwd, "sessionId": identity}
    if harness == "codex":
        return {"type": "session_meta", "payload": {"id": identity, "cwd": cwd, "source": "cli"}}
    return {"type": "session", "id": identity, "cwd": cwd}


def main():
    fixture = json.loads(Path(".fixture.json").read_text())
    harness = fixture.get("harness", os.environ["JARVIS_TEST_HARNESS"])
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
    header = native_header(harness, identity, os.getcwd())
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
    shell = 'source "$1/mailbox/scripts/lib/file-lock.sh"; source "$1/orch/scripts/lib/lane-context.sh"; source "$1/orch/scripts/lib/session-rows.sh"; SESSION_ROWS_WAIT=10; key="$(tmux display-message -p "#{pid} #{pane_id}")"; session_rows_jarvis_write "$JARVIS_RECORD" "$JARVIS_GENERATION" "$key" "$2"'
    subprocess.run([fixture["bash"], "-c", shell, "fixture", fixture["skills"], harness],
                   input=json.dumps(payload), text=True, check=True)
    if fixture.get("hold_prompt"):
        # The direct delivery case first observes the real identity write.
        # Hold its prompt marker so automatic delivery cannot race that probe.
        with gate.open() as stream:
            stream.read(1)
    auth_mode = fixture.get("auth_mode")
    if auth_mode == "stale":
        print(AUTH_MESSAGES[harness] + "\n❯ continue\n❯\u00a0", flush=True)
    else:
        print("❯\u00a0", flush=True)
    prompt = sys.stdin.readline()
    if prompt == "":
        with rows.open("a") as stream:
            stream.write(json.dumps({"eof": True, "id": identity, "harness": harness}) + "\n")
        return
    with rows.open("a") as stream:
        stream.write(json.dumps({"prompt": prompt.strip(), "id": identity, "harness": harness}) + "\n")
    if fixture.get("idle"):
        print("❯\u00a0", flush=True)
    elif auth_mode == "current":
        print(AUTH_MESSAGES[harness], flush=True)
    elif auth_mode == "stale":
        print(AUTH_MESSAGES[harness] + "\nesc to interrupt", flush=True)
    else:
        print("Working to interrupt", flush=True)
    sys.stdin.read()


if __name__ == "__main__":
    main()
