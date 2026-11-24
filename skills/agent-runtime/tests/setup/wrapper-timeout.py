"""Exercise a runtime wrapper with the same stderr lifetime as a timed-out call."""

import os
from pathlib import Path
import select
import shutil
import subprocess
import sys


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
ready, started = os.pipe()
released, release = os.pipe()
os.environ.update(
    AGENT_RUNTIME_CACHE=str(cache), SUITE_CARGO=shutil.which("cargo"),
    PATH=f"{gate_bin}{os.pathsep}{os.environ['PATH']}",
    BUILD_STARTED=str(started), BUILD_RELEASE=str(released),
)
with subprocess.Popen(
    [wrapper, "version"], stderr=subprocess.PIPE, stdout=subprocess.DEVNULL,
    stdin=subprocess.DEVNULL, pass_fds=(started, released),
) as caller:
    os.close(started)
    os.close(released)
    try:
        if read_builder(ready) != b"B":
            sys.exit("wrapper exited before reaching the fake build")
        try:
            caller.wait(timeout=0)
        except subprocess.TimeoutExpired:
            pass
        else:
            sys.exit("wrapper exited before the caller's deadline")
    finally:
        caller.kill()
        caller.wait(timeout=10)
        caller.stderr.close()
        os.close(release)
        # The started pipe closes when all descendants leave. It has no
        # reader for the wrapper's stderr and cannot keep that pipe alive.
        while read_builder(ready):
            pass
        os.close(ready)

expected = cache / "bin" / f"{wrapper.name}-{key}"
if not expected.is_file() or not os.access(expected, os.X_OK):
    sys.exit(f"build did not place {expected}")
