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
# The PATH a row runs the script under. Empty is this host's own; the dependency
# refusal rows below set it to a farm missing one binary.
RUN_PATH=""
run_script() { # SCRIPT ARG...
  local script="$1" err
  shift
  # One error file per call. The slow-poll rows have a detached run and a
  # foreground one going at once, and a single fixed path would hand each
  # assertion the other run's stderr on exactly the failure that needs it.
  err="$(mktemp "$TMP_ROOT/err.XXXXXX")"
  set +e
  OUT="$(env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS PATH="${RUN_PATH:-$PATH}" "$script" "$@" 2>"$err")"
  RC=$?
  set -e
  ERR="$(cat "$err")"
}

# The run directory the start line names, which every later read addresses.
run_dir_of() { # OUTPUT
  sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$1"
}

# The verdict fields a caller acts on, in a fixed order, from the last line.
verdict_of() { # OUTPUT
  sed -n 's/^\(state=[a-z]*\) \(guard-exit=[0-9]*\) at=[^ ]* \(validate=[A-Za-z]*\).*$/\1 \2 \3/p;s/^\(state=timeout\) elapsed-secs=[0-9]* cap-secs=\([0-9]*\) \(validate=[A-Za-z]*\).*$/\1 cap-secs=\2 \3/p;s/^\(state=lost\) elapsed-secs=[0-9]* cap-secs=\([0-9]*\) \(validate=[A-Za-z]*\).*$/\1 cap-secs=\2 \3/p;s/^\(state=running\) elapsed-secs=[0-9]* \(cap-secs=[0-9]*\).*$/\1 \2/p' <<<"$1" | sed -n '$p'
}

# One whole protocol line with only its elapsed seconds folded away, so every
# other field on it is pinned rather than skipped: a drifted run-dir= or log=
# sends the agent to the wrong place on the round that failed.
timed_line() { # OUTPUT
  sed 's/elapsed-secs=[0-9]*/elapsed-secs=N/' <<<"$1" | sed -n '$p'
}

# The log path the started line itself printed, which is the path an agent opens
# after a failing round rather than one it assembles.
log_of() { # OUTPUT
  sed -n 's/^state=started run-dir=[^ ]* log=\([^ ]*\) .*$/\1/p' <<<"$1"
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

# --- Refusals that run on every host, dependencies installed or not -----------
# A PATH holding only what the script and orch-env call, minus the binary under
# test. Both are declared dependencies in the orch README and SKILL.md: a host
# without one is told which, never left with an unbounded run or a launch that
# dies with its caller.
farm_path() { # NAME OMIT...
  local dir="$TMP_ROOT/$1/bin" name src omit
  shift
  mkdir -p "$dir"
  for name in bash sh env git date dirname basename mkdir mv rm cat sed grep cut tr awk \
    sleep kill ls head tail sort wc uname chmod ln find readlink realpath mktemp \
    timeout gtimeout setsid; do
    for omit in "$@"; do
      [[ "$name" != "$omit" ]] || continue 2
    done
    src="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$src" ]] || continue
    ln -sf "$src" "$dir/$name"
  done
  printf '%s\n' "$dir"
}

proj_dep="$(make_proj proj-dep "echo x" 20)"
RUN_PATH="$(farm_path no-timeout timeout gtimeout)"
run_script "$RUN" --worktree "$proj_dep" --poll 1
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: missing-command commands=timeout,gtimeout" \
  "a host carrying neither timeout spelling is refused, never run unbounded"
assert_eq "$RC" "2" "and exits 2"

# setsid is looked up after the bound, so this row needs one of the two present.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  RUN_PATH="$(farm_path no-setsid setsid)"
  run_script "$RUN" --worktree "$proj_dep" --poll 1
  assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: missing-command commands=setsid" \
    "a host with no setsid is refused, since the run could not outlive its launcher"
  assert_eq "$RC" "2" "and exits 2"
fi
RUN_PATH=""

# --- The rows below run the command, so they need what this host may not have -
SKIP_REASON=""
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  SKIP_REASON="neither timeout nor gtimeout is installed"
elif ! command -v setsid >/dev/null 2>&1; then
  SKIP_REASON="setsid is not installed"
fi
if [[ -n "$SKIP_REASON" ]]; then
  echo "  skip  $SKIP_REASON; the runner rows did not run"
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  # The refusal rows above did run, and their result is still the suite's: a
  # skipped host never reports success with nothing exercised.
  [[ "$FAIL" -eq 0 ]] || exit 1
  exit 0
fi

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
proj_log_out="$OUT"
log_dir="$(run_dir_of "$OUT")"
assert_eq "$(cat "$(log_of "$OUT")")" "$(printf 'first\nsecond')" \
  "the log the started line names holds the command's own output, both streams"


# --- Full output devices preserve or fail the verdict protocol ---------------
# These rows pin behavior the runner already has. No runner production edit is
# part of this change, so no production mutation can redden this test surface.
if [[ -e /dev/full ]]; then
  timeout_cmd="$(command -v timeout || command -v gtimeout)"

  full_log_dir="$TMP_ROOT/full-log-run"
  mkdir -p "$full_log_dir"
  {
    printf 'worktree=%s\n' "$proj_log"
    printf 'timeout-bin=%s\n' "$timeout_cmd"
    printf 'start=%s\n' "$(( $(date +%s) - 20 ))"
    printf 'timeout-secs=20\n'
    printf 'poll-secs=1\n'
    printf 'cap-secs=31\n'
  } > "$full_log_dir/start"
  printf '%s\n' 'for i in {1..2000}; do printf "line %s\\n" "$i"; done; exit 1' > "$full_log_dir/cmd"
  ln -s /dev/full "$full_log_dir/log"
  run_script "$RUN" --child --run-dir "$full_log_dir"
  assert_eq "$RC" "0" "a failed command records its sentinel when every log write gets ENOSPC" "$ERR"
  assert_eq "$(sed 's/ at=.*$//' "$full_log_dir/exit")" "guard-exit=1" \
    "and the sentinel keeps the command's failing exit status"
  run_script "$RUN" --wait --run-dir "$full_log_dir" --budget 5
  assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=1 validate=FAILING" \
    "the waiter reports that full-log run as failing" "$ERR"

  full_sentinel_dir="$TMP_ROOT/full-sentinel-run"
  mkdir -p "$full_sentinel_dir"
  {
    printf 'worktree=%s\n' "$proj_log"
    printf 'timeout-bin=%s\n' "$timeout_cmd"
    printf 'start=%s\n' "$(( $(date +%s) - 20 ))"
    printf 'timeout-secs=20\n'
    printf 'poll-secs=1\n'
    printf 'cap-secs=31\n'
  } > "$full_sentinel_dir/start"
  printf '%s\n' 'exit 0' > "$full_sentinel_dir/cmd"
  ln -s /dev/full "$full_sentinel_dir/exit.part"
  run_script "$RUN" --child --run-dir "$full_sentinel_dir"
  assert_eq "$RC" "1" "a sentinel write to a full device fails the child" "$ERR"
  run_script "$RUN" --wait --run-dir "$full_sentinel_dir" --budget 5
  assert_eq "$(verdict_of "$OUT")" "state=lost cap-secs=31 validate=FAILING" \
    "and the missing sentinel is reported as a lost failing run" "$ERR"
else
  echo "  skip  /dev/full is absent; the full-output-device rows did not run"
fi
OUT="$proj_log_out"
# --- Every field of the started and done lines, which the agent reads ---------
assert_eq "$(sed -n 1p <<<"$OUT")" \
  "state=started run-dir=$log_dir log=$log_dir/log sentinel=$log_dir/exit timeout-secs=20 poll-secs=1 cap-secs=31" \
  "the started line names the run directory, its log and sentinel, and all three bounds"
assert_eq "$(sed -n 2p <<<"$OUT")" \
  "state=done guard-exit=0 at=$(sed -n 's/^guard-exit=[0-9]* at=//p' "$log_dir/exit") validate=pass run-dir=$log_dir log=$log_dir/log" \
  "and the done line carries the sentinel's own text beside those same two paths"

# --- The cap is derived from the setting, not chosen by the caller ------------
assert_eq "$(sed -n 's/^cap-secs=//p' "$log_dir/start")" "31" \
  "the cap is the command's bound plus the kill grace plus one poll interval"
assert_eq "$(sed -n 's/^timeout-secs=//p' "$log_dir/start")" "20" \
  "and the bound recorded is the setting's value"

# --- With no bound set, the script's own default is the one that applies -------
proj_default="$TMP_ROOT/proj-default"
git init -q "$proj_default"
printf '[env]\nDEV_VALIDATE_CMD = "echo x"\n' > "$proj_default/kendex.settings.toml"
run_script "$RUN" --worktree "$proj_default" --poll 1
assert_eq "$(sed -n 's/^state=started .* \(timeout-secs=[0-9]*\) .*$/\1/p' <<<"$OUT")" "timeout-secs=3600" \
  "a project that sets no bound gets the documented hour" "$ERR"

# --- The command runs under bash, the shell it was written for ----------------
# On Debian and Ubuntu sh is dash, where source is not a command: a
# DEV_VALIDATE_CMD holding one would record guard-exit=127 and a false FAILING.
proj_bash="$(make_proj proj-bash 'source /dev/null && [[ -n ${BASH_VERSION:-} ]] && echo ran-under-bash' 20)"
run_script "$RUN" --worktree "$proj_bash" --poll 1
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=0 validate=pass" \
  "a bash-only validation command runs and passes" "$ERR"
assert_eq "$(cat "$(log_of "$OUT")")" "ran-under-bash" \
  "and the log names the shell that ran it, not a POSIX one that refused the line"

# --- A command that ignores SIGTERM is still ended inside the bound -----------
# A bound with no kill escalation is one signal, which such a command outlives:
# the run holds open past the setting with no verdict, no sentinel and no owner,
# and fixtures in this repository trap TERM by construction. The elapsed
# assertion is what reddens on that; the command would otherwise run forty
# seconds and the waiter would report the cap instead.
proj_term="$(make_proj proj-term "trap '' TERM; sleep 40" 2)"
term_start="$(date +%s)"
run_script "$RUN" --worktree "$proj_term" --poll 5
term_elapsed=$(( $(date +%s) - term_start ))
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=137 validate=FAILING" \
  "a command that ignores SIGTERM is killed anyway and records that kill as its verdict" "$ERR"
assert_eq "$RC" "1" "and the round fails on it" "$ERR"
assert_eq "$([[ "$term_elapsed" -le 20 ]] && echo within || echo "over:$term_elapsed")" "within" \
  "with the sentinel landing inside the bound plus the grace, not at the command's own length"

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
# The poll interval here is ten times the call budget. A wait that slept a whole
# interval before its next check would return at twenty seconds against a budget
# of two, and a caller sizes its own harness timeout on the budget it asked for:
# the elapsed assertion below is what reddens on that.
proj_slow="$(make_proj proj-slow "sleep 30" 60)"
setsid bash -c "env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS '$RUN' --worktree '$proj_slow' --poll 20 > '$TMP_ROOT/slow.out' 2>&1" &
started=$!
sleep 2
slow_dir="$(run_dir_of "$(cat "$TMP_ROOT/slow.out")")"
slow_start="$(date +%s)"
run_script "$RUN" --wait --run-dir "$slow_dir" --budget 2
slow_elapsed=$(( $(date +%s) - slow_start ))
assert_eq "$(timed_line "$OUT")" "state=running elapsed-secs=N cap-secs=90 run-dir=$slow_dir" \
  "a poll whose call budget ends first reports the run as still going, naming the cap and the directory to poll next" "$ERR"
assert_eq "$RC" "3" "and exits 3, which is the instruction to poll again" "$ERR"
assert_eq "$([[ "$slow_elapsed" -le 5 ]] && echo within || echo "over:$slow_elapsed")" "within" \
  "and it returns on its own budget rather than a whole poll interval past it"
kill -KILL -- "-$started" 2>/dev/null || kill -KILL "$started" 2>/dev/null || true
wait "$started" 2>/dev/null || true

# --- A run whose child is gone is lost, said at once and never read as a pass --
# A host or low-memory kill takes the child with no sentinel written. Waiting the
# whole cap for it is an hour of silence per lost run under the shipped settings.
proj_lost="$(make_proj proj-lost "sleep 25" 60)"
setsid bash -c "env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS '$RUN' --worktree '$proj_lost' --poll 1 > '$TMP_ROOT/lost.out' 2>&1" &
lost_caller=$!
sleep 2
lost_dir="$(run_dir_of "$(cat "$TMP_ROOT/lost.out")")"
lost_pid="$(cat "$lost_dir/pid")"
kill -KILL -- "-$lost_pid" 2>/dev/null || kill -KILL "$lost_pid" 2>/dev/null || true
kill -KILL -- "-$lost_caller" 2>/dev/null || kill -KILL "$lost_caller" 2>/dev/null || true
wait "$lost_caller" 2>/dev/null || true
lost_start="$(date +%s)"
run_script "$RUN" --wait --run-dir "$lost_dir" --budget 30
lost_elapsed=$(( $(date +%s) - lost_start ))
assert_eq "$(timed_line "$OUT")" \
  "state=lost elapsed-secs=N cap-secs=71 validate=FAILING run-dir=$lost_dir log=$lost_dir/log" \
  "a killed child with no sentinel is reported lost, naming the log it had already opened" "$ERR"
assert_eq "$RC" "1" "and exits nonzero, so no caller reads it as a pass" "$ERR"
assert_eq "$([[ "$lost_elapsed" -le 10 ]] && echo within || echo "over:$lost_elapsed")" "within" \
  "on the next poll rather than seventy seconds later at the run's cap"

# The same report where the child never ran at all: no process id to find, and
# no log to name because nothing opened one.
absent="$TMP_ROOT/absent"
mkdir -p "$absent"
{
  printf 'worktree=%s\n' "$TMP_ROOT"
  printf 'timeout-bin=timeout\n'
  printf 'start=%s\n' "$(date +%s)"
  printf 'timeout-secs=600\n'
  printf 'poll-secs=1\n'
  printf 'cap-secs=611\n'
} > "$absent/start"
run_script "$RUN" --wait --run-dir "$absent" --budget 60
assert_eq "$(timed_line "$OUT")" "state=lost elapsed-secs=N cap-secs=611 validate=FAILING run-dir=$absent" \
  "a launch that never ran is lost too, and names no log because none exists" "$ERR"
assert_eq "$RC" "1" "and exits nonzero" "$ERR"

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
assert_eq "$(timed_line "$OUT")" "state=timeout elapsed-secs=N cap-secs=3 validate=FAILING run-dir=$stale" \
  "a run whose cap elapsed with no sentinel is reported as failing, naming its directory and no log" "$ERR"
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

proj_words="$(make_proj proj-words "echo x" 90m)"
run_script "$RUN" --worktree "$proj_words" --poll 1
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: invalid-seconds setting=DEV_VALIDATE_TIMEOUT_SECS value=90m" \
  "a bound written as a duration is refused, not silently read as the default hour"
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
mutant mutant-short-cap 'cap_secs=$(( 10#$timeout_secs + KILL_GRACE + 10#$poll ))' 'cap_secs=1'
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
mutant mutant-unbounded '"$child_timeout_bin" -k "$KILL_GRACE" "$child_timeout_secs" bash -c "$child_cmd"' 'bash -c "$child_cmd"'
proj_unbounded="$(make_proj proj-unbounded "sleep 2; exit 0" 1)"
run_script "$MUTANT" --worktree "$proj_unbounded" --poll 3
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=0 validate=pass" \
  "control: with no bound applied the over-long command runs to completion and passes" "$ERR"
run_script "$RUN" --worktree "$proj_unbounded" --poll 3
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=124 validate=FAILING" \
  "under the bound that same command is killed at it and the round fails" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
