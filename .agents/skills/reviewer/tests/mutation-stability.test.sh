#!/usr/bin/env bash
# Behavioral suite for scripts/mutation-stability.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS="$SCRIPT_DIR/../scripts/mutation-stability"
PASS=0 FAIL=0 rc=0 out=""
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        $2"; }
run_ms() {
  sha="$1"; shift; rc=0
  out=$("$MS" --worktree "$REPO" --sha "$sha" "$@" 2>&1) || rc=$?
}
is_rc() {
  if [ "$rc" = "$1" ]; then ok "$2"; else bad "$2" "rc=$rc out=$out"; fi
}
has() {
  case "$out" in *"$1"*) ok "$2";; *) bad "$2" "$out";; esac
}
lacks() {
  case "$out" in *"$1"*) bad "$2" "$out";; *) ok "$2";; esac
}
stopped() {
  pid="$1" attempts=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

# Every case up to the shared-cache block below builds with `true` or a `test`
# — nothing that keeps a cache, so nothing the copy's mtime has to outrank.
# The two blocks that DO put a whole-second cache behind the build clear this
# again and spend the real wait.
export MUTATION_STABILITY_SETTLE=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ms-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
printf 'add() { echo $(( $1 + $2 )); }\n' > "$REPO/lib.sh"
cat > "$REPO/check.sh" <<'T'
. ./lib.sh
[ "$(add 2 3)" = 5 ]
T
cat > "$REPO/hang.sh" <<'T'
echo $$ > "$HANG_PID_FILE"
trap '' TERM
while :; do :; done
T
cat > "$TMP/launch-window.bashenv" <<'T'
case "$0" in
  *mutation-stability)
    set -T
    trap '
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
    ' DEBUG
    ;;
esac
T
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm x
SHA=$(git -C "$REPO" rev-parse HEAD)

run_ms "$SHA" --test 'bash check.sh' --build 'true' \
  --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
  --stability 2 --threads 2
is_rc 0 "killed mutant exits 0"
# The LAST line, not the whole stream: the run may say something on stderr
# first — a skipped settle boundary does — and the claim here is the shape of
# the verdict this script ends on.
if [ "${out##*$'\n'}" = "mutation: killed 1/1; stability: 2/2 at 2 threads" ]; then ok "summary line is the exact format"; else bad "summary line is the exact format" "$out"; fi

run_ms "$SHA" --test 'bash check.sh' --build 'true' \
  --mutate 'echo "# decoy: still says +" >> lib.sh' --stability 1
is_rc 1 "surviving decoy mutant exits 1"
has "mutation: killed 0/1;" "survivor reported as killed 0/1"

run_ms "$SHA" --test 'false' --build 'true' --mutate 'true' --stability 1
is_rc 2 "red-before-mutation control exits 2"
has "before any mutation" "control names the instrument failure"

run_ms "$SHA" \
  --test 'printf "test result: ok. 0 passed; 0 failed; 0 ignored\n"' \
  --build 'true' --mutate 'true' --stability 1
is_rc 2 "an empty Cargo selection exits 2"
has "filter selected no test" "an empty selection has its own outcome"
lacks "survived" "an empty selection is never a surviving mutant"

run_ms "$SHA" --test 'true' --build 'test -f lib.sh' \
  --mutate 'rm lib.sh' --stability 1
is_rc 2 "a non-compiling mutant exits 2"
has "invalid-mutant" "a build failure reports invalid-mutant"
lacks "killed" "a non-compiling mutant is never killed"

# One invalid input proves the shared positive-integer validator.
run_ms "$SHA" --test 'true' --build 'true' --mutate 'true' --timeout 0
is_rc 2 "the numeric validator rejects zero"

# The settle has its own validator: it admits the 0 the shared one refuses,
# and refuses everything that is not a count of seconds.
rc=0
out=$(MUTATION_STABILITY_SETTLE=soon "$MS" --worktree "$REPO" --sha "$SHA" \
  --test 'true' --build 'true' --mutate 'true' --stability 1 2>&1) || rc=$?
is_rc 2 "a settle that is not a number of seconds exits 2"
has "MUTATION_STABILITY_SETTLE wants a whole number of seconds" "the rejected settle is named"

# Width is part of that grammar: unrefused, this figure is one the shell's
# tests read as an error and sleep waits out, so the run hangs on its first
# write to a copy instead of reporting the setting.
rc=0
out=$(MUTATION_STABILITY_SETTLE=18446744073709551616 "$MS" --worktree "$REPO" --sha "$SHA" \
  --test 'true' --build 'true' --mutate 'true' --stability 1 2>&1) || rc=$?
is_rc 2 "a settle too wide for the arithmetic exits 2"
has "MUTATION_STABILITY_SETTLE wants a whole number of seconds" "the over-wide settle is named"

# And 0 really skips the wait rather than merely shortening it. What the run
# asked for is read off a sleep stub: the settle is the only whole-second
# sleeper in the script, and the sub-second waits are its own polls, which the
# stub still performs so the run behaves normally.
mkdir -p "$TMP/sleepbin"
cat >"$TMP/sleepbin/sleep" <<SH
#!/bin/sh
printf '%s\n' "\$1" >>"$TMP/slept"
case "\$1" in *.*) exec $(command -v sleep) "\$@" ;; esac
SH
chmod +x "$TMP/sleepbin/sleep"
# WANT is the number of seconds the run should have asked for, or `absent` for
# no whole-second wait at all. The figure and not just its shape: a default
# silently changed from 1 to 30 is still a whole number, and would read green.
settle_arm() { # DESC EXPECTATION(seconds|absent) env-argument...
  desc="$1"; want="$2"; shift 2
  : >"$TMP/slept"
  rc=0
  out=$(env "$@" PATH="$TMP/sleepbin:$PATH" "$MS" \
    --worktree "$REPO" --sha "$SHA" --test 'bash check.sh' --build 'true' \
    --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
    --stability 1 --threads 2 2>&1) || rc=$?
  is_rc 0 "control: $desc still reaches its verdict"
  found="$(grep -xE '[0-9]+' "$TMP/slept" | head -1 || true)"
  [ -n "$found" ] || found=absent
  if [ "$found" = "$want" ]; then ok "$desc"; else
    bad "$desc" "whole-second wait $found; slept: $(tr '\n' ' ' <"$TMP/slept")"
  fi
}
settle_arm "the default settle waits one whole second" 1 -u MUTATION_STABILITY_SETTLE
lacks "settle: 0" "the default run says nothing about a skipped boundary"
settle_arm "a zero settle asks for no wait at all" absent MUTATION_STABILITY_SETTLE=0
# A verdict reached without the boundary has to be identifiable afterwards:
# where BUILD does share a cache, a reused binary reads as a survivor and
# nothing else in the output says why.
has "settle: 0 — copies are not mtime-separated" \
  "a skipped boundary is named in the run's own output"

# KEN-999: one timeout control also checks adoption under a non-reaping PID 1.
export HANG_PID_FILE="$TMP/timeout-child.pid"
if command -v unshare >/dev/null 2>&1 \
  && command -v python3 >/dev/null 2>&1 \
  && unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
  rc=0
  out=$(unshare --user --map-root-user --pid --fork --mount-proc \
    python3 -c '
import glob, os, subprocess, sys, time
env = os.environ.copy()
run = subprocess.run([
    sys.argv[1], "--worktree", sys.argv[2], "--sha", sys.argv[3],
    "--test", "true", "--build", "bash hang.sh & wait",
    "--mutate", "true", "--stability", "1", "--timeout", "1",
], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(0.1)
zombies = []
for path in glob.glob("/proc/[0-9]*/stat"):
    try:
        fields = open(path).read().split()
        if fields[2] == "Z" and fields[3] == "1":
            zombies.append((fields[0], fields[1], fields[4]))
    except (IndexError, OSError):
        pass
if run.returncode != 2:
    print("timeout exit: expected 2, got %s" % run.returncode)
if "timed out after 1s" not in run.stderr:
    print("missing timeout diagnostic: %s" % run.stderr)
if zombies:
    print("non-reaping PID 1 adopted zombies: %r" % (zombies,))
sys.exit(0 if run.returncode == 2 and "timed out after 1s" in run.stderr and not zombies else 1)
' "$MS" "$REPO" "$SHA" 2>&1) || rc=$?
  is_rc 0 "a timed-out child leaves no zombies under non-reaping PID 1"
else
  run_ms "$SHA" --test 'true' --build 'bash hang.sh & wait' \
    --mutate 'true' --stability 1 --timeout 1
  is_rc 2 "a hanging child times out"
  has "timed out after 1s" "the timeout is reported"
  child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
  if [ -n "$child" ] && stopped "$child"; then
    ok "the timed-out child is reaped"
  else
    bad "the timed-out child is reaped" "pid=${child:-missing}"
    [ -z "$child" ] || kill -KILL "$child" 2>/dev/null || true
  fi
fi

# One signal-gap control covers cancellation before process ownership lands.
export HANG_PID_FILE="$TMP/launch-window-child.pid"
export LAUNCH_WINDOW_SIGNALLED="$TMP/launch-window-signalled"
rc=0
BASH_ENV="$TMP/launch-window.bashenv" "$MS" --worktree "$REPO" --sha "$SHA" \
  --test 'true' --build 'bash hang.sh & wait' --mutate 'true' \
  --stability 1 --timeout 2 >/dev/null 2>&1 || rc=$?
child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
if [ "$rc" = 143 ] && [ -f "$LAUNCH_WINDOW_SIGNALLED" ] \
  && [ -n "$child" ] && stopped "$child"; then
  ok "launch-window cancellation records ownership and reaps the command"
else
  bad "launch-window cancellation records ownership and reaps the command" \
    "rc=$rc signal_file=$LAUNCH_WINDOW_SIGNALLED pid=${child:-missing}"
  [ -z "$child" ] || kill -KILL "$child" 2>/dev/null || true
fi

# A rerun that fails only after the first clean pass reports partial stability.
cat > "$REPO/check.sh" <<'T'
. ./lib.sh
[ "$(add 2 3)" = 5 ] || exit 1
[ ! -f .ran ] || exit 1
touch .ran
T
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm flaky
SHA2=$(git -C "$REPO" rev-parse HEAD)
run_ms "$SHA2" --test 'bash check.sh' --build 'true' \
  --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
  --stability 3 --threads 2
is_rc 1 "stability failure exits 1 even with the mutant killed"
has "stability: 1/3 at 2 threads" "partial stability is reported as Y/N"

# Shared whole-second caches must rebuild for mutant and clean copies. This is
# the wait's whole reason, so from here the default settle is what runs.
unset MUTATION_STABILITY_SETTLE
export CACHE="$TMP/build-cache"
mkdir -p "$CACHE"
cat > "$REPO/check.sh" <<'T'
built=0
[ ! -f "$CACHE/built.sh" ] || built=$(stat -c %Y "$CACHE/built.sh")
[ "$(stat -c %Y lib.sh)" -le "$built" ] || cp lib.sh "$CACHE/built.sh"
. "$CACHE/built.sh"
[ "$(add 2 3)" = 5 ]
T
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm cached
SHA3=$(git -C "$REPO" rev-parse HEAD)
run_ms "$SHA3" --test 'bash check.sh' --build 'true' \
  --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
  --stability 3 --threads 2
is_rc 0 "a shared whole-second build cache reaches the right verdict"
has "mutation: killed 1/1" "the mutant build rebuilds instead of reusing the control"
has "stability: 3/3 at 2 threads" "the clean copy rebuilds instead of reusing the mutant"

kept=$("$MS" --worktree "$REPO" --sha "$SHA3" --test 'bash check.sh' \
  --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
  --stability 1 --threads 2 --keep 2>&1 >/dev/null || true)
root=$(printf '%s\n' "$kept" | sed -n 's/^kept: //p')
if [ -d "$root/clean" ]; then
  gap=$(( $(stat -c %Y "$root/clean/check.sh") - $(stat -c %Y "$root/mutant/check.sh") ))
  rm -rf "$root"
  if [ "$gap" -ge 1 ]; then ok "each copy outranks the one before"; else bad "each copy outranks the one before" "gap=${gap}s"; fi
else
  bad "each copy outranks the one before" "--keep printed no temp dir: $kept"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
