#!/usr/bin/env bash
# Behavioral tests for run-all.sh's worker pool and its per-suite report.
# The battery runs its suites `nproc` at a time, prints one
# `start suite=<name>` line as each starts, and prints each suite's
# output whole under its header followed by one
# `suite=<name> seconds=<n> pass=<n> fail=<n>` line. One
# `total suites=<n> seconds=<n> pass=<n> fail=<n>` line follows the last
# suite, and the `<tree> tests:` verdict follows the total, <tree> being
# the name of the battery directory's parent, with one `  - <name>` line per
# red suite on a red run. Every run below is a sandbox holding a copy of
# run-all.sh and suites written here, with `nproc` stubbed on PATH, so the
# real scheduler runs over suites whose outcome and timing the case
# controls.
#
# Surfaces:
#   1. the report — each suite's start line comes once, before its output;
#      each summary shape a suite prints becomes that suite's pass and fail
#      counts, the last summary line winning, a suite's seconds cover its
#      own run, and a green battery exits 0
#   2. a red suite — the run exits 1, names the suite in the FAILED block,
#      prints its stdout and stderr whole under its header, and its line
#      never reads fail=0; one row per way a suite goes red
#   3. the worker count — at least 2 suites overlap when nproc reports 2,
#      and exactly 4 where nproc cannot answer; at 1 no two overlap; a count
#      that is not a number refuses
#   4. the ALONE list — each suite run-all.sh names there starts only when
#      no other suite runs, and no suite starts while it runs
#   5. a signal — SIGINT or SIGHUP to the runner's process group, or SIGTERM
#      to the runner alone, ends the run and the suite it was running
#   6. a name filter — a bare one selects each suite whose name holds it,
#      one written `=name` that suite alone, and `!` rejects either way
#   7. caller lane state — an ORCH_STATE_DIR the caller set never reaches a
#      suite, which still sets its own
#   8. --battery — the suites of the directory it names run in place of the
#      runner's own, and the verdict line names that directory's tree
#   9. --alone — with --battery, the suites it names run alone, and a suite
#      sharing a name with one in the runner's own ALONE list runs pooled
#  10. the bound — a suite still running RUN_ALL_SUITE_SECS after its start
#      gets TERM, then KILL, through every process under it, a child that left
#      its process group included; it reports red under its keyed line with
#      the row it printed last, even where it exits 0 on the stop, and a bound
#      that is not a number refuses
#
# Bash 3.2 compatible.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-all-parallel.XXXXXX")" ||
  { echo "mktemp failed" >&2; exit 1; }
# Section 5's suites loop until killed; one a red row left alive dies here.
STAGED=()
trap '[ "${#STAGED[@]}" -eq 0 ] || kill "${STAGED[@]}" 2>/dev/null; rm -rf -- "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"

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

# Runs a battery with nproc answering NPROC (`fail` makes it exit 1), the
# settings in its environment and each ARG after `--` on its command line, and
# leaves the combined output in $OUT and the exit status in $RC.
run_battery() { # DIR NPROC [VAR=VALUE]... [-- ARG...]
  local dir="$1" stub="$1.bin" settings=()
  mkdir -p "$stub"
  if [[ "$2" == fail ]]; then
    printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/nproc"
  else
    printf '#!/usr/bin/env bash\necho %s\n' "$2" >"$stub/nproc"
  fi
  chmod +x "$stub/nproc"
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    settings+=("$1")
    shift
  done
  [ "$#" -eq 0 ] || shift
  RC=0
  OUT="$(env -i PATH="$stub:$PATH" HOME="$HOME" TMPDIR="$dir.tmp" ${settings[@]+"${settings[@]}"} \
    bash "$dir/run-all.sh" "$@" 2>&1)" || RC=$?
}

started_of() { # the suites $OUT names a start line for, one a line, in start order
  printf '%s\n' "$OUT" | sed -n 's/^start suite=//p'
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
  assert_eq "$(printf '%s\n' "$OUT" | awk -v s="start suite=${GREEN_NAMES[i]}" -v h="──── ${GREEN_NAMES[i]} ────" '
      $0 == s { n++; if (!head) before++ } $0 == h { head = 1 }
      END { print "starts=" n + 0 " before-header=" before + 0 }')" "starts=1 before-header=1" \
    "${GREEN_NAMES[i]} prints one start line, before its output"
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
# Each suite NAME appends `start NAME` and, a second later, `end NAME` to the
# file $EV names, so that file's order is the order suites started and
# finished in.
event_suites() { # DIR NAME...
  local dir="$1" name
  shift
  for name in "$@"; do
    printf '#!/usr/bin/env bash\necho "start %s" >>"$EV"\nsleep 1\necho "end %s" >>"$EV"\n' \
      "$name" "$name" >"$dir/$name.sh"
  done
}

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
WORKER_ROWS='2|2|60|rc=0 failed=
fail|4|60|rc=0 failed=
1|2|2|rc=1 failed=meet-1 '
while IFS='|' read -r nproc count secs want; do
  B="$TMP_ROOT/meet-$nproc-$count"
  meet_battery "$B" "$count"
  run_battery "$B" "$nproc" MEET_DIR="$B.meet" MEET_N="$count" MEET_SECS="$secs"
  assert_eq "rc=$RC failed=$(failed_of)" "$want" \
    "nproc $nproc runs $count waiting suites: $want"
done <<<"$WORKER_ROWS"

# The most suites the event file shows running at once, which can only be
# fewer than the runner had, so it bounds the cap from above whatever the
# host's load; the fallback row above bounds it from below.
B="$TMP_ROOT/cap"
battery "$B"
event_suites "$B" ev-1 ev-2 ev-3 ev-4 ev-5 ev-6
run_battery "$B" fail EV="$B.ev"
most="$(awk '$1 == "start" { if (++n > m) m = n } $1 == "end" { n-- } END { print m + 0 }' "$B.ev")"
assert_eq "rc=$RC at-most-4=$([ "$most" -le 4 ] && echo yes || echo "no ($most)")" \
  "rc=0 at-most-4=yes" "nproc fail runs six suites at most 4 at once"

B="$TMP_ROOT/junk"
green_battery "$B"
run_battery "$B" x
assert_eq "rc=$RC $(printf '%s\n' "$OUT" | sed -n '1s/ printed.*//p')" "rc=1 run-all.sh: nproc" \
  "a worker count that is not a number refuses before any suite runs"

echo "=== 4. a suite in the ALONE list runs by itself ==="
ALONE_NAMES="$(sed -n '/^ALONE=(/,/^)/p' "$TEST_DIR/run-all.sh" | sed '1d;$d' | awk '{print $1}')"
assert_eq "$([ -n "$ALONE_NAMES" ] && echo found || echo 'none: the sed over run-all.sh ALONE=( ... ) is broken')" \
  found "the ALONE list is read out of run-all.sh"
B="$TMP_ROOT/alone"
battery "$B"
event_suites "$B" pool-1 pool-2 pool-3 $ALONE_NAMES
run_battery "$B" 4 EV="$B.ev"
verdicts="$(printf '%s\n' "$ALONE_NAMES" | awk -v ev="$B.ev" '
  NR == FNR { alone[$1] = 1; order[++k] = $1; next }
  $1 == "start" { seen[$2] = 1; if (active > 0 && ($2 in alone)) bad[$2] = 1; if (solo != "") bad[solo] = 1
                  active++; if ($2 in alone) solo = $2; next }
  $1 == "end" { active--; if ($2 == solo) solo = "" }
  END { for (i = 1; i <= k; i++) printf "%s=%s ", order[i],
          !(order[i] in seen) ? "missing" : (order[i] in bad) ? "overlapped" : "alone" }
' - "$B.ev")"
want="$(printf '%s\n' "$ALONE_NAMES" | awk '{printf "%s=alone ", $1}')"
assert_eq "rc=$RC $verdicts" "rc=0 $want" "every ALONE suite runs with no other suite beside it"

echo "=== 5. a signal that ends the run ends its suites ==="
# The runner leads its own process group here (set -m), so a group signal
# never reaches this file; perl sets SIGINT back to its default, as a shell
# started with it ignored could not trap it. The suite writes its pid and
# blocks, so only the runner can end it. TERM goes to the runner alone, the
# case the group does not cover.
# SIGNAL|TARGET|EXPECTED RUNNER STATUS
SIGNAL_ROWS='INT|group|130
TERM|runner|143
HUP|group|129'
while IFS='|' read -r sig target want; do
  B="$TMP_ROOT/signal-$sig"
  battery "$B"
  printf '#!/usr/bin/env bash\necho "$$" >"$PIDFILE"\nwhile :; do sleep 1; done\n' >"$B/block.sh"
  mkdir -p "$B.bin"
  printf '#!/usr/bin/env bash\necho 2\n' >"$B.bin/nproc"
  chmod +x "$B.bin/nproc"
  set -m
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' env -i PATH="$B.bin:$PATH" HOME="$HOME" \
    TMPDIR="$B.tmp" PIDFILE="$B.pid" bash "$B/run-all.sh" >"$B.out" 2>&1 &
  runner=$!
  set +m
  tick=0
  until [ -s "$B.pid" ] || [ "$tick" -ge 100 ]; do sleep 0.1; tick=$((tick + 1)); done
  suite_pid="$(cat "$B.pid" 2>/dev/null)"
  STAGED+=("$suite_pid")
  if [ "$target" = group ]; then kill -"$sig" -- "-$runner"; else kill -"$sig" "$runner"; fi
  RC=0
  wait "$runner" 2>/dev/null || RC=$?
  # A suite orphaned by the runner's exit stays visible until it is reaped.
  tick=0
  while kill -0 "$suite_pid" 2>/dev/null && [ "$tick" -lt 50 ]; do sleep 0.1; tick=$((tick + 1)); done
  state=gone
  [ -n "$suite_pid" ] || state=never-started
  ! kill -0 "$suite_pid" 2>/dev/null || state=alive
  assert_eq "rc=$RC suite=$state" \
    "rc=$want suite=gone" "SIG$sig to the $target ends the run at $want and ends the suite it ran"
done <<<"$SIGNAL_ROWS"

echo "=== 6. a name filter selects by substring, or by whole name written =name ==="
B="$TMP_ROOT/filter"
battery "$B"
for name in lanes lanes_context other; do suite "$B" "$name" 0 ''; done
# FILTERS|SUITES THAT START, sorted
FILTER_ROWS='=lanes|lanes
lanes|lanes lanes_context
!=lanes|lanes_context other
=lanes =other|lanes other'
while IFS='|' read -r filters want; do
  # shellcheck disable=SC2086 # the row's filters, split on purpose
  run_battery "$B" 2 -- $filters
  started="$(started_of | sort | tr '\n' ' ')"
  assert_eq "rc=$RC started=$started" "rc=0 started=$want " "the filters $filters start $want"
done <<<"$FILTER_ROWS"

echo "=== 7. caller lane state never replaces fixture state ==="
B="$TMP_ROOT/state"
battery "$B"
mkdir -p "$B/tmp" "$B.planted"
printf '{"marker":"fixture"}\n' >"$B/tmp/workflow-state-oversee.json"
printf '{"marker":"caller"}\n' >"$B.planted/workflow-state-oversee.json"
# Bash 3.2 does not apply errexit to [[ ... ]]; each assertion exits explicitly.
printf '#!/usr/bin/env bash\nset -euo pipefail\ncd -- "$(dirname "$0")"\n[[ "$("$WS" get oversee .marker)" == fixture ]] || exit 1\nexport ORCH_STATE_DIR="$PLANTED"\n[[ "$("$WS" get oversee .marker)" == caller ]] || exit 1\n' \
  >"$B/state.sh"
run_battery "$B" 1 ORCH_STATE_DIR="$B.planted" PLANTED="$B.planted" WS="$TEST_DIR/../scripts/workflow-state"
assert_eq "$RC" 0 "the suite reads fixture state and can set its own ORCH_STATE_DIR"
mutate_file "$B/run-all.sh" 'unset ORCH_STATE_DIR' ': ORCH_STATE_DIR'
run_battery "$B" 1 ORCH_STATE_DIR="$B.planted" PLANTED="$B.planted" WS="$TEST_DIR/../scripts/workflow-state"
assert_eq "rc=$RC failed=$(failed_of)" "rc=1 failed=state " "control: inherited lane state fails the fixture assertion"

echo "=== 8. --battery runs another directory's suites and names its tree ==="
B="$TMP_ROOT/runner-parent/tests"
battery "$B"
suite "$B" home-suite 0 'pass: 1   fail: 0'
OTHER="$TMP_ROOT/other-tree/tests"
mkdir -p "$OTHER"
suite "$OTHER" other-suite 0 'pass: 2   fail: 0'
battery_verdict() { # — what ran and the verdict line, from $OUT
  printf 'rc=%s started=%s verdict=%s' "$RC" "$(started_of | tr '\n' ' ')" \
    "$(printf '%s\n' "$OUT" | sed -n 's/^\(.* tests: .*\)$/\1/p')"
}
run_battery "$B" 2 -- --battery "$OTHER"
assert_eq "$(battery_verdict)" "rc=0 started=other-suite  verdict=other-tree tests: all 1 file(s) passed" \
  "--battery runs that directory's suites, none of the runner's own, and names its tree"
mutate_file "$B/run-all.sh" 'TEST_DIR="$(cd "$2" && pwd)" || exit 1' ':'
run_battery "$B" 2 -- --battery "$OTHER"
assert_eq "$(battery_verdict)" "rc=0 started=home-suite  verdict=runner-parent tests: all 1 file(s) passed" \
  "control: with the directory left unread the runner's own suites run"

echo "=== 9. --battery runs alone the suites its --alone names, and no others ==="
# Under one worker the start order is the run order: the pooled suites by
# name, then the alone ones. The other tree holds a suite named for one in the
# runner's own ALONE list.
O="${ALONE_NAMES%%$'\n'*}"
OTHER="$TMP_ROOT/alone-tree/tests"
mkdir -p "$OTHER"
for name in aaa-alone mmm-alone "$O" zzz-pool; do suite "$OTHER" "$name" 0 'pass: 1   fail: 0'; done
alone_order() { # DIR [FROM TO] ; start order of a fresh runner in DIR, FROM edited to TO
  battery "$1"
  [ "$#" -lt 3 ] || mutate_file "$1/run-all.sh" "$2" "$3"
  run_battery "$1" 1 -- --battery "$OTHER" --alone aaa-alone --alone mmm-alone
  printf 'rc=%s started=%s' "$RC" "$(started_of | tr '\n' ' ')"
}
assert_eq "$(alone_order "$TMP_ROOT/alone-runner/tests")" "rc=0 started=$O zzz-pool aaa-alone mmm-alone " \
  "--alone runs each suite it names after the rest, and the runner's own ALONE name runs pooled"
assert_eq "$(alone_order "$TMP_ROOT/alone-keep/tests" '  ALONE=()' '  :')" "rc=0 started=zzz-pool aaa-alone mmm-alone $O " \
  "control: the runner's own list kept holds back the other tree's same-named suite"
assert_eq "$(alone_order "$TMP_ROOT/alone-drop/tests" 'ALONE+=("$2")' ':')" "rc=0 started=aaa-alone mmm-alone $O zzz-pool " \
  "control: --alone left unread runs every suite pooled"

echo "=== 10. a suite past its bound is stopped and reported under its own name ==="
# The hang the bound exists for: a suite blocked on a child that set up its own
# process group and ignores TERM, as GNU timeout does once it has sent its
# signal and while it waits on a command that never ends. The child writes
# its pid; the suite's EXIT trap marks that TERM came before KILL.
hang_battery() { # DIR [FROM TO]...
  battery "$1"
  suite "$1" green 0 'pass: 1   fail: 0'
  cat >"$1/hang.sh" <<'EOF'
#!/usr/bin/env bash
trap 'echo cleaned >"$MARK"' EXIT
echo 'ok    the row before the hang'
perl -e 'setpgrp(0, 0); $SIG{TERM} = "IGNORE"; open my $f, ">", $ENV{PIDFILE} or die; print $f "$$\n"; close $f; exec "sleep", "1000" or die'
EOF
  local dir="$1"
  shift
  while [ "$#" -ge 2 ]; do mutate_file "$dir/run-all.sh" "$1" "$2"; shift 2; done
}

# Runs DIR's battery with a two-second bound under a deadline of this file's
# own, since a runner without the bound never ends: $OUT and $RC as
# run_battery leaves them, RC=hung where the deadline ended the run, and
# CHILD the hung child's state once the run is over, alive or gone.
run_bounded() { # DIR
  local dir="$1" runner until=$((SECONDS + 40)) child
  mkdir -p "$dir.bin"
  printf '#!/usr/bin/env bash\necho 2\n' >"$dir.bin/nproc"
  chmod +x "$dir.bin/nproc"
  set -m
  env -i PATH="$dir.bin:$PATH" HOME="$HOME" TMPDIR="$dir.tmp" RUN_ALL_SUITE_SECS=2 \
    PIDFILE="$dir.pid" MARK="$dir.mark" bash "$dir/run-all.sh" >"$dir.out" 2>&1 &
  runner=$!
  set +m
  while kill -0 "$runner" 2>/dev/null && [ "$SECONDS" -lt "$until" ]; do sleep 0.1; done
  RC=0
  if kill -0 "$runner" 2>/dev/null; then
    kill -KILL -- "-$runner" 2>/dev/null
    wait "$runner" 2>/dev/null
    RC=hung
  else
    wait "$runner" || RC=$?
  fi
  OUT="$(cat "$dir.out")"
  child="$(cat "$dir.pid" 2>/dev/null)"
  CHILD=never-started
  if [ -n "$child" ]; then
    STAGED+=("$child")
    CHILD=gone
    ! kill -0 "$child" 2>/dev/null || CHILD=alive
  fi
}

# The keyed line and the last row the line after it carries, from $OUT.
stopped_of() { # NAME
  printf '%s\n' "$OUT" | awk -v k="run-all.sh: suite-timeout suite=$1 " \
    'index($0, k) == 1 { print; getline; n = index($0, "ok    "); print (n ? substr($0, n) : "no-row") }' | tr '\n' ';'
}

B="$TMP_ROOT/bound"
hang_battery "$B"
run_bounded "$B"
assert_eq "rc=$RC failed=$(failed_of) child=$CHILD mark=$(cat "$B.mark" 2>/dev/null)" \
  "rc=1 failed=hang  child=gone mark=cleaned" \
  "a hung suite is stopped: TERM reaches its cleanup, KILL its child outside its process group, and the run exits 1 naming it"
assert_eq "$(stopped_of hang)|$(line_of hang)|$(line_of green)" \
  "run-all.sh: suite-timeout suite=hang seconds=2;ok    the row before the hang;|suite=hang seconds=N pass=0 fail=1|suite=green seconds=N pass=1 fail=0" \
  "the stopped suite's keyed line names it and the row it printed last, and the suite beside it still reports"

B="$TMP_ROOT/bound-off"
hang_battery "$B" '      stop_overdue "$k"' '      :'
run_bounded "$B"
assert_eq "rc=$RC" "rc=hung" "control: with the bound never acted on, the hung suite holds the run"

B="$TMP_ROOT/bound-nokill"
hang_battery "$B" '  signal_tree KILL "$tree"' '  :'
run_bounded "$B"
assert_eq "rc=$RC child=$CHILD" "rc=1 child=alive" \
  "control: with no KILL after the grace, the child that ignores TERM outlives the run"

# A suite that traps the stop and exits 0 never finished either.
trapped_battery() { # DIR [FROM TO]
  battery "$1"
  printf '#!/usr/bin/env bash\ntrap "exit 0" TERM\necho "ok    the row before the hang"\nwhile :; do sleep 1; done\n' \
    >"$1/trapped.sh"
  [ "$#" -lt 3 ] || mutate_file "$1/run-all.sh" "$2" "$3"
}
B="$TMP_ROOT/bound-trapped"
trapped_battery "$B"
run_bounded "$B"
assert_eq "rc=$RC failed=$(failed_of)|$(line_of trapped)" "rc=1 failed=trapped |suite=trapped seconds=N pass=0 fail=1" \
  "a suite that exits 0 on the stop is still red"
B="$TMP_ROOT/bound-trapped-ctl"
trapped_battery "$B" '[[ "$2" != 0 || "${4:-}" == 1 ]]' '[[ "$2" != 0 ]]'
run_bounded "$B"
assert_eq "rc=$RC failed=$(failed_of)" "rc=0 failed=" \
  "control: judged by its exit status alone, the stopped suite reads green"

B="$TMP_ROOT/bound-junk"
green_battery "$B"
run_battery "$B" 2 RUN_ALL_SUITE_SECS=x
assert_eq "rc=$RC $(printf '%s\n' "$OUT" | sed -n '1s/ is.*//p') started=$(started_of | tr '\n' ' ')" \
  "rc=1 run-all.sh: RUN_ALL_SUITE_SECS started=" "a bound that is not a number refuses before any suite runs"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
