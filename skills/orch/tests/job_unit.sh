#!/usr/bin/env bash
# Tests for lib/job-unit.sh through its executable interface, the contract a
# markdown recipe calls: --help, name, launch, end, stop, kill-group and
# stop-job. The
# containment each runner gives, the fallbacks behind a failing systemd-run,
# and each rule --stop applies are pinned through dev-validate-run, which
# sources the same functions, in dev_validate_run.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"

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
assert_eq "$RC $(sed -n '1s/ — .*$//p' <<<"$OUT")" "0 job-unit.sh" \
  "--help prints the header, which opens on the script's name, and exits 0"
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

# One job launched under setsid, writing its pid where the row can read it.
JOB_PID=""
launch_setsid_job() { # RECORD PIDFILE
  run env PATH="$FARM" "$JOB_UNIT" launch validate-id-1 "$1" --cap 60 \
    -- bash -c 'echo $$ > "$0"; exec sleep 30' "$2"
  JOB_PID="$(wait_pid "$2")"
}

if command -v setsid >/dev/null 2>&1; then
  record="$TMP_ROOT/setsid.record"
  launch_setsid_job "$record" "$TMP_ROOT/setsid-1.pid"
  assert_eq "$RC $OUT" "0 runner=setsid reason=no-systemd-run" \
    "a launch with no systemd-run prints the setsid runner line"
  assert_eq "$(cat "$record")" "$(printf 'runner=setsid\nline=runner=setsid reason=no-systemd-run')" \
    "and records that runner and line, with no unit"
  assert_eq "$([[ "$JOB_PID" =~ ^[0-9]+$ ]] && kill -0 "$JOB_PID" 2>/dev/null && echo running || echo absent)" "running" \
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
    run "$JOB_UNIT" kill-group "$JOB_PID" "$glob"
    assert_eq "$RC $(proc_state_after "$JOB_PID")" "$want_rc $want_state" \
      "kill-group with argv glob '$glob' exits $want_rc and leaves the job $want_state"
  done

  # stop-job on the record a setsid launch wrote stops that job's group.
  launch_setsid_job "$record" "$TMP_ROOT/setsid-2.pid"
  run "$JOB_UNIT" stop-job "$record" "$JOB_PID" "*sleep 30"
  assert_eq "$RC $(proc_state_after "$JOB_PID")" "0 gone" \
    "stop-job on a setsid record kills the job's group"

  # end is the job's own last call, here made for it: its group ends.
  launch_setsid_job "$record" "$TMP_ROOT/setsid-3.pid"
  run "$JOB_UNIT" end "$record" "$JOB_PID"
  assert_eq "$RC $(proc_state_after "$JOB_PID")" "0 gone" \
    "end on a setsid record kills the group its leader names"

  # A setsid that cannot start the job is a launch failure, by name.
  mkdir -p "$TMP_ROOT/failing-setsid"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/failing-setsid/setsid"
  chmod +x "$TMP_ROOT/failing-setsid/setsid"
  run env PATH="$TMP_ROOT/failing-setsid:$FARM" "$JOB_UNIT" launch validate-id-1 "$record" --cap 60 -- sleep 30
  assert_eq "$RC $ERR" "4 job-unit: launch-failed status=1" \
    "a setsid that cannot start the job exits 4 as launch-failed"
  mutant no-launch-failed '|| job_unit_fail launch-failed "status=$?" 4' ''
  run env PATH="$TMP_ROOT/failing-setsid:$FARM" "$MUTANT" launch validate-id-1 "$record" --cap 60 -- sleep 30
  assert_eq "$RC $ERR" "1 " \
    "control: without its own status a failed launch reads as the record-unwritable status"
else
  echo "  skip  setsid is not installed; the setsid launch rows did not run"
fi

# stop-job on a record the library cannot read is a failure, named.
printf 'runner=bogus\n' > "$TMP_ROOT/bogus.record"
run "$JOB_UNIT" stop-job "$TMP_ROOT/bogus.record" 1 "*"
assert_eq "$RC $ERR" "2 job-unit: record-unreadable path=$TMP_ROOT/bogus.record" \
  "stop-job on an unreadable record exits 2 and names it"

# With neither systemd-run nor setsid there is no runner, and the launch says
# which command is missing.
NO_RUNNER="$TMP_ROOT/no-runner"
mkdir -p "$NO_RUNNER"
for name in bash mv tr; do
  ln -sf "$(command -v "$name")" "$NO_RUNNER/$name"
done
run env PATH="$NO_RUNNER" "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/none.record" --cap 60 -- sleep 30
assert_eq "$RC $ERR" "2 job-unit: missing-command commands=setsid" \
  "a host with neither runner exits 2 naming setsid"

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
