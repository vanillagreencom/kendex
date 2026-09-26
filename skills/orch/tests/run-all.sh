#!/usr/bin/env bash
# Run every orch test in tests/*.sh.
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
#
# Each argument is a substring of a suite's base name. A bare one selects,
# one written `!name` rejects, and a file runs when it matches a selector —
# or none was given — and matches no rejector. Two runs whose arguments are
# a set and that set negated therefore partition the battery: every suite
# runs in exactly one of them, and a suite added later lands in the negated
# run rather than in neither. CI's orch shards are that partition.
#
# Suites run as many at a time as `nproc` reports, or 4 where it cannot
# answer (a stock macOS has no nproc). A suite's stdout and stderr are held
# until it exits and then printed whole under its header, so two suites
# never interleave; headers come in completion order. A suite in ALONE
# below runs by itself after the others. Each suite prints one line when it
# starts, so a run cut off by a signal or a job timeout still names every
# suite that was running; after its output comes one line, and after the
# last suite one total line:
#
#   start suite=<name>
#   suite=<name> seconds=<n> pass=<n> fail=<n>
#   total suites=<n> seconds=<n> pass=<n> fail=<n>
#
# The `orch tests:` verdict line follows the total, and on a red run one
# `  - <name>` line per red suite follows the verdict.
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SELECT=()
REJECT=()
for arg in "$@"; do
  case "$arg" in
    '') echo "run-all.sh: empty name filter; a filter is a substring of a suite's base name" >&2; exit 1 ;;
    '!'*) REJECT+=("${arg#\!}") ;;
    *) SELECT+=("$arg") ;;
  esac
done
FILTER="$*"

# Bash 3.2 under `set -u` errors on "${arr[@]}" when arr is empty, so each
# expansion below sits behind its own count.
wanted() { # BASE
  local keep=1 pat
  if [ "${#SELECT[@]}" -gt 0 ]; then
    keep=0
    for pat in "${SELECT[@]}"; do
      case "$1" in *"$pat"*) keep=1; break ;; esac
    done
  fi
  if [ "$keep" -eq 1 ] && [ "${#REJECT[@]}" -gt 0 ]; then
    for pat in "${REJECT[@]}"; do
      case "$1" in *"$pat"*) keep=0; break ;; esac
    done
  fi
  [ "$keep" -eq 1 ]
}

# Suites that run alone, one at a time, once every other selected suite has
# finished: each holds a fixed wall-clock window that the code under test
# must meet, and a loaded host has made it miss. One name per line, first
# word, with the window it holds; run-all-parallel.sh reads this list.
ALONE=(
  open-terminal-lane      # the lane-tree stub holds the picked account for 2s
  oversee_watch_lifecycle # a takeover case waits 10s for the takeover line
)

alone() { # BASE
  local name
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

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orch-run-all.XXXXXX")" ||
  { echo "run-all.sh: mktemp failed; no directory to hold suite output" >&2; exit 1; }
trap 'rm -rf -- "$OUT_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

report() { # BASE STATUS SECONDS
  local pass fail counts
  printf '\n──── %s ────\n' "$1"
  cat -- "$OUT_DIR/$1.out" 2>/dev/null ||
    echo "run-all.sh: $1 left no readable output"
  # A suite killed mid-line would otherwise glue its last line to the report.
  [[ ! -s "$OUT_DIR/$1.out" || -z "$(tail -c 1 -- "$OUT_DIR/$1.out")" ]] || echo
  counts="$(counts_of "$OUT_DIR/$1.out" 2>/dev/null)" || counts="0 0"
  read -r pass fail <<<"$counts"
  if [[ "$2" != 0 ]]; then
    [[ "$fail" -gt 0 ]] || fail=1
    FAIL_FILES+=("$1")
  fi
  TOTAL_PASS=$((TOTAL_PASS + pass))
  TOTAL_FAIL=$((TOTAL_FAIL + fail))
  printf 'suite=%s seconds=%s pass=%s fail=%s\n' "$1" "$3" "$pass" "$fail"
}

# One slot per worker, each empty or holding the suite it runs. A suite is
# reaped once `kill -0` finds it gone, and `wait` then returns the status the
# shell kept for it. A slot is refilled on the pass that reaps it, except that
# a suite from ALONE starts only when no slot is busy; the loop sleeps only
# when a pass found nothing to reap.
SLOT=()
SLOT_PID=()
SLOT_START=()
k=0
while [ "$k" -lt "$JOBS" ]; do SLOT[k]=""; SLOT_PID[k]=""; SLOT_START[k]=0; k=$((k + 1)); done
started=$SECONDS
next=0
finished=0
running=0
while [ "$finished" -lt "$RUN" ]; do
  reaped=0
  k=0
  while [ "$k" -lt "$JOBS" ]; do
    base="${SLOT[k]}"
    if [ -n "$base" ] && ! kill -0 "${SLOT_PID[k]}" 2>/dev/null; then
      wait "${SLOT_PID[k]}"
      status=$?
      report "$base" "$status" "$((SECONDS - SLOT_START[k]))"
      SLOT[k]=""
      finished=$((finished + 1))
      running=$((running - 1))
      reaped=1
    fi
    if [ -z "${SLOT[k]}" ] && [ "$next" -lt "$RUN" ] &&
      { [ "$next" -lt "$POOLED" ] || [ "$running" -eq 0 ]; }; then
      SLOT[k]="${SUITES[next]}"
      printf 'start suite=%s\n' "${SLOT[k]}"
      bash "$TEST_DIR/${SLOT[k]}.sh" >"$OUT_DIR/${SLOT[k]}.out" 2>&1 </dev/null &
      SLOT_PID[k]=$!
      SLOT_START[k]=$SECONDS
      running=$((running + 1))
      next=$((next + 1))
    fi
    k=$((k + 1))
  done
  [ "$reaped" -eq 1 ] || [ "$finished" -ge "$RUN" ] || sleep 0.1
done

echo
echo "============================================"
printf 'total suites=%d seconds=%d pass=%d fail=%d\n' \
  "$RUN" "$((SECONDS - started))" "$TOTAL_PASS" "$TOTAL_FAIL"
if [[ ${#FAIL_FILES[@]} -eq 0 ]]; then
  printf 'orch tests: all %d file(s) passed\n' "$RUN"
  exit 0
else
  printf 'orch tests: %d/%d file(s) FAILED:\n' "${#FAIL_FILES[@]}" "$RUN"
  for f in "${FAIL_FILES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
