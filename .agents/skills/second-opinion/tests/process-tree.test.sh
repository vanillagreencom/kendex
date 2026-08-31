#!/usr/bin/env bash
# Process-tree ownership: who the run may signal, and what dies with it. Split
# from detached-run.test.sh at the seam between what `wait` REPORTS and what it
# may TERMINATE. Every case builds a real tree — a CLI with a child of its own
# — and asks what survives, because every defect this guards was invisible to a
# suite that watched only exit codes.
#
# A GREEN LINUX RUN IS NOT EVIDENCE FOR THIS FILE. Process groups, signal
# delivery and the availability of `timeout` differ between Linux and macOS,
# and cases here have passed on one while failing on the other. This is the
# suite to run on a mac before believing a change to the teardown paths;
# everything else in the skill is portable enough that Linux answers for it.
#
# Cases that need a facility the host may not have SKIP OUT LOUD, naming what
# is missing. A silent pass would be worse than a failure: it would report
# green for a platform where the case never ran.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
STRAYS=()
cleanup() {
  local p
  for p in ${STRAYS[@]+"${STRAYS[@]}"}; do
    [[ -z "$p" ]] || kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'PASS: %s\n' "$1"; }
assert_rc() { [[ "$1" == "$2" ]] || fail "$3 (expected $2, got $1)"; ok "$3"; }
assert_contains() { grep -Fq "$2" "$1" || fail "$3: $(sed -n '1,40p' "$1")"; ok "$3"; }
gone() { ! kill -0 "$1" 2>/dev/null; }
await_gone() { # PID — up to 10s
  local _
  for _ in $(seq 1 200); do gone "$1" && return 0; sleep 0.05; done
  return 1
}
await_file() { # PATH — up to 10s
  local _
  for _ in $(seq 1 200); do [[ -s "$1" ]] && return 0; sleep 0.05; done
  return 1
}
# A PID READ FROM A FIXTURE MUST BE A PID. A fixture that reaches for a builtin
# its shell does not have — BASHPID under the 3.2 that macOS ships as /bin/bash
# is the one that bit us — writes a blank line instead, and every assertion
# after it then measures nothing while still reporting PASS. Checked where it is
# captured, so the next such builtin fails loudly here rather than passing
# quietly everywhere.
read_pid() { # FILE LABEL -> pid on stdout
  local file="$1" label="$2" pid
  pid="$(cat < "$file" 2>/dev/null || true)"
  [[ -n "$pid" ]] \
    || fail "$label wrote no pid to ${file##*/} — a fixture builtin this shell does not have?"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "$label wrote a non-numeric pid: '$pid'"
  printf '%s' "$pid"
}

mkdir -p "$TMP_ROOT/proj/skills" "$TMP_ROOT/bin" "$TMP_ROOT/psbin" "$TMP_ROOT/work"
git -C "$TMP_ROOT/proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"
RUNTIME="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion-runtime"

cat > "$TMP_ROOT/psbin/ps" <<'SH'
#!/usr/bin/env bash
# Ancestry only; the runtime's `-o pgid=,lstart=` identity check must reach the
# real ps or it reads as "cannot verify" and stops being exercised at all.
args=("$@")
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in
  ppid=) printf '1\n' ;;
  comm=) printf 'bash\n' ;;
  *) for real in /bin/ps /usr/bin/ps; do
       [[ -x "$real" ]] && exec "$real" "${args[@]}"
     done
     exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/psbin/ps"

# A CLI that starts a child of its own and then blocks. The child is the whole
# point: `timeout --foreground` reaps the CLI and leaves this one running, and
# a survivor holding the captured pipe open is what hangs the caller.
cat > "$TMP_ROOT/bin/treeish-codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
sleep 600 &
printf '%s\n' "$!" > "$CLI_KID_FILE"
printf 'started\n' > "$CLI_READY_FILE"
sleep 600
printf 'never\n'
SH
chmod +x "$TMP_ROOT/bin/treeish-codex"
cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'answer from codex\n'
SH
chmod +x "$TMP_ROOT/bin/codex"
# A CLI whose LEADER exits while its child runs on holding stdout. The child
# dies on TERM, so a teardown that reaches the group ends this in seconds while
# one that only probes the leader leaves the child holding the pipe.
#
# The parent records the child with `$!` rather than the child recording
# itself: BASHPID does not exist in bash 3.2, which is what macOS ships as
# /bin/bash, so a self-recording child writes a blank line there and the case
# silently stops testing anything on the one platform it is written for.
cat > "$TMP_ROOT/bin/orphan-codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
sleep 120 &
printf '%s\n' "$!" > "$CLI_KID_FILE"
printf 'started\n' > "$CLI_READY_FILE"
sleep 1
printf 'leader done\n'
SH
chmod +x "$TMP_ROOT/bin/orphan-codex"

unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID
export PATH="$TMP_ROOT/bin:$TMP_ROOT/psbin:$PATH"
export SECOND_OPINION_CURRENT_MODEL=none SECOND_OPINION_TARGET=codex

git -C "$TMP_ROOT/work" init -q
git -C "$TMP_ROOT/work" config user.email test@example.com
git -C "$TMP_ROOT/work" config user.name test
printf 'scope\n' > "$TMP_ROOT/work/file.txt"
git -C "$TMP_ROOT/work" add file.txt
git -C "$TMP_ROOT/work" -c commit.gpgsign=false commit -q -m init

echo "=== a per-CLI timeout takes the CLI's children with it ==="
# The caller CAPTURES stdout, so a surviving grandchild holds that pipe open.
# This measures the caller's wall time, not just the status: the defect was a
# 2-second timeout returning after the child's full 600.
#
# NEEDS A TIMEOUT BINARY, and stock macOS ships neither `timeout` nor
# `gtimeout`. Without one the runtime says so and runs the CLI unbounded, so
# this case would measure the CLI's own lifetime and report the teardown
# defect it is named for — a false accusation that costs a debugging cycle on
# the platform hardest to reach. The next case covers the same teardown with
# no binary at all, so skipping here loses nothing but the timeout path.
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  printf 'SKIP: per-CLI timeout case needs timeout or gtimeout; this host has neither\n'
else
: > "$TMP_ROOT/tree.ready"; : > "$TMP_ROOT/tree.kid"
start=$(date +%s)
rc=0
captured=$(CLI_READY_FILE="$TMP_ROOT/tree.ready" CLI_KID_FILE="$TMP_ROOT/tree.kid" \
  SECOND_OPINION_CODEX_CMD=treeish-codex SECOND_OPINION_TIMEOUT=2 \
  "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" \
  2> "$TMP_ROOT/tree.stderr") || rc=$?
elapsed=$(( $(date +%s) - start ))
kid="$(read_pid "$TMP_ROOT/tree.kid" "the timed-out CLI")"
STRAYS+=("$kid")
[[ $elapsed -lt 60 ]] \
  || fail "the caller waited ${elapsed}s for a 2s timeout — a survivor held the pipe open"
ok "the capturing caller returns promptly (${elapsed}s) after a 2s timeout"
await_gone "$kid" || fail "the CLI's child $kid survived the timeout"
ok "the timeout took the CLI's child with it"
[[ $rc -ne 0 ]] || fail "a timed-out CLI must not read as success"
ok "the timed-out run exits non-zero (rc=$rc)"
fi

echo "=== the CLI's leader exiting first does not end the teardown ==="
# A leader that exits while its child runs on is the ordinary shape of a CLI
# that forks, and a teardown probing the LEADER reads that as "the tree is
# gone". It is not: the child still holds the captured pipe, which is the same
# hang the per-CLI timeout above exists to prevent, one level down.
: > "$TMP_ROOT/orphan.ready"; : > "$TMP_ROOT/orphan.kid"
start=$(date +%s)
rc=0
captured=$(CLI_READY_FILE="$TMP_ROOT/orphan.ready" CLI_KID_FILE="$TMP_ROOT/orphan.kid" \
  SECOND_OPINION_CODEX_CMD=orphan-codex SECOND_OPINION_TIMEOUT=600 \
  "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" \
  2> "$TMP_ROOT/orphan.stderr") || rc=$?
elapsed=$(( $(date +%s) - start ))
orphan_kid="$(read_pid "$TMP_ROOT/orphan.kid" "the orphan CLI")"
STRAYS+=("$orphan_kid")
[[ $elapsed -lt 60 ]] \
  || fail "the capture waited ${elapsed}s after the CLI leader exited — the child held the pipe"
ok "the capture returns (${elapsed}s) once the leader exits"
await_gone "$orphan_kid" \
  || fail "the CLI's surviving child $orphan_kid outlived the run"
ok "the surviving child is torn down with the group"

echo "=== control: the same CLI against a teardown that probes the leader ==="
# Without this the case above cannot say WHICH probe ended the run. It drives
# `group-run` directly — the function the mutation changes — because the
# detached path would not distinguish the two: there the worker leads the group
# AND outlives it, so probing the leader and probing the group agree.
LEADER_MUTANT="$TMP_ROOT/leader-probe-runtime"
sed 's|^process_group_alive() { kill -0 -- "-\$1" 2>/dev/null; }$|process_group_alive() { kill -0 "$1" 2>/dev/null; }|' \
  "$RUNTIME" > "$LEADER_MUTANT"
chmod +x "$LEADER_MUTANT"
cmp -s "$RUNTIME" "$LEADER_MUTANT" && fail "the leader-probe control mutated nothing"
grep -q 'process_group_alive() { kill -0 "$1" 2>/dev/null; }' "$LEADER_MUTANT" \
  || fail "the leader-probe control did not replace the group probe"
ok "the leader-probe control probes the leader instead of the group"
# capture_group_run <runtime> <label>: capture group-run's stdout under a hard
# bound and report 124 if the capture was still held when the bound expired.
# The capture has to be a COMMAND SUBSTITUTION — a survivor holding that pipe
# open is the failure under test, and a file redirect would never show it.
#
# The bound is polled rather than delegated to `timeout`, which stock macOS
# does not ship: borrowing the binary here would make this control fail with
# "command not found" on the one platform it most needs to run.
capture_group_run() { # RUNTIME LABEL -> "rc", 124 when the capture outran the bound
  local runtime="$1" label="$2" rc=0 end job stray
  : > "$TMP_ROOT/$label.ready"; : > "$TMP_ROOT/$label.kid"
  CLI_READY_FILE="$TMP_ROOT/$label.ready" CLI_KID_FILE="$TMP_ROOT/$label.kid" \
    bash -c 'out=$("$1" group-run "$2" orphan-codex < /dev/null); printf %s "$out" > "$3"' \
    _ "$runtime" "$TMP_ROOT/$label.stderr" "$TMP_ROOT/$label.out" &
  job=$!
  end=$(($(date +%s) + 8))
  while kill -0 "$job" 2>/dev/null; do
    if [[ $(date +%s) -ge $end ]]; then
      kill -KILL "$job" 2>/dev/null || true
      wait "$job" 2>/dev/null || true
      # Release the tree the bound left behind: killing the capture does not
      # reach the CLI's child, and it would otherwise hold on for its own life.
      stray="$(cat < "$TMP_ROOT/$label.kid" 2>/dev/null || true)"
      [[ -z "$stray" ]] || kill -KILL "$stray" 2>/dev/null || true
      printf '124'
      return 0
    fi
    sleep 0.2
  done
  wait "$job" || rc=$?
  printf '%s' "$rc"
}
real_rc="$(capture_group_run "$RUNTIME" ctl-real)"
real_kid="$(cat < "$TMP_ROOT/ctl-real.kid" 2>/dev/null || true)"
STRAYS+=("$real_kid")
[[ "$real_rc" != 124 ]] || fail "the shipped runtime held the capture open"
ok "the shipped runtime releases the capture (rc=$real_rc)"
mutant_rc="$(capture_group_run "$LEADER_MUTANT" ctl-mutant)"
mutant_kid="$(read_pid "$TMP_ROOT/ctl-mutant.kid" "the leader-probe control CLI")"
STRAYS+=("$mutant_kid")
[[ "$mutant_rc" == 124 ]] \
  || fail "the leader-probe control released the capture too (rc=$mutant_rc) — the case above proves nothing"
ok "the leader-probe control holds the capture open, so the group probe is what releases it"
kill -KILL "$mutant_kid" 2>/dev/null || true

echo "=== a signal to second-opinion still reaches the CLI ==="
# The other half, and the reason the wrapper cannot simply drop --foreground:
# the caller owns the lane's lifetime. Needs a session to signal, so it is
# skipped where setsid is absent rather than silently proving nothing.
if command -v setsid >/dev/null 2>&1; then
  : > "$TMP_ROOT/sig.ready"; : > "$TMP_ROOT/sig.kid"
  CLI_READY_FILE="$TMP_ROOT/sig.ready" CLI_KID_FILE="$TMP_ROOT/sig.kid" \
    SECOND_OPINION_CODEX_CMD=treeish-codex SECOND_OPINION_TIMEOUT=600 \
    setsid "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" \
    > /dev/null 2> "$TMP_ROOT/sig.stderr" &
  session=$!
  await_file "$TMP_ROOT/sig.ready" || fail "the CLI never started under setsid"
  sig_kid="$(read_pid "$TMP_ROOT/sig.kid" "the signalled CLI")"
  STRAYS+=("$sig_kid")
  kill -TERM -- "-$session" 2>/dev/null || true
  wait "$session" 2>/dev/null || true
  await_gone "$sig_kid" \
    || fail "a group signal to second-opinion left the CLI's child $sig_kid running"
  ok "a group signal to second-opinion tears down the whole CLI tree"
else
  printf 'SKIP: group-signal case needs setsid to build a session to signal\n'
fi

echo "=== the detached deadline takes the CLI tree with it ==="
# The path stock macOS takes, where the worker's own group is the only handle
# on the tree. `wait` reports 124 and deletes the runtime state, so a tree it
# does not stop here is one nothing will ever stop.
: > "$TMP_ROOT/dl.ready"; : > "$TMP_ROOT/dl.kid"
mkdir "$TMP_ROOT/dl-runtime"
CLI_READY_FILE="$TMP_ROOT/dl.ready" CLI_KID_FILE="$TMP_ROOT/dl.kid" \
  SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_LAUNCH_SOURCE=detected \
  SECOND_OPINION_LAUNCH_IN_CALLER_ENV=false SECOND_OPINION_LAUNCH_SESSION_SCOPED=false \
  SECOND_OPINION_CODEX_CMD=treeish-codex \
  "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/dl-answer" "$TMP_ROOT/dl-runtime" \
  6 false 10 quick question --target=codex --cwd "$TMP_ROOT/work" --timeout 600 \
  > "$TMP_ROOT/dl-launch.stdout" 2> "$TMP_ROOT/dl-launch.stderr"
dl_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/dl-launch.stdout")"
dl_pid="$(read_pid "$TMP_ROOT/dl-runtime/pid" "the detached launcher")"
STRAYS+=("$dl_pid")
await_file "$TMP_ROOT/dl.ready" || fail "the detached CLI never started"
dl_kid="$(read_pid "$TMP_ROOT/dl.kid" "the detached CLI")"
STRAYS+=("$dl_kid")
# The worker must be a group leader for the teardown to have anything to aim
# at; assert it rather than assume it, since this is what replaces setsid.
[[ "$(ps -o pgid= -p "$dl_pid" 2>/dev/null | tr -d ' ')" == "$dl_pid" ]] \
  || fail "the detached worker does not lead its own process group"
ok "the detached worker leads its own process group without setsid"
rc=0
bash -c "$dl_wait" > "$TMP_ROOT/dl-wait.stdout" 2> "$TMP_ROOT/dl-wait.stderr" || rc=$?
assert_rc "$rc" 124 "the run reaches its deadline"
await_gone "$dl_pid" || fail "the worker $dl_pid survived its own deadline"
ok "the deadline stops the worker"
await_gone "$dl_kid" \
  || fail "the deadline reported 124 and left the CLI's child $dl_kid running"
ok "the deadline takes the CLI tree with it"

echo "=== a signal inside the fork window still stops the child ==="
# Between the fork and the assignment that records its pid there is nothing for
# a handler to act on. The window is microseconds wide, so it is not raced: a
# copy of the runtime blocks there on a FIFO, and the signal is delivered while
# it is blocked. The logic under test — defer, then honour after assignment —
# is the shipped logic; only the width of the window is staged.
widen_fork_window() { # OUT ANCHOR — insert a FIFO block right after the fork
  local out="$1" anchor="$2"
  awk -v anchor="$anchor" '
    { print }
    index($0, anchor) > 0 && !done { print "  cat < \"$WINDOW_FIFO\" > /dev/null"; done = 1 }
  ' "$RUNTIME" > "$out"
  chmod +x "$out"
  grep -q 'WINDOW_FIFO' "$out" || fail "the window widener matched nothing in $out"
}
# run_in_window <runtime> <label>: start group-run so it blocks in the widened
# window, signal it there, release it, and report the exit status.
run_in_window() { # RUNTIME LABEL -> "rc"
  local runtime="$1" label="$2" rc=0 job
  : > "$TMP_ROOT/$label.ready"; : > "$TMP_ROOT/$label.kid"
  mkfifo "$TMP_ROOT/$label.fifo"
  CLI_READY_FILE="$TMP_ROOT/$label.ready" CLI_KID_FILE="$TMP_ROOT/$label.kid" \
    WINDOW_FIFO="$TMP_ROOT/$label.fifo" \
    "$runtime" group-run "$TMP_ROOT/$label.stderr" orphan-codex \
    < /dev/null > /dev/null 2>&1 &
  job=$!
  # The CLI's own ready file proves the fork happened, so the process is now
  # blocked in the window rather than approaching it.
  await_file "$TMP_ROOT/$label.ready" || fail "$label never reached the fork window"
  kill -TERM "$job" 2>/dev/null || true
  printf 'go\n' > "$TMP_ROOT/$label.fifo"
  wait "$job" 2>/dev/null || rc=$?
  printf '%s' "$rc"
}
WINDOW_RUNTIME="$TMP_ROOT/window-runtime"
widen_fork_window "$WINDOW_RUNTIME" '2>"$stderr_file" &'
window_rc="$(run_in_window "$WINDOW_RUNTIME" fw)"
window_kid="$(read_pid "$TMP_ROOT/fw.kid" "the fork-window CLI")"
STRAYS+=("$window_kid")
assert_rc "$window_rc" 143 "a signal in the fork window still ends the run"
await_gone "$window_kid" \
  || fail "a signal in the fork window abandoned the live child $window_kid"
ok "the child forked in that window is still stopped"

echo "=== control: the same window against a handler that exits in it ==="
# The pre-fix shape: exit from the handler instead of recording. With no pid
# assigned yet there is nothing to stop, so the child must survive — which is
# what says the deferral is doing the work above.
EXIT_MUTANT="$TMP_ROOT/exit-in-window-runtime"
sed 's|^  request_cancel() { cancel_rc="\$1"; }$|  request_cancel() { exit "$1"; }|' \
  "$WINDOW_RUNTIME" > "$EXIT_MUTANT"
chmod +x "$EXIT_MUTANT"
cmp -s "$WINDOW_RUNTIME" "$EXIT_MUTANT" && fail "the exit-in-window control mutated nothing"
grep -q 'request_cancel() { exit "$1"; }' "$EXIT_MUTANT" \
  || fail "the exit-in-window control did not replace the deferral"
ok "the exit-in-window control exits from the handler instead of recording"
ctl_window_rc="$(run_in_window "$EXIT_MUTANT" ctlwin)"
ctl_window_kid="$(read_pid "$TMP_ROOT/ctlwin.kid" "the exit-in-window control CLI")"
STRAYS+=("$ctl_window_kid")
if gone "$ctl_window_kid"; then
  fail "the exit-in-window control stopped the child too — the case above proves nothing"
fi
ok "the control abandons the child, so the deferral is what saves it (rc=$ctl_window_rc)"
kill -KILL "$ctl_window_kid" 2>/dev/null || true

echo "=== a launch cancelled before it publishes takes its worker with it ==="
# Between the fork and the last protocol line the worker exists but nothing can
# reach it: the pid, the identity and the wait command are not all out yet. A
# launch that dies there would strand a run nobody can wait on or stop.
#
# STAGED BY BLOCKING THE PUBLISH, not by timing. `worker-id` is pre-created as a
# FIFO, so the launcher blocks writing it with the worker already running —
# provably inside the window. The signal is then delivered and the FIFO drained,
# so the trap runs at a point this case chose rather than one it raced for.
mkdir "$TMP_ROOT/win-runtime"
mkfifo "$TMP_ROOT/win-runtime/worker-id"
: > "$TMP_ROOT/win.ready"; : > "$TMP_ROOT/win.kid"
CLI_READY_FILE="$TMP_ROOT/win.ready" CLI_KID_FILE="$TMP_ROOT/win.kid" \
  SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_LAUNCH_SOURCE=detected \
  SECOND_OPINION_LAUNCH_IN_CALLER_ENV=false SECOND_OPINION_LAUNCH_SESSION_SCOPED=false \
  SECOND_OPINION_CODEX_CMD=treeish-codex \
  "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/win-answer" "$TMP_ROOT/win-runtime" \
  120 false 10 quick question --target=codex --cwd "$TMP_ROOT/work" --timeout 600 \
  > "$TMP_ROOT/win-launch.stdout" 2> "$TMP_ROOT/win-launch.stderr" &
win_launcher=$!
# The pid file is written before worker-id, so its arrival proves the launcher
# is past the fork and blocked on the FIFO.
await_file "$TMP_ROOT/win-runtime/pid" || fail "the launcher never reached the publish window"
win_pid="$(read_pid "$TMP_ROOT/win-runtime/pid" "the publish-window launcher")"
STRAYS+=("$win_pid")
await_file "$TMP_ROOT/win.ready" || fail "the worker never started"
win_kid="$(read_pid "$TMP_ROOT/win.kid" "the publish-window CLI")"
STRAYS+=("$win_kid")
grep -q '^wait:' "$TMP_ROOT/win-launch.stdout" \
  && fail "the launcher published its wait command before the window closed"
ok "the launcher is inside the window: worker running, protocol unpublished"
kill -TERM "$win_launcher" 2>/dev/null || true
# Draining the FIFO lets the blocked write finish; bash then runs the signal it
# has been holding, before any further command.
cat < "$TMP_ROOT/win-runtime/worker-id" > /dev/null 2>&1 || true
win_rc=0
wait "$win_launcher" 2>/dev/null || win_rc=$?
[[ $win_rc -ne 0 ]] || fail "a cancelled launch reported success"
ok "the cancelled launch exits non-zero (rc=$win_rc)"
grep -q '^wait:' "$TMP_ROOT/win-launch.stdout" \
  && fail "a cancelled launch still published a wait command"
ok "no wait command was published for a run that was cancelled"
await_gone "$win_pid" || fail "the cancelled launch left its worker $win_pid running"
ok "the cancelled launch stopped its worker"
[[ -z "$win_kid" ]] || await_gone "$win_kid" \
  || fail "the cancelled launch left the CLI's child $win_kid running"
ok "and the CLI tree under it"
[[ -e "$TMP_ROOT/win-runtime" ]] && fail "the cancelled launch left its runtime state behind"
ok "the cancelled launch removed its runtime directory"

echo "=== and the launcher's own fork window behaves the same way ==="
# The same defect and the same fix one level up, tested separately because
# launch's cleanup does more than group_run's: it must also reclaim the runtime
# directory, and a signal caught before the pid was owned would leave both the
# worker and that state behind.
LAUNCH_WINDOW_RUNTIME="$TMP_ROOT/launch-window-runtime"
widen_fork_window "$LAUNCH_WINDOW_RUNTIME" '< /dev/null > "$log" 2>&1 &'
mkdir "$TMP_ROOT/lw-runtime"
mkfifo "$TMP_ROOT/lw.fifo"
: > "$TMP_ROOT/lw.ready"; : > "$TMP_ROOT/lw.kid"
CLI_READY_FILE="$TMP_ROOT/lw.ready" CLI_KID_FILE="$TMP_ROOT/lw.kid" \
  WINDOW_FIFO="$TMP_ROOT/lw.fifo" \
  SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_LAUNCH_SOURCE=detected \
  SECOND_OPINION_LAUNCH_IN_CALLER_ENV=false SECOND_OPINION_LAUNCH_SESSION_SCOPED=false \
  SECOND_OPINION_CODEX_CMD=treeish-codex \
  "$LAUNCH_WINDOW_RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/lw-answer" \
  "$TMP_ROOT/lw-runtime" 120 false 10 quick question --target=codex \
  --cwd "$TMP_ROOT/work" --timeout 600 \
  > "$TMP_ROOT/lw-launch.stdout" 2> "$TMP_ROOT/lw-launch.stderr" &
lw_launcher=$!
await_file "$TMP_ROOT/lw.ready" || fail "the launcher never reached its fork window"
lw_kid="$(read_pid "$TMP_ROOT/lw.kid" "the launch fork-window CLI")"
STRAYS+=("$lw_kid")
kill -TERM "$lw_launcher" 2>/dev/null || true
printf 'go\n' > "$TMP_ROOT/lw.fifo"
lw_rc=0
wait "$lw_launcher" 2>/dev/null || lw_rc=$?
assert_rc "$lw_rc" 143 "a signal in the launcher's fork window ends the launch"
grep -q '^wait:' "$TMP_ROOT/lw-launch.stdout" \
  && fail "a launch cancelled in its fork window still published a wait command"
ok "no wait command was published"
await_gone "$lw_kid" \
  || fail "the launcher abandoned the CLI child $lw_kid forked in that window"
ok "the worker's whole tree is stopped"
[[ -e "$TMP_ROOT/lw-runtime" ]] && fail "the cancelled launch left its runtime state behind"
ok "and its runtime directory is reclaimed"

echo "=== wait never signals a pid it cannot verify ==="
# A pid is a number, not an identity. Staged directly: an unrelated live
# process whose pid sits in the runtime dir is what a reused pid looks like
# from here.
# The bystander LEADS ITS OWN GROUP, which is the dangerous shape: teardown
# aims at a process group, so a reused pid that leads no group is out of reach
# anyway and would let this case pass without any identity check at all.
BYSTANDER=""
spawn_bystander() { # sets BYSTANDER to a process leading a group of its own
  # Assigns a global and sends the process's output to /dev/null. Printing the
  # pid through a command substitution would hang instead: the background
  # process inherits the substitution's pipe and holds it open — defect A's
  # exact shape, reproduced inside the suite that exists to catch it.
  set -m
  sleep 600 > /dev/null 2>&1 &
  BYSTANDER=$!
  disown %% 2>/dev/null || true
  set +m
}
spawn_bystander
bystander="$BYSTANDER"
STRAYS+=("$bystander")
[[ "$(ps -o pgid= -p "$bystander" 2>/dev/null | tr -d ' ')" == "$bystander" ]] \
  || fail "the bystander is not a group leader — the case would pass vacuously"
ok "the bystander leads its own group, so teardown could reach it"
mkdir "$TMP_ROOT/by-runtime"
printf 'stagedtoken\n' > "$TMP_ROOT/by-runtime/token"
: > "$TMP_ROOT/by-runtime/worker.log"
printf '%s\n' "$bystander" > "$TMP_ROOT/by-runtime/pid"
# Recorded when the real worker started; the bystander cannot match it.
printf '%s Thu Jan  1 00:00:00 1970\n' "$bystander" > "$TMP_ROOT/by-runtime/worker-id"
printf 'kept\n' > "$TMP_ROOT/by-answer"
rc=0
"$RUNTIME" wait "$TMP_ROOT/by-answer" "$TMP_ROOT/by-runtime" \
  "$(($(date +%s) - 1))" stagedtoken 1 \
  > "$TMP_ROOT/by.stdout" 2> "$TMP_ROOT/by.stderr" || rc=$?
assert_rc "$rc" 124 "an elapsed deadline is still terminal"
kill -0 "$bystander" 2>/dev/null \
  || fail "wait KILLED a process it never verified as its own worker"
ok "the unverifiable pid was not signalled"
# Sparing the pid is right, and doing it in silence is not: the wait is about
# to delete the runtime state and return 124, so this line is the only record
# that something may still be running.
assert_contains "$TMP_ROOT/by.stderr" "its processes could not be" \
  "the decline says so on stderr instead of returning quietly"

echo "=== an unverifiable pid does not read as a running worker either ==="
# The same root cause on the read path: believing a live-but-unverified pid
# leaves the wait reporting "still running" for a run that is over, spending
# the whole slice each time until the deadline.
mkdir "$TMP_ROOT/read-runtime"
printf 'stagedtoken\n' > "$TMP_ROOT/read-runtime/token"
: > "$TMP_ROOT/read-runtime/worker.log"
printf '%s\n' "$bystander" > "$TMP_ROOT/read-runtime/pid"
printf '%s Thu Jan  1 00:00:00 1970\n' "$bystander" > "$TMP_ROOT/read-runtime/worker-id"
printf 'kept\n' > "$TMP_ROOT/read-answer"
start=$(date +%s)
rc=0
"$RUNTIME" wait "$TMP_ROOT/read-answer" "$TMP_ROOT/read-runtime" \
  "$(($(date +%s) + 3600))" stagedtoken 5 \
  > "$TMP_ROOT/read.stdout" 2> "$TMP_ROOT/read.stderr" || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_rc "$rc" 75 "an unverifiable pid is reported as gone"
assert_contains "$TMP_ROOT/read.stderr" "the detached worker is gone" \
  "the 75 names a gone worker"
[[ $elapsed -lt 4 ]] \
  || fail "the wait spent its whole ${elapsed}s slice believing an unverified pid"
ok "it answers promptly (${elapsed}s) instead of spending the slice"
kill -KILL "$bystander" 2>/dev/null || true

echo "=== a reaped worker is not a running one, however well it matches ==="
# THE HARD CASE, and the one the recorded identity alone gets wrong. A zombie
# keeps the pgid and start time it was launched with, and `kill -0` still
# succeeds on it, so its record matches EXACTLY. Only the process state says
# the run is over. On a PID 1 that does not reap — a container without an init
# — this is every run that ends without publishing its marker, not a rare shape.
ZOMBIE=""
spawn_leader_zombie() { # sets ZOMBIE to a reaped process leading its own group
  # The parent execs into `sleep` so that nothing is left which could reap the
  # child; a shell parent collects it and there is no zombie to stage. The
  # child outlives that exec by a second for the same reason. No python here:
  # this suite's whole point is the host it runs on, and it may not have one.
  local pidfile="$TMP_ROOT/zombie.pid" _
  rm -f "$pidfile"
  bash -c 'set -m; sleep 1 & printf "%s\n" "$!" > "$1"; set +m; exec sleep 60' \
    _ "$pidfile" > /dev/null 2>&1 &
  STRAYS+=("$!")
  # Disowned for the same reason the bystander is: cleanup kills it, and the
  # 3.2 bash macOS ships announces a killed job it still tracks. `Killed: 9`
  # in a suite about processes outliving their run reads as a failure to
  # anyone scanning the output. Killing by pid does not need the job table.
  disown %% 2>/dev/null || true
  await_file "$pidfile" || fail "the zombie fixture never reported its pid"
  ZOMBIE="$(read_pid "$pidfile" "the zombie fixture")"
  STRAYS+=("$ZOMBIE")
  for _ in $(seq 1 100); do
    [[ "$(ps -o state= -p "$ZOMBIE" 2>/dev/null | tr -d ' ')" == Z* ]] && return 0
    sleep 0.1
  done
  return 1
}
spawn_leader_zombie || fail "the fixture never became a zombie — nothing to test"
[[ "$(ps -o pgid= -p "$ZOMBIE" 2>/dev/null | tr -d ' ')" == "$ZOMBIE" ]] \
  || fail "the zombie does not lead its own group, so it is not worker-shaped"
kill -0 "$ZOMBIE" 2>/dev/null \
  || fail "kill -0 already rejects the zombie — the case would prove nothing"
ok "the staged zombie is worker-shaped: leads its group, kill -0 accepts it"
mkdir "$TMP_ROOT/z-runtime"
printf 'stagedtoken\n' > "$TMP_ROOT/z-runtime/token"
: > "$TMP_ROOT/z-runtime/worker.log"
printf '%s\n' "$ZOMBIE" > "$TMP_ROOT/z-runtime/pid"
# Its REAL identity, read the way the launcher records it, so the record
# matches and the state is the only thing left that can reject it.
ps -o pgid=,lstart= -p "$ZOMBIE" | tr -s '[:space:]' ' ' \
  | sed 's/^ //; s/ $//' > "$TMP_ROOT/z-runtime/worker-id"
[[ -s "$TMP_ROOT/z-runtime/worker-id" ]] \
  || fail "the zombie's identity did not record — the case would pass vacuously"
printf 'kept\n' > "$TMP_ROOT/z-answer"
start=$(date +%s)
rc=0
"$RUNTIME" wait "$TMP_ROOT/z-answer" "$TMP_ROOT/z-runtime" \
  "$(($(date +%s) + 3600))" stagedtoken 5 \
  > "$TMP_ROOT/z.stdout" 2> "$TMP_ROOT/z.stderr" || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_rc "$rc" 75 "a reaped worker is reported as gone"
assert_contains "$TMP_ROOT/z.stderr" "the detached worker is gone" \
  "the 75 names a gone worker instead of one still running"
[[ $elapsed -lt 4 ]] \
  || fail "the wait spent its whole ${elapsed}s slice waiting on a zombie"
ok "it answers promptly (${elapsed}s) instead of spending the slice"

echo "=== control: the same states against a runtime that trusts a bare pid ==="
# Without this the two cases above cannot say WHICH check spared the bystander
# — an identity check that never ran would pass them both the same way.
MUTANT="$TMP_ROOT/bare-pid-runtime"
sed 's/^worker_is_ours() { # PID RUNTIME_DIR.*/worker_is_ours() { kill -0 "$1" 2>\/dev\/null; return; }\nunused_is_ours() {/' \
  "$RUNTIME" > "$MUTANT"
chmod +x "$MUTANT"
cmp -s "$RUNTIME" "$MUTANT" && fail "the bare-pid control mutated nothing"
bash -n "$MUTANT" || fail "the bare-pid control is not valid shell"
ok "the bare-pid control replaces the identity check with kill -0"
spawn_bystander
control_bystander="$BYSTANDER"
STRAYS+=("$control_bystander")
mkdir "$TMP_ROOT/ctl-runtime"
printf 'stagedtoken\n' > "$TMP_ROOT/ctl-runtime/token"
: > "$TMP_ROOT/ctl-runtime/worker.log"
printf '%s\n' "$control_bystander" > "$TMP_ROOT/ctl-runtime/pid"
printf '%s Thu Jan  1 00:00:00 1970\n' "$control_bystander" > "$TMP_ROOT/ctl-runtime/worker-id"
printf 'kept\n' > "$TMP_ROOT/ctl-answer"
rc=0
"$MUTANT" wait "$TMP_ROOT/ctl-answer" "$TMP_ROOT/ctl-runtime" \
  "$(($(date +%s) - 1))" stagedtoken 1 \
  > "$TMP_ROOT/ctl.stdout" 2> "$TMP_ROOT/ctl.stderr" || rc=$?
if kill -0 "$control_bystander" 2>/dev/null; then
  kill -KILL "$control_bystander" 2>/dev/null || true
  fail "the bare-pid control spared the bystander — the case proves nothing"
fi
ok "the bare-pid control kills the bystander, so the check is what spares it"
