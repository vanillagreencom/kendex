#!/usr/bin/env bash
# The per-mutation verdict of tests/must-fail-controls.sh, driven against a
# synthetic one-suite skill rather than this one.
#
# Why a fixture and not this skill's own roster: every control there reddens
# the assertion each of its mutations names, so none of these verdicts is ever
# reached by a run over skills/linear and deleting any of them would leave the
# whole roster green. The fixture is the only place a control that fails the
# rule is constructible.
#
#   - a control whose every mutation reddens the assertion it named exits 0, so
#     a case here cannot pass by always reporting a finding
#   - a mutation that names an assertion its own run did not redden is WRONG,
#     which is what refuses a mutation reddening only a harness verdict from
#     tests/lib/assert.sh: those carry the same FAIL: prefix as an assertion
#   - two mutations naming one assertion is SHARED, and a mutation naming none
#     is NOEXPECT: the other two ways a mutation stops answering for itself
#   - an expectation with no mutation after it is NOEXPECT too, and names
#     itself: nothing claims it, so nothing checks it
#   - a mutation the suite survived is GREEN, and a run the timeout killed is
#     TIMEOUT, both named by number
#   - a control that edits its copy outside a numbered mutation is UNGATED:
#     that edit rides every pass uncounted, and a suite writing a scratch file
#     inside its own copy is not that
#   - a suite with no control file is MISSING, one failing from its unmutated
#     copy is UNSTAGED, a control declaring no mutation is NOOP, and a
#     mutation whose line the file lacks is BADCTRL
#
# One table. A row names the fixture, the control it writes, the cap, and the
# run's verdict block whole: the exit status, every verdict line the runner
# printed, and its tally. A verdict whose branch is disabled falls through to
# another verdict, which is a different line, so every row is reddened by the
# mutation of its own branch; tests/roster-orphan.test.sh pins that a failing
# control fails the run and is counted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
RUNNER="$SCRIPT_DIR/must-fail-controls.sh"
assert_tmpdir TMP

# A one-suite skill over four values and an inert fifth file. Two of its claims
# share a prefix, so a control naming the shorter one is refused unless the
# match is whole-line. The suite reports
# a failed claim the way tests/lib/assert.sh does, since that prefix is what
# the runner reads a mutation's failures out of.
# `fixture ROOT residue` makes the suite's own run write a scratch file inside
# its copy of the skill, the way a cache or lock suite does; `fixture ROOT
# broken` ships a value the suite fails on before any mutation.
fixture() {
    local root="$1" mode="${2:-}"
    mkdir -p "$root/scripts" "$root/tests/controls"
    printf 'A=1\n' >"$root/scripts/a.sh"
    if [ "$mode" = broken ]; then
        printf 'A=2\n' >"$root/scripts/a.sh"
    fi
    if [ "$mode" = residue ]; then
        # shellcheck disable=SC2016  # the expansion belongs to the written script
        printf 'A=1\n: >"$(dirname "${BASH_SOURCE[0]}")/.alpha-scratch"\n' \
            >"$root/scripts/a.sh"
    fi
    printf 'B=1\n' >"$root/scripts/b.sh"
    printf 'C=1\n' >"$root/scripts/c.sh"
    printf 'E=1\n' >"$root/scripts/e.sh"
    printf 'INERT=1\n' >"$root/scripts/inert.sh"
    cat >"$root/tests/alpha.test.sh" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for v in a b c e; do
    # shellcheck disable=SC1090
    . "$D/../scripts/$v.sh"
done
rc=0
if [ "$A" != 1 ]; then echo "FAIL: a is one" >&2; rc=1; fi
if [ "$B" != 1 ]; then echo "FAIL: b is one" >&2; rc=1; fi
if [ "$C" != 1 ]; then echo "FAIL: c is one" >&2; rc=1; fi
if [ "$E" != 1 ]; then echo "FAIL: a is one with fallback" >&2; rc=1; fi
exit "$rc"
SUITE
    cp "$RUNNER" "$root/tests/must-fail-controls.sh"
}

# control NAME ROOT — the control each case writes for the fixture's suite,
# every mutation against the file as it ships.
control() {
    local body
    # shellcheck disable=SC2016  # the ungated expansion belongs to the written control
    case "$1" in
    # Neither mutation reddens the other's assertion.
    clean) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=2'"'"'
control_expect "b is one"
control_replace scripts/b.sh 1 '"'"'B=1'"'"' '"'"'B=2'"'"'' ;;
    # The second mutation leaves both values alone and reddens the suite with
    # one of the verdicts assert.sh prints when it refuses a suite outright:
    # the same FAIL: prefix an assertion carries, not the assertion it named.
    misnamed) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=2'"'"'
control_expect "b is one"
control_replace scripts/b.sh 1 '"'"'B=1'"'"' \
    '"'"'B=1; echo "FAIL: the suite ended with background job(s) still running: 4242" >&2; exit 1'"'"'' ;;
    # Both reddened something, and the second claims what the first answers
    # for; asked of the expectations before either runs.
    shared) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=2'"'"'
control_expect "a is one"
control_replace scripts/b.sh 1 '"'"'B=1'"'"' '"'"'B=2'"'"'' ;;
    # Declare nothing and there is nothing to check.
    unnamed) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=2'"'"'
control_replace scripts/b.sh 1 '"'"'B=1'"'"' '"'"'B=2'"'"'' ;;
    # The second mutation lands on a file the suite never reads: the tree
    # changes, and on its own copy it proves nothing. On one copy with the
    # first mutation it would ride that one's failures into an ok line.
    green) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=2'"'"'
control_expect "b is one"
control_replace scripts/inert.sh 1 '"'"'INERT=1'"'"' '"'"'INERT=2'"'"'' ;;
    # The run reddens on the clock rather than on the mutation.
    capped) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=1; sleep 2'"'"'' ;;
    # A control is arbitrary bash with CONTROL_ROOT set: this one writes under
    # it directly, so the edit rides the counting pass and every mutation pass.
    ungated) body='control_expect "a is one"
printf '"'"'B=9\n'"'"' >"$CONTROL_ROOT/scripts/b.sh"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=2'"'"'' ;;
    # Two mutations naming what their runs redden, then an expectation no
    # mutation follows: nothing drains it and the next pass truncates it.
    trailing) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=1'"'"' '"'"'A=2'"'"'
control_expect "b is one"
control_replace scripts/b.sh 1 '"'"'B=1'"'"' '"'"'B=2'"'"'
control_expect "c is one"' ;;
    # Reddens only the suite's fourth claim, whose text starts with its first,
    # and names the shorter: a substring match would read that as proof.
    prefix) body='control_expect "a is one"
control_replace scripts/e.sh 1 '"'"'E=1'"'"' '"'"'E=2'"'"'' ;;
    # No control file for alpha; a second suite with its own control keeps
    # the roster non-empty, which is where a missing control is a verdict
    # rather than the runner refusing an empty directory.
    missing)
        cat >"$2/tests/beta.test.sh" <<'SUITE'
#!/usr/bin/env bash
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$D/../scripts/b.sh"
if [ "$B" != 1 ]; then echo "FAIL: b is one" >&2; exit 1; fi
SUITE
        printf '%s\n' 'control_expect "b is one"' \
            "control_replace scripts/b.sh 1 'B=1' 'B=2'" >"$2/tests/controls/beta.control.sh"
        return 0 ;;
    # A control that declares no mutation.
    empty) body='# nothing declared' ;;
    # A mutation whose line the file does not hold.
    badctrl) body='control_expect "a is one"
control_replace scripts/a.sh 1 '"'"'A=7'"'"' '"'"'A=2'"'"'' ;;
    esac
    printf '%s\n' "$body" >"$2/tests/controls/alpha.control.sh"
}

# run FIXTURE CONTROL CAP — a fresh fixture (`plain`, or `residue`, whose suite
# writes a scratch file inside its own copy), the named control, the runner under CAP
# seconds (`-` for its default), rendered as one line: the status, every
# verdict line with its spacing collapsed, and the tally.
run() {
    local root="$TMP/$2-$1" rc=0
    fixture "$root" "$1"
    control "$2" "$root"
    if [ "$3" = "-" ]; then
        bash "$root/tests/must-fail-controls.sh" >"$root.log" 2>&1 || rc=$?
    else
        CONTROL_TIMEOUT="$3" bash "$root/tests/must-fail-controls.sh" >"$root.log" 2>&1 || rc=$?
    fi
    printf 'rc=%s;%s' "$rc" "$(grep -E '^(ok|WRONG|SHARED|NOEXPECT|GREEN|TIMEOUT|UNGATED|UNSTAGED|ORPHAN|MISSING|NOOP|BADCTRL) |controls, ' "$root.log" | tr -s ' ' | paste -sd';' -)"
}

# --- the table -----------------------------------------------------------------
# label|fixture|control|cap|expect
ROWS='
a control whose mutations each redden what they named exits 0|plain|clean|-|rc=0;ok alpha.test.sh;1 controls, 0 failing, 0 orphaned
the misnamed report names the mutation and the assertion|plain|misnamed|-|rc=1;WRONG alpha.test.sh mutation 2 did not redden: b is one;1 controls, 1 failing, 0 orphaned
the shared report names the assertion|plain|shared|-|rc=1;SHARED alpha.test.sh two mutations name one assertion: a is one;1 controls, 1 failing, 0 orphaned
the unnamed report names the mutation|plain|unnamed|-|rc=1;NOEXPECT alpha.test.sh mutation 2 names no assertion;1 controls, 1 failing, 0 orphaned
the green report names its suite|plain|green|-|rc=1;GREEN alpha.test.sh suite passed with mutation 2, its only break;1 controls, 1 failing, 0 orphaned
the timeout report names the mutation and the cap|plain|capped|1|rc=1;TIMEOUT alpha.test.sh mutation 1 hit the 1s cap having measured nothing;1 controls, 1 failing, 0 orphaned
the ungated report says what it refuses|plain|ungated|-|rc=1;UNGATED alpha.test.sh control edits its copy outside a numbered mutation;1 controls, 1 failing, 0 orphaned
the residue a suite writes in its own copy is not read as the edit of its control|residue|clean|-|rc=0;ok alpha.test.sh;1 controls, 0 failing, 0 orphaned
the trailing report names the expectation nothing claims|plain|trailing|-|rc=1;NOEXPECT alpha.test.sh an expectation follows the last mutation and names none: c is one;1 controls, 1 failing, 0 orphaned
the prefix report names the assertion the mutation did not redden|plain|prefix|-|rc=1;WRONG alpha.test.sh mutation 1 did not redden: a is one;1 controls, 1 failing, 0 orphaned
a suite with no control file is reported missing|plain|missing|-|rc=1;MISSING alpha.test.sh no controls/alpha.control.sh;ok beta.test.sh;2 controls, 1 failing, 0 orphaned
a suite failing from its unmutated copy proves nothing under mutation|broken|clean|-|rc=1;UNSTAGED alpha.test.sh suite fails from an unmutated copy;1 controls, 1 failing, 0 orphaned
a control declaring no mutation changed nothing|plain|empty|-|rc=1;NOOP alpha.test.sh control changed nothing;1 controls, 1 failing, 0 orphaned
a mutation whose line the file lacks did not apply|plain|badctrl|-|rc=1;BADCTRL alpha.test.sh mutation 1 did not apply cleanly;1 controls, 1 failing, 0 orphaned
'

while IFS='|' read -r label fix ctl cap expect; do
    [ -n "$label" ] || continue
    assert_eq "$label" "$(run "$fix" "$ctl" "$cap")" "$expect"
done <<<"$ROWS"

