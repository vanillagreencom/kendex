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
      actual="rc=$rc;before-mutation=$(output_has 'before any mutation')"
      ;;
    empty-selection)
      actual="rc=$rc;empty-selection=$(output_has 'filter selected no test');survived=$(output_has 'survived')"
      ;;
    invalid-mutant)
      actual="rc=$rc;invalid-mutant=$(output_has 'invalid-mutant');killed=$(output_has 'killed')"
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
red before mutation	base	false	true	none	1	default	control-failure	rc=2;before-mutation=yes
empty Cargo selection	base	printf "test result: ok. 0 passed; 0 failed; 0 ignored\n"	true	none	1	default	empty-selection	rc=2;empty-selection=yes;survived=no
non-compiling mutant	base	true	test -f lib.sh	remove	1	default	invalid-mutant	rc=2;invalid-mutant=yes;killed=no
partial stability	flaky	bash check.sh	true	kill	3	2	partial-stability	rc=1;partial=yes
ROWS
assert_table_executed "command outcome" "$command_rows"

run_ms "$SHA_BASE" --test 'true' --build 'true' --mutate 'true' --timeout 0
assert_case "numeric validator rejects zero" \
  "rc=$rc;timeout-validator=$(output_has '--timeout wants a positive integer')" \
  "rc=2;timeout-validator=yes"

echo "=== settle validation table ==="
settle_validation_rows=0
while IFS=$'\t' read -r name value expected; do
  rc=0
  out=""
  out=$(MUTATION_STABILITY_SETTLE="$value" "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test 'true' --build 'true' --mutate 'true' --stability 1 2>&1) || rc=$?
  actual="rc=$rc;setting-named=$(output_has 'MUTATION_STABILITY_SETTLE wants a whole number of seconds')"
  assert_row "settle validation" "$name" "$actual" "$expected"
  settle_validation_rows=$((settle_validation_rows + 1))
done <<'ROWS'
non-numeric settle	soon	rc=2;setting-named=yes
over-wide settle	18446744073709551616	rc=2;setting-named=yes
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
  actual="rc=$rc;whole-sleeps=$whole_sleeps;skip-warning=$(output_has 'settle: 0')"
  assert_row "settle setting" "$name" "$actual" "$expected"
  settle_setting_rows=$((settle_setting_rows + 1))
done <<'ROWS'
default settle	unset	rc=0;whole-sleeps=1,1,1;skip-warning=no
zero settle	0	rc=0;whole-sleeps=absent;skip-warning=yes
ROWS
assert_table_executed "settle setting" "$settle_setting_rows"

cat > "$TMP/launch-window.bashenv" <<'CASE'
set -T
trap '
  case "$0" in
    *mutation-stability)
      if [ "$BASH_COMMAND" = "ACTIVE_PID=\$!" ]; then
        trap - DEBUG
        tries=0
        while [ ! -s "$HANG_PID_FILE" ] && [ "$tries" -lt 100 ]; do
          sleep 0.01
          tries=$((tries + 1))
        done
        : > "$LAUNCH_WINDOW_SIGNALLED"
        kill -TERM "$$"
      fi
      ;;
    *) trap - DEBUG ;;
  esac
' DEBUG
CASE

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
  actual="rc=$rc;timeout=$(output_has 'timed out after 1s');child-stopped=$child_stopped"
}

observe_launch_window() {
  export HANG_PID_FILE="$TMP/launch-window-child.pid"
  export LAUNCH_WINDOW_SIGNALLED="$TMP/launch-window-signalled"
  rm -f "$HANG_PID_FILE" "$LAUNCH_WINDOW_SIGNALLED"
  rc=0
  out=""
  BASH_ENV="$TMP/launch-window.bashenv" "$MS" --worktree "$REPO" --sha "$SHA_BASE" --test 'true' --build 'bash hang.sh & wait' --mutate 'true' --stability 1 --timeout 2 >/dev/null 2>&1 || rc=$?
  child=$(sed -n '1p' "$HANG_PID_FILE" 2>/dev/null || true)
  signalled=no
  [ ! -f "$LAUNCH_WINDOW_SIGNALLED" ] || signalled=yes
  child_stopped=no
  if [ -n "$child" ] && stopped "$child"; then
    child_stopped=yes
  elif [ -n "$child" ]; then
    kill -KILL "$child" 2>/dev/null || true
  fi
  child_recorded=no
  [ -z "$child" ] || child_recorded=yes
  actual="rc=$rc;signalled=$signalled;child-recorded=$child_recorded;child-stopped=$child_stopped"
}

namespace_available=no
if command -v unshare >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
  namespace_available=yes
fi

observe_namespace() {
  export HANG_PID_FILE="$TMP/namespace-child.pid"
  rm -f "$HANG_PID_FILE"
  rc=0
  out=""
  out=$(unshare --user --map-root-user --pid --fork --mount-proc python3 -c '
import glob, os, subprocess, sys, time
run = subprocess.run([
    sys.argv[1], "--worktree", sys.argv[2], "--sha", sys.argv[3],
    "--test", "true", "--build", "bash hang.sh & wait",
    "--mutate", "true", "--stability", "1", "--timeout", "1",
], env=os.environ.copy(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(0.1)
zombies = []
for path in glob.glob("/proc/[0-9]*/stat"):
    try:
        fields = open(path).read().split()
        if fields[2] == "Z" and fields[3] == "1":
            zombies.append(fields[0])
    except (IndexError, OSError):
        pass
print("inner-rc=%s;timeout=%s;zombies=%s" % (
    run.returncode,
    "yes" if "timed out after 1s" in run.stderr else "no",
    "none" if not zombies else "present",
))
' "$MS" "$REPO" "$SHA_BASE" 2>&1) || rc=$?
  actual="outer-rc=$rc;${out##*$'\n'}"
}

echo "=== process cleanup table ==="
process_rows=0
while IFS=$'\t' read -r name kind expected; do
  case "$kind" in
    timeout) observe_timeout ;;
    launch-window) observe_launch_window ;;
    namespace)
      if [ "$namespace_available" = no ]; then
        printf '  skip  process cleanup: %s (private PID namespaces unavailable)\n' "$name"
        continue
      fi
      observe_namespace
      ;;
    *) actual="unknown-kind=$kind" ;;
  esac
  assert_row "process cleanup" "$name" "$actual" "$expected"
  process_rows=$((process_rows + 1))
done <<'ROWS'
timed-out child exits, reports, and stops	timeout	rc=2;timeout=yes;child-stopped=yes
launch-window cancellation owns and stops its child	launch-window	rc=143;signalled=yes;child-recorded=yes;child-stopped=yes
non-reaping PID 1 adopts no zombie	namespace	outer-rc=0;inner-rc=2;timeout=yes;zombies=none
ROWS
assert_table_executed "process cleanup" "$process_rows"

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
  root=$(printf '%s\n' "$kept" | sed -n 's/^kept: //p') || root=""
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
