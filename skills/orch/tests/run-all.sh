#!/usr/bin/env bash
# Run every suite in this directory's *.sh, or in the --battery directory's.
#
# Each individual *.sh test is self-contained: builds its own sandbox,
# exercises the target script, prints `pass: N   fail: M`, exits 0 iff
# all assertions passed. This runner invokes them in parallel and
# aggregates the overall exit code so CI / pre-commit hooks have a
# single entry point.
#
# Usage:
#   bash skills/orch/tests/run-all.sh
#   bash skills/orch/tests/run-all.sh session_init      # subset by name
#   bash skills/orch/tests/run-all.sh open-terminal oversee   # either name
#   bash skills/orch/tests/run-all.sh '!open-terminal' '!oversee'  # neither
#   bash skills/orch/tests/run-all.sh =lanes      # that one suite alone
#   bash skills/orch/tests/run-all.sh --shard orch-oversee # CI's platform partition
#   bash skills/orch/tests/run-all.sh --battery tools/tests   # another tree's
#   bash skills/orch/tests/run-all.sh --battery DIR --alone NAME   # NAME alone
#
# `--battery DIR`, given first, runs the suites in DIR in place of this
# directory's, under the same filters, pool and report; tools/tests/run-all.sh
# runs that tree's suites this way. The ALONE list below names this
# directory's suites; with --battery, the suites each `--alone NAME` after it
# names are the ones that run alone.
#
# Each argument is a substring of a suite's base name, or, written `=name`,
# the whole of one. A bare one selects, one written `!name` rejects, and a
# file runs when it matches a selector — or none was given — and matches no
# rejector. Two runs whose arguments are
# a set and that set negated therefore partition the battery: every suite
# runs in exactly one of them, and a suite added later lands in the negated
# run rather than in neither. CI's orch shards are that partition.
#
# Suites run as many at a time as `nproc` reports, or 4 where it cannot
# answer (a stock macOS has no nproc). A suite's stdout and stderr are held
# until it exits and then printed whole under its header, so two suites
# never interleave; headers come in the order the runner reaps the
# suites, which follows completion to within one 0.1s poll. A suite in ALONE
# below runs by itself after the others. run-all.sh prints a start line as
# it launches each suite, so a run cut off by a signal or a job timeout still
# names every suite that was running; after each suite's output it prints
# one line, and after the last suite one total line:
#
#   start suite=<name>
#   suite=<name> seconds=<n> pass=<n> fail=<n>
#   total suites=<n> seconds=<n> pass=<n> fail=<n>
#
# Two bounds hold a suite. RUN_ALL_SUITE_SECS (default 900) counts from the
# suite's own start. RUN_ALL_DEADLINE_EPOCH, where set, is the Unix time in
# seconds by which the whole run ends, whatever time each suite started, and
# no suite starts once it has passed; CI's orch steps get it from the job's
# first step, which sets it inside the job's ceiling (skill-tests.yml). A
# suite still running at the earlier of the two is stopped: TERM to it and
# every process under it, KILL ten seconds later to any of them still
# running, a process that left the suite's process group included. It is then
# a red suite, and between its output and its line come two lines: a keyed
# line, the first form below where its own bound came first and the second
# where the run's deadline did, and the row it reached:
#
#   run-all.sh: suite-timeout suite=<name> seconds=<RUN_ALL_SUITE_SECS>
#   run-all.sh: run-deadline suite=<name> started=yes
#   last line: <the last line it printed before the stop>
#
# A suite the deadline left unstarted is red as well, under an empty output
# with `run-all.sh: run-deadline suite=<name> started=no` and
# `last line: none`. A hang therefore fails the run under the suite's name
# before the job's ceiling cancels the run with no name.
#
# The `<tree> tests:` verdict line follows the total, <tree> being the name
# of the battery directory's parent, `orch` with no --battery, and on a red
# run one `  - <name>` line per red suite follows the verdict.
#
# `seconds` is the suite's own wall time, and the total's is the whole run's.
# `pass` and `fail` are the counts from the last summary line the suite
# printed in any of the shapes the suites use (`pass: N  fail: M`,
# `N passed, M failed`, `N pass, M fail`, or Python unittest's `Ran N tests`
# with `OK` or `FAILED (failures=N, errors=M)`), and 0 where it printed none.
# A suite that exits non-zero with no failure counted reports fail=1, so a
# red suite never prints fail=0.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# lane_process_table, lane_process_below, lane_process_state and
# lane_process_start, for the stop.
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/lane-state.sh" ||
  { echo "run-all.sh: ../scripts/lib/lane-state.sh did not load; a stop would have no process reader" >&2; exit 1; }

# Lane launch settings must not override the suites' own fixture settings.
unset ORCH_STATE_DIR ORCH_LANE_HOST ORCH_TMUX_SESSION \
  ORCH_USER_MODE ORCH_DECISION_MODE ORCH_MERGE_AUTONOMY \
  ORCH_LANE_OUTPUT ORCH_QUESTION_TOOL ORCH_COMPACTION_OVERRIDES

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Suites that run alone, one at a time, once every other selected suite has
# finished: each holds a fixed wall-clock window that the code under test
# must meet, and a loaded host has made it miss. One name per line, first
# word, with the window it holds; run-all-parallel.sh reads this list.
ALONE=(
  open-terminal-lane      # the lane-tree stub holds the picked account for 2s
  oversee_watch_lifecycle # a takeover case waits 10s for the takeover line
)

if [ "${1-}" = --battery ]; then
  TEST_DIR="$(cd "$2" && pwd)" || exit 1
  shift 2
  # Another battery's wrapper names its own, so a suite there sharing a name
  # with one above is not held back.
  ALONE=()
  while [ "${1-}" = --alone ]; do
    ALONE+=("$2")
    shift 2
  done
fi
# The verdict line names the tree whose tests/ the battery is.
BATTERY="$(basename "$(dirname "$TEST_DIR")")"

SELECT=()
REJECT=()
# Main run 37769037887 exhausted the macOS deadline. These watch suites
# share a separate macOS leg; Linux retains the original oversee partition.
if [ "${1-}" = --shard ]; then
  shard="${2-}"
  [ "$#" -eq 2 ] || { echo "run-all.sh: shard-arguments shard=$shard" >&2; exit 1; }
  WATCH=(=oversee_watch =oversee_watch_lifecycle =oversee_watch_terminal =oversee_watch_lanes =oversee_watch_overseer =oversee_watch_overseer_rows)
  case "$shard" in
    orch-oversee)
      set -- oversee '!oversee_succeed' '!oversee_watch_mail' '!oversee_report'
      case "${RUNNER_OS:-Linux}" in
        Linux) ;;
        macOS) for arg in "${WATCH[@]}"; do set -- "$@" "!$arg"; done ;;
        *) echo "run-all.sh: shard-platform value=$RUNNER_OS" >&2; exit 1 ;;
      esac ;;
    orch-oversee-watch) set -- "${WATCH[@]}" ;;
    *) echo "run-all.sh: unknown-shard shard=$shard" >&2; exit 1 ;;
  esac
fi
for arg in "$@"; do
  case "$arg" in
    '') echo "run-all.sh: empty name filter; a filter is a substring of a suite's base name" >&2; exit 1 ;;
    '!'*) REJECT+=("${arg#\!}") ;;
    *) SELECT+=("$arg") ;;
  esac
done
FILTER="$*"

matches() { # BASE FILTER
  case "$2" in
    =*) [ "$1" = "${2#=}" ] ;;
    *) case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac ;;
  esac
}

# Bash 3.2 under `set -u` errors on "${arr[@]}" when arr is empty, so each
# expansion below sits behind its own count.
wanted() { # BASE
  local keep=1 pat
  if [ "${#SELECT[@]}" -gt 0 ]; then
    keep=0
    for pat in "${SELECT[@]}"; do
      if matches "$1" "$pat"; then keep=1; break; fi
    done
  fi
  if [ "$keep" -eq 1 ] && [ "${#REJECT[@]}" -gt 0 ]; then
    for pat in "${REJECT[@]}"; do
      if matches "$1" "$pat"; then keep=0; break; fi
    done
  fi
  [ "$keep" -eq 1 ]
}

alone() { # BASE
  local name
  [ "${#ALONE[@]}" -gt 0 ] || return 1
  for name in "${ALONE[@]}"; do
    [ "$name" != "$1" ] || return 0
  done
  return 1
}

SUITES=()
LATER=()
for test_file in "$TEST_DIR"/*.sh; do
  [[ -f "$test_file" ]] || continue
  base=$(basename "$test_file" .sh)
  [[ "$base" == "run-all" ]] && continue
  wanted "$base" || continue
  if alone "$base"; then LATER+=("$base"); else SUITES+=("$base"); fi
done
# Suites before POOLED share the workers; the rest run alone.
POOLED=${#SUITES[@]}
[ "${#LATER[@]}" -eq 0 ] || SUITES+=("${LATER[@]}")
RUN=${#SUITES[@]}

if [[ "$RUN" -eq 0 ]]; then
  if [[ -n "$FILTER" ]]; then
    echo "run-all.sh: no test scripts matched filter '$FILTER' under $TEST_DIR" >&2
  else
    echo "run-all.sh: no test scripts found under $TEST_DIR" >&2
  fi
  exit 1
fi

JOBS="$(nproc 2>/dev/null)" || JOBS=4
case "$JOBS" in
  '' | *[!0-9]* | 0) echo "run-all.sh: nproc printed '$JOBS', not a worker count" >&2; exit 1 ;;
esac

# A suite's own bound: 1.7 times the slowest suite of merge-group run
# 37477526298, open-terminal-relaunch-route at 540s on macOS. It is the only
# bound where no deadline is set, as on tools/guard's runs, and on a 30-minute
# leg it stops a suite hung early in time for the ALONE suites, which wait for
# every other suite to end, to run before the deadline.
SUITE_SECS="${RUN_ALL_SUITE_SECS:-900}"
case "$SUITE_SECS" in
  '' | *[!0-9]* | 0*) echo "run-all.sh: RUN_ALL_SUITE_SECS is '$SUITE_SECS', not a positive whole number of seconds" >&2; exit 1 ;;
esac
# The run's deadline on the SECONDS clock, or empty for none. It is fixed at
# the run's start, so a suite that starts late gets only the time left.
DEADLINE=""
if [ -n "${RUN_ALL_DEADLINE_EPOCH:-}" ]; then
  case "$RUN_ALL_DEADLINE_EPOCH" in
    *[!0-9]* | 0*) echo "run-all.sh: RUN_ALL_DEADLINE_EPOCH is '$RUN_ALL_DEADLINE_EPOCH', not a Unix time in whole seconds" >&2; exit 1 ;;
  esac
  now="$(date +%s)" || { echo "run-all.sh: date failed; no clock to hold RUN_ALL_DEADLINE_EPOCH to" >&2; exit 1; }
  DEADLINE=$((SECONDS + RUN_ALL_DEADLINE_EPOCH - now))
fi
# How long a stopped suite's processes get to end on TERM, its EXIT trap's
# cleanup among them, before KILL.
STOP_GRACE=10

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orch-run-all.XXXXXX")" ||
  { echo "run-all.sh: mktemp failed; no directory to hold suite output" >&2; exit 1; }
trap 'rm -rf -- "$OUT_DIR"' EXIT
trap 'stop_suites; exit 130' INT
trap 'stop_suites; exit 143' TERM

# Prints "PASS FAIL" from a suite's output, per the shapes the header names.
counts_of() { # FILE
  awk '
    match($0, /pass: *[0-9]+ +fail: *[0-9]+/) ||
    match($0, /[0-9]+ pass(ed)?, *[0-9]+ fail(ed)?/) {
      s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]+/, " ", s)
      split(s, n, " "); p = n[1]; f = n[2]; next
    }
    /^Ran [0-9]+ tests? in / { ran = $2; next }
    ran != "" && /^OK/ { p = ran; f = 0; ran = ""; next }
    ran != "" && /^FAILED \(/ {
      f = 0
      if (match($0, /failures=[0-9]+/)) f += substr($0, RSTART + 9, RLENGTH - 9)
      if (match($0, /errors=[0-9]+/)) f += substr($0, RSTART + 7, RLENGTH - 7)
      p = ran - f; ran = ""; next
    }
    END { print p + 0, f + 0 }
  ' "$1"
}

FAIL_FILES=()
TOTAL_PASS=0
TOTAL_FAIL=0

# STOP is empty for a suite that ended on its own, and otherwise the bound
# that stopped it, suite-timeout or run-deadline, or unstarted for one the
# deadline never let start; LAST is the line it printed last before the stop.
report() { # BASE STATUS SECONDS [STOP LAST]
  local pass fail counts
  printf '\n──── %s ────\n' "$1"
  cat -- "$OUT_DIR/$1.out" 2>/dev/null ||
    echo "run-all.sh: $1 left no readable output"
  # A suite killed mid-line would otherwise glue its last line to the report.
  [[ ! -s "$OUT_DIR/$1.out" || -z "$(tail -c 1 -- "$OUT_DIR/$1.out")" ]] || echo
  case "${4:-}" in
    '') ;;
    suite-timeout) printf 'run-all.sh: suite-timeout suite=%s seconds=%s\n' "$1" "$SUITE_SECS" ;;
    run-deadline) printf 'run-all.sh: run-deadline suite=%s started=yes\n' "$1" ;;
    unstarted) printf 'run-all.sh: run-deadline suite=%s started=no\n' "$1" ;;
    *) echo "run-all.sh: report given stop '$4', not one this runner makes" >&2; exit 1 ;;
  esac
  [[ -z "${4:-}" ]] || printf 'last line: %s\n' "${5:-none}"
  counts="$(counts_of "$OUT_DIR/$1.out" 2>/dev/null)" || counts="0 0"
  read -r pass fail <<<"$counts"
  # A suite that trapped the stop and exited 0 still never finished.
  if [[ "$2" != 0 || -n "${4:-}" ]]; then
    [[ "$fail" -gt 0 ]] || fail=1
    FAIL_FILES+=("$1")
  fi
  TOTAL_PASS=$((TOTAL_PASS + pass))
  TOTAL_FAIL=$((TOTAL_FAIL + fail))
  printf 'suite=%s seconds=%s pass=%s fail=%s\n' "$1" "$3" "$pass" "$fail"
}

# A live process's start time, which with its pid names that one process: a
# number freed by its exit and handed to a later process comes back with
# another start. Status 1 for a process that has ended, a zombie included, or
# whose state or start could not be read, so nothing signals it.
started_at() { # PID
  local state start
  state="$(lane_process_state "$1")" || return 1
  case "$state" in '' | Z) return 1 ;; esac
  start="$(lane_process_start "$1")" || return 1
  [ -n "$start" ] || return 1
  printf '%s\n' "$start"
}

# PID and every process under it, one `PID START` line each. Taken before any
# signal: a process whose parent the stop ends is no longer found under it. A
# process table that cannot be read leaves PID alone in it.
tree_of() { # PID
  local table hops pid start
  table="$(lane_process_table)" || table=""
  while read -r hops pid; do
    [ -n "$pid" ] || continue
    start="$(started_at "$pid")" && printf '%s %s\n' "$pid" "$start"
  done <<<"0 $1
$(lane_process_below "$table" "$1" '' 0 '' pids)"
  return 0
}

# The processes of TREE that are still the ones listed there, one pid a line.
tree_live() { # TREE
  local pid start
  while read -r pid start; do
    [ -n "$pid" ] && [ "$(started_at "$pid")" = "$start" ] && printf '%s\n' "$pid"
  done <<<"$1"
  return 0
}

signal_tree() { # SIGNAL TREE
  local pid
  for pid in $(tree_live "$2"); do kill -"$1" "$pid" 2>/dev/null; done
  return 0
}

tree_running() { [ -n "$(tree_live "$1")" ]; } # TREE

# Suites stay in the runner's process group, so HUP, TERM or KILL sent to
# the group ends them with it. A background job ignores SIGINT, and TERM may
# reach the runner alone, so on either this sends TERM to every running suite
# and its descendants and waits for each before the runner exits.
stop_suites() {
  local k=0
  while [ "$k" -lt "$JOBS" ]; do
    [ -z "${SLOT_PID[k]:-}" ] || signal_tree TERM "$(tree_of "${SLOT_PID[k]}")"
    k=$((k + 1))
  done
  k=0
  while [ "$k" -lt "$JOBS" ]; do
    [ -z "${SLOT_PID[k]:-}" ] || wait "${SLOT_PID[k]}" 2>/dev/null
    k=$((k + 1))
  done
}

# Slot K's suite at its bound: its last line kept, then TERM to its tree and,
# after STOP_GRACE, KILL to whatever of it still runs. A process that set up its
# own process group, as GNU timeout does, is in the tree, which no group signal
# would reach. The slot is reaped and reported on the next pass.
stop_overdue() { # K
  local tree until=$((SECONDS + STOP_GRACE))
  SLOT_STOP[$1]="${SLOT_BOUND[$1]}"
  SLOT_LAST[$1]="$(awk 'NF { last = $0 } END { print last }' "$OUT_DIR/${SLOT[$1]}.out" 2>/dev/null)"
  tree="$(tree_of "${SLOT_PID[$1]}")"
  signal_tree TERM "$tree"
  while tree_running "$tree" && [ "$SECONDS" -lt "$until" ]; do sleep 0.1; done
  signal_tree KILL "$tree"
}

# One slot per worker, each empty or holding the suite it runs. A suite is
# reaped once `kill -0` finds it gone, and `wait` then returns the status the
# shell kept for it; one still running at its DUE time, the earlier of its own
# bound and the deadline, which BOUND names, is stopped on that pass. A slot is
# refilled on the pass that reaps it, except that a suite from ALONE starts
# only when no slot is busy, and none starts past the deadline; the loop
# sleeps only when a pass found nothing to reap.
SLOT=()
SLOT_PID=()
SLOT_START=()
SLOT_DUE=()
SLOT_BOUND=()
SLOT_STOP=()
SLOT_LAST=()
k=0
while [ "$k" -lt "$JOBS" ]; do
  SLOT[k]=""; SLOT_PID[k]=""; SLOT_START[k]=0; SLOT_DUE[k]=0; SLOT_BOUND[k]=""; SLOT_STOP[k]=""; SLOT_LAST[k]=""
  k=$((k + 1))
done
started=$SECONDS
next=0
finished=0
running=0
while [ "$finished" -lt "$RUN" ]; do
  reaped=0
  k=0
  while [ "$k" -lt "$JOBS" ]; do
    base="${SLOT[k]}"
    if [ -n "$base" ] && [ -z "${SLOT_STOP[k]}" ] &&
      [ "$SECONDS" -ge "${SLOT_DUE[k]}" ] && kill -0 "${SLOT_PID[k]}" 2>/dev/null; then
      stop_overdue "$k"
    fi
    if [ -n "$base" ] && ! kill -0 "${SLOT_PID[k]}" 2>/dev/null; then
      wait "${SLOT_PID[k]}"
      status=$?
      report "$base" "$status" "$((SECONDS - SLOT_START[k]))" "${SLOT_STOP[k]}" "${SLOT_LAST[k]}"
      SLOT[k]=""
      SLOT_PID[k]=""
      SLOT_STOP[k]=""
      SLOT_LAST[k]=""
      finished=$((finished + 1))
      running=$((running - 1))
      reaped=1
    fi
    if [ -z "${SLOT[k]}" ] && [ "$next" -lt "$RUN" ] &&
      { [ "$next" -lt "$POOLED" ] || [ "$running" -eq 0 ]; } &&
      { [ -z "$DEADLINE" ] || [ "$SECONDS" -lt "$DEADLINE" ]; }; then
      printf 'start suite=%s\n' "${SUITES[next]}"
      bash "$TEST_DIR/${SUITES[next]}.sh" >"$OUT_DIR/${SUITES[next]}.out" 2>&1 </dev/null &
      SLOT_PID[k]=$!
      SLOT[k]="${SUITES[next]}"
      SLOT_START[k]=$SECONDS
      SLOT_DUE[k]=$((SECONDS + SUITE_SECS))
      SLOT_BOUND[k]=suite-timeout
      if [ -n "$DEADLINE" ] && [ "$DEADLINE" -le "${SLOT_DUE[k]}" ]; then
        SLOT_DUE[k]=$DEADLINE
        SLOT_BOUND[k]=run-deadline
      fi
      running=$((running + 1))
      next=$((next + 1))
    fi
    k=$((k + 1))
  done
  # Past the deadline, once no suite runs, each suite left never started.
  if [ -n "$DEADLINE" ] && [ "$SECONDS" -ge "$DEADLINE" ] && [ "$running" -eq 0 ]; then
    while [ "$next" -lt "$RUN" ]; do
      : >"$OUT_DIR/${SUITES[next]}.out"
      report "${SUITES[next]}" none 0 unstarted
      finished=$((finished + 1))
      next=$((next + 1))
    done
  fi
  [ "$reaped" -eq 1 ] || [ "$finished" -ge "$RUN" ] || sleep 0.1
done

echo
echo "============================================"
printf 'total suites=%d seconds=%d pass=%d fail=%d\n' \
  "$RUN" "$((SECONDS - started))" "$TOTAL_PASS" "$TOTAL_FAIL"
if [[ ${#FAIL_FILES[@]} -eq 0 ]]; then
  printf '%s tests: all %d file(s) passed\n' "$BATTERY" "$RUN"
  exit 0
else
  printf '%s tests: %d/%d file(s) FAILED:\n' "$BATTERY" "${#FAIL_FILES[@]}" "$RUN"
  for f in "${FAIL_FILES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
