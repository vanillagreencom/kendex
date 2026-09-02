#!/usr/bin/env bash
# Behavioral suite for scripts/mutation-stability.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS="$SCRIPT_DIR/../scripts/mutation-stability"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        $2"; }
stopped() {
  pid="$1" attempts=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

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
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm x
SHA=$(git -C "$REPO" rev-parse HEAD)

if command -v unshare >/dev/null 2>&1 \
  && command -v python3 >/dev/null 2>&1 \
  && unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
  rc=0
  out=$(unshare --user --map-root-user --pid --fork --mount-proc \
    python3 -c '
import glob, os, subprocess, sys, time
env = os.environ.copy()
env["HANG_PID_FILE"] = sys.argv[4]
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
if zombies:
    print("non-reaping PID 1 adopted zombies: %r" % (zombies,))
sys.exit(0 if run.returncode == 2 and not zombies else 1)
' "$MS" "$REPO" "$SHA" "$TMP/nonreaping-timeout-child.pid" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    ok "a non-reaping PID 1 adopts no timed-out descendants"
  else
    bad "a non-reaping PID 1 adopts no timed-out descendants" "$out"
  fi
fi

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'bash check.sh' \
      --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 2 --threads 2) || rc=$?
if [ "$rc" = 0 ]; then ok "killed mutant exits 0"; else bad "killed mutant exits 0" "rc=$rc out=$out"; fi
case "$out" in "mutation: killed 1/1; stability: 2/2 at 2 threads") ok "summary line is the exact format";; *) bad "summary line is the exact format" "$out";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'bash check.sh' \
      --build 'true' --mutate 'echo "# decoy: still says +" >> lib.sh' \
      --stability 1) || rc=$?
if [ "$rc" = 1 ]; then ok "surviving decoy mutant exits 1"; else bad "surviving decoy mutant exits 1" "rc=$rc out=$out"; fi
case "$out" in "mutation: killed 0/1;"*) ok "survivor reported as killed 0/1";; *) bad "survivor reported as killed 0/1" "$out";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'false' \
      --build 'true' --mutate 'true' --stability 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "red-before-mutation control exits 2"; else bad "red-before-mutation control exits 2" "rc=$rc"; fi
case "$out" in *"before any mutation"*) ok "control names the instrument failure";; *) bad "control names the instrument failure" "$out";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" \
      --test 'printf "test result: ok. 0 passed; 0 failed; 0 ignored\n"' \
      --build 'true' --mutate 'true' --stability 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "an empty Cargo selection exits 2"; else bad "an empty Cargo selection exits 2" "rc=$rc out=$out"; fi
case "$out" in *"filter selected no test"*) ok "an empty selection has its own outcome";; *) bad "an empty selection has its own outcome" "$out";; esac
case "$out" in *"survived"*) bad "an empty selection is never a surviving mutant" "$out";; *) ok "an empty selection is never a surviving mutant";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" \
      --test 'grep -q "+" lib.sh && printf "test result: ok. 1 passed; 0 failed; 0 ignored\n"' \
      --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 1 --threads 2) || rc=$?
if [ "$rc" = 0 ]; then ok "a non-empty Cargo selection reaches the verdict"; else bad "a non-empty Cargo selection reaches the verdict" "rc=$rc out=$out"; fi
case "$out" in "mutation: killed 1/1; stability: 1/1 at 2 threads") ok "a passing Cargo summary is accepted";; *) bad "a passing Cargo summary is accepted" "$out";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'true' \
      --build 'false' --mutate 'true' --stability 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "a broken control build exits 2"; else bad "a broken control build exits 2" "rc=$rc out=$out"; fi
case "$out" in *"control: build fails before any mutation"*) ok "a broken build is blamed on the control";; *) bad "a broken build is blamed on the control" "$out";; esac
case "$out" in *"invalid-mutant"*) bad "a broken control build is not an invalid mutant" "$out";; *) ok "a broken control build is not an invalid mutant";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'true' \
      --build 'test -f lib.sh' --mutate 'rm lib.sh' --stability 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "a non-compiling mutant exits 2"; else bad "a non-compiling mutant exits 2" "rc=$rc out=$out"; fi
case "$out" in *"invalid-mutant"*) ok "a build failure reports invalid-mutant";; *) bad "a build failure reports invalid-mutant" "$out";; esac
case "$out" in *"killed"*) bad "a non-compiling mutant is never killed" "$out";; *) ok "a non-compiling mutant is never killed";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'true' \
      --mutate 'true' --stability 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "omitting --build exits 2"; else bad "omitting --build exits 2" "rc=$rc out=$out"; fi

for option in --stability --threads --timeout; do
  for value in 0 nope ""; do
    rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'true' \
          --build 'true' --mutate 'true' "$option" "$value" 2>&1) || rc=$?
    if [ "$rc" = 2 ]; then
      ok "$option rejects '${value:-empty}'"
    else
      bad "$option rejects '${value:-empty}'" "rc=$rc out=$out"
    fi
  done
done

export HANG_PID_FILE="$TMP/control-build-timeout-child.pid"
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'true' \
      --build 'bash hang.sh & wait' --mutate 'true' --stability 1 \
      --timeout 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "a timed-out control build exits 2"; else bad "a timed-out control build exits 2" "rc=$rc out=$out"; fi
case "$out" in *"control build timed out after 1s"*) ok "the control-build timeout is reported";; *) bad "the control-build timeout is reported" "$out";; esac
case "$out" in *"build fails"*) bad "a control-build timeout is not a build failure" "$out";; *) ok "a control-build timeout is not a build failure";; esac
control_build_child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
if [ -n "$control_build_child" ] && stopped "$control_build_child"; then
  ok "the timed-out control build is reaped"
else
  bad "the timed-out control build is reaped" "pid=${control_build_child:-missing}"
  [ -z "$control_build_child" ] || kill -KILL "$control_build_child" 2>/dev/null || true
fi

export HANG_PID_FILE="$TMP/mutant-build-timeout-child.pid"
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'true' \
      --build 'grep -q "+" lib.sh || { bash hang.sh & wait; }' \
      --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 1 --timeout 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "a timed-out mutant build exits 2"; else bad "a timed-out mutant build exits 2" "rc=$rc out=$out"; fi
case "$out" in *"mutant build timed out after 1s"*) ok "the mutant-build timeout is reported";; *) bad "the mutant-build timeout is reported" "$out";; esac
case "$out" in *"invalid-mutant"*) bad "a mutant-build timeout is not an invalid mutant" "$out";; *) ok "a mutant-build timeout is not an invalid mutant";; esac
mutant_build_child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
if [ -n "$mutant_build_child" ] && stopped "$mutant_build_child"; then
  ok "the timed-out mutant build is reaped"
else
  bad "the timed-out mutant build is reaped" "pid=${mutant_build_child:-missing}"
  [ -z "$mutant_build_child" ] || kill -KILL "$mutant_build_child" 2>/dev/null || true
fi

export HANG_PID_FILE="$TMP/mutant-timeout-child.pid"
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" \
      --test 'grep -q "+" lib.sh || { bash hang.sh & wait; }' \
      --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 1 --timeout 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "a timed-out mutant exits 2"; else bad "a timed-out mutant exits 2" "rc=$rc out=$out"; fi
case "$out" in *"test timed out after 1s"*) ok "a timed-out mutant is an instrument failure";; *) bad "a timed-out mutant is an instrument failure" "$out";; esac
case "$out" in *"mutation: killed"*) bad "a timed-out mutant is never killed" "$out";; *) ok "a timed-out mutant is never killed";; esac
mutant_timeout_child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
if [ -n "$mutant_timeout_child" ] && stopped "$mutant_timeout_child"; then
  ok "the timed-out mutant process group is reaped"
else
  bad "the timed-out mutant process group is reaped" "pid=${mutant_timeout_child:-missing}"
  [ -z "$mutant_timeout_child" ] || kill -KILL "$mutant_timeout_child" 2>/dev/null || true
fi

export HANG_PID_FILE="$TMP/timeout-child.pid"
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" \
      --test 'bash hang.sh & wait' \
      --build 'true' --mutate 'true' --stability 1 --timeout 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "a hanging control times out"; else bad "a hanging control times out" "rc=$rc out=$out"; fi
case "$out" in *"timed out after 1s"*) ok "the timeout is reported";; *) bad "the timeout is reported" "$out";; esac
timeout_child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
if [ -n "$timeout_child" ] && stopped "$timeout_child"; then
  ok "the timed-out process is reaped"
else
  bad "the timed-out process is reaped" "pid=${timeout_child:-missing}"
  [ -z "$timeout_child" ] || kill -KILL "$timeout_child" 2>/dev/null || true
fi

export HANG_PID_FILE="$TMP/exit-child.pid"
"$MS" --worktree "$REPO" --sha "$SHA" \
  --test 'bash hang.sh & wait' \
  --build 'true' --mutate 'true' --stability 1 --timeout 30 >/dev/null 2>&1 &
ms_pid=$!
i=0
while [ ! -s "$HANG_PID_FILE" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
exit_child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
kill -TERM "$ms_pid" 2>/dev/null || true
wait "$ms_pid" 2>/dev/null || true
if [ -n "$exit_child" ] && stopped "$exit_child"; then
  ok "exit cleanup reaps the active test process"
else
  bad "exit cleanup reaps the active test process" "pid=${exit_child:-missing}"
  [ -z "$exit_child" ] || kill -KILL "$exit_child" 2>/dev/null || true
fi

# flaky test: passes only on its first run in a copy (state file marks reruns)
cat > "$REPO/check.sh" <<'T'
. ./lib.sh
[ "$(add 2 3)" = 5 ] || exit 1
[ ! -f .ran ] || exit 1
touch .ran
T
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm flaky
SHA2=$(git -C "$REPO" rev-parse HEAD)
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA2" --test 'bash check.sh' \
      --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 3 --threads 2) || rc=$?
if [ "$rc" = 1 ]; then ok "stability failure exits 1 even with the mutant killed"; else bad "stability failure exits 1 even with the mutant killed" "rc=$rc out=$out"; fi
case "$out" in *"stability: 1/3 at 2 threads") ok "partial stability is reported as Y/N";; *) bad "partial stability is reported as Y/N" "$out";; esac

export HANG_PID_FILE="$TMP/stability-timeout-child.pid"
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" \
      --test 'if grep -q "-" lib.sh; then exit 1; fi; if [ -f .ran ]; then bash hang.sh & wait; fi; touch .ran' \
      --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 2 --timeout 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "a timed-out stability run exits 2"; else bad "a timed-out stability run exits 2" "rc=$rc out=$out"; fi
case "$out" in *"test timed out after 1s"*) ok "the stability timeout is an instrument failure";; *) bad "the stability timeout is an instrument failure" "$out";; esac
case "$out" in *"mutation: killed"*) bad "a stability timeout prints no trusted summary" "$out";; *) ok "a stability timeout prints no trusted summary";; esac
stability_child=$(cat "$HANG_PID_FILE" 2>/dev/null || true)
if [ -n "$stability_child" ] && stopped "$stability_child"; then
  ok "the timed-out stability run is reaped"
else
  bad "the timed-out stability run is reaped" "pid=${stability_child:-missing}"
  [ -z "$stability_child" ] || kill -KILL "$stability_child" 2>/dev/null || true
fi

rc=0; "$MS" --worktree "$REPO" --sha "$SHA" --test 'true' --build 'true' --mutate 2>/dev/null || rc=$?
if [ "$rc" = 2 ]; then ok "a value-less option exits 2"; else bad "a value-less option exits 2" "rc=$rc"; fi

# A build cache the caller shares across both copies must answer neither run
# with the other's artifact. check.sh is that cache, keyed the way cargo's
# target dir is: it rebuilds for a source strictly newer than what it holds,
# in whole seconds, the coarsest granularity a filesystem or cache keeps. Both
# ways it can be wrong are here — the mutant reusing the control's build and
# surviving, the clean copy reusing the mutant's and failing.
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
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA3" --test 'bash check.sh' \
      --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 3 --threads 2) || rc=$?
if [ "$rc" = 0 ]; then ok "a shared whole-second build cache reaches the right verdict"; else bad "a shared whole-second build cache reaches the right verdict" "rc=$rc out=$out"; fi
case "$out" in "mutation: killed 1/1"*) ok "the mutant build rebuilds instead of reusing the control";; *) bad "the mutant build rebuilds instead of reusing the control" "$out";; esac
case "$out" in *"stability: 3/3 at 2 threads") ok "the clean copy rebuilds instead of reusing the mutant";; *) bad "the clean copy rebuilds instead of reusing the mutant" "$out";; esac

# A filesystem or cache that keeps whole seconds rounds an extraction and the
# build before it to the same second, and a cache rebuilds on a strictly newer
# source, not an equal one. Each copy is stamped a full second past the last.
kept=$("$MS" --worktree "$REPO" --sha "$SHA3" --test 'bash check.sh' \
      --build 'true' --mutate 'sed -i.bak "s/+/-/" lib.sh && rm -f lib.sh.bak' \
      --stability 1 --threads 2 --keep 2>&1 >/dev/null || true)
root=$(printf '%s\n' "$kept" | sed -n 's/^kept: //p')
if [ -d "$root/clean" ]; then
  gap=$(( $(stat -c %Y "$root/clean/check.sh") - $(stat -c %Y "$root/mutant/check.sh") ))
  rm -rf "$root"
  if [ "$gap" -ge 1 ]; then ok "each copy is stamped a whole second past the one before"; else bad "each copy is stamped a whole second past the one before" "gap=${gap}s"; fi
else
  bad "each copy is stamped a whole second past the one before" "--keep printed no temp dir: $kept"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
