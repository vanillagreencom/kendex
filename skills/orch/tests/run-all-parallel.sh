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
#  10. the bounds — one table, a row for each rule run-all.sh's header states
#      for RUN_ALL_SUITE_SECS and RUN_ALL_DEADLINE_EPOCH, each with the
#      control that plants a defect in that rule alone; and a bound that is
#      not a number refuses
#
# Bash 3.2 compatible.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-all-parallel.XXXXXX")" ||
  { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf -- "${SCRATCH_ROOT:?}"' EXIT
# Copied runners resolve github two directories above their battery.
TMP_ROOT="$SCRATCH_ROOT/fixture/tests"
mkdir -p "$TMP_ROOT"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"

# A fresh battery directory holding run-all.sh and no suites, the process
# library run-all.sh sources at its path beside the directory, and DIR.tmp for
# its TMPDIR.
battery() { # DIR
  mkdir -p "$1/lib" "$1.tmp" "${1%/*}/scripts/lib"
  cp "$TEST_DIR/run-all.sh" "$1/run-all.sh"
  printf '#!/usr/bin/env bash\n:\n' >"$1/lib/git-env.sh"
  cp "$TEST_DIR/../scripts/lib/lane-state.sh" "${1%/*}/scripts/lib/lane-state.sh"
  mkdir -p "$1/../../github/scripts/lib"
  cp "$TEST_DIR/../../github/scripts/lib/group-leader.sh" "$1/../../github/scripts/lib/group-leader.sh"
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
for variant in normal hup-unhandled; do
while IFS='|' read -r sig target want; do
  [[ "$variant" != hup-unhandled || "$sig" == HUP ]] || continue
  B="$TMP_ROOT/signal-$variant-$sig"
  battery "$B"
  if [[ "$variant" == hup-unhandled ]]; then
    mutate_file "$B/run-all.sh" "trap 'stop_suites; exit 129' HUP" "trap 'exit 129' HUP"
  fi
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
  if [ "$target" = group ]; then kill -"$sig" -- "-$runner"; else kill -"$sig" "$runner"; fi
  RC=0
  wait "$runner" 2>/dev/null || RC=$?
  # A suite orphaned by the runner's exit stays visible until it is reaped.
  tick=0
  while kill -0 "$suite_pid" 2>/dev/null && [ "$tick" -lt 50 ]; do sleep 0.1; tick=$((tick + 1)); done
  state=gone
  [ -n "$suite_pid" ] || state=never-started
  # The pid names this row's suite only while it runs, so a red row's survivor
  # is killed here and a pid proven gone is never signalled.
  if [ -n "$suite_pid" ] && kill -0 "$suite_pid" 2>/dev/null; then
    state=alive
    kill -KILL -- "-$suite_pid" 2>/dev/null
  fi
  expected="rc=$want suite=gone"
  [[ "$variant" != hup-unhandled ]] || expected="rc=$want suite=alive"
  assert_eq "rc=$RC suite=$state" "$expected" \
    "$variant: SIG$sig to the $target preserves suite teardown"
done <<<"$SIGNAL_ROWS"
done

# A suite must be able to install its own INT and QUIT handlers. Bash cannot
# recover either signal if an asynchronous parent passed it as ignored.
echo "=== suite signal handlers survive the asynchronous launch ==="
for variant in normal signals-ignored; do
  B="$TMP_ROOT/suite-signals-$variant"
  battery "$B"
  for sig in INT QUIT; do
    printf '#!/usr/bin/env bash\ntrap "exit 0" %s\nkill -%s "$$"\nexit 1\n' "$sig" "$sig" > "$B/$sig.sh"
  done
  if [[ "$variant" == signals-ignored ]]; then
    mutate_file "$B/run-all.sh" '      "${KENDEX_GROUP_LEADER[@]}" bash' '      bash'
  fi
  run_battery "$B" 2
  expected='rc=0 red='
  [[ "$variant" != signals-ignored ]] || expected='rc=1 red=INT QUIT '
  assert_eq "rc=$RC red=$(failed_of)" "$expected" \
    "$variant: suites can handle their own INT and QUIT"
done

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
# Batteries, each run on one worker. clock: three suites that sleep two
# seconds, then pass, so the third starts four seconds into the run and cannot
# end before six. trapped: one suite that prints a row, then loops until TERM,
# on which it exits 0. hang: the hang the bound exists for, one suite that
# prints a row, then blocks on a child that set up its own process group and
# ignores TERM, as GNU timeout does once it has sent its signal and while it
# waits on a command that never ends; the child writes its pid, and the suite's
# EXIT trap marks that TERM came before KILL.
bound_battery() { # DIR KIND
  local name
  battery "$1"
  case "$2" in
    suite-clock)
      # Advance only at suite launch. Release each suite after the runner
      # checks its bound, so host scheduling cannot decide the control.
      mutate_file "$1/run-all.sh" 'started=$SECONDS' $'unset SECONDS\nSECONDS=0\nstarted=$SECONDS'
      mutate_file "$1/run-all.sh" '      SLOT_START[k]=$SECONDS' $'      SECONDS=$((next * 3))\n      SLOT_START[k]=$SECONDS'
      mutate_file "$1/run-all.sh" '    if [ -n "$base" ] && ! kill -0 "${SLOT_PID[k]}" 2>/dev/null; then' \
        $'    if [ -n "$base" ]; then\n      touch "$TEST_DIR/$base.release"\n      wait "${SLOT_PID[k]}"\n    fi\n    if [ -n "$base" ] && ! kill -0 "${SLOT_PID[k]}" 2>/dev/null; then'
      for name in c1 c2 c3; do
        printf '#!/usr/bin/env bash\nwhile [ ! -f "%s/%s.release" ]; do sleep 0.1; done\n' "$1" "$name" >"$1/$name.sh"
      done
      ;;
    clock)
      for name in c1 c2 c3; do
        printf '#!/usr/bin/env bash\nsleep 2\necho "pass: 1   fail: 0"\n' >"$1/$name.sh"
      done
      ;;
    trapped)
      printf '#!/usr/bin/env bash\ntrap "exit 0" TERM\necho ok-before-hang\nwhile :; do sleep 1; done\n' >"$1/trapped.sh"
      ;;
    hang)
      cat >"$1/hang.sh" <<'EOF'
#!/usr/bin/env bash
trap 'echo cleaned >"$MARK"' EXIT
echo ok-before-hang
perl -e 'setpgrp(0, 0); $SIG{TERM} = "IGNORE"; open my $f, ">", $ENV{PIDFILE} or die; print $f "$$\n"; close $f; exec "sleep", "1000" or die'
EOF
      ;;
    *) echo "bound_battery: no battery named '$2'" >&2; exit 1 ;;
  esac
}

# Runs DIR's battery on one worker with each VAR=VALUE in its environment, and
# under a deadline of this file's own, since a defect in the stop can leave the
# runner running: $OUT and $RC as run_battery leaves them, RC=hung where that
# deadline ended the run, and CHILD the hung child's state once the run is
# over, alive, gone or never-started. A child still alive is killed here; one
# gone is never signalled, since its pid may by now name another process.
run_bounded() { # DIR [VAR=VALUE]...
  local dir="$1" runner until=$((SECONDS + 40)) child
  shift
  mkdir -p "$dir.bin"
  printf '#!/usr/bin/env bash\necho 1\n' >"$dir.bin/nproc"
  chmod +x "$dir.bin/nproc"
  set -m
  env -i PATH="$dir.bin:$PATH" HOME="$HOME" TMPDIR="$dir.tmp" "$@" \
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
    CHILD=gone
    if kill -0 "$child" 2>/dev/null; then
      CHILD=alive
      kill -KILL "$child" 2>/dev/null
    fi
  fi
}

# One line for a bounded run: its status, the red suites, each stop in report
# order as NAME:BOUND:DETAIL:LAST from its keyed line and the `last line:` after
# it, the hung child's state and the cleanup mark.
bound_outcome() { # DIR
  printf 'rc=%s red=%s stops=%s child=%s mark=%s' "$RC" "$(failed_of | sed 's/ $//')" \
    "$(printf '%s\n' "$OUT" | awk '
      $1 == "run-all.sh:" && $3 ~ /^suite=/ {
        stop = substr($3, 7) ":" $2 ":" $4; getline; sub(/^last line: /, "")
        printf "%s%s:%s", sep, stop, $0; sep = " "
      }')" \
    "$CHILD" "$(cat "$1.mark" 2>/dev/null)"
}

# The defect each control plants in its copy of run-all.sh, by name, as
# mutate_file FROM and TO pairs.
GATE='{ [ -z "$DEADLINE" ] || [ "$SECONDS" -lt "$DEADLINE" ]; }'
edit_of() { # NAME
  case "$1" in
    suite-from-run) EDIT=('SLOT_DUE[k]=$((SECONDS + SUITE_SECS))' 'SLOT_DUE[k]=$((started + SUITE_SECS))') ;;
    deadline-from-suite) EDIT=('SLOT_DUE[k]=$DEADLINE' 'SLOT_DUE[k]=$((SECONDS + DEADLINE - started))' "$GATE" '{ :; }') ;;
    deadline-always) EDIT=('if [ -n "$DEADLINE" ] && [ "$DEADLINE" -le "${SLOT_DUE[k]}" ]; then' 'if [ -n "$DEADLINE" ]; then') ;;
    later-wins) EDIT=('[ "$DEADLINE" -le "${SLOT_DUE[k]}" ]' '[ "$DEADLINE" -ge "${SLOT_DUE[k]}" ]') ;;
    stop-skipped) EDIT=('      stop_overdue "$k"' '      :') ;;
    gate-removed) EDIT=("$GATE" '{ :; }') ;;
    unstarted-green) EDIT=('report "${SUITES[next]}" none 0 unstarted' 'report "${SUITES[next]}" 0 0') ;;
    term-skipped) EDIT=('  signal_tree TERM "$tree"' '  :') ;;
    kill-skipped) EDIT=('  signal_tree KILL "$tree"' '  :') ;;
    tree-root-only) EDIT=('table="$(lane_process_table)" || table=""' 'table=""') ;;
    red-by-status) EDIT=('[[ "$2" != 0 || -n "${4:-}" ]]' '[[ "$2" != 0 ]]') ;;
    last-dropped) EDIT=('SLOT_LAST[$1]="$(awk' 'SLOT_LAST[$1]="$(: awk') ;;
    *) echo "edit_of: no edit named '$1'" >&2; exit 1 ;;
  esac
}

# Every rule run-all.sh's header states for the bounds, one row each: the
# battery and settings that reach the rule, the outcome they give, the defect
# planted in that rule alone, and the outcome under it. A setting written
# VAR=+N is the time N seconds after its run starts. An outcome is a pattern;
# the one `*` stands where load decides whether the deadline found the third
# clock suite started. Rows sharing a battery and settings with no `+` share one
# run of the unmutated runner.
# RULE|BATTERY|SETTINGS|OUTCOME|CONTROL|CONTROL OUTCOME
BOUND_ROWS='the suite bound counts from the suite own start, so a suite that starts late keeps its whole bound|suite-clock|RUN_ALL_SUITE_SECS=5|rc=0 red= stops= child=never-started mark=|suite-from-run|rc=1 red=c3 stops=c3:suite-timeout:seconds=5:none child=never-started mark=
the deadline counts from the run start, so a suite that starts late gets only the time left|clock|RUN_ALL_DEADLINE_EPOCH=+6|rc=1 red=c3 stops=c3:run-deadline:started=*:none child=never-started mark=|deadline-from-suite|rc=0 red= stops= child=never-started mark=
a suite still running at its bound is stopped|clock|RUN_ALL_SUITE_SECS=1|rc=1 red=c1 c2 c3 stops=c1:suite-timeout:seconds=1:none c2:suite-timeout:seconds=1:none c3:suite-timeout:seconds=1:none child=never-started mark=|stop-skipped|rc=0 red= stops= child=never-started mark=
with both bounds set and the suite bound the earlier, the suite bound stops the suite|trapped|RUN_ALL_SUITE_SECS=2 RUN_ALL_DEADLINE_EPOCH=+5|rc=1 red=trapped stops=trapped:suite-timeout:seconds=2:ok-before-hang child=never-started mark=|deadline-always|rc=1 red=trapped stops=trapped:run-deadline:started=yes:ok-before-hang child=never-started mark=
with both bounds set and the deadline the earlier, the deadline stops the suite|trapped|RUN_ALL_SUITE_SECS=6 RUN_ALL_DEADLINE_EPOCH=+3|rc=1 red=trapped stops=trapped:run-deadline:started=yes:ok-before-hang child=never-started mark=|later-wins|rc=1 red=trapped stops=trapped:suite-timeout:seconds=6:ok-before-hang child=never-started mark=
no suite starts once the deadline has passed|clock|RUN_ALL_DEADLINE_EPOCH=+0|rc=1 red=c1 c2 c3 stops=c1:run-deadline:started=no:none c2:run-deadline:started=no:none c3:run-deadline:started=no:none child=never-started mark=|gate-removed|rc=1 red=c1 c2 c3 stops=c1:run-deadline:started=yes:none c2:run-deadline:started=yes:none c3:run-deadline:started=yes:none child=never-started mark=
a suite the deadline left unstarted reports red|clock|RUN_ALL_DEADLINE_EPOCH=+0|rc=1 red=c1 c2 c3 stops=c1:run-deadline:started=no:none c2:run-deadline:started=no:none c3:run-deadline:started=no:none child=never-started mark=|unstarted-green|rc=0 red= stops= child=never-started mark=
the stop sends TERM first, which the suite cleanup runs on|hang|RUN_ALL_SUITE_SECS=2|rc=1 red=hang stops=hang:suite-timeout:seconds=2:ok-before-hang child=gone mark=cleaned|term-skipped|rc=1 red=hang stops=hang:suite-timeout:seconds=2:ok-before-hang child=gone mark=
the stop sends KILL after the grace to a process that ignores TERM|hang|RUN_ALL_SUITE_SECS=2|rc=1 red=hang stops=hang:suite-timeout:seconds=2:ok-before-hang child=gone mark=cleaned|kill-skipped|rc=1 red=hang stops=hang:suite-timeout:seconds=2:ok-before-hang child=alive mark=cleaned
the stop reaches every process under the suite, one that left its process group included|hang|RUN_ALL_SUITE_SECS=2|rc=1 red=hang stops=hang:suite-timeout:seconds=2:ok-before-hang child=gone mark=cleaned|tree-root-only|rc=1 red=hang stops=hang:suite-timeout:seconds=2:ok-before-hang child=alive mark=cleaned
a stopped suite that exits 0 on the stop still reports red|trapped|RUN_ALL_SUITE_SECS=2|rc=1 red=trapped stops=trapped:suite-timeout:seconds=2:ok-before-hang child=never-started mark=|red-by-status|rc=0 red= stops=trapped:suite-timeout:seconds=2:ok-before-hang child=never-started mark=
the stop names the row the suite printed last|trapped|RUN_ALL_SUITE_SECS=2|rc=1 red=trapped stops=trapped:suite-timeout:seconds=2:ok-before-hang child=never-started mark=|last-dropped|rc=1 red=trapped stops=trapped:suite-timeout:seconds=2:none child=never-started mark='
n=0
shared=""
shared_outcome=""
while IFS='|' read -r rule kind settings want edit control_want; do
  n=$((n + 1))
  for variant in row control; do
    if [ "$variant" = row ] && [ -n "$shared" ] && [ "$kind $settings" = "$shared" ]; then
      got="$shared_outcome"
    else
      B="$TMP_ROOT/bound-$n-$variant"
      bound_battery "$B" "$kind"
      if [ "$variant" = control ]; then
        edit_of "$edit"
        e=0
        while [ "$e" -lt "${#EDIT[@]}" ]; do
          mutate_file "$B/run-all.sh" "${EDIT[e]}" "${EDIT[e + 1]}"
          e=$((e + 2))
        done
      fi
      args=()
      for setting in $settings; do
        case "$setting" in *=+*) setting="${setting%%=*}=$(($(date +%s) + ${setting#*=+}))" ;; esac
        args+=("$setting")
      done
      run_bounded "$B" "${args[@]}"
      got="$(bound_outcome "$B")"
      if [ "$variant" = row ]; then
        case "$settings" in
          *=+*) shared="" ;;
          *) shared="$kind $settings"; shared_outcome="$got" ;;
        esac
      fi
    fi
    if [ "$variant" = row ]; then
      expect="$want" name="$rule"
    else
      expect="$control_want" name="control, $edit: $rule fails"
    fi
    # shellcheck disable=SC2053 # the outcome is a pattern
    if [[ "$got" == $expect ]]; then
      pass "$name"
    else
      fail "$name" "expected: $expect"
      printf '        got:      %s\n' "$got"
    fi
  done
done <<<"$BOUND_ROWS"

# SETTING|REFUSAL PREFIX
JUNK_ROWS='RUN_ALL_SUITE_SECS=x|run-all.sh: RUN_ALL_SUITE_SECS
RUN_ALL_DEADLINE_EPOCH=x|run-all.sh: RUN_ALL_DEADLINE_EPOCH'
while IFS='|' read -r setting want; do
  B="$TMP_ROOT/junk-${setting%%=*}"
  green_battery "$B"
  run_battery "$B" 2 "$setting"
  assert_eq "rc=$RC $(printf '%s\n' "$OUT" | sed -n '1s/ is.*//p') started=$(started_of | tr '\n' ' ')" \
    "rc=1 $want started=" "${setting%%=*} that is not a number refuses before any suite runs"
done <<<"$JUNK_ROWS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
