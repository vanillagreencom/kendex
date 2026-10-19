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
import time

# Native errors and turn markers exercised by orch/tests/lane-state-auth.sh.
AUTH_MESSAGES = {
    "claude": "  ⎿ \u00a0Login expired · Please run /login",
    "codex": "■ Your access token could not be refreshed because your refresh token has expired.",
    "copilot": " ✗ You must be logged in to send messages. Please run /login",
}

# Pi's current editor: its title, footer and empty π prompt
# (orch/tests/fixtures/oversee-watch/pi-current.txt).
PI_IDLE = ("── π - jarvis - home " + "─" * 40 + "\n\n"
           + "● home Anthropic / Opus 5.5 / high 1M " + "─" * 20 + " 4%\nπ")
# The spinner a Claude Code 2.1.x Start turn drew (KEN-3862's owner run).
CLAUDE_SPINNER = "✻ Contemplating… (1s · thinking with high effort)"
# A resumed conversation that quotes the folder-trust question, drawn before
# the session's start (above its last turn) or after it (in that turn).
TRUST_HISTORY = {
    "pending": "❯ What does the folder-trust dialog ask?\n  It asks: Do you trust the files in this folder?\n❯ Thanks.\n  Noted.",
    "confirmed": "❯ What does the folder-trust dialog ask?\n  It asks: Do you trust the files in this folder?",
}


# Codex options the launch line spells with a separate value word.
CODEX_VALUE_OPTIONS = {"-c", "--config", "-m", "--model", "-a", "--ask-for-approval", "-p", "--profile",
                       "-s", "--sandbox", "-C", "--cd", "-i", "--image", "--enable", "--disable"}


def launch_prompt(harness, args):
    # Copilot CLI takes the prompt as the value of -i, Codex as the positional
    # after its options and its resume id: `codex [resume ID] [PROMPT]`.
    if harness == "copilot":
        return args[args.index("-i") + 1] if "-i" in args else None
    words, skip = [], False
    for arg in args:
        if skip:
            skip = False
        elif arg in CODEX_VALUE_OPTIONS:
            skip = True
        elif not arg.startswith("-"):
            words.append(arg)
    if words[:1] == ["resume"]:
        words = words[2:]
    return words[0] if words else None


def await_inspections(events, count):
    # A barrier, not a clock: the second pane read that began after the draw
    # proves the controller decided on the first one.
    def seen():
        return len(events.read_text().splitlines()) if events.exists() else 0
    target = seen() + count
    deadline = time.monotonic() + 10
    while seen() < target:
        assert time.monotonic() < deadline, "the controller did not read the drawn pane"
        time.sleep(0.05)


def brief_taken(fixture, harness, identity, event):
    # The native hook's stamp, written by its real library at the default wait.
    shell = 'source "$1/mailbox/scripts/lib/file-lock.sh"; source "$1/orch/scripts/lib/lane-context.sh"; source "$1/orch/scripts/lib/session-rows.sh"; key="$(tmux display-message -p "#{pid} #{pane_id}")"; session_rows_jarvis_taken "$JARVIS_RECORD" "$JARVIS_GENERATION" "$key" "$2" "$3"'
    result = subprocess.run([fixture["bash"], "-c", shell, "fixture", fixture["skills"], harness, event],
                            input=json.dumps({"session_id": identity}), text=True, capture_output=True)
    with Path(fixture["rows"]).open("a") as stream:
        stream.write(json.dumps({"stamp": event, "harness": harness,
                                 "exit": result.returncode, "stderr": result.stderr}) + "\n")
    result.check_returncode()


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
                                # This fixture uses the installed compiler;
                                # repository toolchain installation belongs to CI setup.
                                cwd=path.parent, capture_output=True, text=True, timeout=60)
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
                                 "account": str(account), "record": str(record_path), "pid": os.getpid(),
                                 "display": [os.environ.get("WAYLAND_DISPLAY"), os.environ.get("DISPLAY")]}) + "\n")
    history = fixture.get("history")
    if history == "pending":
        print(TRUST_HISTORY[history], flush=True)
    gate = Path(fixture["gate"])
    if gate.exists():
        with gate.open() as stream:
            stream.read(1)
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
    if fixture.get("trust"):
        # A native folder-trust question holds the harness before its start.
        print(Path(fixture["trust"]).read_text(), end="", flush=True)
        sys.stdin.read()
        return
    barrier = fixture.get("kickoff_barrier")
    deferred = harness in ("copilot", "codex")
    if deferred:
        # Copilot CLI and Codex fire SessionStart only once the first prompt
        # is submitted: the launch line's prompt, or else the first typed line.
        kickoff = launch_prompt(harness, args)
        if kickoff is None:
            print("❯\u00a0", flush=True)
            kickoff = sys.stdin.readline().strip()
        with rows.open("a") as stream:
            stream.write(json.dumps({"kickoff": kickoff, "id": identity, "harness": harness}) + "\n")
        if barrier:
            # The kickoff turn draws before its SessionStart stamp lands.
            print("Working to interrupt", flush=True)
            await_inspections(Path(barrier), 2)
    assert not select.select([sys.stdin], [], [], 0)[0], "a prompt preceded SessionStart"
    payload = {"session_id": identity}
    if harness != "copilot":
        payload["transcript_path"] = str(file)
    shell = 'source "$1/mailbox/scripts/lib/file-lock.sh"; source "$1/orch/scripts/lib/lane-context.sh"; source "$1/orch/scripts/lib/session-rows.sh"; SESSION_ROWS_WAIT=10; key="$(tmux display-message -p "#{pid} #{pane_id}")"; session_rows_jarvis_write "$JARVIS_RECORD" "$JARVIS_GENERATION" "$key" "$2"'
    subprocess.run([fixture["bash"], "-c", shell, "fixture", fixture["skills"], harness],
                   input=json.dumps(payload), text=True, check=True)
    if barrier:
        # The kickoff turn still runs after its stamp and draws only its
        # composer, which the pane reads as idle: no brief may land before
        # the turn's own end. The first read after the draw may pair it with
        # the record from before the stamp, so the third proves the worker
        # decided on a read of both.
        print("\033[2J\033[H❯\u00a0", flush=True)
        await_inspections(Path(barrier), 3)
        assert not select.select([sys.stdin], [], [], 0)[0], "the brief reached the kickoff turn"
        print("\033[2J\033[H", end="", flush=True)
    if history == "confirmed":
        print(TRUST_HISTORY[history], flush=True)
    if fixture.get("hold_prompt"):
        # The direct delivery case first observes the real identity write.
        # Hold its prompt marker so automatic delivery cannot race that probe.
        with gate.open() as stream:
            stream.read(1)
    if deferred:
        # The kickoff turn ends: its native turn-end hook stamps the record.
        brief_taken(fixture, harness, identity, "Stop")
    auth_mode = fixture.get("auth_mode")
    if auth_mode == "stale":
        print(AUTH_MESSAGES[harness] + "\n❯ continue\n❯\u00a0", flush=True)
    elif harness == "pi":
        print(PI_IDLE, flush=True)
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
        if fixture.get("auth_event"):
            # The turn's tool call, drawn after its wall so the worker's
            # first read of the stamp meets the wall on the pane.
            brief_taken(fixture, harness, identity, fixture["auth_event"])
    elif auth_mode == "stale":
        print(AUTH_MESSAGES[harness] + "\nesc to interrupt", flush=True)
    elif harness == "pi":
        # Pi draws no working rung; its first tool call says it took the brief.
        brief_taken(fixture, harness, identity, "PreToolUse")
    elif fixture.get("turn") == "spinner":
        # Claude Code 2.1.x draws a spinner no pane pattern names, then its
        # composer once the turn ends.
        print(CLAUDE_SPINNER + "\n❯\u00a0", flush=True)
        brief_taken(fixture, harness, identity, "Stop")
    elif fixture.get("turn") == "text-only":
        print("Ready.\n❯\u00a0", flush=True)
        # This instantaneous answer must follow the worker's delivery write:
        # before it, Stop still belongs to the already-ended kickoff turn.
        deadline = time.monotonic() + 10
        while not json.loads(record_path.read_text()).get("brief_delivered"):
            assert time.monotonic() < deadline, "the worker did not publish the brief delivery"
            time.sleep(0.05)
        brief_taken(fixture, harness, identity, "Stop")
    else:
        print("Working to interrupt", flush=True)
    if deferred and auth_mode != "current" and fixture.get("turn") != "text-only":
        if barrier:
            # A working pane after a kickoff turn is no proof of the brief:
            # the controller reads it twice before the stamp.
            await_inspections(Path(barrier), 2)
        # The Start brief's first tool call says the session took it.
        brief_taken(fixture, harness, identity, "PreToolUse")
    sys.stdin.read()


if __name__ == "__main__":
    main()
