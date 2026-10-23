#!/usr/bin/env bash
# bash-runtime: 3.2
# The validation timeout sends TERM. Its report must name queued suites.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'run-all-unstarted: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'run-all-unstarted: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'run-all-unstarted: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
if python3 - "$TEST_DIR" "$TMP_ROOT" "$BASH" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

source, root, bash = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
for phase, marker in (
    ("loading", 'source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"'),
    ("discovery", "PROFILE_SELECTED=0"),
    ("ready", "printf 'selected suite=%s\\n' \"${SUITES[@]}\""),
    ("running", None),
):
  for variant in ("normal", "missing-report"):
    battery = root / phase / variant / "orch" / "tests"
    (battery / "lib").mkdir(parents=True)
    (battery.parent / "scripts" / "lib").mkdir(parents=True)
    github = battery.parent.parent / "github" / "scripts" / "lib"
    github.mkdir(parents=True)
    shutil.copy(source / "lib" / "git-env.sh", battery / "lib")
    shutil.copy(source / "lib" / "suite-process.sh", battery / "lib")
    shutil.copy(source.parent / "scripts" / "lib" / "lane-state.sh", battery.parent / "scripts" / "lib")
    shutil.copy(source.parent.parent / "github" / "scripts" / "lib" / "group-leader.sh", github)
    text = (source / "run-all.sh").read_text()
    if marker:
        assert text.count(marker) == 1
        text = text.replace(marker, 'printf ready > "$ACK"\nread -r line < "$FIFO"\n' + marker)
    if variant == "missing-report":
        needle = "    printf 'unstarted suite=%s\\n' \"$name\""
        assert text.count(needle) == 1
        text = text.replace(needle, "    :")
    runner = battery / "run-all.sh"
    runner.write_text(text)
    ack = battery / "ready"
    (battery / "a-block.sh").write_text('test -z "${RUN_ALL_PENDING_SUITES+x}" || exit 1\nprintf ready > "$ACK"\nread -r line < "$FIFO"\n')
    (battery / "z-wait.sh").write_text('echo "pass: 1   fail: 0"\n')
    fifo = battery / "hold"
    os.mkfifo(fifo)
    binary = battery / "bin"
    binary.mkdir()
    (binary / "nproc").write_text('#!/bin/sh\necho 1\n')
    (binary / "nproc").chmod(0o755)
    caller_plan = [str(battery / "a-block.sh"), str(battery / "z-wait.sh"), "future/tests/later.sh"]
    env = {"PATH": str(binary) + os.pathsep + os.environ["PATH"], "HOME": os.environ["HOME"],
           "ACK": str(ack), "FIFO": str(fifo), "RUN_ALL_PENDING_SUITES": "\n".join(caller_plan)}
    process = subprocess.Popen([bash, str(runner)], env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        deadline = time.monotonic() + 20
        while not ack.exists():
            assert process.poll() is None, "runner ended before the suite acknowledgement"
            assert time.monotonic() < deadline, "suite acknowledgement deadline"
            time.sleep(0.01)
        os.killpg(process.pid, signal.SIGTERM)
        # dev-validate-run's teardown sends KILL after the job-unit grace.
        grace_text = (source.parent / "scripts/lib/job-unit.sh").read_text()
        grace = int(next(line.split("=", 1)[1] for line in grace_text.splitlines()
                         if line.startswith("JOB_UNIT_KILL_GRACE=")))
        output, _ = process.communicate(timeout=grace)
        assert process.returncode == 143, output
        selected = [line for line in output.splitlines() if line.startswith("selected suite=")]
        assert selected == (["selected suite=a-block", "selected suite=z-wait"] if phase == "running" else []), output
        unstarted = [line for line in output.splitlines() if line.startswith("unstarted suite=")]
        names = caller_plan if phase in ("loading", "discovery") else (
            ["a-block", "z-wait", "future/tests/later.sh"] if phase == "ready" else
            ["z-wait", "future/tests/later.sh"])
        contract = ["unstarted suite=" + name for name in names]
        expected = contract if variant == "normal" else []
        assert unstarted == expected, output
        assert (unstarted == contract) == (variant == "normal"), output
        print(f"pass: cancellation {phase} {variant}")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
PY
then pass 'TERM reports queued suites and the missing-report control rejects that contract'
else fail 'TERM reports queued suites and the missing-report control rejects that contract'
fi
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
