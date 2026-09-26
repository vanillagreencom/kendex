#!/usr/bin/env bash
# Behavioral tests for run-all.sh's worker pool and its per-suite report.
# The battery runs its suites `nproc` at a time and prints each suite's
# output whole under its header followed by one
# `suite=<name> seconds=<n> pass=<n> fail=<n>` line. One
# `total suites=<n> seconds=<n> pass=<n> fail=<n>` line follows the last
# suite, and the `orch tests:` verdict follows the total, with one
# `  - <name>` line per red suite on a red run. Every run below is a
# sandbox holding a copy of run-all.sh and suites written here, with `nproc`
# stubbed on PATH, so the real scheduler runs over suites whose outcome and
# timing the case controls.
#
# Three surfaces:
#   1. the report — each summary shape a suite prints becomes that suite's
#      pass and fail counts, the last summary line winning, a suite's
#      seconds cover its own run, and a green battery exits 0
#   2. a red suite — the run exits 1, names the suite in the FAILED block,
#      prints its stdout and stderr whole under its header, and its line
#      never reads fail=0; one row per way a suite goes red
#   3. the worker count — at least 2 suites overlap when nproc reports 2,
#      and exactly 4 where nproc cannot answer; at 1 no two overlap; a count
#      that is not a number refuses
#
# Bash 3.2 compatible.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-all-parallel.XXXXXX")" ||
  { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf -- "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# A fresh battery directory holding run-all.sh and no suites, and DIR.tmp for
# its TMPDIR.
battery() { # DIR
  mkdir -p "$1/lib" "$1.tmp"
  cp "$TEST_DIR/run-all.sh" "$1/run-all.sh"
  printf '#!/usr/bin/env bash\n:\n' >"$1/lib/git-env.sh"
}

# A suite that prints BODY, if any, then ERR, if any, to stderr, and exits
# STATUS.
suite() { # DIR NAME STATUS BODY [ERR]
  {
    printf '#!/usr/bin/env bash\n'
    [[ -z "$4" ]] || printf 'printf "%%s\\n" %q\n' "$4"
    [[ -z "${5:-}" ]] || printf 'printf "%%s\\n" %q >&2\n' "$5"
    printf 'exit %s\n' "$3"
  } >"$1/$2.sh"
}

# The green roster: one suite per summary shape, and the counts it reports.
GREEN_NAMES=(shape-colon shape-words shape-short shape-unittest shape-none)
GREEN_BODIES=(
  $'pass: 1   fail: 9\npass: 3   fail: 0'
  'Results: 4 passed, 0 failed'
  'container-close: 5 pass, 0 fail'
  $'Ran 6 tests in 0.1s\n\nOK'
  'no summary at all'
)
GREEN_WANT=('pass=3 fail=0' 'pass=4 fail=0' 'pass=5 fail=0' 'pass=6 fail=0' 'pass=0 fail=0')

green_battery() { # DIR
  local i=0
  battery "$1"
  while [ "$i" -lt "${#GREEN_NAMES[@]}" ]; do
    suite "$1" "${GREEN_NAMES[i]}" 0 "${GREEN_BODIES[i]}"
    i=$((i + 1))
  done
}

# Runs a battery with nproc answering NPROC (`fail` makes it exit 1), and
# leaves the combined output in $OUT and the exit status in $RC.
run_battery() { # DIR NPROC [VAR=VALUE]...
  local dir="$1" stub="$1.bin"
  mkdir -p "$stub"
  if [[ "$2" == fail ]]; then
    printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/nproc"
  else
    printf '#!/usr/bin/env bash\necho %s\n' "$2" >"$stub/nproc"
  fi
  chmod +x "$stub/nproc"
  shift 2
  RC=0
  OUT="$(env -i PATH="$stub:$PATH" HOME="$HOME" TMPDIR="$dir.tmp" "$@" \
    bash "$dir/run-all.sh" 2>&1)" || RC=$?
}

line_of() { # NAME ; that suite's report line, seconds masked
  printf '%s\n' "$OUT" | sed -n "s/^suite=$1 seconds=[0-9][0-9]* /suite=$1 seconds=N /p"
}

failed_of() { # the FAILED block's names, sorted and space-joined
  printf '%s\n' "$OUT" | sed -n 's/^  - //p' | sort | tr '\n' ' '
}

echo "=== 1. the report: every summary shape is a count, and green exits 0 ==="
B="$TMP_ROOT/green"
green_battery "$B"
run_battery "$B" 3
assert_eq "$RC" 0 "a green battery exits 0"
i=0
while [ "$i" -lt "${#GREEN_NAMES[@]}" ]; do
  assert_eq "$(line_of "${GREEN_NAMES[i]}")" "suite=${GREEN_NAMES[i]} seconds=N ${GREEN_WANT[i]}" \
    "${GREEN_NAMES[i]} reports ${GREEN_WANT[i]}"
  i=$((i + 1))
done
assert_eq "$(printf '%s\n' "$OUT" | sed -n 's/^total suites=5 seconds=[0-9][0-9]* /total suites=5 seconds=N /p')" \
  "total suites=5 seconds=N pass=18 fail=0" "the total line counts every suite and sums its counts"
assert_eq "$(ls -A "$B.tmp")" "" "the run removes the directory that held suite output"

# The lower bound is the suite's own sleep; load only makes it longer.
B="$TMP_ROOT/timed"
battery "$B"
printf '#!/usr/bin/env bash\nsleep 2\n' >"$B/timed.sh"
run_battery "$B" 3
secs="$(printf '%s\n' "$OUT" | sed -n 's/^suite=timed seconds=\([0-9][0-9]*\) .*/\1/p')"
assert_eq "rc=$RC at-least-2=$([ "${secs:-0}" -ge 2 ] && echo yes || echo "no ($secs)")" \
  "rc=0 at-least-2=yes" "a suite that sleeps 2s reports seconds of at least 2"

echo "=== 2. a red suite fails the run, under its own name ==="
RED_NAMES=(red-counted red-uncounted red-crash red-unittest)
RED_STATUS=(1 1 3 1)
RED_BODIES=(
  'pass: 2   fail: 1'
  'pass: 2   fail: 0'
  ''
  $'Ran 5 tests in 0.1s\n\nFAILED (failures=1, errors=1)'
)
# red-counted also writes to stderr, which lands under its header after its
# stdout.
RED_ERR=('stderr-marker' '' '' '')
RED_WANT=('pass=2 fail=1' 'pass=2 fail=1' 'pass=0 fail=1' 'pass=3 fail=2')
i=0
while [ "$i" -lt "${#RED_NAMES[@]}" ]; do
  name="${RED_NAMES[i]}"
  B="$TMP_ROOT/$name"
  green_battery "$B"
  suite "$B" "$name" "${RED_STATUS[i]}" "${RED_BODIES[i]}" "${RED_ERR[i]}"
  want_body="${RED_BODIES[i]}"
  [[ -z "${RED_ERR[i]}" ]] || want_body+=$'\n'"${RED_ERR[i]}"
  run_battery "$B" 3
  assert_eq "rc=$RC failed=$(failed_of)" "rc=1 failed=$name " "$name: the run exits 1 and names only it"
  assert_eq "$(line_of "$name")" "suite=$name seconds=N ${RED_WANT[i]}" "$name reports ${RED_WANT[i]}"
  assert_eq "$(printf '%s\n' "$OUT" | awk -v h="──── $name ────" -v t="suite=$name " \
    '$0 == h { on = 1; next } on && index($0, t) == 1 { exit } on')" "$want_body" \
    "$name: its stdout and stderr are printed whole under its header"
  i=$((i + 1))
done

echo "=== 3. the worker count ==="
# Each meet-* suite marks itself started, then waits for all MEET_N to have
# started; it passes only when that many run at once.
meet_battery() { # DIR COUNT
  local i=1
  battery "$1"
  mkdir -p "$1.meet"
  while [ "$i" -le "$2" ]; do
    cat >"$1/meet-$i.sh" <<'EOF'
#!/usr/bin/env bash
touch "$MEET_DIR/${0##*/}"
tick=0
while :; do
  set -- "$MEET_DIR"/*
  [ "$#" -ge "$MEET_N" ] && { echo 'pass: 1   fail: 0'; exit 0; }
  tick=$((tick + 1))
  [ "$tick" -le $((MEET_SECS * 10)) ] || { echo 'pass: 0   fail: 1'; exit 1; }
  sleep 0.1
done
EOF
    i=$((i + 1))
  done
}

# NPROC|SUITES|WAIT SECONDS|EXPECTED
# A row whose suites cannot all meet shows the cap: the first NPROC time out
# and the one started after them finds every marker already there.
WORKER_ROWS='2|2|60|rc=0 failed=
fail|4|60|rc=0 failed=
fail|5|2|rc=1 failed=meet-1 meet-2 meet-3 meet-4 
1|2|2|rc=1 failed=meet-1 '
while IFS='|' read -r nproc count secs want; do
  B="$TMP_ROOT/meet-$nproc-$count"
  meet_battery "$B" "$count"
  run_battery "$B" "$nproc" MEET_DIR="$B.meet" MEET_N="$count" MEET_SECS="$secs"
  assert_eq "rc=$RC failed=$(failed_of)" "$want" \
    "nproc $nproc runs $count waiting suites: $want"
done <<<"$WORKER_ROWS"

B="$TMP_ROOT/junk"
green_battery "$B"
run_battery "$B" x
assert_eq "rc=$RC $(printf '%s\n' "$OUT" | sed -n '1s/ printed.*//p')" "rc=1 run-all.sh: nproc" \
  "a worker count that is not a number refuses before any suite runs"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
