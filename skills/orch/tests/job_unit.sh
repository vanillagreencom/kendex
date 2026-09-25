#!/usr/bin/env bash
# Tests for lib/job-unit.sh through its executable interface, the contract a
# markdown recipe calls: --help, name, launch, stop and kill-group. The
# containment each runner gives, the fallbacks behind a failing systemd-run,
# and each rule --stop applies are pinned through dev-validate-run, which
# sources the same functions, in dev_validate_run.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB_UNIT="$TEST_DIR/../scripts/lib/job-unit.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

OUT=""
ERR=""
RC=0
run() { # SCRIPT ARG...
  set +e
  OUT="$("$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}

# A copy of the executable with one literal substitution applied, for the
# controls. The counts are the edit's proof.
MUTANT=""
mutant() { # NAME OLD NEW
  MUTANT="$TMP_ROOT/$1.sh"
  assert_eq "$(grep -c -F -- "$2" "$JOB_UNIT")" "1" "control $1 finds one line to mutate"
  awk -v old="$2" -v new="$3" '{
    i = index($0, old)
    if (i > 0) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) }
    print
  }' "$JOB_UNIT" > "$MUTANT"
  chmod +x "$MUTANT"
  assert_eq "$(grep -c -F -- "$2" "$MUTANT")" "0" "control $1 applied its mutation"
}

echo "=== job-unit executable ==="

run "$JOB_UNIT" --help
assert_eq "$RC $(sed -n 1p <<<"$OUT")" "0 job-unit.sh — start a long-lived orch job so no process it starts outlives" \
  "--help prints the header and exits 0"
assert_eq "$(grep -c -E '^  job-unit\.sh (name|launch|end|stop|kill-group|stop-job) ' <<<"$OUT")" "6" \
  "and names every subcommand"
run "$JOB_UNIT" launch validate-x
assert_eq "$RC $ERR" "3 job-unit: usage subcommand=launch" "a launch missing its arguments is refused as usage"

# --- The unit name shape ---------------------------------------------------------
# name|pid|unit name
NAME_ROWS=(
  'validate-ken-1784|180993|orch-validate-ken-1784-180993'
  'validate-proj-${HOME}|1|orch-validate-proj-__HOME_-1'
  'watch a b/c|7|orch-watch_a_b_c-7'
)
for row in "${NAME_ROWS[@]}"; do
  IFS='|' read -r name pid want <<<"$row"
  run "$JOB_UNIT" name "$name" "$pid"
  assert_eq "$OUT" "$want" "name '$name' and pid $pid name the unit $want"
done
mutant no-sanitize "| LC_ALL=C tr -c 'A-Za-z0-9_.-' '_'" ''
run "$MUTANT" name 'watch a b/c' 7
assert_eq "$OUT" "orch-watch a b/c-7" "control: unsanitized, the name's spaces and slash reach the unit name"

# --- A launch where no systemd-run is installed ------------------------------------
# A PATH holding what the setsid launch and its job call, and no systemd-run.
FARM="$TMP_ROOT/farm"
mkdir -p "$FARM"
for name in bash setsid sleep mv tr; do
  ln -sf "$(command -v "$name")" "$FARM/$name"
done
wait_pid() { # FILE — the pid the job wrote, once it has
  local n=0
  while [[ ! -s "$1" ]] && (( n < 50 )); do sleep 0.1; n=$((n + 1)); done
  cat "$1" 2>/dev/null || true
}

if command -v setsid >/dev/null 2>&1; then
  record="$TMP_ROOT/setsid.record"
  pidfile="$TMP_ROOT/setsid.pid"
  run env PATH="$FARM" "$JOB_UNIT" launch validate-id-1 "$record" --cap 60 \
    -- bash -c 'echo $$ > "$0"; exec sleep 30' "$pidfile"
  assert_eq "$RC $OUT" "0 runner=setsid reason=no-systemd-run" \
    "a launch with no systemd-run prints the setsid runner line"
  assert_eq "$(cat "$record")" "$(printf 'runner=setsid\nline=runner=setsid reason=no-systemd-run')" \
    "and records that runner and line, with no unit"
  job_pid="$(wait_pid "$pidfile")"
  assert_eq "$([[ "$job_pid" =~ ^[0-9]+$ ]] && kill -0 "$job_pid" 2>/dev/null && echo running || echo absent)" "running" \
    "and the job runs"

  # kill-group: the job leads its group, and its argv decides whether it is
  # the one meant.
  # argv glob|exit|the job after
  KILL_ROWS=(
    "*sleep 29|1|alive"
    "*sleep 30|0|gone"
  )
  for row in "${KILL_ROWS[@]}"; do
    IFS='|' read -r glob want_rc want_state <<<"$row"
    run "$JOB_UNIT" kill-group "$job_pid" "$glob"
    sleep 0.2
    assert_eq "$RC $(kill -0 "$job_pid" 2>/dev/null && echo alive || echo gone)" "$want_rc $want_state" \
      "kill-group with argv glob '$glob' exits $want_rc and leaves the job $want_state"
  done
else
  echo "  skip  setsid is not installed; the setsid launch rows did not run"
fi

# --- A launch where a user manager answers ------------------------------------------
# Which runner this host gives is read off the executable's own answer: a host
# where no manager answers skips these rows, saying so.
record="$TMP_ROOT/unit.record"
run "$JOB_UNIT" launch validate-id-2 "$record" --cap 60 -- sleep 30
if [[ "$(sed -n 's/^runner=//p' "$record" 2>/dev/null)" == systemd ]]; then
  unit="$(sed -n 's/^unit=//p' "$record")"
  assert_eq "$RC ${unit%-*}-PID $OUT" "0 orch-validate-id-2-PID runner=systemd unit=$unit" \
    "a launch where a user manager answers prints runner=systemd with a unit of the documented shape"
  assert_eq "$(cat "$record")" "$(printf 'runner=systemd\nunit=%s\nline=runner=systemd unit=%s' "$unit" "$unit")" \
    "and records that runner, unit and line"
  assert_eq "$(systemctl --user is-active -- "$unit.service" 2>/dev/null || true)" "active" \
    "and that unit is running the job"
  # exit of the first stop, then of a second stop of the same name
  STOP_ROWS=("0|a running unit is stopped by its exact name" "1|a unit that has ended answers not-found, apart from a failure")
  for row in "${STOP_ROWS[@]}"; do
    IFS='|' read -r want label <<<"$row"
    run "$JOB_UNIT" stop "$unit"
    assert_eq "$RC" "$want" "$label"
  done
  assert_eq "$(systemctl --user is-active -- "$unit.service" 2>/dev/null || true)" "inactive" \
    "and the unit is gone"

  # Control: a manager's not-found read as a failure.
  mutant no-not-found '&& [[ "$load" == not-found ]]; then' '&& false; then'
  run "$MUTANT" stop "$unit"
  assert_eq "$RC $(sed 's/ detail=.*$//' <<<"$ERR")" "2 job-unit: stop-failed unit=$unit.service" \
    "control: without the not-found read an ended unit is a stop failure, named on stderr"
else
  echo "  skip  no systemd user manager answers on this host ($(sed -n 's/^line=//p' "$record" 2>/dev/null)); the unit rows did not run"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
