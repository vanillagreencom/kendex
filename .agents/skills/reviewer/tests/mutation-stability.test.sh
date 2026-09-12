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
  sha="$1"
  shift
  rc=0
  out=""
  out=$("$MS" --worktree "$REPO" --sha "$sha" "$@" 2>&1) || rc=$?
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
trap 'rm -rf "$TMP"' EXIT
RUNTIME_TMP="$TMP/runtime"
mkdir -p "$RUNTIME_TMP"
export TMPDIR="$RUNTIME_TMP"
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
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

echo "=== command outcome table ==="
command_rows=0
while IFS=$'\t' read -r name revision test_cmd build_cmd mutation_token stability threads probe expected; do
  resolve_sha "$revision"
  mutation_for "$mutation_token"
  if [ "$threads" = "default" ]; then
    run_ms "$sha" --test "$test_cmd" --build "$build_cmd" --mutate "$mutation" --stability "$stability"
  else
    run_ms "$sha" --test "$test_cmd" --build "$build_cmd" --mutate "$mutation" --stability "$stability" --threads "$threads"
  fi
  case "$probe" in
    exact-summary)
      actual="rc=$rc;last=${out##*$'\n'}"
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
killed mutant	base	bash check.sh	true	kill	2	2	exact-summary	rc=0;last=mutation: killed 1/1; stability: 2/2 at 2 threads
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
# A GREEN LINUX RUN IS NOT EVIDENCE FOR THE PIN: the race never fires here. The
# planted row below is what shows the pin can go red at all, and the failing-
# child row is what shows it is not green because the transcript is discarded.
MUTANT_TREE="$TMP/mutant-tree"
mkdir -p "$MUTANT_TREE/reviewer/scripts" "$MUTANT_TREE/github/scripts/lib"
cp "$SCRIPT_DIR/../../github/scripts/lib/group-leader.sh" \
  "$MUTANT_TREE/github/scripts/lib/group-leader.sh"
MS_NOISY="$MUTANT_TREE/reviewer/scripts/mutation-stability"
sed 's|^  \(.*KENDEX_GROUP_LEADER.*\)$|  echo "child setpgid (1 to 1): Operation not permitted" >\&2; \1|' \
  "$MS" > "$MS_NOISY"
chmod +x "$MS_NOISY"
planted=$(grep -c 'child setpgid (1 to 1)' "$MS_NOISY") || planted=unreadable
if [ "$planted" != 1 ]; then
  fail "parent-noise control" "planted $planted lines, wanted exactly 1"
elif ! bash -n "$MS_NOISY"; then
  fail "parent-noise control" "the mutant is not valid shell"
else
  pass "parent-noise control plants exactly one parent-side line"
fi

# The two lines the script itself owes this run: SETTLE=0 is how the tables
# above tell it their stub builds share no cache, and it says so once.
QUIET_TRANSCRIPT='notice=settle-disabled value=0|copies are not mtime-separated; verdicts assume BUILD shares no cache|'

transcript_of() { # SCRIPT ARGS... — the script's own stderr, stdout discarded
  script="$1"
  shift
  ms_rc=0
  ms_err=""
  ms_err=$("$script" --worktree "$REPO" --sha "$SHA_BASE" "$@" 2>&1 >/dev/null) || ms_rc=$?
  ms_transcript=$(printf '%s\n' "$ms_err" | tr '\n' '|')
}

echo "=== runner transcript table ==="
transcript_rows=0
while IFS=$'\t' read -r name kind expected; do
  case "$kind" in
    quiet)
      transcript_of "$MS" --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 1 --threads 2
      actual="rc=$ms_rc;transcript=$ms_transcript"
      ;;
    noisy)
      transcript_of "$MS_NOISY" --test 'bash check.sh' --build 'true' --mutate "$KILL_MUTATION" --stability 1 --threads 2
      if [ "$ms_transcript" = "$QUIET_TRANSCRIPT" ]; then matches=yes; else matches=no; fi
      actual="rc=$ms_rc;matches-quiet-pin=$matches"
      ;;
    loud)
      transcript_of "$MS" --test 'printf "boom\n" >&2; exit 1' --build 'true' --mutate 'true' --stability 1
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
a planted parent-side line reddens that pin	noisy	rc=0;matches-quiet-pin=no
a failing child still reddens that pin	loud	rc=2;matches-quiet-pin=no
ROWS
assert_table_executed "runner transcript" "$transcript_rows"

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
