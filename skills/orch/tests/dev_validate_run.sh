#!/usr/bin/env bash
# Tests for dev-validate-run, the bounded runner a dev agent validates through.
#
# The script runs DEV_VALIDATE_CMD under DEV_VALIDATE_TIMEOUT_SECS, detaches it,
# and records one `guard-exit=N at=TIME` sentinel beside the log. A waiter reads
# the verdict from that file, with a cap derived from the setting rather than
# chosen by the agent. The rows below pin each of those.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/skills/orch/scripts"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

RUN="$SCRIPTS_DIR/dev-validate-run"

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3" extra="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    [[ -z "$extra" ]] || printf '        stderr:   %s\n' "$extra"
  fi
}

# A project whose settings carry one validation command and one bound. The
# environment is passed explicitly so a developer's own DEV_VALIDATE_* never
# reaches the run: orch-env reads the process environment first.
make_proj() { # NAME CMD TIMEOUT_SECS
  local dir="$TMP_ROOT/$1"
  git init -q "$dir"
  {
    printf '[env]\n'
    printf 'DEV_VALIDATE_CMD = "%s"\n' "$2"
    printf 'DEV_VALIDATE_TIMEOUT_SECS = "%s"\n' "$3"
  } > "$dir/kendex.settings.toml"
  printf '%s\n' "$dir"
}

OUT=""
ERR=""
RC=0
run_script() { # SCRIPT ARG...
  local script="$1"
  shift
  set +e
  OUT="$(env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS "$script" "$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}

# The run directory the start line names, which every later read addresses.
run_dir_of() { # OUTPUT
  sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$1"
}

# The verdict fields a caller acts on, in a fixed order, from the last line.
verdict_of() { # OUTPUT
  sed -n 's/^\(state=[a-z]*\) \(guard-exit=[0-9]*\) at=[^ ]* \(validate=[A-Za-z]*\).*$/\1 \2 \3/p;s/^\(state=timeout\) elapsed-secs=[0-9]* cap-secs=\([0-9]*\) \(validate=[A-Za-z]*\).*$/\1 cap-secs=\2 \3/p;s/^\(state=running\) elapsed-secs=[0-9]* \(cap-secs=[0-9]*\).*$/\1 \2/p' <<<"$1" | sed -n '$p'
}

# A copy of the script with one literal substitution applied, for the controls.
# The count assertions are the edit's proof: a pattern that stopped matching
# would otherwise leave the control running the shipped code and passing. The
# copy's path lands in MUTANT rather than on stdout, which the assertions own.
MUTANT=""
mutant() { # NAME OLD NEW
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/lib"
  cp "$SCRIPTS_DIR/dev-validate-run" "$SCRIPTS_DIR/orch-env" "$dir/"
  cp "$SCRIPTS_DIR/lib"/*.sh "$dir/lib/"
  chmod +x "$dir/dev-validate-run" "$dir/orch-env"
  assert_eq "$(grep -c -F -- "$2" "$dir/dev-validate-run")" "1" "control $1 finds one line to mutate"
  awk -v old="$2" -v new="$3" '{
    i = index($0, old)
    if (i > 0) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) }
    print
  }' "$dir/dev-validate-run" > "$dir/mutated"
  mv "$dir/mutated" "$dir/dev-validate-run"
  chmod +x "$dir/dev-validate-run"
  assert_eq "$(grep -c -F -- "$2" "$dir/dev-validate-run")" "0" "control $1 applied its mutation"
  MUTANT="$dir/dev-validate-run"
}

echo "=== dev-validate-run bounded validation runner ==="

for dep in timeout setsid; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "  skip  $dep is not installed; the runner rows did not run"
    printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
    exit 0
  fi
done

# --- The verdict a finished command leaves behind -----------------------------
# label|cmd|timeout-secs|expected verdict|expected exit status
ROWS=(
  "a command that succeeds records a zero sentinel and passes|echo built; exit 0|20|state=done guard-exit=0 validate=pass|0"
  "a command that fails records its own status and fails the round|echo broke; exit 7|20|state=done guard-exit=7 validate=FAILING|1"
  "a command that outlives the bound is killed at it and fails the round|sleep 30|2|state=done guard-exit=124 validate=FAILING|1"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r label cmd secs want_verdict want_rc <<<"$row"
  proj="$(make_proj "proj-$want_rc-$secs" "$cmd" "$secs")"
  run_script "$RUN" --worktree "$proj" --poll 1
  assert_eq "$(verdict_of "$OUT")" "$want_verdict" "$label" "$ERR"
  assert_eq "$RC" "$want_rc" "$label — exit status" "$ERR"
done

# The last run above is the timeout one; its own sentinel and log are the files
# a waiter in another process reads.
timeout_dir="$(run_dir_of "$OUT")"
assert_eq "$(sed 's/ at=.*$//' "$timeout_dir/exit")" "guard-exit=124" \
  "the sentinel file carries the guard-exit line on its own"
assert_eq "$(sed -n 's/^guard-exit=[0-9]* at=\(.*\)$/\1/p' "$timeout_dir/exit" | grep -c -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1" \
  "and one UTC timestamp beside it"

# --- The command's output goes to the log, never into the verdict -------------
proj_log="$(make_proj proj-log "echo first; echo second >&2; exit 0" 20)"
run_script "$RUN" --worktree "$proj_log" --poll 1
log_dir="$(run_dir_of "$OUT")"
assert_eq "$(cat "$log_dir/log")" "$(printf 'first\nsecond')" \
  "the log holds the command's own output, both streams"

# --- The cap is derived from the setting, not chosen by the caller ------------
assert_eq "$(sed -n 's/^cap-secs=//p' "$log_dir/start")" "21" \
  "the cap is the command's bound plus one poll interval"
assert_eq "$(sed -n 's/^timeout-secs=//p' "$log_dir/start")" "20" \
  "and the bound recorded is the setting's value"

# --- The sentinel survives the death of the shell that launched the run -------
# A harness reaps a background shell by killing its process group. The run is
# detached into its own session, so the verdict is still recorded and a later
# poll still finds it — the whole point of writing it to a file.
proj_kill="$(make_proj proj-kill "sleep 4; echo survived" 30)"
setsid bash -c "env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS '$RUN' --worktree '$proj_kill' --poll 1 > '$TMP_ROOT/kill.out' 2>&1" &
caller=$!
sleep 1
kill -KILL -- "-$caller" 2>/dev/null || kill -KILL "$caller" 2>/dev/null || true
wait "$caller" 2>/dev/null || true
kill_dir="$(run_dir_of "$(cat "$TMP_ROOT/kill.out")")"
assert_eq "$([[ -n "$kill_dir" && ! -s "$kill_dir/exit" ]] && echo running || echo recorded)" "running" \
  "the caller is killed while the run has recorded no verdict yet"
run_script "$RUN" --wait --run-dir "$kill_dir" --budget 30
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=0 validate=pass" \
  "a later poll reads the verdict the detached run recorded after that kill" "$ERR"
assert_eq "$RC" "0" "and exits on it" "$ERR"

# --- A poll that runs out of its own call budget says so and asks for another --
proj_slow="$(make_proj proj-slow "sleep 6" 60)"
run_script "$RUN" --worktree "$proj_slow" --poll 1 &
started=$!
sleep 1
slow_dir="$(ls -d "$proj_slow"/tmp/dev-validate-* 2>/dev/null | sed -n 1p)"
run_script "$RUN" --wait --run-dir "$slow_dir" --budget 2
assert_eq "$(verdict_of "$OUT")" "state=running cap-secs=61" \
  "a poll whose call budget ends first reports the run as still going" "$ERR"
assert_eq "$RC" "3" "and exits 3, which is the instruction to poll again" "$ERR"
wait "$started" 2>/dev/null || true

# --- A cap that really has elapsed is a failed validation, never a pass -------
stale="$TMP_ROOT/stale"
mkdir -p "$stale"
{
  printf 'worktree=%s\n' "$TMP_ROOT"
  printf 'timeout-bin=timeout\n'
  printf 'start=1\n'
  printf 'timeout-secs=2\n'
  printf 'poll-secs=1\n'
  printf 'cap-secs=3\n'
} > "$stale/start"
run_script "$RUN" --wait --run-dir "$stale" --budget 5
assert_eq "$(verdict_of "$OUT")" "state=timeout cap-secs=3 validate=FAILING" \
  "a run whose cap elapsed with no sentinel is reported as failing" "$ERR"
assert_eq "$RC" "1" "and exits nonzero, so no caller reads it as a pass" "$ERR"

# --- Refusals: every one names its key and exits 2 ----------------------------
proj_empty="$(make_proj proj-empty "" 20)"
run_script "$RUN" --worktree "$proj_empty" --poll 1
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: empty-validate-cmd setting=DEV_VALIDATE_CMD" \
  "an empty validation command is refused, naming the setting"
assert_eq "$RC" "2" "and exits 2"

proj_zero="$(make_proj proj-zero "echo x" 0)"
run_script "$RUN" --worktree "$proj_zero" --poll 1
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: invalid-seconds setting=DEV_VALIDATE_TIMEOUT_SECS value=0" \
  "a bound of zero is refused rather than read as no bound"
assert_eq "$RC" "2" "and exits 2"

mkdir -p "$TMP_ROOT/unstarted"
run_script "$RUN" --wait --run-dir "$TMP_ROOT/unstarted"
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: no-run path=$TMP_ROOT/unstarted/start" \
  "a poll of a directory no run started is refused"
assert_eq "$RC" "2" "and exits 2"

run_script "$RUN" --wait --run-dir "$stale" --poll 5
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: option-unused option=--poll mode=wait" \
  "a poll interval handed to the waiter is refused, never silently dropped"
assert_eq "$RC" "2" "and exits 2"

run_script "$RUN" --worktree "$proj_log" --budget 5
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: option-unused option=--budget mode=start" \
  "a call budget handed to the blocking form is refused the same way"
assert_eq "$RC" "2" "and exits 2"

run_script "$RUN" --poll 1
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: required options=--worktree,--wait,--child" \
  "a call naming no mode is refused"
assert_eq "$RC" "2" "and exits 2"

# --- Control: the cap is not derived from the bound ---------------------------
# The reported failure: the wait ended before the guard did, so the round had no
# verdict and the agent went idle. With the cap pinned to a second instead of
# derived from the setting, the same run reports no verdict at all.
mutant mutant-short-cap 'cap_secs=$(( 10#$timeout_secs + 10#$poll ))' 'cap_secs=1'
proj_cap="$(make_proj proj-cap "sleep 5; echo done" 30)"
run_script "$MUTANT" --worktree "$proj_cap" --poll 1
assert_eq "$(verdict_of "$OUT")" "state=timeout cap-secs=1 validate=FAILING" \
  "control: a cap below the run's length reports no verdict for a run that finishes" "$ERR"
run_script "$RUN" --worktree "$proj_cap" --poll 1
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=0 validate=pass" \
  "the derived cap outlasts that same run and reports its verdict" "$ERR"

# --- Control: the command is not run under the bound --------------------------
# Without the bound a command that never ends is never killed, so the sentinel
# says the validation passed when nothing had finished inside the limit.
# The poll interval keeps the cap clear of both outcomes, so the only thing the
# two runs differ in is whether the command was killed at its bound.
mutant mutant-unbounded '"$child_timeout_bin" "$child_timeout_secs" sh -c "$child_cmd"' 'sh -c "$child_cmd"'
proj_unbounded="$(make_proj proj-unbounded "sleep 2; exit 0" 1)"
run_script "$MUTANT" --worktree "$proj_unbounded" --poll 3
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=0 validate=pass" \
  "control: with no bound applied the over-long command runs to completion and passes" "$ERR"
run_script "$RUN" --worktree "$proj_unbounded" --poll 3
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=124 validate=FAILING" \
  "under the bound that same command is killed at it and the round fails" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
