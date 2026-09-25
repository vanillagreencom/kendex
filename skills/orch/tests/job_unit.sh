#!/usr/bin/env bash
# Tests for lib/job-unit.sh called directly, as any orch job calls it: the
# runner a launch answers and records, the unit name shape
# references/job-units.md states, and a stop by the exact recorded name. The
# containment each runner gives and the fallbacks behind a failing
# systemd-run are pinned through dev-validate-run in dev_validate_run.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../scripts/lib/job-unit.sh"
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

# A copy of the library with one literal substitution applied, for the
# controls. The counts are the edit's proof.
MUTANT=""
mutant() { # NAME OLD NEW
  MUTANT="$TMP_ROOT/$1.sh"
  assert_eq "$(grep -c -F -- "$2" "$LIB")" "1" "control $1 finds one line to mutate"
  awk -v old="$2" -v new="$3" '{
    i = index($0, old)
    if (i > 0) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) }
    print
  }' "$LIB" > "$MUTANT"
  assert_eq "$(grep -c -F -- "$2" "$MUTANT")" "0" "control $1 applied its mutation"
}

echo "=== job-unit library ==="

# --- The unit name shape ---------------------------------------------------------
# kind|id|stamp|name
NAME_ROWS=(
  'validate|ken-1784|20260925T041553Z-180993|validate-ken-1784-20260925T041553Z-180993'
  'validate|proj-${HOME}|20260925T041553Z-1|validate-proj-__HOME_-20260925T041553Z-1'
  'watch|a b/c|7|watch-a_b_c-7'
)
for row in "${NAME_ROWS[@]}"; do
  IFS='|' read -r kind id stamp want <<<"$row"
  assert_eq "$(source "$LIB" && job_unit_name "$kind" "$id" "$stamp")" "$want" \
    "kind $kind, id '$id' and stamp $stamp name the unit $want"
done
mutant no-sanitize "| LC_ALL=C tr -c 'A-Za-z0-9_.-' '_'" ''
assert_eq "$(source "$MUTANT" && job_unit_name validate 'a b/c' 7)" "validate-a b/c-7" \
  "control: unsanitized, the id's space and slash reach the unit name"

# --- A launch where no systemd-run is installed ------------------------------------
# A PATH holding what the setsid launch and its job call, and no systemd-run.
FARM="$TMP_ROOT/farm"
mkdir -p "$FARM"
for name in bash setsid sleep mv; do
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
  got="$(PATH="$FARM" && source "$LIB" \
    && job_unit_launch testjob id-1 S1 60 "$record" -- bash -c 'echo $$ > "$0"; exec sleep 30' "$pidfile" \
    && printf '%s|%s|%s' "$JOB_UNIT_RUNNER" "$JOB_UNIT_NAME" "$JOB_UNIT_LINE")"
  assert_eq "$got" "setsid||runner=setsid reason=no-systemd-run" \
    "a launch with no systemd-run answers the setsid runner line and no unit"
  assert_eq "$(cat "$record")" "$(printf 'runner=setsid\nline=runner=setsid reason=no-systemd-run')" \
    "and records that runner and line"
  job_pid="$(wait_pid "$pidfile")"
  assert_eq "$([[ "$job_pid" =~ ^[0-9]+$ ]] && kill -0 "$job_pid" 2>/dev/null && echo running || echo absent)" "running" \
    "and the job runs"
  [[ ! "$job_pid" =~ ^[0-9]+$ ]] || kill -KILL "$job_pid" 2>/dev/null || true
else
  echo "  skip  setsid is not installed; the setsid launch row did not run"
fi

# --- A launch where a user manager answers ------------------------------------------
# Which runner this host gives is read off the library's own answer: a host
# where no manager answers skips these rows, saying so.
record="$TMP_ROOT/unit.record"
(source "$LIB" && job_unit_launch testjob id-2 "S$$" 60 "$record" -- sleep 30) || true
if [[ "$(sed -n 's/^runner=//p' "$record" 2>/dev/null)" == systemd ]]; then
  unit="testjob-id-2-S$$"
  assert_eq "$(cat "$record")" "$(printf 'runner=systemd\nunit=%s\nline=runner=systemd unit=%s' "$unit" "$unit")" \
    "a launch where a user manager answers records runner=systemd and a unit of the documented shape"
  assert_eq "$(systemctl --user is-active -- "$unit.service" 2>/dev/null || true)" "active" \
    "and that unit is running the job"
  # status of the first stop, then of a second stop of the same name
  STOP_ROWS=("0|a running unit is stopped by its exact name" "1|a unit that has ended answers not-found, apart from a failure")
  for row in "${STOP_ROWS[@]}"; do
    IFS='|' read -r want label <<<"$row"
    rc=0
    (source "$LIB" && job_unit_stop "$unit") || rc=$?
    assert_eq "$rc" "$want" "$label"
  done
  assert_eq "$(systemctl --user is-active -- "$unit.service" 2>/dev/null || true)" "inactive" \
    "and the unit is gone"

  # Control: a manager's not-found read as a failure.
  mutant no-not-found '&& [[ "$load" == not-found ]]; then' '&& false; then'
  rc=0
  (source "$MUTANT" && job_unit_stop "$unit") || rc=$?
  assert_eq "$rc" "2" "control: without the not-found read an ended unit is a stop failure"
else
  echo "  skip  no systemd user manager answers on this host ($(sed -n 's/^line=//p' "$record" 2>/dev/null)); the unit rows did not run"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
