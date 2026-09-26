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
# A user manager is used only where it lingers, which this host's may not:
# every row reaches it through a loginctl that says it does, except the rows
# that plant their own answer.
mkdir -p "$TMP_ROOT/linger"
printf '#!/bin/sh\necho yes\n' > "$TMP_ROOT/linger/loginctl"
chmod +x "$TMP_ROOT/linger/loginctl"
export PATH="$TMP_ROOT/linger:$PATH"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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
# controls: one per subcommand that has one, name, launch and stop, and one for
# the kill_sites reading below. The counts are the edit's proof.
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
# A cap is optional and, given, a positive whole number; a launch names a job.
# launch arguments|label
while IFS='|' read -r args label; do
  # shellcheck disable=SC2086 # the arguments column is words
  run "$JOB_UNIT" launch $args
  assert_eq "$RC $ERR" "3 job-unit: usage subcommand=launch" "$label"
done <<ROWS
validate-x $TMP_ROOT/usage.record --cap 0 -- true|a zero cap is refused as usage
validate-x $TMP_ROOT/usage.record --cap -- true|a cap with no number is refused as usage
validate-x $TMP_ROOT/usage.record --|a launch with no command is refused as usage
validate-x $TMP_ROOT/usage.record --memory-max 0 -- true|a zero memory bound is refused as usage
ROWS

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

  # No process group holds a memory bound, so a launch that would run under
  # setsid refuses one, naming its runner line, and starts nothing.
  rm -f -- "${TMP_ROOT:?}/memory.record"
  run env PATH="$FARM" "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/memory.record" --memory-max 512 -- true
  assert_eq "$RC $ERR $([[ -e "$TMP_ROOT/memory.record" ]] && echo recorded || echo unrecorded)" \
    "5 job-unit: memory-max-unheld runner=setsid reason=no-systemd-run unrecorded" \
    "a --memory-max launch that would run under setsid exits 5 as memory-max-unheld and starts nothing"
else
  echo "  skip  setsid is not installed; the setsid launch rows did not run"
fi

# A systemd-run that fails after the probe answered, as a client-side timeout
# does while the manager may still start the unit. The manager's word on the
# recorded name decides: a unit it has is the job, one it has no record of
# falls back to setsid, and no answer fails the launch rather than risk a
# second copy of the job. The stubs stand for systemd-run and for the manager.
TIMED_OUT="$TMP_ROOT/timed-out"
mkdir -p "$TIMED_OUT"
printf '#!/usr/bin/env bash\n[[ "${*: -1}" == true ]] && exit 0\necho "Failed to start transient service unit: Connection timed out" >&2\nexit 1\n' > "$TIMED_OUT/systemd-run"
printf '#!/usr/bin/env bash\n[[ "$STUB_LOAD" != none ]] || exit 1\nprintf "%%s\\n" "$STUB_LOAD"\n' > "$TIMED_OUT/systemctl"
cp "$TMP_ROOT/linger/loginctl" "$TIMED_OUT/loginctl"
chmod +x "$TIMED_OUT/systemd-run" "$TIMED_OUT/systemctl"
# What a launch answers, its unit's pid folded to PID: exit, stdout, stderr and
# the record's runner.
timed_out_launch() { # STUB_LOAD
  record="$TMP_ROOT/timed-out.record"
  rm -f -- "$record"
  run env PATH="$TIMED_OUT:$FARM" STUB_LOAD="$1" "$JOB_UNIT" launch validate-id-9 "$record" --cap 60 -- bash -c :
  printf '%s|%s|%s|%s' "$RC" "$OUT" "$ERR" "$(sed -n 's/^runner=//p' "$record" 2>/dev/null)" \
    | sed 's/orch-validate-id-9-[0-9]*/orch-validate-id-9-PID/g'
}
if command -v setsid >/dev/null 2>&1; then
  detail="detail=Failed to start transient service unit: Connection timed out"
  # manager's answer|what the launch answers|label
  TIMED_OUT_ROWS=(
    "loaded%0|runner=systemd unit=orch-validate-id-9-PID||systemd%a unit the manager has after a failed call is the job, never a second copy"
    "not-found%0|runner=setsid reason=unit-launch-failed $detail||setsid%a unit the manager has no record of falls back to setsid"
    "none%4||job-unit: launch-failed unit=orch-validate-id-9-PID.service step=show $detail|systemd%a manager that does not answer fails the launch"
  )
  for row in "${TIMED_OUT_ROWS[@]}"; do
    IFS='%' read -r load want label <<<"$row"
    assert_eq "$(timed_out_launch "$load")" "$want" "$label"
  done
fi

# Every SIGKILL the library sends is job_unit_teardown's, after its SIGTERM and
# grace, so no setsid teardown can send SIGKILL alone. The floor names a broken
# extractor, not a missing site.
kill_sites() { # SCRIPT — `1 1`: the teardown holds a SIGKILL, and holds every one
  local teardown all
  teardown="$(awk '/^job_unit_teardown[(][)]/ { on = 1 } on { print } on && /^}/ { exit }' "$1" | grep -c 'kill -KILL' || true)"
  all="$(grep -c 'kill -KILL' "$1" || true)"
  printf '%s %s' "$(( teardown >= 1 ))" "$(( all == teardown ))"
}
assert_eq "$(kill_sites "$JOB_UNIT")" "1 1" "every SIGKILL in job-unit.sh is inside job_unit_teardown"
mutant kill-alone '  job_unit_teardown "$pid"' '  kill -KILL -- "-$pid"'
assert_eq "$(kill_sites "$MUTANT")" "1 0" "control: a SIGKILL sent outside the teardown is found"

# stop-job on a record the library cannot read is a failure, named.
printf 'runner=bogus\n' > "$TMP_ROOT/bogus.record"
run "$JOB_UNIT" stop-job "$TMP_ROOT/bogus.record" 1 "*"
assert_eq "$RC $ERR" "2 job-unit: record-unreadable path=$TMP_ROOT/bogus.record" \
  "stop-job on an unreadable record exits 2 and names it"

# A user manager that does not linger, or whose Linger cannot be read, is
# passed over for setsid: it would stop every unit when the last login session
# ends. The stubs stand for a systemd-run that would start anything and for
# loginctl's answer.
if command -v setsid >/dev/null 2>&1; then
  mkdir -p "$TMP_ROOT/no-linger" "$TMP_ROOT/linger-unread"
  printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/no-linger/systemd-run"
  printf '#!/bin/sh\necho no\n' > "$TMP_ROOT/no-linger/loginctl"
  cp "$TMP_ROOT/no-linger/systemd-run" "$TMP_ROOT/linger-unread/systemd-run"
  printf '#!/bin/sh\necho "Failed to connect to bus: No such file or directory" >&2\nexit 1\n' > "$TMP_ROOT/linger-unread/loginctl"
  chmod +x "$TMP_ROOT"/no-linger/* "$TMP_ROOT"/linger-unread/*
  # stub dir|the runner line, its unit's pid folded|label
  while IFS='|' read -r stub want label; do
    run env PATH="$TMP_ROOT/$stub:$FARM" "$JOB_UNIT" launch validate-linger "$TMP_ROOT/linger.record" -- true
    assert_eq "$RC $(sed 's/-[0-9]*$/-PID/' <<<"$OUT")" "$want" "$label"
  done <<ROWS
no-linger|0 runner=setsid reason=no-linger|a manager that does not linger is passed over for setsid
linger-unread|0 runner=setsid reason=linger-unread detail=Failed to connect to bus: No such file or directory|a Linger loginctl cannot read is no linger, named with loginctl's words
ROWS
  # A capped job, bounded anyway, keeps its unit where the manager does not
  # linger.
  run env PATH="$TMP_ROOT/no-linger:$FARM" "$JOB_UNIT" launch validate-linger "$TMP_ROOT/linger.record" --cap 60 -- true
  assert_eq "$RC $(sed 's/-[0-9]*$/-PID/' <<<"$OUT")" "0 runner=systemd unit=orch-validate-linger-PID" \
    "a capped launch keeps its unit where the manager does not linger"
fi

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

  # --cap is the unit's RuntimeMaxSec, and a launch with none, the repeat
  # watch's, sets none.
  unit_property() { # PROPERTY ARG... — exit and PROPERTY of the unit launched
    local prop="$1" rec="$TMP_ROOT/cap.record" u
    shift
    rm -f -- "${rec:?}"
    run "$JOB_UNIT" "$@" -- sleep 30
    u="$(sed -n 's/^unit=//p' "$rec" 2>/dev/null)"
    printf '%s %s' "$RC" "$(systemctl --user show -p "$prop" --value -- "${u:-none}.service" 2>/dev/null)"
    [[ -z "$u" ]] || "$JOB_UNIT" stop "$u" >/dev/null 2>&1 || true
  }
  # cap arguments|RuntimeMaxUSec|label
  while IFS='|' read -r cap want label; do
    # shellcheck disable=SC2086 # the cap column is words
    assert_eq "$(unit_property RuntimeMaxUSec launch validate-cap "$TMP_ROOT/cap.record" $cap)" "$want" "$label"
  done <<ROWS
--cap 60|0 1min|a launch with --cap sets that RuntimeMaxSec
|0 infinity|a launch with no --cap sets no RuntimeMaxSec
ROWS
  # --memory-max is the unit's MemoryMax in MiB, and a launch with none sets none.
  while IFS='|' read -r mem want label; do
    # shellcheck disable=SC2086 # the memory column is words
    assert_eq "$(unit_property MemoryMax launch validate-memory "$TMP_ROOT/cap.record" $mem)" "$want" "$label"
  done <<ROWS
--memory-max 512|0 536870912|a launch with --memory-max 512 sets MemoryMax=536870912
|0 infinity|a launch with no --memory-max sets no MemoryMax
ROWS

  # A service ignores SIGPIPE by default; a unit job takes it at its default,
  # as a job the caller starts does. SigIgn bit 13 is SIGPIPE.
  sigpipe_state() {
    local out="$TMP_ROOT/sigign.$RANDOM" n=0
    run "$JOB_UNIT" launch validate-sigpipe "$TMP_ROOT/sigpipe.record" -- sh -c 'sed -n "s/^SigIgn:[[:space:]]*//p" /proc/self/status > "$0"' "$out"
    while [[ ! -s "$out" ]] && (( n < 50 )); do sleep 0.1; n=$((n + 1)); done
    if [[ -s "$out" ]]; then
      (( (16#$(cat "$out") >> 12) & 1 )) && echo ignored || echo default
    else
      echo unread
    fi
  }
  assert_eq "$(sigpipe_state)" "default" "a unit job takes SIGPIPE at its default"
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
