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

# A run directory's start file, the bounds a waiter reads, polled every second,
# and the change class a child hands its command. Its runner record is a
# unit's: a child run directly here is what a unit's main process is, one that
# leaves containment to the unit and kills nothing itself.
write_start() { # DIR WORKTREE TIMEOUT_BIN START TIMEOUT_SECS CAP_SECS
  mkdir -p "$1"
  printf 'worktree=%s\ntimeout-bin=%s\nstart=%s\ntimeout-secs=%s\npoll-secs=1\ncap-secs=%s\nclass=standard\ndocs-only=false\n' \
    "$2" "$3" "$4" "$5" "$6" > "$1/start"
  printf 'runner=systemd\nunit=validate-fixture\nline=runner=systemd unit=validate-fixture\n' > "$1/runner"
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
  # A class the caller's shell carries is cleared like the settings are: this
  # suite also runs under dev-validate-run itself, which sets one. A row that
  # means to hand one in names it in INHERITED_CLASS.
  OUT="$(env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS \
    -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
    ${INHERITED_CLASS:+DEV_VALIDATE_CLASS=$INHERITED_CLASS} \
    PATH="${RUN_PATH:-$PATH}" "$script" "$@" 2>"$err")"
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

# What the command itself wrote: the log after its first line, which names the
# runner and is pinned by the containment rows.
output_of() { # OUTPUT
  sed 1d "$(log_of "$1")"
}

# A copy of the scripts with one literal substitution applied to one of them,
# dev-validate-run unless MUTANT_FILE names lib/job-unit.sh, for the controls.
# The count assertions are the edit's proof: a pattern that stopped matching
# would otherwise leave the control running the shipped code and passing. The
# copy's path lands in MUTANT rather than on stdout, which the assertions own.
MUTANT=""
mutant() { # NAME OLD NEW
  local dir="$TMP_ROOT/$1" file="${MUTANT_FILE:-dev-validate-run}"
  mkdir -p "$dir/lib"
  cp "$SCRIPTS_DIR/dev-validate-run" "$SCRIPTS_DIR/orch-env" "$dir/"
  cp "$SCRIPTS_DIR/lib"/*.sh "$dir/lib/"
  chmod +x "$dir/dev-validate-run" "$dir/orch-env"
  assert_eq "$(grep -c -F -- "$2" "$dir/$file")" "1" "control $1 finds one line to mutate"
  awk -v old="$2" -v new="$3" '{
    i = index($0, old)
    if (i > 0) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) }
    print
  }' "$dir/$file" > "$dir/mutated"
  mv "$dir/mutated" "$dir/$file"
  chmod +x "$dir/dev-validate-run"
  assert_eq "$(grep -c -F -- "$2" "$dir/$file")" "0" "control $1 applied its mutation"
  MUTANT="$dir/dev-validate-run"
}

echo "=== dev-validate-run bounded validation runner ==="

# --- Refusals that run on every host, dependencies installed or not -----------
# A PATH holding only what the script and orch-env call, minus the binary under
# test. Both are declared dependencies in the orch README and SKILL.md: a host
# without one is told which, never left with an unbounded run or a launch that
# dies with its caller. The farm carries no systemd-run, so a run under it is
# the setsid fallback of a host where no user manager answers.
farm_path() { # NAME OMIT...
  local dir="$TMP_ROOT/$1/bin" name src omit
  shift
  mkdir -p "$dir"
  for name in bash sh env git date dirname basename mkdir mv rm cat sed grep cut tr awk \
    sleep kill ls head tail sort wc uname chmod ln find readlink realpath mktemp \
    timeout gtimeout setsid ps; do
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
log_dir="$(run_dir_of "$OUT")"
assert_eq "$(output_of "$OUT")" "$(printf 'first\nsecond')" \
  "the log the started line names holds, under its runner line, the command's own output, both streams"

# --- Every field of the started and done lines, which the agent reads ---------
# The fixture has no commit, so no worktree commit can be written to classify
# and the class falls back to standard, naming why.
assert_eq "$(sed -n 1p <<<"$OUT")" \
  "state=started run-dir=$log_dir log=$log_dir/log sentinel=$log_dir/exit timeout-secs=20 poll-secs=1 cap-secs=31 class=standard docs-only=false class-fallback=worktree-unrecorded" \
  "the started line names the run directory, its log and sentinel, all three bounds and the class"
assert_eq "$(sed -n 2p <<<"$OUT")" \
  "state=done guard-exit=0 at=$(sed -n 's/^guard-exit=[0-9]* at=//p' "$log_dir/exit") validate=pass run-dir=$log_dir log=$log_dir/log" \
  "and the done line carries the sentinel's own text beside those same two paths"

# --- The cap is derived from the setting, not chosen by the caller ------------
assert_eq "$(sed -n 's/^cap-secs=//p' "$log_dir/start")" "31" \
  "the cap is the command's bound plus the kill grace plus one poll interval"
assert_eq "$(sed -n 's/^timeout-secs=//p' "$log_dir/start")" "20" \
  "and the bound recorded is the setting's value"

# --- Full output devices preserve or fail the verdict protocol ---------------
# A failing command keeps its status when every log write fails, and a failed
# sentinel write reads as a lost run. These rows add no rule to the runner, so
# they carry no must-fail control.
if [[ -e /dev/full ]]; then
  timeout_cmd="$(command -v timeout || command -v gtimeout)"
  full_log_dir="$TMP_ROOT/full-log-run"
  write_start "$full_log_dir" "$proj_log" "$timeout_cmd" "$(date +%s)" 20 31
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
  write_start "$full_sentinel_dir" "$proj_log" "$timeout_cmd" "$(date +%s)" 20 31
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
assert_eq "$(output_of "$OUT")" "ran-under-bash" \
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
write_start "$absent" "$TMP_ROOT" timeout "$(date +%s)" 600 611
run_script "$RUN" --wait --run-dir "$absent" --budget 60
assert_eq "$(timed_line "$OUT")" "state=lost elapsed-secs=N cap-secs=611 validate=FAILING run-dir=$absent" \
  "a launch that never ran is lost too, and names no log because none exists" "$ERR"
assert_eq "$RC" "1" "and exits nonzero" "$ERR"

# --- A cap that really has elapsed is a failed validation, never a pass -------
stale="$TMP_ROOT/stale"
write_start "$stale" "$TMP_ROOT" timeout 1 2 3
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
assert_eq "$(sed -n 1p <<<"$ERR")" "dev-validate-run: required options=--worktree,--wait,--stop,--child" \
  "a call naming no mode is refused"
assert_eq "$RC" "2" "and exits 2"

# --- The command learns the change class, and only from the classifier --------
# The classifier and the docs reader are stubs beside a copy of the scripts,
# laid out as the installed packages are: orch/scripts next to
# harness-ci/scripts. The classifier records its arguments and answers what
# the row names; the docs reader answers STUB_DOCS and writes the paths file.
# The command prints what it was handed, so each row reads the battery's
# selectors straight off the log.
LAYOUT="$TMP_ROOT/layout"
mkdir -p "$LAYOUT/orch/scripts/lib" "$LAYOUT/harness-ci/scripts"
cp "$SCRIPTS_DIR/dev-validate-run" "$SCRIPTS_DIR/orch-env" "$SCRIPTS_DIR/resolve-base-branch" "$LAYOUT/orch/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$LAYOUT/orch/scripts/lib/"
cat > "$LAYOUT/harness-ci/scripts/change-class" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGS"
# What the head it was handed holds, read while that head still exists: the
# snapshot lives in a scratch store the runner removes when it exits.
head="$(sed -n '/^--head$/{n;p;}' "$STUB_ARGS")"
repo="$(sed -n '/^--repo$/{n;p;}' "$STUB_ARGS")"
{
  git -C "$repo" show --name-only --format= "$head"
  git -C "$repo" rev-parse "$head^"
} > "$STUB_SEEN" 2>&1
case "$STUB_ANSWER" in
  exit-2) echo "wiring-error: cause=stub" >&2; exit 2 ;;
  *) printf '%s\n' "$STUB_ANSWER" ;;
esac
SH
cat > "$LAYOUT/harness-ci/scripts/harness-only" <<'SH'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [[ "$prev" != --paths-output ]] || printf 'docs/a.md\n' > "$a"
  prev="$a"
done
case "$STUB_DOCS" in
  exit-2) exit 2 ;;
  *) printf 'docs_only=%s\n' "$STUB_DOCS" ;;
esac
SH
chmod +x "$LAYOUT/harness-ci/scripts/change-class" "$LAYOUT/harness-ci/scripts/harness-only"
export STUB_ARGS="$TMP_ROOT/stub-args" STUB_SEEN="$TMP_ROOT/stub-seen"
proj_class="$(make_proj proj-class 'printf %s:%s:%s ${DEV_VALIDATE_CLASS-unset} ${DEV_VALIDATE_DOCS_ONLY-unset} $(cat ${DEV_VALIDATE_PATHS-/dev/null})' 20)"
# The run directories land under tmp/, which an orch project ignores.
printf 'tmp/\n' > "$proj_class/.gitignore"
git -C "$proj_class" add kendex.settings.toml .gitignore
git -C "$proj_class" -c user.name=t -c user.email=t@example.com commit -q -m base
git -C "$proj_class" update-ref refs/remotes/origin/main HEAD
# classifier answer|docs answer|what the command is handed|the started line's class fields
CLASS_ROWS=(
  "change_class=render|false|render:false:docs/a.md|class=render docs-only=false"
  "change_class=trivial|true|trivial:true:docs/a.md|class=trivial docs-only=true"
  "change_class=micro|false|micro:false:docs/a.md|class=micro docs-only=false"
  "change_class=small|false|small:false:docs/a.md|class=small docs-only=false"
  "change_class=standard|true|standard:true:docs/a.md|class=standard docs-only=true"
  "exit-2|true|standard:false:|class=standard docs-only=false class-fallback=classifier-exit-2"
  "change_class=Tiny|true|standard:false:|class=standard docs-only=false class-fallback=classifier-unreadable"
  "change_class=micro|exit-2|standard:false:|class=standard docs-only=false class-fallback=docs-reader-exit-2"
)
for row in "${CLASS_ROWS[@]}"; do
  IFS='|' read -r answer docs want_handed want_fields <<<"$row"
  export STUB_ANSWER="$answer" STUB_DOCS="$docs"
  # An inherited class is what a lane asserting its own would look like.
  INHERITED_CLASS=trivial run_script "$LAYOUT/orch/scripts/dev-validate-run" --worktree "$proj_class" --poll 1
  assert_eq "$(output_of "$OUT" 2>/dev/null)" "$want_handed" \
    "classifier '$answer' and docs reader '$docs' hand the command $want_handed" "$ERR"
  assert_eq "$(sed -n 's/^state=started .* cap-secs=[0-9]* //p' <<<"$OUT")" "$want_fields" \
    "and the started line reports $want_fields" "$ERR"
done

# The diff classified is the worktree as it stands: a file no commit holds yet
# is in the head the classifier is handed, and HEAD and the index are not moved.
# Nothing the snapshot writes lands in the repository's own object store.
loose_objects() { git -C "$proj_class" count-objects -v | sed -n 's/^count: //p'; }
printf 'draft\n' > "$proj_class/draft.md"
export STUB_ANSWER=change_class=trivial STUB_DOCS=true
objects_before="$(loose_objects)"
run_script "$LAYOUT/orch/scripts/dev-validate-run" --worktree "$proj_class" --poll 1
assert_eq "$(sed -n '/^--event$/{n;p;}' "$STUB_ARGS") $(sed -n '/^--base$/{n;p;}' "$STUB_ARGS")" \
  "pull_request origin/main" "the classifier judges a pull request against the base branch" "$ERR"
assert_eq "$(cat "$STUB_SEEN")" "$(printf 'draft.md\n%s' "$(git -C "$proj_class" rev-parse HEAD)")" \
  "the head it judges carries the uncommitted file and sits on HEAD" "$ERR"
assert_eq "$(git -C "$proj_class" status --porcelain)" "?? draft.md" \
  "and HEAD, the index and the tree stay as they were" "$ERR"
assert_eq "$(loose_objects)" "$objects_before" \
  "and the repository's object store gains no object from the snapshot" "$ERR"

# Control: with the scratch store never exported the snapshot writes the
# untracked file's blob, its tree and its commit into the shared store.
mutant mutant-shared-store 'export GIT_OBJECT_DIRECTORY="$class_scratch/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects"' 'true'
cp "$MUTANT" "$LAYOUT/orch/scripts/dev-validate-run"
objects_before="$(loose_objects)"
run_script "$LAYOUT/orch/scripts/dev-validate-run" --worktree "$proj_class" --poll 1
assert_eq "$(( $(loose_objects) > objects_before ))" "1" \
  "control: without the scratch store the snapshot adds loose objects to the shared store" "$ERR"
cp "$SCRIPTS_DIR/dev-validate-run" "$LAYOUT/orch/scripts/dev-validate-run"
rm -f "$proj_class/draft.md"

# With no classifier installed the class is standard, and says why.
mv "$LAYOUT/harness-ci" "$LAYOUT/harness-ci.off"
run_script "$LAYOUT/orch/scripts/dev-validate-run" --worktree "$proj_class" --poll 1
assert_eq "$(output_of "$OUT" 2>/dev/null) $(sed -n 's/^state=started .* cap-secs=[0-9]* //p' <<<"$OUT")" \
  "standard:false: class=standard docs-only=false class-fallback=classifier-absent" \
  "no classifier runs the whole battery, naming the absence" "$ERR"
mv "$LAYOUT/harness-ci.off" "$LAYOUT/harness-ci"

# Control: the class is read but never handed to the command, which is the
# runner before this contract: the trivial row's command sees no class and
# runs its whole battery.
mutant mutant-no-class 'DEV_VALIDATE_CLASS="$child_class" DEV_VALIDATE_DOCS_ONLY' 'DEV_VALIDATE_DOCS_ONLY'
cp "$MUTANT" "$LAYOUT/orch/scripts/dev-validate-run"
export STUB_ANSWER=change_class=trivial STUB_DOCS=true
run_script "$LAYOUT/orch/scripts/dev-validate-run" --worktree "$proj_class" --poll 1
assert_eq "$(output_of "$OUT" 2>/dev/null)" "unset:true:docs/a.md" \
  "control: with the class not handed over the trivial row's command runs with no class" "$ERR"
cp "$SCRIPTS_DIR/dev-validate-run" "$LAYOUT/orch/scripts/dev-validate-run"

# --- The real classifier refuses render over uncommitted edits ------------------
# change-class proves render only on a clean tree, and dev-implement validates
# before it commits. A diff of generated files alone, left uncommitted, is
# standard at dev completion. The kendex on PATH is a stub that fails if run:
# the dirty-tree refusal comes before any render proof.
proj_render="$(make_proj proj-render 'printf %s ${DEV_VALIDATE_CLASS-unset}' 20)"
mkdir -p "$proj_render/.agents/skills/demo"
printf 'tmp/\n' > "$proj_render/.gitignore"
printf '# demo\n' > "$proj_render/.agents/skills/demo/SKILL.md"
printf '%s\n' '[".agents/skills/demo/SKILL.md"]' > "$proj_render/.kendex-generated.json"
git -C "$proj_render" add -A
git -C "$proj_render" -c user.name=t -c user.email=t@example.com commit -q -m base
git -C "$proj_render" update-ref refs/remotes/origin/main HEAD
printf 'rendered again\n' >> "$proj_render/.agents/skills/demo/SKILL.md"
mkdir -p "$TMP_ROOT/render-bin"
printf '#!/usr/bin/env bash\necho "stub kendex ran" >&2\nexit 99\n' > "$TMP_ROOT/render-bin/kendex"
chmod +x "$TMP_ROOT/render-bin/kendex"
RUN_PATH="$TMP_ROOT/render-bin:$PATH"
run_script "$RUN" --worktree "$proj_render" --poll 1
RUN_PATH=""
render_dir="$(run_dir_of "$OUT")"
assert_eq "$(output_of "$OUT" 2>/dev/null) $(sed -n 's/^class: class=\([a-z]*\) \(measured=[a-z]*\) \(cause=[a-z-]*\).*$/\1 \2 \3/p' "$render_dir/class.log")" \
  "standard standard measured=false cause=judged-tree-dirty" \
  "an uncommitted render diff runs as standard, the classifier naming the dirty tree" "$ERR"

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
mutant mutant-unbounded '"$child_timeout_bin" --foreground -k "$KILL_GRACE" "$child_timeout_secs" bash -c "$child_cmd"' 'bash -c "$child_cmd"'
proj_unbounded="$(make_proj proj-unbounded "sleep 2; exit 0" 1)"
run_script "$MUTANT" --worktree "$proj_unbounded" --poll 3
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=0 validate=pass" \
  "control: with no bound applied the over-long command runs to completion and passes" "$ERR"
run_script "$RUN" --worktree "$proj_unbounded" --poll 3
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=124 validate=FAILING" \
  "under the bound that same command is killed at it and the round fails" "$ERR"

# --- No process the run starts outlives it ------------------------------------
# Each command leaves a grandchild behind and records its pid in the worktree.
# One that calls setsid leaves the run's process group, which only a unit's
# cgroup still holds; one that does not stays in the group the setsid fallback
# kills. Neither is gone the instant the verdict lands, since the unit or the
# group ends just after, so each read allows five seconds. A zombie waiting on
# its reaper counts as gone.
state_of() { # PID
  local n=0 stat
  while kill -0 "$1" 2>/dev/null; do
    stat="$(ps -o stat= -p "$1" 2>/dev/null || true)"
    [[ "$stat" != Z* ]] || break
    (( n < 50 )) || { echo alive; return 0; }
    sleep 0.1
    n=$((n + 1))
  done
  echo gone
}
# The grandchild a row's command recorded, killed after the read so a control
# that leaves it running leaves nothing behind the suite.
grandchild_state() { # PROJ
  local pid
  pid="$(cat "$1/grand.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo unrecorded; return 0; }
  state_of "$pid"
  kill -KILL "$pid" 2>/dev/null || true
}
# The runner line a run's log opens with, with its unit's run stamp folded to
# RUN so the rest of the name is pinned.
runner_line() { # OUTPUT
  sed -n '1{s/-[0-9]\{8\}T[0-9]\{6\}Z-[0-9]*$/-RUN/;p;}' "$(log_of "$1")"
}

# Which runner this host gives a run, read off a run's own log: a host where no
# user manager answers skips the unit rows, saying so, and never passes them.
proj_probe="$(make_proj proj-probe "exit 0" 20)"
run_script "$RUN" --worktree "$proj_probe" --poll 1
HOST_RUNNER="$(sed -n '1s/^runner=\([a-z]*\) .*$/\1/p' "$(log_of "$OUT")")"

if [[ "$HOST_RUNNER" == systemd ]]; then
  # label|name|cmd|timeout-secs|expected verdict
  UNIT_ROWS=(
    "a completed run leaves no grandchild that started its own session|proj-unit-done|setsid sleep 300 & echo \$! > grand.pid; exit 0|20|state=done guard-exit=0 validate=pass"
    "a run killed at its bound leaves no such grandchild either|proj-unit-bound|setsid sleep 300 & echo \$! > grand.pid; sleep 30|2|state=done guard-exit=124 validate=FAILING"
  )
  for row in "${UNIT_ROWS[@]}"; do
    IFS='|' read -r label name cmd secs want_verdict <<<"$row"
    proj="$(make_proj "$name" "$cmd" "$secs")"
    run_script "$RUN" --worktree "$proj" --poll 1
    assert_eq "$(verdict_of "$OUT")" "$want_verdict" "$label: the verdict" "$ERR"
    assert_eq "$(runner_line "$OUT")" "runner=systemd unit=validate-$name-RUN" \
      "$label: the log opens naming its unit" "$ERR"
    assert_eq "$(grandchild_state "$proj")" "gone" "$label" "$ERR"
  done

  # Control: the run launched under setsid on this same host, which is the
  # runner before units. The grandchild that left the group outlives it.
  MUTANT_FILE=lib/job-unit.sh mutant mutant-no-unit 'elif probe_err="$(systemd-run --user --quiet --collect true </dev/null 2>&1 >/dev/null)"; then' 'elif false; then'
  proj_nounit="$(make_proj proj-no-unit 'setsid sleep 300 & echo $! > grand.pid; exit 0' 20)"
  run_script "$MUTANT" --worktree "$proj_nounit" --poll 1
  assert_eq "$(runner_line "$OUT") $(grandchild_state "$proj_nounit")" "runner=setsid reason=probe-failed detail= alive" \
    "control: outside a unit the grandchild that started its own session outlives the run" "$ERR"

  # The unit carries what a user unit does not inherit: the caller's exported
  # variables and its open-file soft limit, lowered here so it differs from
  # any manager default.
  proj_inherit="$(make_proj proj-inherit 'printf %s:%s ${VALIDATE_ENV_MARK-unset} $(ulimit -Sn)' 20)"
  export VALIDATE_ENV_MARK=x
  run_script bash -c 'ulimit -Sn 777 && exec "$0" "$@"' "$RUN" --worktree "$proj_inherit" --poll 1
  assert_eq "$(output_of "$OUT")" "x:777" \
    "a unit's command sees the caller's exported variable and open-file soft limit" "$ERR"
  MUTANT_FILE=lib/job-unit.sh mutant mutant-no-env ' ${unit_env[@]+"${unit_env[@]}"}' ''
  run_script bash -c 'ulimit -Sn 777 && exec "$0" "$@"' "$MUTANT" --worktree "$proj_inherit" --poll 1
  assert_eq "$(output_of "$OUT" | cut -d: -f1)" "unset" \
    "control: with no environment handed over the command sees no such variable" "$ERR"
  MUTANT_FILE=lib/job-unit.sh mutant mutant-no-nofile '-p "LimitNOFILE=$nofile" ' ''
  run_script bash -c 'ulimit -Sn 777 && exec "$0" "$@"' "$MUTANT" --worktree "$proj_inherit" --poll 1
  assert_eq "$([[ "$(output_of "$OUT")" == x:777 ]] && echo caller || echo manager)" "manager" \
    "control: with no limit handed over the command runs under the manager's" "$ERR"
  unset VALIDATE_ENV_MARK

  # A host with a user manager and no setsid runs: setsid is the fallback's
  # alone. systemd-run refuses to resolve its command through a symlink, so
  # the probe's `true` is a copy here rather than a farm link.
  mkdir -p "$TMP_ROOT/unit-bin"
  ln -sf "$(command -v systemd-run)" "$TMP_ROOT/unit-bin/systemd-run"
  cp "$(type -P true)" "$TMP_ROOT/unit-bin/true"
  RUN_PATH="$TMP_ROOT/unit-bin:$(farm_path unit-no-setsid setsid)"
  proj_nosetsid="$(make_proj proj-no-setsid "exit 0" 20)"
  run_script "$RUN" --worktree "$proj_nosetsid" --poll 1
  assert_eq "$(verdict_of "$OUT") $(runner_line "$OUT")" "state=done guard-exit=0 validate=pass runner=systemd unit=validate-proj-no-setsid-RUN" \
    "a host with a user manager and no setsid runs its validation in a unit" "$ERR"
  MUTANT_FILE=lib/job-unit.sh mutant mutant-setsid-first '  [[ "$JOB_UNIT_RUNNER" == systemd ]] || command -v setsid' '  command -v setsid'
  run_script "$MUTANT" --worktree "$proj_nosetsid" --poll 1
  assert_eq "$(sed -n 1p <<<"$ERR") $RC" "dev-validate-run: missing-command commands=setsid 2" \
    "control: with setsid required ahead of the probe that host is refused" "$ERR"
  RUN_PATH=""

  # The manager expands ${NAME} in a unit's command line, so a worktree path
  # that carries one reaches the child only with its $ written $$. The unit
  # name carries none of it.
  proj_dollar="$(make_proj 'proj-${HOME}' "exit 0" 20)"
  run_script "$RUN" --worktree "$proj_dollar" --poll 1
  assert_eq "$(verdict_of "$OUT") $(runner_line "$OUT")" "state=done guard-exit=0 validate=pass runner=systemd unit=validate-proj-__HOME_-RUN" \
    "a worktree whose path carries a \$ runs in a unit and passes" "$ERR"
  MUTANT_FILE=lib/job-unit.sh mutant mutant-unescaped 'unit_argv+=("$(job_unit_arg "$arg")")' 'unit_argv+=("$arg")'
  run_script "$MUTANT" --worktree "$proj_dollar" --poll 1
  assert_eq "$(verdict_of "$OUT")" "state=lost cap-secs=31 validate=FAILING" \
    "control: unescaped, the manager rewrites that path and the child never finds its run" "$ERR"
else
  echo "  skip  no systemd user manager answers on this host; the unit rows did not run"
fi

# The setsid fallback, on a PATH with no systemd-run, holds what stays in its
# process group.
RUN_PATH="$(farm_path fallback)"
proj_group="$(make_proj proj-group 'sleep 300 & echo $! > grand.pid; exit 0' 20)"
run_script "$RUN" --worktree "$proj_group" --poll 1
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=0 validate=pass" \
  "a run on a host with no systemd-run passes under setsid" "$ERR"
assert_eq "$(runner_line "$OUT")" "runner=setsid reason=no-systemd-run" \
  "and its log opens naming that runner and why" "$ERR"
assert_eq "$(grandchild_state "$proj_group")" "gone" \
  "and a grandchild left in its process group is gone once it completes" "$ERR"

# Control: the child records its verdict and exits without ending its group.
mutant mutant-no-group-kill '    setsid) kill -KILL -- "-$$" ;;' '    setsid) ;;'
run_script "$MUTANT" --worktree "$proj_group" --poll 1
assert_eq "$(grandchild_state "$proj_group")" "alive" \
  "control: without the group kill that grandchild outlives the run" "$ERR"

# Where systemd-run is installed and fails, the run is still made under setsid
# and its log carries systemd-run's own first line. The stubs fail the probe
# unit, or start only that unit.
FALLBACK_PATH="$RUN_PATH"
mkdir -p "$TMP_ROOT/probe-bin" "$TMP_ROOT/refusing-bin"
printf '#!/usr/bin/env bash\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$TMP_ROOT/probe-bin/systemd-run"
printf '#!/usr/bin/env bash\n[[ "${*: -1}" == true ]] && exit 0\necho "Failed to start transient service unit: refused" >&2\nexit 1\n' > "$TMP_ROOT/refusing-bin/systemd-run"
chmod +x "$TMP_ROOT/probe-bin/systemd-run" "$TMP_ROOT/refusing-bin/systemd-run"
proj_refused="$(make_proj proj-refused "echo ran" 20)"
# stub dir|the log's first line
FALLBACK_ROWS=(
  "probe-bin|runner=setsid reason=probe-failed detail=Failed to connect to bus: No medium found"
  "refusing-bin|runner=setsid reason=unit-launch-failed detail=Failed to start transient service unit: refused"
)
for row in "${FALLBACK_ROWS[@]}"; do
  IFS='|' read -r stub want_line <<<"$row"
  RUN_PATH="$TMP_ROOT/$stub:$FALLBACK_PATH"
  run_script "$RUN" --worktree "$proj_refused" --poll 1
  assert_eq "$(verdict_of "$OUT") $(output_of "$OUT")" "state=done guard-exit=0 validate=pass ran" \
    "a systemd-run from $stub still gets a run, under setsid" "$ERR"
  assert_eq "$(runner_line "$OUT")" "$want_line" \
    "and the log names why, in systemd-run's words" "$ERR"
done

# Control: the refused unit is not replaced, so no run is started at all.
MUTANT_FILE=lib/job-unit.sh mutant mutant-no-fallback '    command -v setsid >/dev/null 2>&1 || return 2' '    return 2'
run_script "$MUTANT" --worktree "$proj_refused" --poll 1
assert_eq "$(verdict_of "$OUT")|$RC" "|2" \
  "control: without the fallback a refused unit leaves no run at all" "$ERR"
RUN_PATH=""

# --- --stop ends the runs a worktree's run directories record ------------------
# The run is started detached and still going when --stop is called, as a lane
# closed mid-validation leaves it. PATH is empty for this host's own runner.
STOP_CALLER=""
start_long_run() { # PROJ PATH
  local out="$1.out" n=0
  setsid bash -c "env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS PATH='${2:-$PATH}' '$RUN' --worktree '$1' --poll 1 > '$out' 2>&1" &
  STOP_CALLER=$!
  while [[ ! -s "$1/grand.pid" ]] && (( n < 100 )); do sleep 0.1; n=$((n + 1)); done
}
end_long_run() {
  kill -KILL -- "-$STOP_CALLER" 2>/dev/null || true
  wait "$STOP_CALLER" 2>/dev/null || true
}
long_cmd='sleep 300 & echo $! > grand.pid; sleep 300'

if [[ "$HOST_RUNNER" == systemd ]]; then
  proj_stop_unit="$(make_proj proj-stop-unit "setsid $long_cmd" 600)"
  start_long_run "$proj_stop_unit" ""
  run_script "$RUN" --stop --worktree "$proj_stop_unit"
  assert_eq "$OUT $RC" "state=stopped units=1 groups=0 0" \
    "--stop stops the unit its worktree's run records name" "$ERR"
  assert_eq "$(grandchild_state "$proj_stop_unit")" "gone" \
    "and the unit's grandchild that started its own session is gone with it" "$ERR"
  end_long_run

  # Control: the unit is never stopped, so the running one keeps its
  # grandchild.
  MUTANT_FILE=lib/job-unit.sh mutant mutant-no-unit-stop 'out="$(systemctl --user stop -- "$1.service" 2>&1)"' 'out="$(true)"'
  proj_stop_kept="$(make_proj proj-stop-kept "setsid $long_cmd" 600)"
  start_long_run "$proj_stop_kept" ""
  run_script "$MUTANT" --stop --worktree "$proj_stop_kept"
  assert_eq "$(grandchild_state "$proj_stop_kept")" "alive" \
    "control: with no unit stopped the running validation's grandchild survives --stop" "$ERR"
  end_long_run
  run_script "$RUN" --stop --worktree "$proj_stop_kept"

  # Two worktrees of one name under different parents, as two repositories'
  # lanes for the same item are: stopping one leaves the other's unit running.
  proj_twin_a="$(make_proj twin-a/proj-twin "setsid $long_cmd" 600)"
  proj_twin_b="$(make_proj twin-b/proj-twin "exit 0" 20)"
  start_long_run "$proj_twin_a" ""
  run_script "$RUN" --stop --worktree "$proj_twin_b"
  assert_eq "$OUT $RC $(state_of "$(cat "$proj_twin_a/grand.pid")")" "state=stopped units=0 groups=0 0 alive" \
    "--stop on one worktree leaves a same-named worktree's unit running" "$ERR"
  run_script "$RUN" --stop --worktree "$proj_twin_a"
  assert_eq "$OUT $(grandchild_state "$proj_twin_a")" "state=stopped units=1 groups=0 gone" \
    "and stops it when that worktree is the one named" "$ERR"
  end_long_run

  # A caller that cannot reach the manager is told so, never that nothing ran.
  proj_nobus="$(make_proj proj-no-bus "setsid $long_cmd" 600)"
  start_long_run "$proj_nobus" ""
  nobus_dir="$(ls -d "$proj_nobus"/tmp/dev-validate-*)"
  nobus_unit="$(sed -n 's/^unit=//p' "$nobus_dir/runner").service"
  set +e
  nobus_err="$(env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS "$RUN" --stop --worktree "$proj_nobus" 2>&1 >/dev/null)"
  nobus_rc=$?
  set -e
  assert_eq "$(sed -n '1s/ detail=.*$//p' <<<"$nobus_err") $nobus_rc" \
    "dev-validate-run: stop-failed run-dir=$nobus_dir unit=$nobus_unit 1" \
    "--stop with no bus to the manager fails naming the unit it could not stop" "$nobus_err"
  run_script "$RUN" --stop --worktree "$proj_nobus"
  grandchild_state "$proj_nobus" >/dev/null
  end_long_run
fi

RUN_PATH="$(farm_path fallback)"
proj_stop_group="$(make_proj proj-stop-group "$long_cmd" 600)"
start_long_run "$proj_stop_group" "$RUN_PATH"
stop_child="$(cat "$proj_stop_group"/tmp/dev-validate-*/pid 2>/dev/null || true)"
run_script "$RUN" --stop --worktree "$proj_stop_group"
assert_eq "$OUT $RC" "state=stopped units=0 groups=1 0" \
  "--stop on a host with no user manager ends each setsid run's group" "$ERR"
assert_eq "$(state_of "$stop_child") $(grandchild_state "$proj_stop_group")" "gone gone" \
  "and the run's child and the grandchild in its group are gone" "$ERR"
end_long_run

# Control: the group is never signalled, so the run goes on.
mutant mutant-no-group-stop 'kill -KILL -- "-$pid" 2>/dev/null ||' 'true ||'
proj_stop_left="$(make_proj proj-stop-left "$long_cmd" 600)"
start_long_run "$proj_stop_left" "$RUN_PATH"
stop_child="$(cat "$proj_stop_left"/tmp/dev-validate-*/pid 2>/dev/null || true)"
run_script "$MUTANT" --stop --worktree "$proj_stop_left"
assert_eq "$(state_of "$stop_child") $(grandchild_state "$proj_stop_left")" "alive alive" \
  "control: without the group kill --stop leaves the run and its grandchild running" "$ERR"
kill -KILL -- "-$stop_child" 2>/dev/null || true
end_long_run
RUN_PATH=""

# --- Which recorded runs --stop may signal -------------------------------------
# One planted run record per worktree, naming a live process that leads its own
# group: `child` carries a run child's argv tail for that directory, `other` is
# a plain sleep, and `dead` is a pid that has exited. The systemctl stub stops
# whatever it is asked to, so a unit record is counted and never signalled.
mkdir -p "$TMP_ROOT/stop-bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/stop-bin/systemctl"
chmod +x "$TMP_ROOT/stop-bin/systemctl"
# plant sets PLANT_PROJ and PLANTED rather than printing them: a command
# substitution would wait on the planted process holding its output open.
PLANTED=""
PLANT_PROJ=""
plant() { # NAME RUNNER VERDICT PROCESS
  local dir
  PLANT_PROJ="$TMP_ROOT/planted/$1"
  dir="$PLANT_PROJ/tmp/dev-validate-planted-$1"
  mkdir -p "$dir"
  printf 'runner=%s\nunit=validate-planted-%s\nline=planted\n' "$2" "$1" > "$dir/runner"
  [[ "$3" == no ]] || printf 'guard-exit=0 at=now\n' > "$dir/exit"
  case "$4" in
    child) setsid bash -c 'sleep 300; :' planted --child --run-dir "$dir" </dev/null >/dev/null 2>&1 & PLANTED=$!; disown "$PLANTED" ;;
    other) setsid sleep 300 </dev/null >/dev/null 2>&1 & PLANTED=$!; disown "$PLANTED" ;;
    dead) sleep 0 & PLANTED=$!; wait "$PLANTED" ;;
  esac
  printf '%s\n' "$PLANTED" > "$dir/pid"
  sleep 0.2
}
# name|runner|verdict recorded|process|what --stop prints|the process after
PLANT_ROWS=(
  "run-child|setsid|no|child|state=stopped units=0 groups=1|gone"
  "reused-pid|setsid|no|other|state=stopped units=0 groups=0|alive"
  "has-verdict|setsid|yes|child|state=stopped units=0 groups=0|alive"
  "unit-run|systemd|no|child|state=stopped units=1 groups=0|alive"
  "gone-pid|setsid|no|dead|state=stopped units=0 groups=0|gone"
)
# name%the one line of --stop each control removes%what that control then sees
PLANT_CONTROLS=(
  'reused-pid%        [[ "$args" == *" --child --run-dir "*"/tmp/${dir##*/}" ]] || continue%state=stopped units=0 groups=1 0 gone'
  'has-verdict%    [[ ! -s "$dir/exit" ]] || continue%state=stopped units=0 groups=1 0 gone'
  'unit-run%    case "$(start_field "$runner_file" runner)" in%state=stopped units=0 groups=1 0 gone'
  'gone-pid%          kill -0 "$pid" 2>/dev/null || continue% 1 gone'
)
RUN_PATH="$TMP_ROOT/stop-bin:$PATH"
for row in "${PLANT_ROWS[@]}"; do
  IFS='|' read -r name runner verdict process want_out want_state <<<"$row"
  plant "$name" "$runner" "$verdict" "$process"
  proj="$PLANT_PROJ"
  run_script "$RUN" --stop --worktree "$proj"
  assert_eq "$OUT $RC $(state_of "$PLANTED")" "$want_out 0 $want_state" \
    "--stop on a planted $name record" "$ERR"
  kill -KILL -- "-$PLANTED" 2>/dev/null || true
  rm -rf -- "$proj"
done
for row in "${PLANT_CONTROLS[@]}"; do
  IFS='%' read -r name line want <<<"$row"
  for plant_row in "${PLANT_ROWS[@]}"; do
    [[ "$plant_row" == "$name|"* ]] || continue
    IFS='|' read -r _ runner verdict process _ _ <<<"$plant_row"
  done
  case "$line" in
    *'case "$(start_field'*) mutant "mutant-plant-$name" "$line" '    case setsid in' ;;
    *) mutant "mutant-plant-$name" "$line" "${line%%[^ ]*}:" ;;
  esac
  plant "$name" "$runner" "$verdict" "$process"
  proj="$PLANT_PROJ"
  run_script "$MUTANT" --stop --worktree "$proj"
  assert_eq "$OUT $RC $(state_of "$PLANTED")" "$want" \
    "control: without that line --stop on the $name record signals or fails" "$ERR"
  kill -KILL -- "-$PLANTED" 2>/dev/null || true
  rm -rf -- "$proj"
done

# A systemctl that cannot stop a unit the record names, and cannot say it has
# ended, fails --stop: exit 1 and the stop-failed line lane-close refuses on.
printf '#!/usr/bin/env bash\necho "stub refused" >&2\nexit 1\n' > "$TMP_ROOT/stop-bin/systemctl"
plant unit-refused systemd no other
proj="$PLANT_PROJ"
run_script "$RUN" --stop --worktree "$proj"
assert_eq "$(sed -n 1p <<<"$ERR") $RC" \
  "dev-validate-run: stop-failed run-dir=$proj/tmp/dev-validate-planted-unit-refused unit=validate-planted-unit-refused.service detail=stub refused 1" \
  "a unit systemctl will not stop fails --stop, naming it" "$ERR"
mutant mutant-stop-exit-0 'in this worktree may still be running.' "in this worktree.'; exit 0; printf '"
run_script "$MUTANT" --stop --worktree "$proj"
assert_eq "$RC" "0" "control: a stop failure that exits 0 reads as a clean stop" "$ERR"
kill -KILL -- "-$PLANTED" 2>/dev/null || true
RUN_PATH=""

# --- A value option given twice is refused, never half-read ---------------------
run_script "$RUN" --worktree "$proj_probe" --worktree "$proj_log" --poll 1
assert_eq "$(sed -n 1p <<<"$ERR") $RC" "dev-validate-run: repeated option=--worktree 2" \
  "a second --worktree is refused rather than silently winning"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
