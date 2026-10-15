#!/usr/bin/env bash
# Tests for scripts/overseer-run, the wrapper every overseer launch line runs
# under: it hands back its command's own status, and writes that status into
# the oversee state's session record only where the record names the pane it
# runs in. tmux is a stub answering the server pid, and the server's start
# for lib/tmux-server.sh's read of it; workflow-state is the real script over
# a sandbox state directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$TEST_DIR/../scripts" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "overseer_run: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "overseer_run: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "overseer_run: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state"
cat > "$TMP_ROOT/bin/tmux" <<'STUB'
#!/bin/sh
case "$*" in
  *'#{start_time}'*) printf '7000 1790000000\n' ;;
  *) printf '7000\n' ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/tmux"

STATE="$TMP_ROOT/state/workflow-state-oversee.json"
# state PANE [START] — a fleet state whose record names PANE on server 7000,
# bound to the server started at START: by default the stub's own start,
# which every tmux record a launch, a watch start or `oversee register`
# writes carries, and `none` for a record carrying no start.
state() {
  jq -n --arg pane "$1" --arg start "${2:-1790000000}" '{issue_id: "oversee", overseer: ({runtime: "tmux", server: "7000", pane: $pane,
    window: "@1", generation: 1, launch_line: "claude"} + (if $start == "none" then {} else {server_start: ($start | tonumber)} end))}' > "$STATE"
}
exit_of() { jq -r '.overseer.exit.status // "none"' "$STATE"; }

# run [TMUX_PANE] -- COMMAND... — the wrapper from the sandbox, in that pane.
run() {
  local pane="$1"
  shift 2
  RC=0
  ERR="$TMP_ROOT/err"
  (cd "$TMP_ROOT" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" ORCH_STATE_DIR="$TMP_ROOT/state" \
    ${pane:+TMUX=fake TMUX_PANE="$pane"} "$BASH" "${RUN_BIN:-$SCRIPTS/overseer-run}" "$@") >"$TMP_ROOT/out" 2>"$ERR" || RC=$?
}

echo "=== overseer-run ==="

while IFS='|' read -r label recorded start pane want_exit want_error; do
  state "$recorded" "$start"
  run "$pane" -- sh -c 'exit 7'
  keys="$(sed -n 's/^overseer-run: \([^=]*\)=.*/\1/p' "$ERR" | paste -sd , -)"
  assert_eq "rc=$RC exit=$(exit_of) keys=$keys" "rc=7 exit=$want_exit keys=$want_error" "$label" "$ERR"
done <<'ROWS'
this server and pane record completion|%9|1790000000|%9|7|
a startless record stays unbound|%9|none|%9|none|start-unrecorded,exit-unrecorded
an earlier server stays unbound|%9|1789996400|%9|none|start-unrecorded,exit-unrecorded
another pane stays unbound|%3||%9|none|start-unrecorded,exit-unrecorded
outside tmux keeps command status|%9|||none|
ROWS

state %9
run %9 -- true
assert_eq "rc=$RC exit=$(exit_of) active=$(jq -r '.overseer | has("harness_pid") or has("harness_start")' "$STATE")" \
  'rc=0 exit=0 active=false' 'completion clears active identity and keeps zero status'
assert_eq "$(jq -r '.overseer.exit.run | [.server,.server_start,.pane,.generation] | @tsv' "$STATE")" \
  $'7000\t1790000000\t%9\t1' 'completion retains the server, pane and generation binding'
run %9 --
assert_eq "rc=$RC" "rc=2" "no command is a usage error"

state %9
jq '.overseer.exit = {status: 9}' "$STATE" > "$STATE.next"
mv -- "$STATE.next" "$STATE"
run %9 -- "$BASH" -c '
  jq -e --arg pid "$$" ".overseer | .harness_pid == \$pid and (.harness_start | length > 0) and .exit == null" "$1" >/dev/null
' harness "$STATE"
assert_eq "rc=$RC exit=$(exit_of)" "rc=0 exit=0" 'COMMAND sees its own exec PID and start with the old exit removed' "$ERR"

# The child reaches its binding wait before the launcher replaces OL_PRIOR.
# A sleep fixture acknowledges that progress, then waits for the writer.
mkdir -p "$TMP_ROOT/wait-bin"
mkfifo "$TMP_ROOT/release"
cat > "$TMP_ROOT/wait-bin/sleep" <<STUB
#!/bin/sh
: > "$TMP_ROOT/waiting"
read -r release < "$TMP_ROOT/release"
STUB
chmod +x "$TMP_ROOT/wait-bin/sleep"
state %3
(
  PATH="$TMP_ROOT/wait-bin:$PATH" run %9 -- "$BASH" -c 'jq -e --arg pid "$$" ".overseer.harness_pid == \$pid" "$1" >/dev/null' harness "$STATE"
  printf '%s\n' "$RC" > "$TMP_ROOT/launch-rc"
) &
launch_pid=$!
if await_marker "$TMP_ROOT/waiting"; then
  assert_eq "$(jq -r '.overseer.pane' "$STATE")" '%3' 'binding wait acknowledges before record replacement'
  state %9
  printf 'release\n' > "$TMP_ROOT/release"
else
  fail 'child reached binding wait'
  kill "$launch_pid" 2>/dev/null || true
fi
wait "$launch_pid" || true
assert_eq "$(cat "$TMP_ROOT/launch-rc")|$(exit_of)" '0|0' 'replacement retains the executed child identity through completion' "$ERR"

# Record failure never prevents COMMAND, including the binding deadline.
for record in broken missing; do
  if [[ "$record" == broken ]]; then printf 'not json' > "$STATE"
  else rm -f -- "${STATE:?}"; fi
  run %9 -- sh -c 'printf command-started; exit 5'
  assert_eq "$RC|$(cat "$TMP_ROOT/out")" '5|command-started' "$record record keeps command output and status" "$ERR"
  assert_eq "$(sed -n 's/^overseer-run: \([^=]*\)=.*/\1/p' "$ERR" | paste -sd , -)" \
    'start-unrecorded,exit-unrecorded' "$record record reports unavailable start and completion"
done

# The current identity changes during COMMAND: its old exit writer must refuse.
while IFS='|' read -r field value; do
  state %9
  run %9 -- sh -c 'jq --arg field "$2" --arg value "$3" ".overseer[\$field] = \$value" "$1" > "$1.next" && mv -- "$1.next" "$1"; exit 6' harness "$STATE" "$field" "$value"
  assert_eq "$RC|$(exit_of)|$(jq -r --arg field "$field" '.overseer[$field]' "$STATE")" \
    "6|none|$value" "old completion cannot overwrite changed $field" "$ERR"
done <<'ROWS'
harness_pid|999
harness_start|later
generation|later
server|other
server_start|other
pane|%3
ROWS

# A writable read with a refused atomic update still reaches COMMAND.
REFUSED="$(mutant_scripts refused workflow-state)" || exit 1
mutate_file "$REFUSED/workflow-state" '    update)    shift; cmd_update "$@" ;;' \
  '    update)    printf "fixture-write-refused\n" >&2; exit 1 ;;'
state %9
RUN_BIN="$REFUSED/overseer-run" run %9 -- sh -c 'printf command-started; exit 5'
assert_eq "$RC|$(cat "$TMP_ROOT/out")|$(exit_of)" '5|command-started|none' 'failed atomic start write keeps COMMAND and its status' "$ERR"

# A real pseudo-terminal supplies input only after COMMAND acknowledges stdin.
state %9
TTY_RC=0
python3 - "$BASH" "$SCRIPTS/overseer-run" "$TMP_ROOT" "$PATH" "$GIT_CEILING_DIRECTORIES" <<'PYTTY' > "$TMP_ROOT/tty" || TTY_RC=$?
import os, pty, select, signal, sys, time
shell, wrapper, root, path, ceiling = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    env = dict(HOME=root, PATH=root + "/bin:" + path, ORCH_STATE_DIR=root + "/state", TMUX="fake", TMUX_PANE="%9", GIT_CEILING_DIRECTORIES=ceiling)
    os.execve(shell, [shell, wrapper, "sh", "-c", 'test -t 0 || exit 8; printf "input-ready\n"; read -r text; printf "input=%s\n" "$text"; exit 7'], env)
data, sent, status = b"", False, None
deadline = time.monotonic() + 15
try:
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.05)[0]:
            try: chunk = os.read(fd, 4096)
            except OSError: chunk = b""
            data += chunk
        if b"input-ready" in data and not sent:
            os.write(fd, b"terminal-value\n")
            sent = True
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            pid = None
            break
    else:
        raise RuntimeError("terminal input deadline")
    assert os.waitstatus_to_exitcode(status) == 7, (status, data)
    assert b"input=terminal-value" in data, data
    print("terminal-input=kept status=7")
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(fd)
PYTTY
assert_eq "$TTY_RC|$(cat "$TMP_ROOT/tty")|$(exit_of)" '0|terminal-input=kept status=7|7' 'foreground exec retains terminal input and COMMAND status'

# Start binding is tested by the same identity assertion in a disposable copy.
CONTROL="$(mutant_scripts identity-control lib/overseer-launch.sh)" || exit 1
mutate_file "$CONTROL/lib/overseer-launch.sh" '.harness_pid = $run.harness_pid' '.harness_pid = "999"'
state %9
RUN_BIN="$CONTROL/overseer-run" run %9 -- "$BASH" -c 'jq -e --arg pid "$$" ".overseer.harness_pid == \$pid" "$1" >/dev/null' harness "$STATE"
assert_eq "$RC" '1' 'control: a different recorded PID fails the COMMAND identity assertion'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
