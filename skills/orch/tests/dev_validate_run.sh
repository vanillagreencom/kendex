#!/usr/bin/env bash
# Tests for dev-validate-run, the bounded runner a dev agent validates through.
#
# The script runs DEV_VALIDATE_CMD under DEV_VALIDATE_TIMEOUT_SECS, detaches it,
# and records one `guard-exit=N at=TIME` sentinel beside the log. A waiter reads
# the verdict from that file, with a cap derived from the setting rather than
# chosen by the agent. The rows below pin each of those.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/skills/orch/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "dev_validate_run: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "dev_validate_run: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "dev_validate_run: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

RUN="$SCRIPTS_DIR/dev-validate-run"

# start_of RUN_DIR — the epoch second the run's start record names, which its
# --record line carries.
start_of() { sed -n 's/^start=//p' "$1/start"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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
  OUT="$(env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_BASE \
    -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS -u WORKTREE_DEFAULT_BRANCH -u DEV_VALIDATE_CI_CONTEXT \
    ${INHERITED_CLASS:+DEV_VALIDATE_CLASS=$INHERITED_CLASS} \
    PATH="${RUN_PATH:-$PATH}" "$script" "$@" 2>"$err")"
  RC=$?
  set -e
  ERR="$err"
}

# The run directory the start line names, which every later read addresses.
run_dir_of() { # OUTPUT
  sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$1"
}

# The verdict fields a caller acts on, in a fixed order, from the last line.
verdict_of() { # OUTPUT
  sed -n 's/^\(state=[a-z]*\) \(guard-exit=[0-9]*\) at=[^ ]* \(validate=[A-Za-z-]*\).*$/\1 \2 \3/p;s/^\(state=timeout\) elapsed-secs=[0-9]* cap-secs=\([0-9]*\) \(validate=[A-Za-z]*\).*$/\1 cap-secs=\2 \3/p;s/^\(state=lost\) elapsed-secs=[0-9]* cap-secs=\([0-9]*\) \(validate=[A-Za-z]*\).*$/\1 cap-secs=\2 \3/p;s/^\(state=running\) elapsed-secs=[0-9]* \(cap-secs=[0-9]*\).*$/\1 \2/p' <<<"$1" | sed -n '$p'
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

# One control per mode the suite runs (a start, --record, --stop and
# --resolve-mode): a private copy of dev-validate-run with one literal
# substitution, beside links to the shipped scripts it calls. mutate_file's
# count assertions are the edit's proof. The copy's path lands in MUTANT rather
# than on stdout, which the assertions own.
MUTANT=""
mutant() { # NAME OLD NEW
  MUTANT="$(mutant_scripts "$1" dev-validate-run)/dev-validate-run" || exit 1
  mutate_file "$MUTANT" "$2" "$3"
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
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: missing-command commands=timeout,gtimeout" \
  "a host carrying neither timeout spelling is refused, never run unbounded"
assert_eq "$RC" "2" "and exits 2"

# setsid is looked up after the bound, so this row needs one of the two present.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  RUN_PATH="$(farm_path no-setsid setsid)"
  run_script "$RUN" --worktree "$proj_dep" --poll 1
  assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: missing-command commands=setsid" \
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
  "a command that exits 124 itself inside the bound fails the round|exit 124|20|state=done guard-exit=124 validate=FAILING|1"
  "a command that exits 137 itself fails the round|exit 137|20|state=done guard-exit=137 validate=FAILING|1"
  "a command that outlives the bound is cut off at it: no verdict, neither pass nor FAILING|sleep 30|2|state=done guard-exit=124 validate=no-verdict|1"
)
row_n=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r label cmd secs want_verdict want_rc <<<"$row"
  row_n=$((row_n + 1))
  proj="$(make_proj "proj-row-$row_n" "$cmd" "$secs")"
  run_script "$RUN" --worktree "$proj" --poll 1
  assert_eq "$(verdict_of "$OUT")" "$want_verdict" "$label" "$ERR"
  assert_eq "$RC" "$want_rc" "$label — exit status" "$ERR"
done

# The last run above is the timeout one; its own sentinel and log are the files
# a waiter in another process reads.
timeout_dir="$(run_dir_of "$OUT")"
assert_eq "$(sed 's/ at=[^ ]*//' "$timeout_dir/exit")" "guard-exit=124 verdict=no-verdict" \
  "the sentinel file carries the guard-exit line and the bound's verdict on one line"
assert_eq "$(sed -n 's/^guard-exit=[0-9]* at=\([^ ]*\).*$/\1/p' "$timeout_dir/exit" | grep -c -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1" \
  "and one UTC timestamp beside it"
# The wall time beside it: its three lines, its end the sentinel's own at=, its
# seconds that span, and the span the command's, which a 2-second bound killed.
# A missing file reads empty, so its rows fail rather than end the suite.
timing_field() { sed -n "s/^$1=//p" "$timeout_dir/timing" 2>/dev/null || true; }
t_start="$(timing_field started-at)"
t_end="$(timing_field ended-at)"
t_secs="$(timing_field seconds)"
assert_eq "$(sed 's/=.*//' "$timeout_dir/timing" 2>/dev/null | tr '\n' ' ' || true)" "started-at ended-at seconds " \
  "the timing file carries the start, the end and the seconds on their own"
assert_eq "$t_end" "$(sed -n 's/^guard-exit=[0-9]* at=\([^ ]*\).*$/\1/p' "$timeout_dir/exit")" \
  "and its end is the time the sentinel records"
assert_eq "$t_secs" "$(jq -n --arg a "$t_start" --arg b "$t_end" '($b | fromdateiso8601) - ($a | fromdateiso8601)')" \
  "and its seconds are the span from its start to its end"
assert_eq "$([[ "$t_secs" -ge 2 ]] && echo within || echo "outside:$t_secs")" "within" \
  "and the span is the command's: at least its 2-second bound"
run_script "$RUN" --record --run-dir "$timeout_dir"
assert_eq "$OUT rc=$RC" "validate-mode=full selection=unreported verdict=no-verdict head= start=$(start_of "$timeout_dir") seconds=$t_secs started-at=$t_start ended-at=$t_end rc=0" \
  "the record of a run killed at its bound reads no-verdict, never pass or FAILING, and carries its wall time" "$ERR"

# --record's control: a sentinel reader that files the bound's verdict with the
# failures hands the receipt a FAILING for that same cut-off run.
mutant mutant-cut-failing '*" verdict=no-verdict") SENTINEL_VERDICT=no-verdict ;;' '*" verdict=no-verdict") SENTINEL_VERDICT=FAILING ;;'
run_script "$MUTANT" --record --run-dir "$timeout_dir"
assert_eq "$OUT" "validate-mode=full selection=unreported verdict=FAILING head= start=$(start_of "$timeout_dir") seconds=$t_secs started-at=$t_start ended-at=$t_end" \
  "control: with the bound's verdict unread the cut-off run's record reads FAILING" "$ERR"

# DEV_VALIDATE_CMD's optional line reports lanes independently of invocation mode.
# A malformed last candidate must not borrow an earlier valid report.
lane_dir="$(validate_run_dir "$TMP_ROOT/lane-record" full)"
LANE_ROWS=(
  "all lanes|validate: lanes=lint,test selection=all|lanes=lint,test selection=all"
  "subset|validate: lanes=unit-test,types.v2,lint_1 selection=subset|lanes=unit-test,types.v2,lint_1 selection=subset"
  "no line|build passed|selection=unreported"
  "empty names|validate: lanes= selection=all|selection=unreported"
  "empty element|validate: lanes=lint,,test selection=subset|selection=unreported"
  "trailing comma|validate: lanes=lint, selection=all|selection=unreported"
  "unknown selection|validate: lanes=lint selection=some|selection=unreported"
  "extra field|validate: lanes=lint selection=all extra=yes|selection=unreported"
  "wrong order|validate: selection=all lanes=lint|selection=unreported"
  "last valid|validate: lanes=lint selection=all\nvalidate: lanes=test selection=subset|lanes=test selection=subset"
  "last malformed|validate: lanes=lint selection=all\nvalidate: lanes= selection=subset|selection=unreported"
)
for row in "${LANE_ROWS[@]}"; do
  IFS='|' read -r label log want <<<"$row"
  printf '%b\n' "$log" > "$lane_dir/log"
  run_script "$RUN" --record --run-dir "$lane_dir"
  assert_eq "$RC|${OUT%% verdict=*}" "0|validate-mode=full $want" "lane record: $label" "$ERR"
done
rm -- "${lane_dir:?}/log"
run_script "$RUN" --record --run-dir "$lane_dir"
assert_eq "$RC|${OUT%% verdict=*}" "0|validate-mode=full selection=unreported" "a missing log reports no lanes" "$ERR"
printf 'validate: lanes=lint,test selection=subset\n' > "$lane_dir/log"
# Removing metadata from the output restores the previous record behavior.
mutant mutant-lanes-unreported '"$record_mode" "$record_selection" "$record_verdict"' '"$record_mode" "" "$record_verdict"'
run_script "$MUTANT" --record --run-dir "$lane_dir"
assert_eq "$RC|${OUT%% verdict=*}" "0|validate-mode=full " "control: the old record behavior reds the reported-lanes assertion" "$ERR"

# The start's control: with the own-exit marker never written, a command's own
# exit 124 reads as the bound's.
mutant mutant-no-own-exit 'rc=$?; : > "$2"; exit "$rc"' 'rc=$?; exit "$rc"'
run_script "$MUTANT" --worktree "$(make_proj proj-own-124 "exit 124" 20)" --poll 1
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=124 validate=no-verdict" \
  "control: without the own-exit marker a command's own 124 reads as the bound's" "$ERR"

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

# --- The mode picks the command, and the run records the mode that ran --------
# A committed project whose full battery and range command each print which one
# ran; the range command also prints the base it was handed.
make_mode_proj() { # NAME RANGE_CMD — RANGE_CMD empty leaves the setting unset
  local dir
  dir="$(make_proj "$1" "echo full" 20)"
  [[ -z "$2" ]] || printf 'DEV_VALIDATE_RANGE_CMD = "%s"\n' "$2" >> "$dir/kendex.settings.toml"
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
  git -C "$dir" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
  printf '%s\n' "$dir"
}
start_line() { # RUN_DIR KEY — one line of the run's start record
  sed -n "s/^$2=//p" "$1/start"
}
RANGE_CMD='echo range $DEV_VALIDATE_BASE'
# label|project's range command|arguments|log|validate-mode|validate-base is the head (yes/no)|record's class base
MODE_ROWS=(
  "a run given no mode runs the whole battery and records full|$RANGE_CMD||full|full|no|"
  "a range run runs the range command against the commit its base names|$RANGE_CMD|--validate-mode range --base HEAD|range HEAD|range|yes| class-base=HEAD"
  "a range run in a project with no range command runs the whole battery and records full, with the class base that run read||--validate-mode range --base HEAD|full|full|no| class-base=HEAD"
)
n=0
for row in "${MODE_ROWS[@]}"; do
  IFS='|' read -r label range_cmd args want_log want_mode want_base want_class_base <<<"$row"
  n=$((n + 1))
  proj="$(make_mode_proj "proj-mode-$n" "$range_cmd")"
  head_sha="$(git -C "$proj" rev-parse HEAD)"
  want_log="${want_log/HEAD/$head_sha}"
  want_class_base="${want_class_base/HEAD/$head_sha}"
  # shellcheck disable=SC2086 # the row's argument list, split on purpose
  run_script "$RUN" --worktree "$proj" --poll 1 $args
  mode_dir="$(run_dir_of "$OUT")"
  got_base=no
  [[ "$(start_line "$mode_dir" validate-base)" != "$head_sha" ]] || got_base=yes
  assert_eq "$(verdict_of "$OUT") $(output_of "$OUT")" "state=done guard-exit=0 validate=pass $want_log" "$label" "$ERR"
  assert_eq "$(start_line "$mode_dir" validate-mode) base=$got_base" "$want_mode base=$want_base" \
    "$label — the start record names the mode and base that ran" "$ERR"
  run_script "$RUN" --record --run-dir "$mode_dir"
  assert_eq "$(sed -E 's/ seconds=[0-9]+ started-at=[^ ]+ ended-at=[^ ]+$/ seconds=N started-at=T ended-at=T/' <<<"$OUT")" \
    "validate-mode=$want_mode selection=unreported verdict=pass head=$head_sha start=$(start_of "$mode_dir")$want_class_base seconds=N started-at=T ended-at=T" \
    "$label — the run's record names that mode, the pass, the HEAD and second it started at, any class base and its wall time" "$ERR"
done
# The last range run's started line keeps the shape every waiter reads; the
# class fields that close it are the classifier rows' to pin.
proj="$(make_mode_proj proj-mode-line "$RANGE_CMD")"
run_script "$RUN" --worktree "$proj" --poll 1 --validate-mode range --base HEAD
mode_dir="$(run_dir_of "$OUT")"
assert_eq "$(sed -n '1s/ class=[a-z]* docs-only=[a-z]*\( class-fallback=[a-z0-9-]*\)\{0,1\}$//p' <<<"$OUT")" \
  "state=started run-dir=$mode_dir log=$mode_dir/log sentinel=$mode_dir/exit timeout-secs=20 poll-secs=1 cap-secs=31" \
  "a range run prints the same started line as a full one" "$ERR"

# --- --resolve-mode names the mode a range run records, and starts nothing ----
# label|project's range command|mode printed
RESOLVE_ROWS=(
  "a project with a range command resolves a range request to range|$RANGE_CMD|range"
  "a project with no range command resolves a range request to full||full"
)
n=0
for row in "${RESOLVE_ROWS[@]}"; do
  IFS='|' read -r label range_cmd want_mode <<<"$row"
  n=$((n + 1))
  proj="$(make_mode_proj "proj-resolve-$n" "$range_cmd")"
  run_script "$RUN" --resolve-mode --worktree "$proj"
  assert_eq "$OUT rc=$RC runs=$(find "$proj" -maxdepth 2 -name 'dev-validate-*' | wc -l | tr -d ' ')" \
    "validate-mode=$want_mode rc=0 runs=0" "$label" "$ERR"
done
# Control: a resolution that never reads the range command names full for the
# project that sets one.
mutant mutant-resolve-full $'  else\n    validate_mode=range' $'  else\n    validate_mode=full'
run_script "$MUTANT" --resolve-mode --worktree "$TMP_ROOT/proj-resolve-1"
assert_eq "$OUT" "validate-mode=full" \
  "control: with the range command unread the project that sets one resolves to full" "$ERR"
# --- A range base a rebase left off the branch ---------------------------------
# A branch that forked from main, committed b1 (the round's recorded base, the
# pre-rebase head), and was then rebased over the three commits main gained and
# given the round's own commit r1. The range command prints the files the range
# it was handed holds.
orphan_commit() { # DIR FILE — one commit adding FILE
  : > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" -c user.name=t -c user.email=t@example.com commit -q -m "$2"
}
proj_orphan="$(make_proj proj-orphan "echo full" 20)"
printf 'DEV_VALIDATE_RANGE_CMD = "git diff --name-only $DEV_VALIDATE_BASE HEAD"\n' >> "$proj_orphan/kendex.settings.toml"
git -C "$proj_orphan" config gc.auto 0
git -C "$proj_orphan" config maintenance.auto false
git -C "$proj_orphan" checkout -q -b main
orphan_commit "$proj_orphan" base
git -C "$proj_orphan" checkout -q -b ken-1
orphan_commit "$proj_orphan" b1
pre_rebase="$(git -C "$proj_orphan" rev-parse HEAD)"
git -C "$proj_orphan" checkout -q main
for f in m1 m2 m3; do orphan_commit "$proj_orphan" "$f"; done
git -C "$proj_orphan" update-ref refs/remotes/origin/main main
git -C "$proj_orphan" checkout -q ken-1
git -C "$proj_orphan" -c user.name=t -c user.email=t@example.com rebase -q main
rebased_b1="$(git -C "$proj_orphan" rev-parse HEAD)"
orphan_commit "$proj_orphan" r1
fork="$(git -C "$proj_orphan" rev-parse main)"

# label|--base|files the range holds|validate-base|validate-base-orphaned|class-base
ORPHAN_ROWS=(
  "a base the rebase left off the branch validates the branch's own diff|$pre_rebase|b1 r1 |$fork|$pre_rebase|"
  "a base still on the branch validates from that base, as before|$rebased_b1|r1 |$rebased_b1||$rebased_b1"
)
# One field of a --record line, empty where the line carries none.
record_field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }
for row in "${ORPHAN_ROWS[@]}"; do
  IFS='|' read -r label base want_range want_base want_orphaned want_class_base <<<"$row"
  run_script "$RUN" --worktree "$proj_orphan" --poll 1 --validate-mode range --base "$base"
  orphan_dir="$(run_dir_of "$OUT")"
  assert_eq "$RC $(output_of "$OUT" | tr '\n' ' ')" "0 $want_range" "$label" "$ERR"
  assert_eq "$(start_line "$orphan_dir" validate-base)|$(start_line "$orphan_dir" validate-base-orphaned)" \
    "$want_base|$want_orphaned" "$label — the start record names the base that ran and the orphaned one" "$ERR"
  run_script "$RUN" --record --run-dir "$orphan_dir"
  assert_eq "$RC $(record_field validate-base-orphaned "$OUT")|$(record_field class-base "$OUT")" "0 $want_orphaned|$want_class_base" \
    "$label — the record names the orphaned base a fix receipt binds through, and the base its class was read from" "$ERR"
done

# An orphaned base with no origin base branch to take a fork point from is
# refused, never run over the orphaned range.
git -C "$proj_orphan" update-ref -d refs/remotes/origin/main
run_script "$RUN" --worktree "$proj_orphan" --poll 1 --validate-mode range --base "$pre_rebase"
assert_eq "$RC $(grep '^dev-validate-run: ' <"$ERR")" "2 dev-validate-run: orphaned-base-unresolved base=$pre_rebase" \
  "an orphaned base with no origin base branch is refused, naming the base"

# A project with no range command runs its whole battery on an orphaned base,
# which needs no fork point, so a missing origin base branch refuses nothing.
proj_orphan_full="$TMP_ROOT/proj-orphan-full"
cp -R "$proj_orphan" "$proj_orphan_full"
grep -v '^DEV_VALIDATE_RANGE_CMD' "$proj_orphan/kendex.settings.toml" > "$proj_orphan_full/kendex.settings.toml"
# It still records the orphaned base, which a fix receipt binds through.
run_script "$RUN" --worktree "$proj_orphan_full" --poll 1 --validate-mode range --base "$pre_rebase"
full_dir="$(run_dir_of "$OUT")"
assert_eq "$RC $(output_of "$OUT") $(start_line "$full_dir" validate-mode) $(start_line "$full_dir" validate-base-orphaned)" \
  "0 full full $pre_rebase" \
  "an orphaned base in a project with no range command runs the whole battery and records the base" "$ERR"

# --- A command that ignores SIGTERM is still ended inside the bound -----------
# Fixtures in this repository trap TERM by construction. The bound's TERM ends
# the wrapper the command runs under, whatever the command does with it, and
# the teardown ends the command after the verdict. A run held open past the
# setting would leave no sentinel: the elapsed assertion is what reddens on
# that; the command would otherwise run forty seconds and the waiter would
# report the cap instead.
proj_term="$(make_proj proj-term "trap '' TERM; sleep 40" 2)"
term_start="$(date +%s)"
run_script "$RUN" --worktree "$proj_term" --poll 5
term_elapsed=$(( $(date +%s) - term_start ))
assert_eq "$(verdict_of "$OUT")" "state=done guard-exit=124 validate=no-verdict" \
  "a command that ignores SIGTERM still ends the run at its bound with the bound's verdict" "$ERR"
assert_eq "$RC" "1" "and exits 1, which is never a pass" "$ERR"
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
run_script "$RUN" --record --run-dir "$slow_dir"
assert_eq "$OUT rc=$RC" "validate-mode=full selection=unreported verdict=unfinished head= start=$(start_of "$slow_dir") rc=0" \
  "the record of a run still going reads unfinished, never pass" "$ERR"
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
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: empty-validate-cmd setting=DEV_VALIDATE_CMD" \
  "an empty validation command is refused, naming the setting"
assert_eq "$RC" "2" "and exits 2"

proj_zero="$(make_proj proj-zero "echo x" 0)"
run_script "$RUN" --worktree "$proj_zero" --poll 1
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: invalid-seconds setting=DEV_VALIDATE_TIMEOUT_SECS value=0" \
  "a bound of zero is refused rather than read as no bound"
assert_eq "$RC" "2" "and exits 2"

proj_words="$(make_proj proj-words "echo x" 90m)"
run_script "$RUN" --worktree "$proj_words" --poll 1
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: invalid-seconds setting=DEV_VALIDATE_TIMEOUT_SECS value=90m" \
  "a bound written as a duration is refused, not silently read as the default hour"
assert_eq "$RC" "2" "and exits 2"

mkdir -p "$TMP_ROOT/unstarted"
run_script "$RUN" --wait --run-dir "$TMP_ROOT/unstarted"
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: no-run path=$TMP_ROOT/unstarted/start" \
  "a poll of a directory no run started is refused"
assert_eq "$RC" "2" "and exits 2"

run_script "$RUN" --wait --run-dir "$stale" --poll 5
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: option-unused option=--poll mode=wait" \
  "a poll interval handed to the waiter is refused, never silently dropped"
assert_eq "$RC" "2" "and exits 2"

run_script "$RUN" --worktree "$proj_log" --budget 5
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: option-unused option=--budget mode=start" \
  "a call budget handed to the blocking form is refused the same way"
assert_eq "$RC" "2" "and exits 2"

run_script "$RUN" --poll 1
assert_eq "$(sed -n 1p <"$ERR")" "dev-validate-run: required options=--worktree,--wait,--stop,--record,--resolve-mode,--child" \
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
cp -R "$SCRIPTS_DIR/lib/." "$LAYOUT/orch/scripts/lib/"
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
git -C "$repo" ls-tree -r "$head" > "$STUB_SEEN.tree" 2>&1
case "$STUB_ANSWER" in
  exit-2) echo "wiring-error: cause=stub" >&2; exit 2 ;;
  *) printf '%s\n' "$STUB_ANSWER" ;;
esac
# The classifier's own measured marker, where the row names one.
[[ -z "${STUB_MEASURED:-}" ]] \
  || printf 'class: class=%s measured=%s cause=stub\n' "${STUB_ANSWER#change_class=}" "$STUB_MEASURED" >&2
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
rm -f "$proj_class/draft.md"

# A staged file rewritten in the second its index was written, at its staged
# size, is in the head judged: git trusts an entry's stat data once the index
# is newer than its file, so an index copy stamped at copy time hides the
# rewrite. The control copies the index plainly and the staged text stays.
mtime_of() { perl -e 'print((stat shift)[9])' "$1"; }
racy_blob() { # SCRIPT — the blob the head judged holds for racy.txt, in RACY_BLOB
  local file="$proj_class/racy.txt" first _
  for _ in 1 2 3 4 5; do
    printf 'aaaa\n' > "$file"
    first="$(mtime_of "$file")"
    git -C "$proj_class" add racy.txt
    printf 'bbbb\n' > "$file"
    [[ "$(mtime_of "$file")" != "$first" ]] || break
  done
  assert_eq "$(mtime_of "$file")" "$first" "the fixture stages and rewrites racy.txt in one second"
  # A real wait: only a copy stamped in a later second trusts the stale entry.
  sleep 1
  run_script "$1" --worktree "$proj_class" --poll 1
  RACY_BLOB="$(awk '$4 == "racy.txt" { print $3 }' "$STUB_SEEN.tree")"
  git -C "$proj_class" rm -q --cached -f racy.txt
}
racy_blob "$LAYOUT/orch/scripts/dev-validate-run"
assert_eq "$RACY_BLOB" "$(git -C "$proj_class" hash-object racy.txt)" \
  "a same-second, same-size rewrite of a staged file is in the head judged" "$ERR"
cp -p -- "$LAYOUT/orch/scripts/dev-validate-run" "$TMP_ROOT/dev-validate-run.kept"
# shellcheck disable=SC2016 # the script's own text, not an expansion
mutate_file "$LAYOUT/orch/scripts/dev-validate-run" 'cp -p -- "$index"' 'cp -- "$index"'
racy_blob "$LAYOUT/orch/scripts/dev-validate-run"
assert_eq "$RACY_BLOB" "$(printf 'aaaa\n' | git hash-object --stdin)" \
  "control: a plain index copy keeps the staged text" "$ERR"
cp -p -- "$TMP_ROOT/dev-validate-run.kept" "$LAYOUT/orch/scripts/dev-validate-run"
rm -f "$proj_class/racy.txt"

# With no classifier installed the class is standard, and says why.
mv "$LAYOUT/harness-ci" "$LAYOUT/harness-ci.off"
run_script "$LAYOUT/orch/scripts/dev-validate-run" --worktree "$proj_class" --poll 1
assert_eq "$(output_of "$OUT" 2>/dev/null) $(sed -n 's/^state=started .* cap-secs=[0-9]* //p' <<<"$OUT")" \
  "standard:false: class=standard docs-only=false class-fallback=classifier-absent" \
  "no classifier runs the whole battery, naming the absence" "$ERR"
mv "$LAYOUT/harness-ci.off" "$LAYOUT/harness-ci"

# --- A ci request runs nothing where the base requires the named context -------
# Projects whose validation command is `echo full` and whose range command
# prints that it ran. Each names the context that runs its validation, or
# none, in DEV_VALIDATE_CI_CONTEXT. The gh on PATH is a stub that answers the
# pull request read and the two rule reads of the default branch main, and of
# a stacked base feature/parent that requires nothing, the way gh does,
# applying the --jq filter it is handed to a JSON payload built from the world
# the row names, then exiting with that world's status; any other call fails.
# Each
# row's run is a ci request; the classifier stub answers the class, the docs
# verdict and the measured marker.
GH_STUB_BIN="$TMP_ROOT/gh-stub"
mkdir -p "$GH_STUB_BIN"
cat > "$GH_STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") path=pr-view ;;
  "api "*) path="$2" ;;
  *) exit 9 ;;
esac
shift 2
filter=""
while (( $# > 0 )); do
  case "$1" in
    --jq) filter="$2"; shift 2 ;;
    --paginate) shift ;;
    --json) [[ "$path" == pr-view && "$2" == baseRefName,state ]] || exit 9; shift 2 ;;
    *) exit 9 ;;
  esac
done
[[ -n "$filter" ]] || exit 9
list() { jq -cn --arg v "$1" '$v | split(",") | map(select(. != ""))'; }
case "$path" in
  pr-view)
    payload="$(jq -cn --arg base "${STUB_PR_BASE:-main}" --arg state "${STUB_PR_STATE:-OPEN}" '{baseRefName: $base, state: $state}')"
    status="${STUB_PR_EXIT:-0}"
    ;;
  'repos/{owner}/{repo}/rules/branches/feature%2Fparent')
    payload='[]'
    status=0
    ;;
  'repos/{owner}/{repo}/branches/feature%2Fparent')
    payload='{"name":"feature/parent","protection":{"enabled":false,"required_status_checks":{"contexts":[],"checks":[]}}}'
    status=0
    ;;
  'repos/{owner}/{repo}/rules/branches/main')
    payload="$(jq -cn --argjson req "$(list "${STUB_RULES:-}")" --argjson other "$(list "${STUB_OTHER:-}")" '
      [{type: "required_status_checks", parameters: {required_status_checks: ($req | map({context: ., integration_id: 15368}))}},
       {type: "workflows", parameters: {required_status_checks: ($other | map({context: .}))}}]')"
    status="${STUB_RULES_EXIT:-0}"
    [[ -z "${STUB_RULES_STDERR:-}" ]] || printf '%s\n' "$STUB_RULES_STDERR" >&2
    ;;
  'repos/{owner}/{repo}/branches/main')
    if [[ "${STUB_CLASSIC:-}" == absent ]]; then
      payload='{"name":"main","protected":true}'
    else
      payload="$(jq -cn --argjson ctx "$(list "${STUB_CLASSIC:-}")" --argjson chk "$(list "${STUB_CLASSIC_CHECKS:-}")" '
        {name: "main", protection: {enabled: true, required_status_checks: {contexts: $ctx, checks: ($chk | map({context: ., app_id: 15368}))}}}')"
    fi
    status="${STUB_CLASSIC_EXIT:-0}"
    ;;
  *) exit 9 ;;
esac
jq -r "$filter" <<<"$payload" || exit $?
exit "$status"
SH
chmod +x "$GH_STUB_BIN/gh"
# ci_world WORLD — exports the payloads and statuses the gh stub answers with:
#   rules           a ruleset requires CI
#   classic         classic protection's contexts require CI, no ruleset does
#   classic-check   classic protection's checks require CI, no ruleset does
#   other-type      CI appears only in a rule of another type
#   unrequired      both reads answer, and neither names CI
#   rules-fail      the ruleset read prints CI, then fails
#   classic-absent  the branch payload carries no protection key
#   classic-fail    the classic read prints CI, then fails
#   stacked         main requires CI; the pull request's base,
#                   feature/parent, requires nothing
#   pr-merged       main requires CI; the branch's pull request is merged
#   pr-unread       main requires CI; the pull request read prints main's
#                   name, then fails
ci_world() {
  export STUB_RULES=Lint STUB_OTHER="" STUB_CLASSIC="" STUB_CLASSIC_CHECKS="" STUB_RULES_EXIT=0 STUB_CLASSIC_EXIT=0 \
    STUB_PR_BASE=main STUB_PR_STATE=OPEN STUB_PR_EXIT=0
  case "$1" in
    rules) STUB_RULES=Lint,CI ;;
    classic) STUB_CLASSIC=CI ;;
    classic-check) STUB_CLASSIC_CHECKS=CI ;;
    other-type) STUB_OTHER=CI ;;
    unrequired) STUB_RULES=Lint,CI-extra STUB_CLASSIC=Deploy ;;
    rules-fail) STUB_RULES=CI STUB_RULES_EXIT=1 ;;
    classic-absent) STUB_CLASSIC=absent ;;
    classic-fail) STUB_CLASSIC=CI STUB_CLASSIC_EXIT=1 ;;
    stacked) STUB_RULES=Lint,CI STUB_PR_BASE=feature/parent ;;
    pr-merged) STUB_RULES=Lint,CI STUB_PR_STATE=MERGED ;;
    pr-unread) STUB_RULES=Lint,CI STUB_PR_EXIT=1 ;;
    *) printf 'ci_world: world=%s\n' "$1" >&2; return 1 ;;
  esac
}
ci_proj() { # NAME CONTEXT — CONTEXT empty leaves the setting unset
  local dir
  dir="$(make_mode_proj "$1" 'echo range')"
  [[ -z "$2" ]] || printf 'DEV_VALIDATE_CI_CONTEXT = "%s"\n' "$2" >> "$dir/kendex.settings.toml"
  printf 'tmp/\n' > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.com commit -q -m ignore
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  printf '%s\n' "$dir"
}
proj_ci="$(ci_proj proj-ci CI)"
proj_ci_unset="$(ci_proj proj-ci-unset '')"
ci_head="$(git -C "$proj_ci" rev-parse HEAD)"
# label|setting named (yes/no)|world|classifier answer|docs answer|measured|verdict and what the command printed|recorded mode|ci-fallback line
CI_ROWS=(
  "a measured micro diff under a ruleset's required context is left to CI|yes|rules|change_class=micro|false|true|state=done guard-exit=0 validate=pass |ci|"
  "a measured small diff under a ruleset's required context is left to CI|yes|rules|change_class=small|false|true|state=done guard-exit=0 validate=pass |ci|"
  "a measured standard diff under a ruleset's required context is left to CI|yes|rules|change_class=standard|false|true|state=done guard-exit=0 validate=pass |ci|"
  "a context classic protection's contexts require is left to CI|yes|classic|change_class=standard|false|true|state=done guard-exit=0 validate=pass |ci|"
  "a context classic protection's checks require is left to CI|yes|classic-check|change_class=standard|false|true|state=done guard-exit=0 validate=pass |ci|"
  "a project that names no context runs the range command|no|rules|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|setting-empty"
  "a context only a rule of another type names runs the range command|yes|other-type|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|context-unrequired"
  "a context the base does not require runs the range command|yes|unrequired|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|context-unrequired"
  "a ruleset read that fails runs the range command|yes|rules-fail|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|rules-unread"
  "a branch payload with no protection runs the range command|yes|classic-absent|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|rules-unread"
  "a classic read that fails runs the range command|yes|classic-fail|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|rules-unread"
  "a stacked pull request whose own base requires nothing runs the range command|yes|stacked|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|context-unrequired"
  "a branch whose pull request is merged runs the range command|yes|pr-merged|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|base-unresolved"
  "a pull request read that fails runs the range command|yes|pr-unread|change_class=standard|false|true|state=done guard-exit=0 validate=pass range|range|base-unresolved"
  "a render diff, whose checks CI stands down, runs the range command|yes|rules|change_class=render|false|true|state=done guard-exit=0 validate=pass range|range|class-uncovered"
  "a trivial diff outside the docs set runs the range command|yes|rules|change_class=trivial|false|true|state=done guard-exit=0 validate=pass range|range|class-uncovered"
  "a standard diff of docs alone runs the range command|yes|rules|change_class=standard|true|true|state=done guard-exit=0 validate=pass range|range|class-uncovered"
  "a standard class the classifier fell back to runs the range command|yes|rules|change_class=standard|false|false|state=done guard-exit=0 validate=pass range|range|class-uncovered"
  "a class with no measured marker runs the range command|yes|rules|change_class=micro|false||state=done guard-exit=0 validate=pass range|range|class-uncovered"
  "a docs verdict that did not read runs the range command|yes|rules|change_class=micro|exit-2|true|state=done guard-exit=0 validate=pass range|range|class-uncovered"
)
# ci_rows SCRIPT — one line per row: its label, its stderr file, then the
# verdict, what the command printed, the recorded mode and the recorded
# ci-fallback, tab-separated.
ci_rows() {
  local row label named world answer docs measured proj ci_dir
  for row in "${CI_ROWS[@]}"; do
    IFS='|' read -r label named world answer docs measured _ _ _ <<<"$row"
    proj="$proj_ci"
    [[ "$named" == yes ]] || proj="$proj_ci_unset"
    ci_world "$world"
    RUN_PATH="$GH_STUB_BIN:$PATH" STUB_ANSWER="$answer" STUB_DOCS="$docs" STUB_MEASURED="$measured" \
      run_script "$1" --worktree "$proj" --poll 1 --validate-mode ci --base HEAD
    ci_dir="$(run_dir_of "$OUT")"
    printf '%s\t%s\t%s %s|%s|%s\n' "$label" "$ERR" "$(verdict_of "$OUT")" "$(output_of "$OUT" 2>/dev/null)" \
      "$(start_line "$ci_dir" validate-mode 2>/dev/null)" "$(start_line "$ci_dir" ci-fallback 2>/dev/null)"
  done
}
CI_SCRIPT="$LAYOUT/orch/scripts/dev-validate-run"
CI_GOT="$(ci_rows "$CI_SCRIPT")"
for row in "${CI_ROWS[@]}"; do
  IFS='|' read -r label _ _ _ _ _ want_out want_mode want_fallback <<<"$row"
  got_line="$(awk -F'\t' -v want="$label" '$1 == want' <<<"$CI_GOT")"
  IFS=$'\t' read -r _ err got <<<"$got_line"
  assert_eq "$got" "$want_out|$want_mode|$want_fallback" "$label" "$err"
done
# A failed read's own stderr is kept beside the run, never discarded.
ci_world rules-fail
STUB_RULES_STDERR='gh: HTTP 401: Bad credentials' RUN_PATH="$GH_STUB_BIN:$PATH" \
  STUB_ANSWER=change_class=micro STUB_DOCS=false STUB_MEASURED=true \
  run_script "$CI_SCRIPT" --worktree "$proj_ci" --poll 1 --validate-mode ci --base HEAD
assert_eq "$(start_line "$(run_dir_of "$OUT")" ci-fallback) $(cat "$(run_dir_of "$OUT")/ci.log" 2>/dev/null)" \
  "rules-unread gh: HTTP 401: Bad credentials" \
  "a rules read that fails names rules-unread and keeps gh's error in ci.log" "$ERR"
# ci_run [ARG...] — a micro ci request in proj_ci, whose base requires CI.
ci_run() {
  ci_world rules
  RUN_PATH="$GH_STUB_BIN:$PATH" STUB_ANSWER=change_class=micro STUB_DOCS=false STUB_MEASURED=true \
    run_script "$@" --worktree "$proj_ci" --poll 1 --validate-mode ci --base HEAD
}
# The ci run's record, its wait and its exit: no command ran, so no time passed.
ci_run "$CI_SCRIPT"
ci_dir="$(run_dir_of "$OUT")"
assert_eq "$RC $(sed -n 2p <<<"$OUT" | sed 's/ at=[^ ]* / at=T /')" \
  "0 state=done guard-exit=0 at=T validate=pass run-dir=$ci_dir log=$ci_dir/log" \
  "a ci run passes, and its done line names the run directory and the log" "$ERR"
run_script "$CI_SCRIPT" --record --run-dir "$ci_dir"
assert_eq "$(sed -E 's/started-at=[^ ]+ ended-at=[^ ]+$/started-at=T ended-at=T/' <<<"$OUT")" \
  "validate-mode=ci selection=unreported verdict=pass head=$ci_head start=$(start_of "$ci_dir") seconds=0 started-at=T ended-at=T" \
  "its record names the ci mode, a pass, the HEAD it started at and no wall time" "$ERR"
# Under --attached a ci run still prints its started line first, then the done
# line, since no child runs to print it before.
ci_run "$CI_SCRIPT" --attached
assert_eq "$RC $(sed -n 1p <<<"$OUT" | cut -d' ' -f1) $(verdict_of "$OUT")" \
  "0 state=started state=done guard-exit=0 validate=pass" \
  "an attached ci run prints its started line, then its done line" "$ERR"
cp -p -- "$CI_SCRIPT" "$CI_SCRIPT.mutant"
mutate_file "$CI_SCRIPT.mutant" '[[ "$attached" == true && "$validate_mode" != ci ]]' '[[ "$attached" == true ]]'
ci_run "$CI_SCRIPT.mutant" --attached
assert_eq "$(sed -n 1p <<<"$OUT" | cut -d' ' -f1)" "state=done" \
  "control: an attached ci run that skips its started line opens on the done line" "$ERR"
# One control per rule the ci route holds: each mutant copy sits beside the
# stubbed classifier and turns the one row that rule decides, to ci unless
# the control names another result.
ci_control() { # LABEL ANCHOR REPLACEMENT ROW [EXPECT]
  local got_line got
  cp -p -- "$CI_SCRIPT" "$CI_SCRIPT.mutant"
  mutate_file "$CI_SCRIPT.mutant" "$2" "$3"
  got_line="$(ci_rows "$CI_SCRIPT.mutant" | awk -F'\t' -v want="$4" '$1 == want')"
  IFS=$'\t' read -r _ _ got <<<"$got_line"
  assert_eq "$got" "${5:-state=done guard-exit=0 validate=pass |ci|}" "control: with $1, '$4' fails"
}
# shellcheck disable=SC2016 # the script's own text, not expansions
{
ci_control 'the setting defaulting to CI' 'DEV_VALIDATE_CI_CONTEXT "")"' 'DEV_VALIDATE_CI_CONTEXT CI)"' \
  'a project that names no context runs the range command'
ci_control 'the required contexts unread' 'grep -Fxq -- "$context" <<<"$rules"$'"'"'\n'"'"'"$classic"' 'true' \
  'a context the base does not require runs the range command'
ci_control 'every rule type read' 'select(.type == "required_status_checks") | ' '' \
  'a context only a rule of another type names runs the range command'
ci_control 'a failed ruleset read kept' $'    rules=""\n    unread=true\n' $'    unread=true\n' \
  'a ruleset read that fails runs the range command'
ci_control 'a failed classic read kept' $'    classic=""\n    unread=true\n' $'    unread=true\n' \
  'a classic read that fails runs the range command'
ci_control 'a missing protection read as empty' 'error("protection unreadable")' 'empty' \
  'a branch payload with no protection runs the range command' \
  'state=done guard-exit=0 validate=pass range|range|context-unrequired'
ci_control 'classic protection unread' '"repos/{owner}/{repo}/branches/$uri"' '"repos/{owner}/{repo}/branchesx/$uri"' \
  "a context classic protection's contexts require is left to CI" \
  'state=done guard-exit=0 validate=pass range|range|rules-unread'
ci_control "the default branch read instead of the pull request's base" \
  "gh pr view --json baseRefName,state --jq 'select(.state == \"OPEN\") | .baseRefName'" \
  '"$SCRIPT_DIR/resolve-base-branch" "$worktree"' \
  'a stacked pull request whose own base requires nothing runs the range command'
ci_control 'the pull request state unread' 'select(.state == "OPEN") | .baseRefName' '.baseRefName' \
  'a branch whose pull request is merged runs the range command'
ci_control 'a failed pull request read kept' ".baseRefName' 2>>\"\$log\")\"" ".baseRefName' 2>>\"\$log\" || true)\"" \
  'a pull request read that fails runs the range command'
ci_control 'an empty base read as a branch' $'    || [[ -z "$base_branch" ]] \\\n' '' \
  'a branch whose pull request is merged runs the range command' \
  'state=done guard-exit=0 validate=pass range|range|rules-unread'
ci_control 'an unread rule named as unrequired' 'if [[ "$unread" == true ]]; then' 'if false; then' \
  'a ruleset read that fails runs the range command' \
  'state=done guard-exit=0 validate=pass range|range|context-unrequired'
ci_control 'the class cause unrecorded' $'    ci_fallback=class-uncovered\n' '' \
  'a render diff, whose checks CI stands down, runs the range command' \
  'state=done guard-exit=0 validate=pass range|range|'
ci_control 'render among the covered classes' \
  'micro|small|standard) if ci_runs_validation' 'micro|small|standard|render) if ci_runs_validation' \
  'a render diff, whose checks CI stands down, runs the range command'
ci_control 'the docs verdict unread' ' && "$docs_only" == false ]]' ' ]]' \
  'a standard diff of docs alone runs the range command'
ci_control 'the measured marker unread' ' && "$CHANGE_CLASS_MEASURED" == true' '' \
  'a standard class the classifier fell back to runs the range command'
ci_control 'the class fallback unread' '-z "$class_fallback" && ' '' \
  'a docs verdict that did not read runs the range command'
}
# The rules read names the base branch: a read of another branch's rules is
# one the stub fails, so the micro row runs range.
cp -p -- "$CI_SCRIPT" "$CI_SCRIPT.mutant"
# shellcheck disable=SC2016
mutate_file "$CI_SCRIPT.mutant" 'rules/branches/$uri' 'rules/branches/x$uri'
ci_run "$CI_SCRIPT.mutant"
assert_eq "$(start_line "$(run_dir_of "$OUT")" validate-mode)" "range" \
  "control: a rules read of another branch leaves the micro row to range" "$ERR"
# The read's error stays beside the run: a run directory that drops ci.log
# loses gh's line.
cp -p -- "$CI_SCRIPT" "$CI_SCRIPT.mutant"
# shellcheck disable=SC2016
mutate_file "$CI_SCRIPT.mutant" '[[ ! -f "$class_scratch/ci.log" ]] || mv' 'true ||'
ci_world rules-fail
RUN_PATH="$GH_STUB_BIN:$PATH" STUB_ANSWER=change_class=micro STUB_DOCS=false STUB_MEASURED=true \
  run_script "$CI_SCRIPT.mutant" --worktree "$proj_ci" --poll 1 --validate-mode ci --base HEAD
assert_eq "$([[ -f "$(run_dir_of "$OUT")/ci.log" ]] && echo kept || echo dropped)" "dropped" \
  "control: a run directory that does not take ci.log keeps no read error" "$ERR"
# A ci run left to CI reads neither command, so a project that sets neither
# passes it. Control: resolving the range mode first, as a range run does,
# reads the empty DEV_VALIDATE_CMD and refuses.
printf '[env]\nDEV_VALIDATE_TIMEOUT_SECS = "20"\nDEV_VALIDATE_CI_CONTEXT = "CI"\n' > "$proj_ci/kendex.settings.toml"
cp -p -- "$CI_SCRIPT" "$CI_SCRIPT.mutant"
mutate_file "$CI_SCRIPT.mutant" '[[ "$validate_mode" == ci ]] || resolve_range_mode' 'resolve_range_mode'
ci_run "$CI_SCRIPT"
assert_eq "$RC $(verdict_of "$OUT")" "0 state=done guard-exit=0 validate=pass" \
  "a ci run left to CI in a project that sets no command passes" "$ERR"
ci_run "$CI_SCRIPT.mutant"
assert_eq "$RC $(sed -n 1p <"$ERR")" "2 dev-validate-run: empty-validate-cmd setting=DEV_VALIDATE_CMD" \
  "control: a ci run that resolves the range mode first is refused" "$ERR"
rm -f -- "${CI_SCRIPT:?}.mutant"

# --- The real classifier weighs uncommitted render edits -----------------------
# dev-implement validates before it commits, so the runner hands the
# classifier a snapshot commit of the worktree as the range's head, and
# change-class checks that commit out privately for its render proof. The
# kendex on PATH is a stub that passes the proof only where the tree it runs
# in holds the uncommitted edit, so a classifier weighing the worktree's
# committed HEAD answers standard.
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
cat > "$TMP_ROOT/render-bin/kendex" <<'STUB'
#!/usr/bin/env bash
grep -qx 'rendered again' .agents/skills/demo/SKILL.md || exit 99
printf '%s\n' '{"version":1,"clean":true,"checked":1,"failed":0,"rows":[{"state":"ok","positions":[{"path":".agents/skills/demo","owns":"tree"}]}]}'
STUB
chmod +x "$TMP_ROOT/render-bin/kendex"
RUN_PATH="$TMP_ROOT/render-bin:$PATH"
run_script "$RUN" --worktree "$proj_render" --poll 1
RUN_PATH=""
render_dir="$(run_dir_of "$OUT")"
assert_eq "$(output_of "$OUT" 2>/dev/null) $(sed -n 's/^class: class=\([a-z]*\) \(measured=[a-z]*\) \(cause=[a-z-]*\).*$/\1 \2 \3/p' "$render_dir/class.log")" \
  "render render measured=true cause=renders-match-their-sources" \
  "an uncommitted render diff the proof passes runs as render" "$ERR"

# --- A range request is classified from its own base --------------------------
# A branch whose first commit changes code and whose fix round, from that
# commit, changes one document. The project sets no range command, so the
# range request runs the whole battery, which still reads the round's own
# docs verdict and paths through the real classifier, while the run records
# full. The control classifies from the base branch and reads the code commit.
proj_round="$(make_proj proj-round 'echo ${DEV_VALIDATE_DOCS_ONLY-unset} $(cat ${DEV_VALIDATE_PATHS-/dev/null})' 20)"
printf 'tmp/\n' > "$proj_round/.gitignore"
git -C "$proj_round" add -A
git -C "$proj_round" -c user.name=t -c user.email=t@example.com commit -q -m base
git -C "$proj_round" update-ref refs/remotes/origin/main HEAD
orphan_commit "$proj_round" app.sh
round_base="$(git -C "$proj_round" rev-parse HEAD)"
mkdir -p "$proj_round/docs"
orphan_commit "$proj_round" docs/note.md
run_script "$RUN" --worktree "$proj_round" --poll 1 --validate-mode range --base "$round_base"
round_dir="$(run_dir_of "$OUT")"
assert_eq "$RC $(output_of "$OUT") $(start_line "$round_dir" validate-mode)" "0 true docs/note.md full" \
  "a docs-only round on a branch with an earlier code commit classifies docs-only against the round base" "$ERR"
# That full pass ran the round's lanes only, so its record names the class base
# that keeps submit from reusing it as the branch's.
run_script "$RUN" --record --run-dir "$round_dir"
assert_eq "$RC ${OUT%% *} $(record_field class-base "$OUT")" "0 validate-mode=full $round_base" \
  "the full run judged from the round base records that base as its class base" "$ERR"
mutant mutant-record-class-base '"${record_class_base:+ class-base=$record_class_base}"' '""'
run_script "$MUTANT" --record --run-dir "$round_dir"
assert_eq "$RC $(record_field class-base "$OUT")" "0 " \
  "control: with the class base unprinted the full run's record reads as the branch's" "$ERR"
mutant mutant-round-base 'class_base="$base_sha"' 'class_base=""'
# The mutant's copy sits outside the catalog, so it finds the classifier on PATH.
RUN_PATH="$REPO_ROOT/skills/harness-ci/scripts:$PATH"
run_script "$MUTANT" --worktree "$proj_round" --poll 1 --validate-mode range --base "$round_base"
RUN_PATH=""
assert_eq "$RC $(output_of "$OUT") $(start_line "$(run_dir_of "$OUT")" class-base)" "0 false app.sh docs/note.md " \
  "control: classified from the base branch, the round reads the branch's code commit and records no class base" "$ERR"


# label|arguments after the worktree or run directory|refusal's first line
proj_refuse="$(make_mode_proj proj-mode-refuse "$RANGE_CMD")"
# A verdict with no wall time beside it, and one wall time per malformed field.
for name in untimed badtimed badstart badend; do
  mkdir -p "$TMP_ROOT/$name"
  printf 'validate-mode=full\n' > "$TMP_ROOT/$name/start"
  printf 'guard-exit=0 at=2026-01-01T00:55:00Z\n' > "$TMP_ROOT/$name/exit"
done
printf 'started-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:55:00Z\nseconds=soon\n' > "$TMP_ROOT/badtimed/timing"
printf 'started-at=2026-01-01 00:00:00\nended-at=2026-01-01T00:55:00Z\nseconds=3300\n' > "$TMP_ROOT/badstart/timing"
printf 'started-at=2026-01-01T00:00:00Z\nended-at=soon\nseconds=3300\n' > "$TMP_ROOT/badend/timing"
MODE_REFUSALS=(
  "a validation mode outside the three is refused, naming it|--worktree $proj_refuse --validate-mode fast|dev-validate-run: invalid-mode option=--validate-mode value=fast"
  "a range run with no base is refused|--worktree $proj_refuse --validate-mode range|dev-validate-run: required option=--base validate-mode=range"
  "a ci run with no base is refused|--worktree $proj_refuse --validate-mode ci|dev-validate-run: required option=--base validate-mode=ci"
  "a base handed to a full run is refused, never silently dropped|--worktree $proj_refuse --base HEAD|dev-validate-run: option-unused option=--base validate-mode=full"
  "a base that names no commit is refused, naming it|--worktree $proj_refuse --validate-mode range --base no-such-ref|dev-validate-run: invalid-base base=no-such-ref"
  "a validation mode handed to the waiter is refused|--wait --run-dir $stale --validate-mode range|dev-validate-run: option-unused option=--validate-mode mode=wait"
  "a base handed to the waiter is refused|--wait --run-dir $stale --base HEAD|dev-validate-run: option-unused option=--base mode=wait"
  "a validation mode handed to --stop is refused|--stop --worktree $proj_refuse --validate-mode range|dev-validate-run: option-unused option=--validate-mode mode=stop"
  "a base handed to --stop is refused|--stop --worktree $proj_refuse --base HEAD|dev-validate-run: option-unused option=--base mode=stop"
  "a record of a directory no run started is refused|--record --run-dir $TMP_ROOT/unstarted|dev-validate-run: no-run path=$TMP_ROOT/unstarted/start"
  "a record whose start names no mode is refused|--record --run-dir $stale|dev-validate-run: record-unreadable path=$stale/start validate-mode="
  "a call budget handed to the record is refused|--record --run-dir $stale --budget 5|dev-validate-run: option-unused option=--budget mode=record"
  "a record of a verdict with no wall time is refused|--record --run-dir $TMP_ROOT/untimed|dev-validate-run: timing-unreadable path=$TMP_ROOT/untimed/timing"
  "a record of a wall time whose seconds are no number is refused|--record --run-dir $TMP_ROOT/badtimed|dev-validate-run: timing-unreadable path=$TMP_ROOT/badtimed/timing"
  "a record of a wall time whose start is no UTC time is refused|--record --run-dir $TMP_ROOT/badstart|dev-validate-run: timing-unreadable path=$TMP_ROOT/badstart/timing"
  "a record of a wall time whose end is no UTC time is refused|--record --run-dir $TMP_ROOT/badend|dev-validate-run: timing-unreadable path=$TMP_ROOT/badend/timing"
  "a base handed to --resolve-mode is refused|--resolve-mode --worktree $proj_refuse --base HEAD|dev-validate-run: option-unused option=--base mode=resolve"
  "a validation mode handed to --resolve-mode is refused|--resolve-mode --worktree $proj_refuse --validate-mode range|dev-validate-run: option-unused option=--validate-mode mode=resolve"
  "--resolve-mode with no worktree is refused|--resolve-mode|dev-validate-run: required option=--worktree"
)
for row in "${MODE_REFUSALS[@]}"; do
  IFS='|' read -r label args want <<<"$row"
  # shellcheck disable=SC2086 # the row's argument list, split on purpose
  run_script "$RUN" $args
  assert_eq "$(sed -n 1p <"$ERR") rc=$RC" "$want rc=2" "$label"
done

# --- No process the run starts outlives it ------------------------------------
# Each command leaves a grandchild behind and records its pid in the worktree.
# One that calls setsid leaves the run's process group, which only a unit's
# cgroup still holds; one that does not stays in the group the setsid fallback
# kills. Neither is gone the instant the verdict lands, since the unit or the
# group ends just after, so each read is proc_state_after's bounded poll.
# The grandchild a row's command recorded, killed after the read so a row
# that leaves it running leaves nothing behind the suite.
grandchild_state() { # PROJ
  local pid
  pid="$(cat "$1/grand.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo unrecorded; return 0; }
  proc_state_after "$pid"
  kill -KILL "$pid" 2>/dev/null || true
}

# A grandchild that runs as grand.sh and records its own pid in grand.pid only
# once its TERM trap, if it has one, is installed. A signal that reaches it
# before the trap kills it before that write, so a recorded pid, or a flag the
# trap wrote before the write came, is a grandchild that was ready when the
# group's SIGTERM came, and no timing on a slow host can turn an unready one
# into a missed trap.
write_grandchild() { # PROJ trap|no-trap
  {
    [[ "$2" == no-trap ]] || printf '%s\n' "trap 'echo got-term > term.flag; exit 0' TERM"
    printf '%s\n' 'echo $$ > grand.pid' 'while :; do sleep 1; done'
  } > "$1/grand.sh"
}
# Whether the grandchild ran its TERM trap: got-term, no-term for one that
# recorded its pid and wrote no flag, or unready for one that did neither. The
# run's verdict lands before its group gets SIGTERM, so the flag is polled for
# up to five seconds rather than read once, and read before readiness is
# judged: a trap that ran before the pid write proves the trap was installed.
term_state() { # PROJ
  local n=0
  while [[ ! -s "$1/term.flag" ]]; do
    if (( n >= 50 )); then
      if [[ -s "$1/grand.pid" ]]; then echo no-term; else echo unready; fi
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
  cat "$1/term.flag"
}
# The runner line a run's log opens with, with its unit's launching pid folded
# to PID so the rest of the name is pinned.
runner_line() { # OUTPUT
  sed -n '1{s/^\(runner=systemd unit=.*\)-[0-9][0-9]*$/\1-PID/;p;}' "$(log_of "$1")"
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
    "a run killed at its bound leaves no such grandchild either|proj-unit-bound|setsid sleep 300 & echo \$! > grand.pid; sleep 30|2|state=done guard-exit=124 validate=no-verdict"
  )
  for row in "${UNIT_ROWS[@]}"; do
    IFS='|' read -r label name cmd secs want_verdict <<<"$row"
    proj="$(make_proj "$name" "$cmd" "$secs")"
    run_script "$RUN" --worktree "$proj" --poll 1
    assert_eq "$(verdict_of "$OUT")" "$want_verdict" "$label: the verdict" "$ERR"
    assert_eq "$(runner_line "$OUT")" "runner=systemd unit=orch-validate-$name-PID" \
      "$label: the log opens naming its unit" "$ERR"
    assert_eq "$(grandchild_state "$proj")" "gone" "$label" "$ERR"
  done

  proj_nounit="$(make_proj proj-no-unit 'setsid sleep 300 & echo $! > grand.pid; exit 0' 20)"
  # A capped run keeps its unit where the manager does not linger: linger is
  # asked only of a session-long job.
  mkdir -p "$TMP_ROOT/no-linger-bin"
  printf '#!/bin/sh\necho no\n' > "$TMP_ROOT/no-linger-bin/loginctl"
  chmod +x "$TMP_ROOT/no-linger-bin/loginctl"
  RUN_PATH="$TMP_ROOT/no-linger-bin:$PATH"
  run_script "$RUN" --worktree "$proj_nounit" --poll 1
  RUN_PATH=""
  assert_eq "$(runner_line "$OUT") $(grandchild_state "$proj_nounit")" "runner=systemd unit=orch-validate-proj-no-unit-PID gone" \
    "a validation run where the manager does not linger is still a unit, and no grandchild outlives it" "$ERR"

  # The unit carries what a user unit does not inherit: the caller's exported
  # variables and its open-file soft limit, lowered here so it differs from
  # any manager default.
  proj_inherit="$(make_proj proj-inherit 'printf %s:%s ${VALIDATE_ENV_MARK-unset} $(ulimit -Sn)' 20)"
  export VALIDATE_ENV_MARK=x
  run_script bash -c 'ulimit -Sn 777 && exec "$0" "$@"' "$RUN" --worktree "$proj_inherit" --poll 1
  assert_eq "$(output_of "$OUT")" "x:777" \
    "a unit's command sees the caller's exported variable and open-file soft limit" "$ERR"
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
  assert_eq "$(verdict_of "$OUT") $(runner_line "$OUT")" "state=done guard-exit=0 validate=pass runner=systemd unit=orch-validate-proj-no-setsid-PID" \
    "a host with a user manager and no setsid runs its validation in a unit" "$ERR"
  RUN_PATH=""

  # The manager expands ${NAME} in a unit's command line, so a worktree path
  # that carries one reaches the child only with its $ written $$. The unit
  # name carries none of it.
  proj_dollar="$(make_proj 'proj-${HOME}' "exit 0" 20)"
  run_script "$RUN" --worktree "$proj_dollar" --poll 1
  assert_eq "$(verdict_of "$OUT") $(runner_line "$OUT")" "state=done guard-exit=0 validate=pass runner=systemd unit=orch-validate-proj-__HOME_-PID" \
    "a worktree whose path carries a \$ runs in a unit and passes" "$ERR"
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

# The group's end is SIGTERM first, a kill grace before SIGKILL, as a unit's
# stop is: a grandchild of a run killed at its bound runs its TERM trap. The
# grandchild with no trap is term_state's control: it is never reported as
# trapped.
# label|name|grandchild|what term_state reads
TERM_ROWS=(
  "a setsid run's grandchild gets SIGTERM, and runs its trap, when the run ends at its bound|proj-term-group|trap|got-term"
  "a grandchild with no TERM trap is not reported as having run one|proj-term-untrapped|no-trap|no-term"
)
for row in "${TERM_ROWS[@]}"; do
  IFS='|' read -r label name grandchild want_term <<<"$row"
  proj="$(make_proj "$name" 'bash grand.sh & sleep 30' 2)"
  write_grandchild "$proj" "$grandchild"
  run_script "$RUN" --worktree "$proj" --poll 1
  assert_eq "$(verdict_of "$OUT") $(term_state "$proj")" \
    "state=done guard-exit=124 validate=no-verdict $want_term" "$label" "$ERR"
  grandchild_state "$proj" >/dev/null
done

# Where systemd-run is installed and fails, the run is still made under setsid
# and its log carries systemd-run's own first line. The stubs fail the probe
# unit, or start only that unit.
FALLBACK_PATH="$RUN_PATH"
mkdir -p "$TMP_ROOT/probe-bin" "$TMP_ROOT/refusing-bin"
printf '#!/usr/bin/env bash\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$TMP_ROOT/probe-bin/systemd-run"
printf '#!/usr/bin/env bash\n[[ "${*: -1}" == true ]] && exit 0\necho "Failed to start transient service unit: refused" >&2\nexit 1\n' > "$TMP_ROOT/refusing-bin/systemd-run"
# The manager the refusing stub stands for has no unit of the refused name.
printf '#!/usr/bin/env bash\necho not-found\n' > "$TMP_ROOT/refusing-bin/systemctl"
chmod +x "$TMP_ROOT/probe-bin/systemd-run" "$TMP_ROOT/refusing-bin/systemd-run" "$TMP_ROOT/refusing-bin/systemctl"
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

# setsid that cannot start the child fails the start by name, never as a
# record that could not be written.
mkdir -p "$TMP_ROOT/failing-setsid-bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/failing-setsid-bin/setsid"
chmod +x "$TMP_ROOT/failing-setsid-bin/setsid"
RUN_PATH="$TMP_ROOT/failing-setsid-bin:$FALLBACK_PATH"
run_script "$RUN" --worktree "$proj_refused" --poll 1
assert_eq "$(sed -n 1p <"$ERR") $RC" "dev-validate-run: launch-failed status=1 2" \
  "a setsid that cannot start the child fails the start as launch-failed" "$ERR"
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

  # Two worktrees of one name under different parents, as two repositories'
  # lanes for the same item are: stopping one leaves the other's unit running.
  proj_twin_a="$(make_proj twin-a/proj-twin "setsid $long_cmd" 600)"
  proj_twin_b="$(make_proj twin-b/proj-twin "exit 0" 20)"
  start_long_run "$proj_twin_a" ""
  run_script "$RUN" --stop --worktree "$proj_twin_b"
  assert_eq "$OUT $RC $(proc_state_after "$(cat "$proj_twin_a/grand.pid")")" "state=stopped units=0 groups=0 0 alive" \
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
assert_eq "$(proc_state_after "$stop_child") $(grandchild_state "$proj_stop_group")" "gone gone" \
  "and the run's child and the grandchild in its group are gone" "$ERR"
end_long_run

# --stop tears a setsid run down the way its own end does, SIGTERM first: a
# grandchild of a run stopped mid-validation runs its TERM trap.
# start_long_run's wait for grand.pid is the wait for the trap.
proj_stop_term="$(make_proj proj-stop-term 'bash grand.sh & sleep 300' 600)"
write_grandchild "$proj_stop_term" trap
start_long_run "$proj_stop_term" "$RUN_PATH"
run_script "$RUN" --stop --worktree "$proj_stop_term"
assert_eq "$OUT $(term_state "$proj_stop_term")" "state=stopped units=0 groups=1 got-term" \
  "--stop sends a setsid run's group SIGTERM, and a grandchild runs its trap" "$ERR"
grandchild_state "$proj_stop_term" >/dev/null
end_long_run
RUN_PATH=""

# --- Which recorded runs --stop may signal -------------------------------------
# One planted run record per worktree, naming a process: `child` leads its own
# group and carries a run child's argv tail for that directory, `nonleader`
# carries that tail from inside this suite's own group, `other` is a plain
# sleep leading its group, `dead` is a pid that has exited, and `none` plants
# no run directory at all. The systemctl stub stops whatever it is asked to, so
# a unit record is counted and never signalled.
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
  PLANTED=""
  dir="$PLANT_PROJ/tmp/dev-validate-planted-$1"
  if [[ "$4" == none ]]; then
    mkdir -p "$PLANT_PROJ/tmp"
    return 0
  fi
  mkdir -p "$dir"
  printf 'runner=%s\nunit=validate-planted-%s\nline=planted\n' "$2" "$1" > "$dir/runner"
  [[ "$3" == no ]] || printf 'guard-exit=0 at=now\n' > "$dir/exit"
  case "$4" in
    child) setsid bash -c 'sleep 300; :' planted --child --run-dir "$dir" </dev/null >/dev/null 2>&1 & PLANTED=$!; disown "$PLANTED" ;;
    nonleader) bash -c 'sleep 300; :' planted --child --run-dir "$dir" </dev/null >/dev/null 2>&1 & PLANTED=$!; disown "$PLANTED" ;;
    other) setsid sleep 300 </dev/null >/dev/null 2>&1 & PLANTED=$!; disown "$PLANTED" ;;
    dead) sleep 0 & PLANTED=$!; wait "$PLANTED" ;;
  esac
  printf '%s\n' "$PLANTED" > "$dir/pid"
  sleep 0.2
}
# The planted process's state after --stop, `-` where none was planted, then
# the process killed whether it leads a group or not.
planted_state() {
  [[ -n "$PLANTED" ]] || { echo -; return 0; }
  proc_state_after "$PLANTED"
  kill -KILL -- "-$PLANTED" 2>/dev/null || kill -KILL "$PLANTED" 2>/dev/null || true
}
# name|runner|verdict recorded|process|what --stop prints|the process after
PLANT_ROWS=(
  "run-child|setsid|no|child|state=stopped units=0 groups=1|gone"
  "reused-pid|setsid|no|other|state=stopped units=0 groups=0|alive"
  "has-verdict|setsid|yes|child|state=stopped units=0 groups=0|alive"
  "unit-run|systemd|no|child|state=stopped units=1 groups=0|alive"
  "gone-pid|setsid|no|dead|state=stopped units=0 groups=0|gone"
  "not-leader|setsid|no|nonleader|state=stopped units=0 groups=0|alive"
  "no-run|setsid|no|none|state=stopped units=0 groups=0|-"
)
RUN_PATH="$TMP_ROOT/stop-bin:$PATH"
for row in "${PLANT_ROWS[@]}"; do
  IFS='|' read -r name runner verdict process want_out want_state <<<"$row"
  plant "$name" "$runner" "$verdict" "$process"
  proj="$PLANT_PROJ"
  run_script "$RUN" --stop --worktree "$proj"
  assert_eq "$OUT $RC $(planted_state)" "$want_out 0 $want_state" \
    "--stop on a planted $name record" "$ERR"
  rm -rf -- "$proj"
done

# A systemctl that cannot stop a unit the record names, and cannot say it has
# ended, fails --stop: exit 1 and the stop-failed line lane-close refuses on.
printf '#!/usr/bin/env bash\necho "stub refused" >&2\nexit 1\n' > "$TMP_ROOT/stop-bin/systemctl"
plant unit-refused systemd no other
proj="$PLANT_PROJ"
run_script "$RUN" --stop --worktree "$proj"
assert_eq "$(sed -n 1p <"$ERR") $RC" \
  "dev-validate-run: stop-failed run-dir=$proj/tmp/dev-validate-planted-unit-refused unit=validate-planted-unit-refused.service detail=stub refused 1" \
  "a unit systemctl will not stop fails --stop, naming it" "$ERR"
# --stop's control: a stop failure that exits 0.
mutant mutant-stop-exit-0 'in this worktree may still be running.' "in this worktree.'; exit 0; printf '"
run_script "$MUTANT" --stop --worktree "$proj"
assert_eq "$RC" "0" "control: a stop failure that exits 0 reads as a clean stop" "$ERR"
kill -KILL -- "-$PLANTED" 2>/dev/null || true
RUN_PATH=""

# --- A start beside a run still going in the worktree is refused ---------------
# The same planted records, now in a project a start can run in: only a run
# with no verdict whose pid is still that run's child holds the worktree. A
# refused start records no run directory of its own.
# name|verdict recorded|process|what the start does
LIVE_ROWS=(
  "live-child|no|child|refused"
  "live-nonleader|no|nonleader|refused"
  "live-reused-pid|no|other|started"
  "live-has-verdict|yes|child|started"
  "live-gone-pid|no|dead|started"
  "live-no-run|no|none|started"
)
# One line per row: its name, then `refused` with the refusal's keyed line or
# `started` with the verdict, and the run directories the worktree holds after.
live_rows() { # SCRIPT
  local row name verdict process want proj result
  for row in "${LIVE_ROWS[@]}"; do
    IFS='|' read -r name verdict process want <<<"$row"
    plant "$name" setsid "$verdict" "$process"
    proj="$PLANT_PROJ"
    git init -q "$proj"
    git -C "$proj" config gc.auto 0
    git -C "$proj" config maintenance.auto false
    printf '[env]\nDEV_VALIDATE_CMD = "true"\nDEV_VALIDATE_TIMEOUT_SECS = "30"\n' > "$proj/kendex.settings.toml"
    run_script "$1" --worktree "$proj" --poll 1
    if [[ "$RC" == 2 ]]; then
      result="refused $(sed -n 1p <"$ERR" | sed "s|$proj|PROJ|; s|pid=$PLANTED\$|pid=PLANTED|")"
    else
      result="started $(verdict_of "$OUT") rc=$RC"
    fi
    printf '%s %s runs=%s\n' "$name" "$result" "$(find "$proj/tmp" -mindepth 1 -maxdepth 1 -name 'dev-validate-*' | wc -l | tr -d ' ')"
    [[ -z "$PLANTED" ]] || kill -KILL -- "-$PLANTED" 2>/dev/null || kill -KILL "$PLANTED" 2>/dev/null || true
    rm -rf -- "$proj"
  done
}
# The line a row prints under the shipped script.
live_want() { # NAME
  local row name verdict process want
  for row in "${LIVE_ROWS[@]}"; do
    IFS='|' read -r name verdict process want <<<"$row"
    [[ "$name" == "$1" ]] || continue
    case "$want" in
      refused) printf '%s refused dev-validate-run: run-live run-dir=PROJ/tmp/dev-validate-planted-%s pid=PLANTED runs=1\n' "$name" "$name" ;;
      started) printf '%s started state=done guard-exit=0 validate=pass rc=0 runs=%s\n' "$name" "$([[ "$process" == none ]] && echo 1 || echo 2)" ;;
    esac
  done
}
live_out="$(live_rows "$RUN")"
for row in "${LIVE_ROWS[@]}"; do
  IFS='|' read -r name _ <<<"$row"
  assert_eq "$(grep "^$name " <<<"$live_out")" "$(live_want "$name")" \
    "a start in a worktree holding a planted $name record"
done
# One control per rule the check holds, each turning its own row: no refusal
# at all, a run with a verdict counted as live, and any live pid counted as
# the run's child.
live_control() { # NAME OLD NEW ROW
  local got
  mutant "$1" "$2" "$3"
  got="$(live_rows "$MUTANT" | grep "^$4 " || true)"
  assert_eq "$([[ "$got" != "$(live_want "$4")" ]] && echo turned || echo "held:$got")" "turned" \
    "control: $1 turns the $4 row"
}
live_control mutant-live-unchecked '[[ -z "$LIVE_RUN_DIR" ]] || die run-live' ': || die run-live' live-child
live_control mutant-live-verdict $'dir="${pid_file%/pid}"\n    [[ ! -s "$dir/exit" ]] || continue' 'dir="${pid_file%/pid}"' live-has-verdict
live_control mutant-live-argv '[[ "$args" == $(child_glob "$dir") ]] || continue' ':' live-reused-pid

# --- A value option given twice is refused, never half-read ---------------------
# option|the arguments that repeat it
REPEAT_ROWS=(
  "--worktree|--worktree $proj_probe --worktree $proj_log --poll 1"
  "--poll|--worktree $proj_probe --poll 1 --poll 2"
  "--run-dir|--wait --run-dir $stale --run-dir $absent"
  "--budget|--wait --run-dir $stale --budget 5 --budget 6"
)
repeat_rows() { # SCRIPT
  local row flag args
  for row in "${REPEAT_ROWS[@]}"; do
    IFS='|' read -r flag args <<<"$row"
    # shellcheck disable=SC2086 # the row's arguments are space-separated paths without spaces
    run_script "$1" $args
    printf '%s %s\n' "$(sed -n 1p <"$ERR")" "$RC"
  done
}
repeat_out="$(repeat_rows "$RUN")"
for row in "${REPEAT_ROWS[@]}"; do
  IFS='|' read -r flag _ <<<"$row"
  assert_eq "$(grep -c -x -F -- "dev-validate-run: repeated option=$flag 2" <<<"$repeat_out")" "1" \
    "a second $flag is refused rather than silently winning"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
