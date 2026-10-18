#!/usr/bin/env bash
# Direct launch coverage stays local; production caller coverage stays in CI.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

mkdir -p "$R/skills/orch/scripts" "$R/skills/orch/tests/lib" "$R/tools/tests"
printf '#!/usr/bin/env bash\nlaunch_status=0\n' > "$R/skills/orch/scripts/open-terminal"
printf 'source "$PWD/skills/orch/scripts/open-terminal"\n' > "$R/skills/orch/scripts/dispatcher"
printf 'source "$PWD/skills/orch/scripts/open-terminal"\n' > "$R/skills/orch/tests/lib/launch.sh"
for row in 'direct|scripts/open-terminal' 'helper|tests/lib/launch.sh' 'indirect|scripts/dispatcher'; do
  IFS='|' read -r name input <<<"$row"
  printf 'source "$PWD/skills/orch/%s"\nprintf "%s\\n" >> "$SUITE_LOG"\nexit "$launch_status"\n' "$input" "$name" > "$R/skills/orch/tests/$name.sh"
done
printf 'printf "named\\n" >> "$SUITE_LOG"\n' > "$R/skills/orch/tests/open-terminal.test.sh"
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm launch
BASE="$(git -C "$R" rev-parse HEAD)"
SUITE_LOG="$TMP/suites"

launch_selection() { # SCOPED STATUS GUARD
  printf '#!/usr/bin/env bash\nlaunch_status=%s\n# changed\n' "$2" > "$R/skills/orch/scripts/open-terminal"
  : > "$SUITE_LOG"
  RC=0
  OUT="$(cd "$R" && DEV_VALIDATE_SCOPED="$1" SUITE_LOG="$SUITE_LOG" "$3" --selection --range "$BASE" 2>&1)" || RC=$?
  SELECTED="$(sort "$SUITE_LOG" | tr '\n' ' ')"
}
for status in 0 1; do
  launch_selection true "$status" "$GUARD"
  [ "$RC" -eq "$status" ] && [ "$SELECTED" = 'direct helper named ' ] \
    && ok "open-terminal scoped fixture returns status $status with direct, named and helper coverage" \
    || bad "open-terminal scoped fixture returns status $status with direct, named and helper coverage" "rc=$RC selected=$SELECTED out=$OUT"
done

# Restore main's reach without removing any file text or input references.
# The same launch diff then executes every suite in this fixture's orch tree.
if mutant_guard '/^  if \[ "\$scoped_only" -eq 1 \] \&\& \[ "\${3:-reader}" != changed \]; then$/,/^  fi$/d'; then
  launch_selection true 0 "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$SELECTED" = 'direct helper indirect named ' ] \
    && ok 'control: main reach selects the full launch fixture and breaks the direct-only assertion' \
    || bad 'control: main reach selects the full launch fixture and breaks the direct-only assertion' "rc=$RC selected=$SELECTED out=$OUT"
else
  bad 'control changes the scoped reach'
fi

# Normal range selection still includes the production caller. This is the
# mapper CI already owns, not the local scoped branch above.
printf '#!/usr/bin/env bash\nlaunch_status=0\n# changed\n' > "$R/skills/orch/scripts/open-terminal"
: > "$SUITE_LOG"
RC=0
OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$GUARD" --range "$BASE" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && [ "$(sort "$SUITE_LOG" | tr '\n' ' ')" = 'direct helper indirect named ' ] \
  && ok 'normal range retains full production caller coverage' \
  || bad 'normal range retains full production caller coverage' "rc=$RC out=$OUT"

# A real cancellation must also name suites in batteries not yet entered.
# The first selected suite acknowledges its start before the parent sends TERM.
printf 'source "$PWD/skills/orch/scripts/open-terminal"\nprintf ready > "$ACK"\nread -r line < "$FIFO"\n' > "$R/skills/orch/tests/direct.sh"
printf '# Inputs: skills/orch/scripts/open-terminal\nprintf "later\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/later.sh"
mkdir -p "$R/skills/orch/scripts/lib" "$R/skills/github/scripts/lib" "$TMP/serial-bin"
cp "$REPO/skills/orch/tests/run-all.sh" "$R/skills/orch/tests/run-all.sh"
cp "$REPO/skills/orch/tests/lib/git-env.sh" "$R/skills/orch/tests/lib/git-env.sh"
cp "$REPO/skills/orch/scripts/lib/lane-state.sh" "$R/skills/orch/scripts/lib/lane-state.sh"
cp "$REPO/skills/github/scripts/lib/group-leader.sh" "$R/skills/github/scripts/lib/group-leader.sh"
printf '#!/bin/sh\necho 1\n' > "$TMP/serial-bin/nproc"
chmod +x "$TMP/serial-bin/nproc"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm cancellation
BASE="$(git -C "$R" rev-parse HEAD)"
printf '# changed\n' >> "$R/skills/orch/scripts/open-terminal"
if python3 - "$R" "$GUARD" "$BASE" "$TMP" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

repo, guard, base, scratch = sys.argv[1:]
ack, fifo = Path(scratch) / "ready", Path(scratch) / "hold"
os.mkfifo(fifo)
env = dict(os.environ, DEV_VALIDATE_SCOPED="true", ACK=str(ack), FIFO=str(fifo),
           PATH=str(Path(scratch) / "serial-bin") + os.pathsep + os.environ["PATH"])
process = subprocess.Popen([guard, "--selection", "--range", base], cwd=repo, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           start_new_session=True)
try:
    deadline = time.monotonic() + 20
    while not ack.exists():
        if process.poll() is not None:
            raise AssertionError("guard ended before the suite acknowledgement: " + process.communicate()[0])
        assert time.monotonic() < deadline, "suite acknowledgement deadline"
        time.sleep(0.01)
    os.killpg(process.pid, signal.SIGTERM)
    output, _ = process.communicate(timeout=20)
    assert process.returncode == 143, output
    selected = [line for line in output.splitlines() if line.startswith("guard-note: selected-suite=")]
    assert "guard-note: selected-suite=tools/tests/later.sh" in selected, output
    unstarted = [line for line in output.splitlines() if line.startswith("unstarted suite=")]
    assert unstarted == ["unstarted suite=helper", "unstarted suite=open-terminal.test",
                         "unstarted suite=tools/tests/later.sh"], output
    assert not any(line.startswith("guard-note: unstarted-suite=") for line in output.splitlines()), output
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
PY
then ok 'guard cancellation reports unstarted suites in the current and later batteries'
else bad 'guard cancellation reports unstarted suites in the current and later batteries'
fi
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
