#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOUNDED="$(cd "$TEST_DIR/.." && pwd)/scripts/lib/bounded.sh"
SELF="$TEST_DIR/$(basename "${BASH_SOURCE[0]}")"

if [[ "${KENDEX_BOUNDED_NONREAPING_PID1:-0}" != "1" ]] \
  && command -v unshare >/dev/null 2>&1 \
  && command -v python3 >/dev/null 2>&1 \
  && unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
  exec unshare --user --map-root-user --pid --fork --mount-proc \
    python3 -c '
import glob, os, subprocess, sys, time
env = os.environ.copy()
env["KENDEX_BOUNDED_NONREAPING_PID1"] = "1"
run = subprocess.run(["bash", sys.argv[1]], env=env)
time.sleep(0.1)
zombies = []
for path in glob.glob("/proc/[0-9]*/stat"):
    try:
        fields = open(path).read().split()
        if fields[2] == "Z" and fields[3] == "1":
            zombies.append((fields[0], fields[1], fields[4]))
    except (IndexError, OSError):
        pass
if zombies:
    print("FAIL  non-reaping PID 1 adopted zombies: %r" % (zombies,))
    sys.exit(1)
print("ok    non-reaping PID 1 adopted no zombies")
sys.exit(run.returncode)
' "$SELF"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

cat >"$TMP/worker.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$PID_FILE"
exec >/dev/null 2>&1
sleep 30
EOF
chmod +x "$TMP/worker.sh"

cat >"$TMP/wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$BOUNDED"
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
kendex_github_run_bounded 30 "$WORKER"
EOF
chmod +x "$TMP/wrapper.sh"

check_signal() {
  local signal="$1" expected="$2" rc child_pid="" tries=0
  local pid_file="$TMP/$signal.pid"
  set +e
  SIGNAL="$signal" BOUNDED="$BOUNDED" WORKER="$TMP/worker.sh" \
    WRAPPER="$TMP/wrapper.sh" PID_FILE="$pid_file" \
    bash -c '
      set -m
      "$WRAPPER" &
      wrapper=$!
      tries=0
      while [[ ! -s "$PID_FILE" && "$tries" -lt 100 ]]; do
        sleep 0.02
        tries=$((tries + 1))
      done
      kill -s "$SIGNAL" "$wrapper"
      wait "$wrapper"
      exit $?
    ' >"$TMP/$signal.out" 2>"$TMP/$signal.err"
  rc=$?
  set -e

  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s exits %s\n' "$signal" "$expected"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s exit: expected %s, got %s\n' "$signal" "$expected" "$rc"
  fi

  if [[ -s "$pid_file" ]]; then
    child_pid="$(<"$pid_file")"
  fi
  while [[ -n "$child_pid" ]] && kill -0 -- "-$child_pid" 2>/dev/null \
    && [[ "$tries" -lt 20 ]]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if [[ -n "$child_pid" ]] && kill -0 -- "-$child_pid" 2>/dev/null; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s left process group %s alive\n' "$signal" "$child_pid"
    kill -KILL -- "-$child_pid" 2>/dev/null || true
  elif [[ -n "$child_pid" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s cleaned process group %s\n' "$signal" "$child_pid"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s worker wrote no pid\n' "$signal"
  fi
}

echo "=== bounded runner signal cleanup ==="
check_signal HUP 129
check_signal INT 130
check_signal TERM 143

# The bound is enforced on a 0.1s tick, so a caller may ask for tenths. Junk
# is refused with 125 rather than run unbounded: a bound that silently stops
# bounding is how a hung `gh` becomes a hung lane.
check_bound() { # LABEL BOUND EXPECTED-RC [COMMAND...]
  local label="$1" bound="$2" expected="$3" rc=0
  shift 3
  [ "$#" -gt 0 ] || set -- sleep 30
  BOUNDED="$BOUNDED" BOUND="$bound" bash -c '
    source "$BOUNDED"
    kendex_github_run_bounded "$BOUND" "$@"
  ' bash "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s: expected %s, got %s\n' "$label" "$expected" "$rc"
  fi
}

echo "=== bounded runner bound parsing ==="
check_bound "a tenth-of-a-second bound times out" 0.2 124
check_bound "a whole-second bound times out" 1 124
# Under octal arithmetic 08 is not a number at all, so a command that finishes
# well inside the bound separates the two readings without waiting out either.
check_bound "a leading-zero bound is decimal, not octal" 08 0 true
check_bound "a two-place bound is refused" 0.25 125
check_bound "a bare decimal point is refused" . 125
check_bound "a trailing decimal point is refused" 5. 125
check_bound "a non-numeric bound is refused" soon 125
# Width is part of the grammar: this one multiplies out to exactly 0 in signed
# 64-bit arithmetic, and 0 is the documented way to ask for no bound at all.
check_bound "a bound too wide for the arithmetic is refused" 1844674407370955161.6 125 true
# Sub-second bounds must not have become "no bound at all": a zero bound is
# the documented way to ask for that, and nothing else may reach it.
check_bound "a zero bound runs the command unbounded" 0.0 0 true

# WHAT A CALLER CAPTURES IS THE CHILD'S TRANSCRIPT, not the runner's. Under job
# control bash called setpgid on the child from the parent, and when it lost
# that race with the child's own exec it printed
# `child setpgid (N to N): Operation not permitted` onto this stderr. On the
# macOS shard that line reddened a pin on a captured transcript and ejected an
# unrelated pull request from the merge queue.
#
# A GREEN LINUX RUN IS NOT EVIDENCE FOR THE PIN: the race never fires here. The
# planted row below is what shows the pin can go red at all, and the failing-
# child row is what shows it is not green because the transcript is discarded.
MIRROR="$TMP/mirror"
mkdir -p "$MIRROR"
cp "$(dirname "$BOUNDED")/group-leader.sh" "$MIRROR/group-leader.sh"
NOISY_BOUNDED="$MIRROR/bounded.sh"
sed 's|^  \(.*KENDEX_GROUP_LEADER.*&\)$|  echo "child setpgid (1 to 1): Operation not permitted" >\&2; \1|' \
  "$BOUNDED" > "$NOISY_BOUNDED"
if cmp -s "$BOUNDED" "$NOISY_BOUNDED"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  the parent-noise control mutated nothing\n'
elif [[ "$(grep -c 'child setpgid (1 to 1)' "$NOISY_BOUNDED")" != 1 ]]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  the parent-noise control planted more than one line\n'
elif ! bash -n "$NOISY_BOUNDED"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  the parent-noise control is not valid shell\n'
else
  PASS=$((PASS + 1)); printf '  ok    the parent-noise control plants exactly one parent-side line\n'
fi

check_transcript() { # LABEL RUNNER EXPECTED COMMAND...
  local label="$1" runner="$2" expected="$3" rc=0 actual
  shift 3
  BOUNDED="$runner" bash -c '
    source "$BOUNDED"
    kendex_github_run_bounded 30 "$@"
  ' bash "$@" >/dev/null 2>"$TMP/transcript.err" || rc=$?
  actual="rc=$rc;transcript=$(tr '\n' '|' <"$TMP/transcript.err")"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual"
  fi
}

echo "=== bounded runner transcript ==="
check_transcript "a silent child leaves the runner's stderr empty" \
  "$BOUNDED" "rc=0;transcript=" true
check_transcript "a failing child keeps its own status and stderr" \
  "$BOUNDED" "rc=3;transcript=boom|" bash -c 'printf "boom\n" >&2; exit 3'
check_transcript "a planted parent-side line reddens the empty pin" \
  "$NOISY_BOUNDED" \
  "rc=0;transcript=child setpgid (1 to 1): Operation not permitted|" true

# A TEARDOWN CAN ARRIVE WHILE THE CHILD IS STILL UNGROUPED. The child takes its
# group between the fork and its exec, so `kill -0 -- "-$pid"` can find nothing
# while the pid is very much alive; signalling the group alone would signal
# nothing and report success over a running child. Driven at the function with a
# child that shares this shell's group, which is the same state the window
# produces without racing it.
WINDOW_BOUNDED="$MIRROR/window-bounded.sh"
sed 's%^    kill -0 "\$pid" 2>/dev/null || return 0$%    return 0%' \
  "$BOUNDED" > "$WINDOW_BOUNDED"
if cmp -s "$BOUNDED" "$WINDOW_BOUNDED"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  the absent-group control mutated nothing\n'
elif ! bash -n "$WINDOW_BOUNDED"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  the absent-group control is not valid shell\n'
else
  PASS=$((PASS + 1)); printf '  ok    the absent-group control drops the ungrouped-child branch\n'
fi

check_window() { # LABEL RUNNER EXPECTED
  local label="$1" runner="$2" expected="$3" actual
  actual="$(BOUNDED="$runner" bash -c '
    sleep 30 &
    pid=$!
    source "$BOUNDED"
    _kendex_github_stop_bounded_group TERM "$pid"
    if kill -0 "$pid" 2>/dev/null; then
      printf alive
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    else
      printf gone
    fi
  ')"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s: expected %s, got %s\n' "$label" "$expected" "$actual"
  fi
}

echo "=== bounded teardown with the child still ungrouped ==="
check_window "an ungrouped child is stopped through its own pid" "$BOUNDED" gone
check_window "the absent-group control leaves it running" "$WINDOW_BOUNDED" alive

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
