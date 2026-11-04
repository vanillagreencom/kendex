#!/usr/bin/env bash
# Surface: claude-attention.sh. Inputs: that hook and tests/lib/assert.sh.
set -euo pipefail
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$TEST_DIR/../claude-attention.sh}"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d "$TEST_DIR/../../tmp/claude-attention.XXXXXX")" || { echo 'claude-attention-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "claude-attention-test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'claude-attention-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/lib/assert.sh"
PYTHON="$(command -v python3)"

status=0
"$PYTHON" - "$HOOK" "$BASH" "$TMP_ROOT" "${1:-}" "${BASH_SOURCE[0]}" <<'PY' || status=$?
import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import sys

hook, bash, scratch, selected, suite = sys.argv[1:]
root = Path(scratch)
bin_dir = root / "bin"
bin_dir.mkdir()
permission = {"hook_event_name": "Notification", "notification_type": "permission_prompt"}
question = {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"}
bell = {"terminalSequence": "\u0007"}

# The interpreter boundary supplies time and process-failure fixtures. The
# production hook retains real subprocess argv, JSON, filesystem and flock.
interpreter = bin_dir / "python3"
interpreter.write_text("#!" + sys.executable + "\n" + '''
import fcntl, os, subprocess, sys, time
time.time = lambda: float(os.environ["FIXTURE_TIME"])
if os.environ.get("FIXTURE_TIMEOUT"):
    def timeout(*args, **kwargs):
        assert kwargs["timeout"] == 1
        raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])
    subprocess.run = timeout
if os.environ.get("FIXTURE_BARRIER"):
    original_flock = fcntl.flock
    def flock(fd, operation):
        os.write(int(os.environ["FIXTURE_READY_FD"]), b"r")
        assert os.read(int(os.environ["FIXTURE_RELEASE_FD"]), 1) == b"x"
        return original_flock(fd, operation)
    fcntl.flock = flock
if os.environ.get("FIXTURE_LOCK_ERROR"):
    def unavailable_lock(*args): raise OSError("fixture lock failure")
    fcntl.flock = unavailable_lock
if os.environ.get("FIXTURE_WRITE_ERROR"):
    original_fdopen = os.fdopen
    class State:
        def __init__(self, *args, **kwargs):
            self.file = original_fdopen(*args, **kwargs)
        def __enter__(self): return self
        def __exit__(self, *args): self.file.close()
        def __getattr__(self, name): return getattr(self.file, name)
        def write(self, text): raise OSError("fixture write failure")
    os.fdopen = State
assert sys.argv[1] == "-c"
exec(compile(sys.argv[2], "<hook>", "exec"))
''')
interpreter.chmod(0o755)
tmux = bin_dir / "tmux"
tmux.write_text("#!" + sys.executable + "\n" + '''
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FIXTURE_CALLS"], "a") as calls:
    calls.write(json.dumps(args) + "\\n")
if args == ["display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{pane_id}\\t#{session_id}"]:
    sys.stdout.write(os.environ["FIXTURE_SOURCE"])
    sys.exit(int(os.environ.get("FIXTURE_SOURCE_EXIT", "0")))
if args == ["list-clients", "-F", "#{session_id}\\t#{pane_id}"]:
    sys.stdout.write(os.environ["FIXTURE_CLIENTS"])
    sys.exit(int(os.environ.get("FIXTURE_CLIENTS_EXIT", "0")))
sys.exit(99)
''')
tmux.chmod(0o755)


def world(name):
    home = root / name
    home.mkdir()
    return {"HOME": str(home), "PATH": str(bin_dir), "TMUX": "fixture,1,0",
            "TMUX_PANE": "%1", "XDG_CACHE_HOME": str(home / "cache"),
            "FIXTURE_TIME": "100", "FIXTURE_SOURCE": "%1\t$1\n",
            "FIXTURE_CLIENTS": "$1\t%2\n", "FIXTURE_CALLS": str(home / "calls")}


def state_path(env):
    return Path(env.get("XDG_CACHE_HOME") or str(Path(env["HOME"]) / ".cache")) / "kendex" / "claude-attention"


def fire(env, payload=permission):
    data = payload if isinstance(payload, str) else json.dumps(payload)
    result = subprocess.run([bash, hook], input=data, text=True, capture_output=True,
                            env=env, timeout=8)
    assert result.returncode == 0, (result.returncode, result.stderr)
    return result


def emitted(result):
    assert json.loads(result.stdout) == bell, repr(result.stdout)
    assert result.stderr == "", result.stderr


def quiet(result, key=None):
    assert result.stdout == "", repr(result.stdout)
    if key:
        assert result.stderr.splitlines()[0] == "claude-attention: " + key, result.stderr
    else:
        assert result.stderr == "", result.stderr


def active_row():
    env = world("active")
    path = state_path(env)
    path.parent.mkdir(parents=True)
    path.write_text("75")
    before = path.stat().st_ino
    env["FIXTURE_CLIENTS"] = "$1\t%2\n$9\t%1\n"
    quiet(fire(env))
    assert path.read_text() == "75" and path.stat().st_ino == before
    env["FIXTURE_CLIENTS"] = "$1\t%2\n"
    env["FIXTURE_TIME"] = "101"
    emitted(fire(env))


def all_rows():
    for name, changes in [
        ("inactive-split", {}),
        ("inactive-window", {"FIXTURE_CLIENTS": "$1\t%9\n$2\t%8\n"}),
        ("moved-session", {"FIXTURE_SOURCE": "%1\t$4\n", "FIXTURE_CLIENTS": "$4\t%7\n"}),
        ("home-cache", {"XDG_CACHE_HOME": ""}),
    ]:
        env = world(name)
        env.update(changes)
        emitted(fire(env))
        assert state_path(env).read_text() == "100.0"

    for name, clients in [("active-source-session", "$1\t%1\n"),
                          ("active-several-clients", "$1\t%2\n$1\t%1\n$3\t%1\n")]:
        env = world(name)
        env["FIXTURE_CLIENTS"] = clients
        quiet(fire(env))
        assert not state_path(env).exists()
    active_row()

    absent_rows = [
        ("outside-tmux", {"TMUX": ""}, None),
        ("missing-pane", {"TMUX_PANE": ""}, None),
        ("invalid-pane", {"TMUX_PANE": "%1;bad"}, None),
        ("stale-pane", {"FIXTURE_SOURCE_EXIT": "1"}, None),
        ("detached", {"FIXTURE_CLIENTS": ""}, None),
        ("other-session-only", {"FIXTURE_CLIENTS": "$2\t%2\n"}, None),
        ("bad-source", {"FIXTURE_SOURCE": "%3\t$1\n"}, "query=invalid-source"),
        ("partial-source", {"FIXTURE_SOURCE": "%1\t$1\n%1\t$2\n"}, "query=invalid-source"),
        ("bad-session", {"FIXTURE_SOURCE": "%1\tnone\n"}, "query=invalid-source"),
        ("partial-clients", {"FIXTURE_CLIENTS": "$1\t%2\ninvalid\n"}, "query=invalid-clients"),
        ("failed-clients", {"FIXTURE_CLIENTS_EXIT": "1"}, "query=failed"),
        ("timeout", {"FIXTURE_TIMEOUT": "1"}, "query=timeout"),
    ]
    for name, changes, key in absent_rows:
        env = world(name)
        env.update(changes)
        quiet(fire(env), key)
        assert not state_path(env).exists()
    env = world("no-target-does-not-consume")
    env["FIXTURE_CLIENTS"] = ""
    quiet(fire(env))
    env.update(FIXTURE_CLIENTS="$1\t%2\n", FIXTURE_TIME="101")
    emitted(fire(env))

    for name, payload, key in [
        ("idle", {"hook_event_name": "Notification", "notification_type": "idle_prompt"}, None),
        ("auth", {"hook_event_name": "Notification", "notification_type": "auth_success"}, None),
        ("agent-input", {"hook_event_name": "Notification", "notification_type": "agent_needs_input"}, None),
        ("wrong-tool", {"hook_event_name": "PreToolUse", "tool_name": "Bash"}, None),
        ("wrong-event", {"hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion"}, None),
        ("empty-object", {}, None),
        ("malformed", "{", "payload=unreadable"),
        ("empty-payload", "", "payload=unreadable"),
        ("non-object", [], "payload=invalid-object"),
    ]:
        env = world(name)
        quiet(fire(env, payload), key)
        assert not Path(env["FIXTURE_CALLS"]).exists()
        assert not state_path(env).exists()

    env = world("shared-cooldown")
    emitted(fire(env))
    path = state_path(env)
    inode = path.stat().st_ino
    env.update(TMUX_PANE="%3", FIXTURE_SOURCE="%3\t$2\n", FIXTURE_CLIENTS="$2\t%4\n",
               FIXTURE_TIME="109.999")
    quiet(fire(env, question))
    assert path.read_text() == "100.0"
    env["FIXTURE_TIME"] = "110"
    emitted(fire(env, question))
    assert path.stat().st_ino == inode
    env["FIXTURE_TIME"] = "90"
    emitted(fire(env))
    assert path.read_text() == "90.0"

    for name, saved in [("malformed-state", "broken"), ("nan-state", "nan"), ("infinite-state", "inf")]:
        env = world(name)
        path = state_path(env)
        path.parent.mkdir(parents=True)
        path.write_text(saved)
        quiet(fire(env), "state=unavailable")
        assert path.read_text() == saved
    env = world("cache-open-error")
    Path(env["XDG_CACHE_HOME"]).write_text("not a directory")
    quiet(fire(env), "state=unavailable")
    env = world("cache-write-error")
    env["FIXTURE_WRITE_ERROR"] = "1"
    quiet(fire(env), "state=unavailable")
    env = world("lock-error")
    env["FIXTURE_LOCK_ERROR"] = "1"
    quiet(fire(env), "state=unavailable")
    assert state_path(env).read_text() == ""

    env = world("lock-contention")
    path = state_path(env)
    path.parent.mkdir(parents=True)
    with path.open("w+") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        quiet(fire(env))
        assert path.read_text() == ""
    emitted(fire(env))

    env = world("concurrent")
    ready_read, ready_write = os.pipe()
    release_read, release_write = os.pipe()
    children = []
    try:
        env.update(FIXTURE_BARRIER="1", FIXTURE_READY_FD=str(ready_write),
                   FIXTURE_RELEASE_FD=str(release_read))
        for _ in range(2):
            child = subprocess.Popen([bash, hook], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, env=env,
                                     pass_fds=(ready_write, release_read))
            children.append(child)
            child.stdin.write(json.dumps(permission))
            child.stdin.close()
            child.stdin = None
        received = b""
        while len(received) < 2:
            assert select.select([ready_read], [], [], 8)[0], "barrier not reached"
            received += os.read(ready_read, 2 - len(received))
        os.write(release_write, b"xx")
        outputs = [child.communicate(timeout=8) for child in children]
        assert all(child.returncode == 0 for child in children)
        assert all(err == "" for _, err in outputs), outputs
        assert sum(bool(out) for out, _ in outputs) == 1, outputs
        assert [json.loads(out) for out, _ in outputs if out] == [bell]
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
            child.wait()
        for fd in (ready_read, ready_write, release_read, release_write):
            os.close(fd)

    env = world("missing-tmux")
    tmux.rename(bin_dir / "tmux-away")
    try:
        quiet(fire(env))
        assert not state_path(env).exists()
    finally:
        (bin_dir / "tmux-away").rename(tmux)
    env = world("missing-python")
    env["PATH"] = str(root / "empty-bin")
    quiet(fire(env), "missing-tools=python3")


try:
    if selected == "--active-pane-row":
        active_row()
    else:
        all_rows()
except AssertionError as error:
    print("FAIL active-pane-silence" if selected else "FAIL attention-contract", error, file=sys.stderr)
    sys.exit(1)

if not selected and not os.environ.get("HOOK_UNDER_TEST"):
    source = Path(hook)
    assert not source.is_symlink()
    text = source.read_text()
    anchor = "    if viewed or not attached:\n        return"
    assert text.count(anchor) == 1
    changed = text.replace(anchor, "    if viewed or not attached:\n        if not viewed:\n            return")
    assert changed != text
    mutant = root / "control.sh"
    mutant.write_text(changed)
    result = subprocess.run([bash, suite, "--active-pane-row"], capture_output=True, text=True,
                            env={"PATH": os.defpath, "HOOK_UNDER_TEST": str(mutant)}, timeout=15)
    assert result.returncode == 1, (result.returncode, result.stdout, result.stderr)
    assert "FAIL active-pane-silence" in result.stderr, result.stderr
    print("must-fail active-pane control rejected")
print("attention fixtures passed")
PY
assert_eq "$status" 0 'production attention contract'
[ "$FAIL" -eq 0 ]
