"""Exercise a runtime wrapper with the same stderr lifetime as a timed-out call."""

import os
from pathlib import Path
import platform
import select
import shutil
import signal
import subprocess
import sys
import time

# Orch's `ready` bound under AGENT_RUNTIME_TMUX_VERIFY_SECS=2, well inside
# the fetch's six-second budget.
CALLER_SECONDS = 2


def read_builder(fd):
    if not select.select([fd], [], [], 10)[0]:
        raise TimeoutError("waiting for the fake build to start or finish")
    return os.read(fd, 1)


wrapper, key_lib, scratch = map(Path, sys.argv[1:])
key = subprocess.check_output(
    [shutil.which("bash"), "-euc", 'source "$1"; agent_runtime_key "$2"', "--",
     key_lib, wrapper.parent.parent / "runtime"],
    text=True, timeout=10,
).strip()
cache = scratch / "cache-timeout"
gate_bin = scratch / "gate-bin"
gate_bin.mkdir()
cargo = gate_bin / "cargo"
cargo.write_text("""#!/usr/bin/env bash
set -eu
printf B >&"$BUILD_STARTED"
read -r release <&"$BUILD_RELEASE" || :
printf 'fake cargo: resuming build\n' >&2
exec "$SUITE_CARGO" "$@"
""")
cargo.chmod(0o755)
# Stall the listing past the caller's bound, so setup can start in time
# only if the fetch does not hold it back.
listing_started = scratch / "listing-started"
gh = gate_bin / "gh"
gh.write_text("""#!/bin/sh
: >"$LISTING_STARTED"
exec sleep 30
""")
gh.chmod(0o755)
ready, started = os.pipe()
released, release = os.pipe()
os.environ.update(
    AGENT_RUNTIME_CACHE=str(cache), SUITE_CARGO=shutil.which("cargo"),
    PATH=f"{gate_bin}{os.pathsep}{os.environ['PATH']}",
    BUILD_STARTED=str(started), BUILD_RELEASE=str(released),
    LISTING_STARTED=str(listing_started),
)
first_line = b""
deadline = time.monotonic() + CALLER_SECONDS
with subprocess.Popen(
    [wrapper, "version"], stderr=subprocess.PIPE, stdout=subprocess.DEVNULL,
    stdin=subprocess.DEVNULL, pass_fds=(started, released), start_new_session=True,
) as caller:
    os.close(started)
    os.close(released)
    try:
        err = caller.stderr.fileno()
        while b"\n" not in first_line:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([err], [], [], left)[0]:
                break
            chunk = os.read(err, 4096)
            if not chunk:
                break
            first_line += chunk
        try:
            caller.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass
        else:
            sys.exit("wrapper exited before the caller's deadline")
    finally:
        # Like Slack's timeout cleanup, signal the group while the leader's
        # unreaped PID still owns its identity.
        if caller.returncode is None:
            try:
                os.killpg(caller.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        caller.wait(timeout=10)
        caller.stderr.close()
    # Setup starts only once the stalled listing gives up, after the caller.
    try:
        if read_builder(ready) != b"B":
            sys.exit("setup ended without reaching the fake build")
    finally:
        os.close(release)
        # The started pipe closes when all descendants leave. It has no
        # reader for the wrapper's stderr and cannot keep that pipe alive.
        while read_builder(ready):
            pass
        os.close(ready)

name = wrapper.name
expected_line = f"{name}: setup-building key={key} run={wrapper.parent / 'setup'}"
if first_line.split(b"\n", 1)[0].decode(errors="replace") != expected_line:
    sys.exit(f"stderr did not open with {expected_line!r} within the caller's bound: {first_line!r}")
expected = cache / "bin" / f"{name}-{key}"
if caller.returncode != -signal.SIGKILL:
    sys.exit("wrapper did not receive the timeout signal")
if platform.system() == "Linux" and platform.machine() == "x86_64" and all(
    shutil.which(tool) for tool in ("jq", "timeout", "unzip")
) and not listing_started.is_file():
    sys.exit("wrapper did not attempt the stalled listing")
if not expected.is_file() or not os.access(expected, os.X_OK):
    sys.exit(f"build did not place {expected}")

# The next call answers from the keyed binary within the same bound: no
# fetch reaches the stalled listing, and the gated cargo, whose fd is
# closed, would fail.
listing_started.unlink(missing_ok=True)
nxt = subprocess.run(
    [wrapper, "version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, timeout=CALLER_SECONDS,
)
if nxt.returncode != 0 or listing_started.exists():
    sys.exit(f"the next call did not answer from {expected}: rc={nxt.returncode} stderr={nxt.stderr!r}")
