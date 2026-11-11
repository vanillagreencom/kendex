#!/usr/bin/env bash
# Behavioral suite for scripts/mutation-stability.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS="$SCRIPT_DIR/../scripts/mutation-stability"
PASS=0
FAIL=0
rc=0
out=""

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

assert_row() {
  table="$1" name="$2" actual="$3" expected="$4"
  if [ "$actual" = "$expected" ]; then
    pass "$table: $name"
  else
    fail "$table: $name" "expected <$expected>, got <$actual>; output: $out"
  fi
}

assert_case() {
  name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected <$expected>, got <$actual>; output: $out"
  fi
}

assert_table_executed() {
  table="$1" rows="$2"
  if [ "$rows" -gt 0 ]; then
    pass "$table: executed rows"
  else
    fail "$table: executed rows" "the table executed no assertion row"
  fi
}

output_has() {
  case "$out" in
    *"$1"*) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

output_first_line() {
  printf '%s' "${out%%$'\n'*}"
}

output_error_line() {
  local key="$1" line
  while IFS= read -r line; do
    case "$line" in
      "error=$key "*) printf '%s' "$line"; return 0 ;;
    esac
  done <<< "$out"
  printf 'absent'
}

stopped() {
  pid="$1" attempts=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

KILL_MUTATION='before=$(cksum < lib.sh) && matches=$(grep -cF '\''add() { echo $(( $1 + $2 )); }'\'' lib.sh) && [ "$matches" -eq 1 ] && sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak && after=$(cksum < lib.sh) && [ "$before" != "$after" ]'

mutation_for() {
  case "$1" in
    kill) mutation="$KILL_MUTATION" ;;
    decoy) mutation='printf '\''%s\n'\'' "# decoy: still says +" >> lib.sh' ;;
    remove) mutation='rm lib.sh' ;;
    none) mutation='true' ;;
    *) fail "fixture mutation" "unknown mutation token: $1"; mutation='false' ;;
  esac
}

run_ms() {
  run_ms_env "" "$@"
}

# run_ms_env ENV SHA ARGS... — ENV, when not empty, is one NAME=VALUE the
# script starts with. SECONDS=N starts its SECONDS counter at N, so a summary's
# seconds field reads as N plus the call's own elapsed time.
run_ms_env() {
  ms_env="$1" sha="$2"
  shift 2
  rc=0
  out=""
  out=$(env ${ms_env:+"$ms_env"} "$MS" --worktree "$REPO" --sha "$sha" "$@" 2>&1) || rc=$?
}

resolve_sha() {
  case "$1" in
    base) sha="$SHA_BASE" ;;
    flaky) sha="$SHA_FLAKY" ;;
    cached) sha="$SHA_CACHED" ;;
    *) fail "fixture revision" "unknown revision token: $1"; sha="$SHA_BASE" ;;
  esac
}

# The command and process tables use stub builds, so no copied source must
# outrank a shared build cache. The shared-cache table restores the default.
export MUTATION_STABILITY_SETTLE=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ms-test.XXXXXX") || exit 2
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap '[ -e "$TMP/keep-process-scratch" ] || rm -rf "$TMP"' EXIT
RUNTIME_TMP="$TMP/runtime"
mkdir -p "$RUNTIME_TMP"
export TMPDIR="$RUNTIME_TMP"
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
printf 'add() { echo $(( $1 + $2 )); }\n' > "$REPO/lib.sh"
cat > "$REPO/check.sh" <<'CASE'
. ./lib.sh
[ "$(add 2 3)" = 5 ]
CASE
cat > "$REPO/hang.sh" <<'CASE'
echo $$ > "$HANG_PID_FILE"
trap '' TERM
while :; do :; done
CASE
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm base
SHA_BASE=$(git -C "$REPO" rev-parse HEAD)

cat > "$REPO/check.sh" <<'CASE'
. ./lib.sh
[ "$(add 2 3)" = 5 ] || exit 1
[ ! -f .ran ] || exit 1
touch .ran
CASE
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm flaky
SHA_FLAKY=$(git -C "$REPO" rev-parse HEAD)

cat > "$REPO/check.sh" <<'CASE'
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}
built=0
if [ -f "$CACHE/built.sh" ]; then
  built=$(file_mtime "$CACHE/built.sh") || exit 2
fi
source_time=$(file_mtime lib.sh) || exit 2
[ "$source_time" -le "$built" ] || cp lib.sh "$CACHE/built.sh"
. "$CACHE/built.sh"
[ "$(add 2 3)" = 5 ]
CASE
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm cached
SHA_CACHED=$(git -C "$REPO" rev-parse HEAD)

# The exact-summary row starts the script's clock at CLOCK_BASE and bounds the
# reported seconds by this shell's own count across the call: a hard-coded
# figure or an absolute clock lands outside base..base+elapsed.
CLOCK_BASE=5000

echo "=== command outcome table ==="
command_rows=0
while IFS=$'\t' read -r name revision test_cmd build_cmd mutation_token stability threads probe expected; do
  resolve_sha "$revision"
  mutation_for "$mutation_token"
  clock=""
  [ "$probe" != exact-summary ] || clock="SECONDS=$CLOCK_BASE"
  started=$SECONDS
  if [ "$threads" = "default" ]; then
    run_ms_env "$clock" "$sha" --test "$test_cmd" --build "$build_cmd" --mutate "$mutation" --stability "$stability"
  else
    run_ms_env "$clock" "$sha" --test "$test_cmd" --build "$build_cmd" --mutate "$mutation" --stability "$stability" --threads "$threads"
  fi
  elapsed=$((SECONDS - started))
  case "$probe" in
    exact-summary)
      last=${out##*$'\n'}
      seconds=${last##*; seconds: }
      case "$seconds" in
        '' | *[!0-9]*) seconds=missing ;;
        *)
          if [ "$seconds" -ge "$CLOCK_BASE" ] && [ "$seconds" -le $((CLOCK_BASE + elapsed)) ]; then
            seconds=call-elapsed
          else
            seconds="outside-$CLOCK_BASE..$((CLOCK_BASE + elapsed)):$seconds"
          fi
          ;;
      esac
      actual="rc=$rc;last=${last%; seconds: *};seconds=$seconds"
      ;;
    killed-zero)
      actual="rc=$rc;killed-zero=$(output_has 'mutation: killed 0/1;')"
      ;;
    control-failure)
      actual="rc=$rc;diagnostic=$(output_error_line control-test-failed)"
      ;;
    empty-selection)
      actual="rc=$rc;diagnostic=$(output_error_line control-selection-empty);survived=$(output_has 'survived')"
      ;;
    invalid-mutant)
      actual="rc=$rc;diagnostic=$(output_error_line mutant-build-failed);killed=$(output_has 'killed')"
      ;;
    partial-stability)
      actual="rc=$rc;partial=$(output_has 'stability: 1/3 at 2 threads')"
      ;;
    *)
      actual="unknown-probe=$probe"
      ;;
  esac
  assert_row "command outcome" "$name" "$actual" "$expected"
  command_rows=$((command_rows + 1))
done <<'ROWS'
killed mutant	base	bash check.sh	true	kill	2	2	exact-summary	rc=0;last=mutation: killed 1/1; stability: 2/2 at 2 threads;seconds=call-elapsed
surviving decoy	base	bash check.sh	true	decoy	1	default	killed-zero	rc=1;killed-zero=yes
red before mutation	base	false	true	none	1	default	control-failure	rc=2;diagnostic=error=control-test-failed exit=1
empty Cargo selection	base	printf "test result: ok. 0 passed; 0 failed; 0 ignored\n"	true	none	1	default	empty-selection	rc=2;diagnostic=error=control-selection-empty count=0;survived=no
non-compiling mutant	base	true	test -f lib.sh	remove	1	default	invalid-mutant	rc=2;diagnostic=error=mutant-build-failed exit=1;killed=no
partial stability	flaky	bash check.sh	true	kill	3	2	partial-stability	rc=1;partial=yes
ROWS
assert_table_executed "command outcome" "$command_rows"

# A copy two levels deep inside the workspace, so the prefix it resolves is a
# path this suite owns and knows is absent. The skill declares github required
# for exactly this file; an install that dropped it must refuse by name rather
# than fork a child into this script's own process group.
ORPHAN_MS_DIR="$TMP/orphan/a/b"
mkdir -p "$ORPHAN_MS_DIR"
ORPHAN_MS="$ORPHAN_MS_DIR/mutation-stability"
cp "$MS" "$ORPHAN_MS"
chmod +x "$ORPHAN_MS"

echo "=== input and dependency refusal table ==="
input_rows=0
while IFS=$'\t' read -r name kind expected_line; do
  rc=0
  out=""
  case "$kind" in
    missing-value) out=$("$MS" --worktree 2>&1) || rc=$? ;;
    unknown) out=$("$MS" --unknown 2>&1) || rc=$? ;;
    arguments) out=$("$MS" 2>&1) || rc=$? ;;
    temp) out=$(MUTATION_STABILITY_SETTLE=1 TMPDIR="$TMP/absent" "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test true --build true --mutate true 2>&1) || rc=$? ;;
    temp-space) out=$(MUTATION_STABILITY_SETTLE=1 TMPDIR="$TMP/space absent" "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test true --build true --mutate true 2>&1) || rc=$? ;;
    archive) out=$(MUTATION_STABILITY_SETTLE=1 "$MS" --worktree "$REPO" --sha not-a-sha --test true --build true --mutate true 2>&1) || rc=$? ;;
    control-build) out=$(MUTATION_STABILITY_SETTLE=1 "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test true --build false --mutate true 2>&1) || rc=$? ;;
    mutate) out=$(MUTATION_STABILITY_SETTLE=1 "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test 'printf "test result: ok. 1 passed; 0 failed; 0 ignored\n"' --build true --mutate 'printf "mutation detail\n" >&2; false' 2>&1) || rc=$? ;;
    group-leader) out=$("$ORPHAN_MS" --worktree "$REPO" --sha "$SHA_BASE" --test true --build true --mutate true 2>&1) || rc=$? ;;
    *) fail "input refusal fixture" "unknown kind: $kind" ;;
  esac
  assert_row "input refusal" "$name" "rc=$rc;first=$(output_first_line)" "rc=2;first=$expected_line"
  input_rows=$((input_rows + 1))
done <<ROWS
missing option value	missing-value	error=argument-value-missing option=--worktree
unknown option	unknown	error=argument-unknown argument=--unknown
missing required options	arguments	error=arguments-missing set=worktree-sha-test-build-mutate
temporary workspace failure	temp	error=temp-create-failed path=$TMP/absent
temporary workspace path escaping	temp-space	error=temp-create-failed path=$TMP/space\ absent
archive failure	archive	error=archive-failed sha=not-a-sha
control build failure	control-build	error=control-build-failed exit=1
mutation command failure	mutate	error=mutate-command-failed exit=1
absent group-leader prefix	group-leader	error=group-leader-missing path=$ORPHAN_MS_DIR/../../github/scripts/lib/group-leader.sh
ROWS
assert_table_executed "input refusal" "$input_rows"

run_ms "$SHA_BASE" --test 'true' --build 'true' --mutate 'true' --timeout 0
assert_case "numeric validator rejects zero" \
  "rc=$rc;diagnostic=$(output_first_line)" \
  "rc=2;diagnostic=error=positive-integer-invalid option=--timeout:0"

echo "=== settle validation table ==="
settle_validation_rows=0
while IFS=$'\t' read -r name value expected; do
  rc=0
  out=""
  out=$(MUTATION_STABILITY_SETTLE="$value" "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test 'true' --build 'true' --mutate 'true' --stability 1 2>&1) || rc=$?
  actual="rc=$rc;diagnostic=$(output_first_line)"
  assert_row "settle validation" "$name" "$actual" "$expected"
  settle_validation_rows=$((settle_validation_rows + 1))
done <<'ROWS'
non-numeric settle	soon	rc=2;diagnostic=error=settle-invalid value=soon
over-wide settle	18446744073709551616	rc=2;diagnostic=error=settle-invalid value=18446744073709551616
ROWS
assert_table_executed "settle validation" "$settle_validation_rows"

sleep_bin="$TMP/sleepbin"
sleep_log="$TMP/slept"
real_sleep=$(command -v sleep)
mkdir -p "$sleep_bin"
cat > "$sleep_bin/sleep" <<CASE
#!/bin/sh
printf '%s\n' "\$1" >>"$sleep_log"
case "\$1" in *.*) exec "$real_sleep" "\$@" ;; esac
CASE
chmod +x "$sleep_bin/sleep"

echo "=== settle setting table ==="
settle_setting_rows=0
while IFS=$'\t' read -r name setting expected; do
  : > "$sleep_log"
  rc=0
  out=""
  if [ "$setting" = "unset" ]; then
    out=$(env -u MUTATION_STABILITY_SETTLE PATH="$sleep_bin:$PATH" "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 1 --threads 2 2>&1) || rc=$?
  else
    out=$(env MUTATION_STABILITY_SETTLE="$setting" PATH="$sleep_bin:$PATH" "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 1 --threads 2 2>&1) || rc=$?
  fi
  whole_sleeps=$(awk '/^[0-9]+$/ { if (seen++) printf ","; printf "%s", $0 }' "$sleep_log") || whole_sleeps=unreadable
  [ -n "$whole_sleeps" ] || whole_sleeps=absent
  if [ "$setting" = 0 ]; then skip_notice="$(output_first_line)"; else skip_notice=absent; fi
  actual="rc=$rc;whole-sleeps=$whole_sleeps;skip-notice=$skip_notice"
  assert_row "settle setting" "$name" "$actual" "$expected"
  settle_setting_rows=$((settle_setting_rows + 1))
done <<'ROWS'
default settle	unset	rc=0;whole-sleeps=1,1,1;skip-notice=absent
zero settle	0	rc=0;whole-sleeps=absent;skip-notice=notice=settle-disabled value=0
ROWS
assert_table_executed "settle setting" "$settle_setting_rows"

observe_timeout() {
  export HANG_PID_FILE="$TMP/timeout-child.pid"
  rm -f "$HANG_PID_FILE"
  run_ms "$SHA_BASE" --test 'true' --build 'bash hang.sh & wait' --mutate 'true' --stability 1 --timeout 1
  child=$(sed -n '1p' "$HANG_PID_FILE" 2>/dev/null || true)
  child_stopped=no
  if [ -n "$child" ] && stopped "$child"; then
    child_stopped=yes
  elif [ -n "$child" ]; then
    kill -KILL "$child" 2>/dev/null || true
  fi
  actual="rc=$rc;timeout=$(output_error_line command-timeout);child-stopped=$child_stopped"
}

echo "=== process cleanup table ==="
process_rows=0
while IFS=$'\t' read -r name kind expected; do
  case "$kind" in
    timeout) observe_timeout ;;
    *) actual="unknown-kind=$kind" ;;
  esac
  assert_row "process cleanup" "$name" "$actual" "$expected"
  process_rows=$((process_rows + 1))
done <<'ROWS'
timed-out child exits, reports, and stops	timeout	rc=2;timeout=error=command-timeout seconds=1;child-stopped=yes
ROWS
assert_table_executed "process cleanup" "$process_rows"

# WHAT A CALLER CAPTURES IS THIS SCRIPT'S DIAGNOSTIC PROTOCOL and the child's
# own output, nothing else. Under job control bash called setpgid on the child
# from the parent, and when it lost that race with the child's own exec it
# printed `child setpgid (N to N): Operation not permitted` onto this stderr.
# On the macOS shard that line reddened a pin on a captured transcript and
# ejected an unrelated pull request from the merge queue.
#
# The failing-child row shows the pin is not green because the transcript is
# discarded.
#
# The two lines the script itself owes this run: SETTLE=0 is how the tables
# above tell it their stub builds share no cache, and it says so once.
QUIET_TRANSCRIPT='notice=settle-disabled value=0|copies are not mtime-separated; verdicts assume BUILD shares no cache|'

transcript_of() { # ARGS... — the script's own stderr, stdout discarded
  ms_rc=0
  ms_err=""
  ms_err=$("$MS" --worktree "$REPO" --sha "$SHA_BASE" "$@" 2>&1 >/dev/null) || ms_rc=$?
  ms_transcript=$(printf '%s\n' "$ms_err" | tr '\n' '|')
}

echo "=== runner transcript table ==="
transcript_rows=0
while IFS=$'\t' read -r name kind expected; do
  case "$kind" in
    quiet)
      transcript_of --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 1 --threads 2
      actual="rc=$ms_rc;transcript=$ms_transcript"
      ;;
    loud)
      transcript_of --test 'printf "boom\n" >&2; exit 1' --build 'true' --mutate 'true' --stability 1
      if [ "$ms_transcript" = "$QUIET_TRANSCRIPT" ]; then matches=yes; else matches=no; fi
      actual="rc=$ms_rc;matches-quiet-pin=$matches"
      ;;
    *)
      actual="unknown-kind=$kind"
      ;;
  esac
  assert_row "runner transcript" "$name" "$actual" "$expected"
  transcript_rows=$((transcript_rows + 1))
done <<ROWS
a clean run writes only its own keyed notice	quiet	rc=0;transcript=$QUIET_TRANSCRIPT
a failing child still reddens that pin	loud	rc=2;matches-quiet-pin=no
ROWS
assert_table_executed "runner transcript" "$transcript_rows"

# The suite command takes longer than the repeat start budget. Its clean-copy
# failure is seeded only in the clean copy, after the control and kill.
echo "=== repeat budget table ==="
while IFS='|' read -r name seeded expected_rc expected_samples; do
  started=$SECONDS
  run_ms "$SHA_BASE" --test ". ./lib.sh; [ \"\$(add 2 3)\" = 5 ] || exit 1; sleep 2; if [ '$seeded' = yes ] && [ -f .ran ]; then exit 1; fi; touch .ran" \
    --build true --mutate "$KILL_MUTATION" --stability-budget 1 --timeout 3 --threads 2
  elapsed=$((SECONDS - started))
  assert_row "repeat budget" "$name" "rc=$rc;samples=$(output_has "$expected_samples")" "rc=$expected_rc;samples=yes"
  # Four fixed commands plus budget plus two final timeouts, in seconds.
  if [ "$elapsed" -le 19 ]; then pass "$name: within command bound"; else fail "$name: within command bound" "elapsed=$elapsed; bound=19"; fi
done <<'ROWS'
slow stable suite|no|0|stability: 2/2 at 2 threads
slow seeded failure|yes|1|stability: 1/2 at 2 threads
ROWS

# The control's copy of the script, beside its own group-leader lib, with the
# platform probe's refusal replaced by a fallback.
variant_tree="$TMP/variant-ignored-platform-failure"
mkdir -p "$variant_tree/reviewer/scripts" "$variant_tree/github/scripts/lib"
cp "$SCRIPT_DIR/../../github/scripts/lib/group-leader.sh" "$variant_tree/github/scripts/lib/group-leader.sh"
MS_PLATFORM_UNCHECKED="$variant_tree/reviewer/scripts/mutation-stability"
platform_unchecked='  platform=$(uname -s) || platform=unknown'
awk -v from='  platform=$(uname -s) || refuse cleanup-unavailable path "$ROOT" "platform probe failed; workspace kept"' \
  -v to="$platform_unchecked" '$0 == from { print to; next } { print }' "$MS" > "$MS_PLATFORM_UNCHECKED"
chmod +x "$MS_PLATFORM_UNCHECKED"
planted=$(grep -cxF -- "$platform_unchecked" "$MS_PLATFORM_UNCHECKED") || planted=0
if [ "$planted" != 1 ] || cmp -s "$MS" "$MS_PLATFORM_UNCHECKED" || ! bash -n "$MS_PLATFORM_UNCHECKED"; then
  fail "ignored-platform-failure control" "planted $planted lines, wanted exactly 1 in valid shell"
else
  pass "ignored-platform-failure control plants exactly one line"
fi
PLATFORM_BIN="$TMP/platform-probe"
mkdir -p "$PLATFORM_BIN"
cat > "$PLATFORM_BIN/uname" <<'CASE'
#!/bin/sh
exit 42
CASE
chmod +x "$PLATFORM_BIN/uname"
echo "=== failed platform probe table ==="
platform_rows=0
while IFS=$'\t' read -r name script expected; do
  case "$script" in fixed) script="$MS" ;; control) script="$MS_PLATFORM_UNCHECKED" ;; esac
  probe_log="$TMP/platform-workspace"
  rc=0
  out=$(PATH="$PLATFORM_BIN:$PATH" "$script" --worktree "$REPO" --sha "$SHA_BASE" \
    --test true --build "pwd -P > \"$probe_log\"; false" --mutate true 2>&1) || rc=$?
  probe_dir=$(cat "$probe_log") || probe_dir=""
  probe_root=${probe_dir%/mutant}
  retained=no
  [ ! -d "$probe_root" ] || retained=yes
  assert_row "failed platform probe" "$name" \
    "rc=$rc;retained=$retained;refusal=$(output_has 'error=cleanup-unavailable path=')" "$expected"
  # The fixture launches no detached process; its command exited and was reaped.
  case "$probe_root" in
    "$RUNTIME_TMP"/mutation-stability.*) rm -rf -- "$probe_root" ;;
    *) fail "platform probe fixture" "unexpected workspace path: $probe_root" ;;
  esac
  platform_rows=$((platform_rows + 1))
done <<'ROWS'
failed probe retains scratch	fixed	rc=2;retained=yes;refusal=yes
control: ignored probe fails scratch-retention assertion	control	rc=2;retained=no;refusal=no
ROWS
assert_table_executed "failed platform probe" "$platform_rows"

if [ -d /proc/self ] && command -v setsid >/dev/null && command -v python3 >/dev/null; then
  mkdir -p "$TMP/no-numeric" "$TMP/no-pidfd" "$TMP/other-user"
  cat > "$TMP/no-numeric/sitecustomize.py" <<'PY'
import sys

def require_process_handle(event, args):
    if event == "os.kill":
        raise RuntimeError("numeric process signaling is unsafe")

sys.addaudithook(require_process_handle)
PY
  cat > "$TMP/no-pidfd/sitecustomize.py" <<'PY'
import os
if hasattr(os, "pidfd_open"):
    del os.pidfd_open
PY
  # Supply the other-user credential comparison without requiring a root
  # runner. The fixture still creates a real unreadable proc cwd.
  cat > "$TMP/other-user/sitecustomize.py" <<'PY'
import os
owner_uid = os.geteuid()
os.geteuid = lambda: owner_uid + 1
PY
  cat > "$TMP/private-child.py" <<'PY'
import ctypes
import os
from pathlib import Path
import signal

libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(4, 0, 0, 0, 0) != 0:  # PR_SET_DUMPABLE
    raise OSError(ctypes.get_errno(), "cannot hide fixture cwd")
Path(os.environ["DETACHED_PID_FILE"]).write_text(str(os.getpid()))
signal.pause()
PY
  # A subreaper adopts this fixture's orphan, so the test can keep its pidfd
  # and reap a child the run left before the suite removes any scratch.
  cat > "$TMP/detached-check.py" <<'PY'
import ctypes
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

script, repo, sha, scratch, mode, kill_mutation = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
    raise OSError(ctypes.get_errno(), "cannot adopt fixture descendants")
probe = os.pidfd_open(os.getpid())
try:
    signal.pidfd_send_signal(probe, 0)
finally:
    os.close(probe)
pid_path = Path(scratch) / "detached.pid"
ack_path = Path(scratch) / "detached.ack"
pid_path.unlink(missing_ok=True)
ack_path.unlink(missing_ok=True)
env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "MUTATION_STABILITY_SETTLE")}
env.update(DETACHED_PID_FILE=str(pid_path), DETACHED_ACK_FILE=str(ack_path), DETACHED_MODE=mode)
private = mode in ("private-pass", "private-fail", "other-user")
env["PYTHONPATH"] = str(Path(scratch) / ("other-user" if mode == "other-user" else
                                      "no-pidfd" if mode == "unavailable" else "no-numeric"))
env["DETACHED_HELPER"] = str(Path(scratch) / "private-child.py")
fixture = '''
if [ "$DETACHED_MODE" = kill ]; then trap '' TERM; fi
setsid sleep 1000 >/dev/null 2>&1 &
child=$!
echo "$child" > "$DETACHED_PID_FILE"
while [ ! -e "$DETACHED_ACK_FILE" ]; do sleep 0.01; done
exit 0
'''
if private:
    fixture = '''
if [ ! -e "$DETACHED_PID_FILE" ]; then
  setsid python3 "$DETACHED_HELPER" >/dev/null 2>&1 &
  while [ ! -e "$DETACHED_ACK_FILE" ]; do sleep 0.01; done
fi
bash check.sh
'''
mutation = "true" if mode == "private-fail" else kill_mutation
runner = subprocess.Popen([script, "--worktree", repo, "--sha", sha,
                           "--build", "true", "--mutate", mutation if private else "false", "--stability", "1",
                           "--test", fixture], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
child = pidfd = None
try:
    deadline = time.monotonic() + 15
    while not pid_path.exists() or not pid_path.read_text().strip():
        if runner.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError("fixture did not publish its child")
        time.sleep(0.01)
    child = int(pid_path.read_text())
    # The fixture keeps its parent alive until this test holds the process.
    pidfd = os.pidfd_open(child)
    while os.getsid(child) != child:
        if time.monotonic() >= deadline:
            raise RuntimeError("fixture did not create its session")
        time.sleep(0.01)
    if private:
        try:
            os.readlink("/proc/" + str(child) + "/cwd")
        except PermissionError:
            pass
        else:
            raise AssertionError("fixture cwd is readable; host cannot exercise permission denial")
    ack_path.touch()
    output = runner.communicate(timeout=15)[0].decode()
    poll = select.poll()
    poll.register(pidfd, select.POLLIN)
    stopped = bool(poll.poll(0))
    notice = "notice=workspace-process-ended pid=" + str(child) + "\n" in output
    if private:
        root = Path(os.environ["TMPDIR"])
        workspaces = list(root.glob("mutation-stability.*"))
        # Each invocation has its own runtime dir so retention is observable.
        assert not stopped, output
        expected_exit = 1 if mode == "private-fail" else 0
        notice = "notice=workspace-process-unreadable pid=" + str(child)
        assert runner.returncode == expected_exit, output
        assert "mutation: killed " + ("0" if mode == "private-fail" else "1") + "/1; stability: 1/1" in output, output
        assert output.splitlines().count(notice) == (0 if mode == "other-user" else 1), output
        assert bool(workspaces) == (mode != "other-user"), output
    elif mode == "unavailable":
        assert not stopped, output
        cwd = os.readlink("/proc/" + str(child) + "/cwd")
        assert Path(cwd).is_dir(), "failed cleanup deleted an occupied workspace"
        assert "error=cleanup-incomplete path=" in output, output
    else:
        assert stopped, output
        _, status = os.waitpid(child, 0)
        expected_signal = signal.SIGKILL if mode == "kill" else signal.SIGTERM
        assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == expected_signal, status
        child = None
        assert notice and runner.returncode == 2, output
finally:
    ack_path.touch()
    try:
        runner.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        runner.kill()
        runner.communicate(timeout=15)
    if pidfd is not None:
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        except ProcessLookupError:
            pass
        poll = select.poll()
        poll.register(pidfd, select.POLLIN)
        if not poll.poll(1000):
            (Path(scratch) / "keep-process-scratch").touch()
            raise RuntimeError("fixture cleanup did not stop its child")
        if child is not None:
            os.waitpid(child, 0)
        os.close(pidfd)
    elif child is not None:
        (Path(scratch) / "keep-process-scratch").touch()
        raise RuntimeError("fixture cleanup has no safe process handle")
PY
  for mode in term kill unavailable private-pass private-fail other-user; do
    mode_tmp="$TMP/detached-$mode"
    mkdir -p "$mode_tmp"
    if TMPDIR="$mode_tmp" python3 "$TMP/detached-check.py" "$MS" "$REPO" "$SHA_BASE" "$TMP" "$mode" "$KILL_MUTATION"; then
      pass "detached child: $mode"
    else
      fail "detached child: $mode" "child termination or fixture cleanup failed"
    fi
  done
fi

LINKED="$TMP/linked"
git -C "$REPO" worktree add -q --detach "$LINKED" "$SHA_BASE"
REPO_PHYSICAL=$(cd "$REPO" && pwd -P) || exit 2
LINKED_PHYSICAL=$(cd "$LINKED" && pwd -P) || exit 2
WHERE_LOG="$TMP/workspace-where"

echo "=== workspace placement table ==="
placement_rows=0
while IFS=$'\t' read -r name worktree tmpdir outcome expected; do
  case "$worktree" in main) worktree="$REPO" ;; linked) worktree="$LINKED" ;; esac
  case "$tmpdir" in worktree) tmpdir="$REPO/tmp" ;; gitdir) tmpdir="$REPO/.git/ms-tmp" ;; esac
  case "$outcome" in pass) build='true' ;; fail) build='false' ;; esac
  mkdir -p "$tmpdir"
  : > "$WHERE_LOG"
  rc=0
  out=$(TMPDIR="$tmpdir" "$MS" --worktree "$worktree" --sha "$SHA_BASE" --test 'bash check.sh' \
    --build "pwd -P >> \"$WHERE_LOG\"; $build" --mutate "$KILL_MUTATION" --stability 1 --threads 2 2>&1) || rc=$?
  inside=absent
  while IFS= read -r where; do
    case "$where/" in
      "$REPO_PHYSICAL"/* | "$LINKED_PHYSICAL"/*) inside=yes ;;
      *) [ "$inside" = yes ] || inside=no ;;
    esac
  done < "$WHERE_LOG"
  left=$(find "$REPO" "$LINKED" -name 'mutation-stability.*' -prune -print | wc -l | tr -d ' ')
  find "$REPO" "$LINKED" -name 'mutation-stability.*' -prune -exec rm -rf {} +
  assert_row "workspace placement" "$name" "rc=$rc;inside=$inside;left=$left" "$expected"
  placement_rows=$((placement_rows + 1))
done <<'ROWS'
TMPDIR in the worktree, passing run	main	worktree	pass	rc=0;inside=no;left=0
TMPDIR in the worktree, failing run	main	worktree	fail	rc=2;inside=no;left=0
TMPDIR in the common Git directory	main	gitdir	pass	rc=0;inside=no;left=0
TMPDIR in a linked worktree's common Git directory	linked	gitdir	pass	rc=0;inside=no;left=0
ROWS
assert_table_executed "workspace placement" "$placement_rows"
git -C "$REPO" worktree remove --force "$LINKED"
rm -rf "$REPO/tmp" "$REPO/.git/ms-tmp"

# A git on PATH whose archive leaves the copy open for a second after its
# bytes are out, so a signal lands while tar is still writing the workspace,
# and a tar that acknowledges when it, the copy's last writer, has exited.
SLOW_GIT_BIN="$TMP/slow-git"
STOP_MARKER="$TMP/copy-started"
COPY_DONE="$TMP/copy-done"
mkdir -p "$SLOW_GIT_BIN"
cat > "$SLOW_GIT_BIN/git" <<CASE
#!/bin/sh
case " \$* " in
  *" archive "*) "$(command -v git)" "\$@"; status=\$?; : > "$STOP_MARKER"; sleep 1; exit \$status ;;
esac
exec "$(command -v git)" "\$@"
CASE
cat > "$SLOW_GIT_BIN/tar" <<CASE
#!/bin/sh
status=0
"$(command -v tar)" "\$@" || status=\$?
: > "$COPY_DONE"
exit \$status
CASE
chmod +x "$SLOW_GIT_BIN/git" "$SLOW_GIT_BIN/tar"

# The script's TERM handler exits 143, after the copy in flight ends, and that
# exit runs the cleanup trap.
observe_stop() {
  stop_tmp="$TMP/stop-term"
  mkdir -p "$stop_tmp"
  rm -f "$STOP_MARKER" "$COPY_DONE"
  PATH="$SLOW_GIT_BIN:$PATH" TMPDIR="$stop_tmp" "$MS" --worktree "$REPO" --sha "$SHA_BASE" \
    --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 1 >/dev/null 2>&1 &
  stop_pid=$!
  attempts=0
  while [ ! -e "$STOP_MARKER" ] && [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  copying=no
  [ ! -e "$STOP_MARKER" ] || copying=yes
  kill -s TERM "$stop_pid" 2>/dev/null || :
  rc=0
  out=""
  { wait "$stop_pid"; } 2>/dev/null || rc=$?
  # Count once tar has acknowledged its exit, so a copy still being written
  # is not missed.
  attempts=0
  while [ ! -e "$COPY_DONE" ] && [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  settled=no
  [ ! -e "$COPY_DONE" ] || settled=yes
  left=$(find "$stop_tmp" -name 'mutation-stability.*' -prune -print | wc -l | tr -d ' ')
  actual="rc=$rc;copying=$copying;settled=$settled;left=$left"
}

echo "=== stop signal ==="
observe_stop
assert_row "stop signal" "SIGTERM mid-copy removes the workspace" "$actual" "rc=143;copying=yes;settled=yes;left=0"

unset MUTATION_STABILITY_SETTLE
export CACHE="$TMP/build-cache"

observe_cache_verdict() {
  rm -rf "$CACHE"
  mkdir -p "$CACHE"
  run_ms "$SHA_CACHED" --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 3 --threads 2
  actual="rc=$rc;killed=$(output_has 'mutation: killed 1/1');stable=$(output_has 'stability: 3/3 at 2 threads')"
}

observe_kept_copies() {
  rm -rf "$CACHE"
  mkdir -p "$CACHE"
  rc=0
  out=""
  kept=$("$MS" --worktree "$REPO" --sha "$SHA_CACHED" --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 1 --threads 2 --keep 2>&1 >/dev/null) || rc=$?
  root=$(printf '%s\n' "$kept" | sed -n 's/^notice=workspace-kept path=//p') || root=""
  clean_present=no
  gap_ok=no
  case "$root" in
    "$RUNTIME_TMP"/mutation-stability.*)
      if [ -d "$root/clean" ]; then
        clean_present=yes
        mutant_time=$(file_mtime "$root/mutant/check.sh") || mutant_time=unreadable
        clean_time=$(file_mtime "$root/clean/check.sh") || clean_time=unreadable
        if [ "$mutant_time" != unreadable ] && [ "$clean_time" != unreadable ] && [ $((clean_time - mutant_time)) -ge 1 ]; then
          gap_ok=yes
        fi
      fi
      rm -rf "$root"
      ;;
  esac
  out="$kept"
  actual="rc=$rc;clean-present=$clean_present;mtime-gap=$gap_ok"
}

echo "=== shared build cache table ==="
cache_rows=0
while IFS=$'\t' read -r name kind expected; do
  case "$kind" in
    verdict) observe_cache_verdict ;;
    keep) observe_kept_copies ;;
    *) actual="unknown-kind=$kind" ;;
  esac
  assert_row "shared build cache" "$name" "$actual" "$expected"
  cache_rows=$((cache_rows + 1))
done <<'ROWS'
mutant and clean copies both rebuild	verdict	rc=0;killed=yes;stable=yes
kept copy times advance	keep	rc=0;clean-present=yes;mtime-gap=yes
ROWS
assert_table_executed "shared build cache" "$cache_rows"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
