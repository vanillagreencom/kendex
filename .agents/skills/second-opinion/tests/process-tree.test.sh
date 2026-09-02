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
# Ancestry only. Other queries reach the host ps.
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
sleep 0.2
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
  SECOND_OPINION_CODEX_CMD=treeish-codex SECOND_OPINION_TIMEOUT=1 \
  "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" \
  2> "$TMP_ROOT/tree.stderr") || rc=$?
elapsed=$(( $(date +%s) - start ))
kid="$(read_pid "$TMP_ROOT/tree.kid" "the timed-out CLI")"
STRAYS+=("$kid")
[[ $elapsed -lt 60 ]] \
  || fail "the caller waited ${elapsed}s for a 1s timeout — a survivor held the pipe open"
ok "the capturing caller returns promptly (${elapsed}s) after a 1s timeout"
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
  # 3s: the shipped runtime releases the capture as soon as the orphan CLI's
  # leader exits (0.2s in), and the leader-probe control never releases it at
  # all, so anything above the leader's own life only lengthens the control.
  end=$(($(date +%s) + 3))
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
  SECOND_OPINION_LAUNCH_MODEL=claude \
  SECOND_OPINION_CODEX_CMD=treeish-codex \
  "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/dl-answer" "$TMP_ROOT/dl-runtime" \
  4 false 10 quick question --target=codex --cwd "$TMP_ROOT/work" --timeout 600 \
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

echo "=== process-group cleanup failures stay loud and recoverable ==="
rc=0
RUNTIME_PATH="$RUNTIME" bash -c '
  source "$RUNTIME_PATH"
  process_group_alive() { return 0; }
  kill() { return 1; }
  stop_process_group 4242 1
' > "$TMP_ROOT/term-fail.stdout" 2> "$TMP_ROOT/term-fail.stderr" || rc=$?
assert_rc "$rc" 1 "a TERM failure is reported"
assert_contains "$TMP_ROOT/term-fail.stderr" "could not send TERM to process group 4242" \
  "the TERM failure names the signal and group"

printf '100\n' > "$TMP_ROOT/kill-fail.clock"
rc=0
RUNTIME_PATH="$RUNTIME" TEST_CLOCK="$TMP_ROOT/kill-fail.clock" bash -c '
  source "$RUNTIME_PATH"
  process_group_alive() { return 0; }
  kill() { [[ "$1" != -KILL ]]; }
  sleep() { :; }
  date() {
    local now
    IFS= read -r now < "$TEST_CLOCK"
    now=$((now + 1))
    printf "%s\n" "$now" > "$TEST_CLOCK"
    printf "%s\n" "$now"
  }
  stop_process_group 4292 1
' > "$TMP_ROOT/kill-fail.stdout" 2> "$TMP_ROOT/kill-fail.stderr" || rc=$?
assert_rc "$rc" 1 "a KILL failure after TERM is reported"
assert_contains "$TMP_ROOT/kill-fail.stderr" "could not send KILL to process group 4292" \
  "the KILL failure names the signal and group"

KILL_FAILURE_MUTANT="$TMP_ROOT/kill-failure-mutant-runtime"
awk '
  /could not send KILL to process group/ {
    print
    if (getline <= 0 || $0 !~ /return 1/) exit 8
    sub(/return 1/, "return 0")
    print
    changed++
    next
  }
  { print }
  END { if (changed != 1) exit 9 }
' "$RUNTIME" > "$KILL_FAILURE_MUTANT" \
  || fail "KILL-failure mutant did not replace exactly one refusal"
chmod +x "$KILL_FAILURE_MUTANT"
bash -n "$KILL_FAILURE_MUTANT" || fail "KILL-failure mutant is not valid shell"
printf '100\n' > "$TMP_ROOT/kill-fail-mutant.clock"
rc=0
RUNTIME_PATH="$KILL_FAILURE_MUTANT" TEST_CLOCK="$TMP_ROOT/kill-fail-mutant.clock" bash -c '
  source "$RUNTIME_PATH"
  process_group_alive() { return 0; }
  kill() { [[ "$1" != -KILL ]]; }
  sleep() { :; }
  date() {
    local now
    IFS= read -r now < "$TEST_CLOCK"
    now=$((now + 1))
    printf "%s\n" "$now" > "$TEST_CLOCK"
    printf "%s\n" "$now"
  }
  stop_process_group 4292 1
' > "$TMP_ROOT/kill-fail-mutant.stdout" 2> "$TMP_ROOT/kill-fail-mutant.stderr" || rc=$?
assert_rc "$rc" 0 "the KILL-failure mutant hides the cleanup failure"
ok "the mutant proves KILL-send failure must return nonzero"

printf '100\n' > "$TMP_ROOT/final-live.clock"
rc=0
RUNTIME_PATH="$RUNTIME" TEST_CLOCK="$TMP_ROOT/final-live.clock" \
  WAIT_CALLED="$TMP_ROOT/final-live.wait-called" bash -c '
  source "$RUNTIME_PATH"
  process_group_alive() { return 0; }
  kill() { return 0; }
  wait() { touch "$WAIT_CALLED"; return 0; }
  sleep() { :; }
  date() {
    local now
    IFS= read -r now < "$TEST_CLOCK"
    now=$((now + 1))
    printf "%s\n" "$now" > "$TEST_CLOCK"
    printf "%s\n" "$now"
  }
  stop_process_group 4343 1
' > "$TMP_ROOT/final-live.stdout" 2> "$TMP_ROOT/final-live.stderr" || rc=$?
assert_rc "$rc" 1 "a process group still alive after KILL is reported"
assert_contains "$TMP_ROOT/final-live.stderr" "process group 4343 is still alive after KILL" \
  "the final-liveness failure names the group and signal"
[[ ! -e "$TMP_ROOT/final-live.wait-called" ]] \
  || fail "post-KILL cleanup entered wait while the group was still alive"
ok "post-KILL cleanup stays inside its bounded liveness loop"

mkdir "$TMP_ROOT/cleanup-fail-runtime"
: > "$TMP_ROOT/cleanup-fail-runtime/worker.log"
: > "$TMP_ROOT/cleanup-fail-runtime/worker.status"
printf '4444\n' > "$TMP_ROOT/cleanup-fail-runtime/pid"
printf 'kept\n' > "$TMP_ROOT/cleanup-fail-answer"
rc=0
RUNTIME_PATH="$RUNTIME" FAIL_ROOT="$TMP_ROOT" bash -c '
  source "$RUNTIME_PATH"
  stop_process_group() {
    echo "second-opinion-runtime: injected cleanup refusal" >&2
    return 1
  }
  wait_for_run "$FAIL_ROOT/cleanup-fail-answer" "$FAIL_ROOT/cleanup-fail-runtime" \
    "$(($(date +%s) - 1))" 1
' > "$TMP_ROOT/cleanup-fail.stdout" 2> "$TMP_ROOT/cleanup-fail.stderr" || rc=$?
assert_rc "$rc" 75 "deadline cleanup failure remains recoverable"
assert_contains "$TMP_ROOT/cleanup-fail.stderr" "injected cleanup refusal" \
  "the cleanup cause reaches the caller"
assert_contains "$TMP_ROOT/cleanup-fail.stderr" "runtime state preserved" \
  "the wait names the preserved recovery state"
[[ -d "$TMP_ROOT/cleanup-fail-runtime" ]] \
  || fail "cleanup failure deleted the runtime state needed to retry"
ok "cleanup failure preserves the runtime directory"

run_launch_cleanup_failure() { # RUNTIME LABEL
  local runtime="$1" label="$2" root rc=0
  root="$TMP_ROOT/$label"
  mkdir "$root-runtime"
  : > "$root-runtime/pid"
  RUNTIME_PATH="$runtime" SECOND_OPINION_PATH="$SECOND_OPINION" CASE_ROOT="$TMP_ROOT" \
    CASE_LABEL="$label" STOP_CAPTURE="$root.stop-pid" \
    SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_CODEX_CMD=treeish-codex \
    CLI_READY_FILE="$root.ready" CLI_KID_FILE="$root.kid" bash -c '
      source "$RUNTIME_PATH"
      stop_process_group() {
        printf "%s\n" "$1" > "$STOP_CAPTURE"
        echo "second-opinion-runtime: injected launch cleanup refusal" >&2
        return 1
      }
      launch "$SECOND_OPINION_PATH" "$CASE_ROOT/$CASE_LABEL-answer" \
        "$CASE_ROOT/$CASE_LABEL-runtime" 120 false 10 quick question \
        --target=codex --cwd "$CASE_ROOT/work" --timeout 600
    ' > "$root.stdout" 2> "$root.stderr" || rc=$?
  printf '%s\n' "$rc"
}
cleanup_captured_launch() { # LABEL
  local label="$1" pid
  pid=$(cat < "$TMP_ROOT/$label.stop-pid")
  kill -KILL -- "-$pid" 2>/dev/null || true
  for _ in $(seq 1 200); do gone "$pid" && return 0; sleep 0.05; done
  return 1
}

rc="$(run_launch_cleanup_failure "$RUNTIME" launch-cleanup)"
assert_rc "$rc" 1 "a publication failure with failed cleanup exits nonzero"
assert_contains "$TMP_ROOT/launch-cleanup.stderr" "injected launch cleanup refusal" \
  "launch cleanup reports the stop failure"
assert_contains "$TMP_ROOT/launch-cleanup.stderr" "runtime state preserved" \
  "launch cleanup names the preserved state"
[[ -d "$TMP_ROOT/launch-cleanup-runtime" ]] \
  || fail "launch cleanup failure deleted its recovery state"
ok "launch cleanup failure preserves the runtime directory"
cleanup_captured_launch launch-cleanup || fail "launch cleanup control left its worker running"

LAUNCH_CLEANUP_MUTANT="$TMP_ROOT/launch-cleanup-mutant-runtime-script"
awk '
  /launch cleanup failed; runtime state preserved/ {
    print
    if (getline <= 0 || $0 !~ /return 1/) exit 8
    sub(/return 1/, ":")
    print
    changed++
    next
  }
  { print }
  END { if (changed != 1) exit 9 }
' "$RUNTIME" > "$LAUNCH_CLEANUP_MUTANT" \
  || fail "launch-cleanup mutant did not replace exactly one refusal"
chmod +x "$LAUNCH_CLEANUP_MUTANT"
bash -n "$LAUNCH_CLEANUP_MUTANT" || fail "launch-cleanup mutant is not valid shell"
ok "the launch-cleanup mutant removes the preserve-state return"
rc="$(run_launch_cleanup_failure "$LAUNCH_CLEANUP_MUTANT" launch-cleanup-mutant)"
assert_rc "$rc" 1 "the launch-cleanup mutant still reports publication failure"
[[ ! -e "$TMP_ROOT/launch-cleanup-mutant-runtime" ]] \
  || fail "the launch-cleanup mutant did not delete recovery state"
ok "the mutant proves the return preserves launch recovery state"
cleanup_captured_launch launch-cleanup-mutant \
  || fail "launch-cleanup mutant left its worker running"
