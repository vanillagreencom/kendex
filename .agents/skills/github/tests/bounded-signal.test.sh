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

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
