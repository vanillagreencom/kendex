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

# A SIGINT SENT BY kill(2) CAN BE LOST ON BASH 3.2, the macOS shard's shell.
# While the runner waits on its foreground `sleep 0.1` poll, bash swaps its own
# SIGINT handler in for the trap and judges the signal once the sleep is reaped.
# One that lands after that judgement and before the trap is put back sets a
# flag nothing reads, so the runner never forwards it and runs to its bound:
# `INT exit: expected 130, got 0` after the full 30 seconds. HUP and TERM take
# no such detour. Stock, the window is the few statements between the two; a
# bash 3.2 build that holds it open 50ms per poll lost 4 of 20 INTs sent at
# random points.
#
# So where the bash that runs wrapper.sh, found on PATH as its shebang finds
# it, is older than 4, the INT row resends, as a person pressing ^C again
# would; on any newer bash it sends one INT, and a runner that does not honour
# that first INT fails the row. A resend waits until the worker's group has
# outlived DROP_PROOF seconds since the last INT. A delivered INT has the
# runner signal that group on its first stop pass, ahead of the runner's
# one-second grace, so no resend lands inside a forward already under way.
# Each resend waits a random part of the runner's 0.1s poll first: a fixed
# DROP_PROOF can fall on the same point of that poll as the INT it replaces,
# and the widened build then lost the resend too in six drops of seven. A
# runner that never forwards INT still runs to its bound across every resend.
# One that exits without stopping the group gets no resend, since a dropped INT
# always leaves the wrapper running, and the cleanup row below finds the group
# it left.
check_signal() { # SIGNAL EXPECTED [RESENDS]
  local signal="$1" expected="$2" resends="${3:-0}" rc child_pid="" tries=0
  local pid_file="$TMP/$signal.pid" resent_file="$TMP/$signal.resent" resent=""
  set +e
  SIGNAL="$signal" BOUNDED="$BOUNDED" WORKER="$TMP/worker.sh" \
    WRAPPER="$TMP/wrapper.sh" PID_FILE="$pid_file" \
    RESENDS="$resends" RESENT_FILE="$resent_file" DROP_PROOF=3 \
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
      if [[ "$RESENDS" -gt 0 && -s "$PID_FILE" ]]; then
        worker="$(<"$PID_FILE")"
        sent=0
        while [[ "$sent" -lt "$RESENDS" ]]; do
          tries=0
          while kill -0 -- "-$worker" 2>/dev/null \
            && [[ "$tries" -lt $((DROP_PROOF * 20)) ]]; do
            sleep 0.05
            tries=$((tries + 1))
          done
          kill -0 "$wrapper" 2>/dev/null || break
          kill -0 -- "-$worker" 2>/dev/null || break
          sleep "0.0$((RANDOM % 10))"
          kill -s "$SIGNAL" "$wrapper"
          sent=$((sent + 1))
        done
        printf "%s" "$sent" >"$RESENT_FILE"
      fi
      wait "$wrapper"
      exit $?
    ' >"$TMP/$signal.out" 2>"$TMP/$signal.err"
  rc=$?
  set -e

  if [[ -s "$resent_file" && "$(<"$resent_file")" != 0 ]]; then
    resent=" after $(<"$resent_file") resend(s) of a dropped $signal"
  fi
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s exits %s%s\n' "$signal" "$expected" "$resent"
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

WRAPPER_BASH_MAJOR="$(bash -c 'printf "%s" "${BASH_VERSINFO[0]}"')" \
  || { echo "bounded-signal: wrapper-bash=unreadable" >&2; exit 1; }
[[ "$WRAPPER_BASH_MAJOR" =~ ^[0-9]+$ ]] \
  || { echo "bounded-signal: wrapper-bash=[$WRAPPER_BASH_MAJOR] is not a major version" >&2; exit 1; }
INT_RESENDS=0
if [[ "$WRAPPER_BASH_MAJOR" -lt 4 ]]; then
  INT_RESENDS=2
fi

echo "=== bounded runner signal cleanup ==="
check_signal HUP 129
check_signal INT 130 "$INT_RESENDS"
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
