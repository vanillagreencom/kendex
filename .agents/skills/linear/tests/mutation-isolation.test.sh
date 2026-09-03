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
#
# Each case asserts what its own verdict says, and only what breaking that
# verdict's branch can take away: SHARED, GREEN and TIMEOUT all fall through to
# another verdict when their branch is disabled, so the run still fails and is
# still counted whatever they do, and asserting either there would assert
# nothing. tests/roster-orphan.test.sh pins that a failing control fails the
# run and is counted.
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
# its copy of the skill, the way a cache or lock suite does.
fixture() {
    local root="$1" mode="${2:-}"
    mkdir -p "$root/scripts" "$root/tests/controls"
    printf 'A=1\n' >"$root/scripts/a.sh"
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

# run_roster LOGFILE ROOT — run the fixture's copy of the runner, combined
# output to LOGFILE. Echoes its status; the caller asserts on that rather than
# branching, so no assertion runs inside a subshell.
run_roster() {
    local log="$1" root="$2"
    bash "$root/tests/must-fail-controls.sh" >"$log" 2>&1
    echo "$?"
}

# run_roster_capped SECONDS LOGFILE ROOT — the same, with the runner's suite
# timeout set, so a case can reach the kill without waiting out the default.
run_roster_capped() {
    local cap="$1" log="$2" root="$3"
    CONTROL_TIMEOUT="$cap" bash "$root/tests/must-fail-controls.sh" >"$log" 2>&1
    echo "$?"
}

# --- each mutation reddening the assertion it named is the baseline --------
# Neither mutation reddens the other's assertion, so the ok line here says both
# copies were staged, both suites ran, and no case below can pass by the runner
# always reporting a finding.
clean="$TMP/clean"
fixture "$clean"
cat >"$clean/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=2'
control_expect "b is one"
control_replace scripts/b.sh 1 'B=1' 'B=2'
CONTROL

rc="$(run_roster "$TMP/clean.log" "$clean")"
assert_eq "a control whose mutations each redden what they named exits 0" "$rc" 0
assert_file_contains "the clean control is reported ok" \
    "$TMP/clean.log" "ok       alpha.test.sh"
assert_file_contains "the clean run counts no failure" \
    "$TMP/clean.log" "1 controls, 0 failing, 0 orphaned"

# --- a mutation whose redness is not the assertion it named ----------------
# The reproduction the whole rule exists for. The second mutation leaves both
# values alone and reddens the suite with one of the verdicts assert.sh prints
# when it refuses a suite outright. That carries the same FAIL: prefix an
# assertion does, so a non-empty fail set is not proof of anything: it is not
# the assertion the mutation named.
misnamed="$TMP/misnamed"
fixture "$misnamed"
cat >"$misnamed/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=2'
control_expect "b is one"
control_replace scripts/b.sh 1 'B=1' \
    'B=1; echo "FAIL: the suite ended with background job(s) still running: 4242" >&2; exit 1'
CONTROL

rc="$(run_roster "$TMP/misnamed.log" "$misnamed")"
assert_ne "a mutation reddening only a harness verdict fails the run" "$rc" 0
assert_file_contains "the misnamed report names its suite" \
    "$TMP/misnamed.log" "WRONG    alpha.test.sh"
assert_file_contains "the misnamed report names the mutation and the assertion" \
    "$TMP/misnamed.log" "mutation 2 did not redden: b is one"
assert_file_contains "the misnamed control is counted, not just printed" \
    "$TMP/misnamed.log" "1 controls, 1 failing, 0 orphaned"

# --- two mutations naming one assertion ------------------------------------
# Both reddened something, and the second's claim is one the first answers for.
# Asking each mutation in isolation cannot see that, so it is asked of the
# expectations before either runs.
shared="$TMP/shared"
fixture "$shared"
cat >"$shared/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=2'
control_expect "a is one"
control_replace scripts/b.sh 1 'B=1' 'B=2'
CONTROL

run_roster "$TMP/shared.log" "$shared" >/dev/null
assert_file_contains "the shared report names its suite" \
    "$TMP/shared.log" "SHARED   alpha.test.sh"
assert_file_contains "the shared report names the assertion" \
    "$TMP/shared.log" "two mutations name one assertion: a is one"

# --- a mutation naming no assertion ----------------------------------------
# The third way out: declare nothing and there is nothing to check.
unnamed="$TMP/unnamed"
fixture "$unnamed"
cat >"$unnamed/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=2'
control_replace scripts/b.sh 1 'B=1' 'B=2'
CONTROL

rc="$(run_roster "$TMP/unnamed.log" "$unnamed")"
assert_ne "a mutation naming no assertion fails the run" "$rc" 0
assert_file_contains "the unnamed report names its suite" \
    "$TMP/unnamed.log" "NOEXPECT alpha.test.sh"
assert_file_contains "the unnamed report names the mutation" \
    "$TMP/unnamed.log" "mutation 2 names no assertion"
assert_file_contains "the unnamed control is counted, not just printed" \
    "$TMP/unnamed.log" "1 controls, 1 failing, 0 orphaned"

# --- a mutation the suite survived -----------------------------------------
# The second mutation lands on a file the suite never reads, so the tree really
# changes and this is not the NOOP case. This is where the copies matter: on
# one copy with the first mutation it rides that one's failures into an ok
# line, and only run on its own does it report what it proves, which is
# nothing.
green="$TMP/green"
fixture "$green"
cat >"$green/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=2'
control_expect "b is one"
control_replace scripts/inert.sh 1 'INERT=1' 'INERT=2'
CONTROL

run_roster "$TMP/green.log" "$green" >/dev/null
assert_file_contains "the green report names its suite" \
    "$TMP/green.log" "GREEN    alpha.test.sh"
assert_file_contains "the green report names the mutation that proved nothing" \
    "$TMP/green.log" "mutation 2, its only break"

# --- a run the timeout killed ----------------------------------------------
# The run reddened on the clock rather than on the mutation, so it names the
# kill instead of reporting the assertion it could not reach as unreddened.
capped="$TMP/capped"
fixture "$capped"
cat >"$capped/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=1; sleep 2'
CONTROL

run_roster_capped 1 "$TMP/capped.log" "$capped" >/dev/null
assert_file_contains "the timeout report names its suite" \
    "$TMP/capped.log" "TIMEOUT  alpha.test.sh"
assert_file_contains "the timeout report names the mutation and the cap" \
    "$TMP/capped.log" "mutation 1 hit the 1s cap having measured nothing"

# --- an edit made outside a numbered mutation ------------------------------
# A control is arbitrary bash with CONTROL_ROOT set. This one writes under it
# directly, so the edit lands on the counting pass and on every mutation pass,
# uncounted and never isolated: the way out of the regime, if nothing asks.
ungated="$TMP/ungated"
fixture "$ungated"
cat >"$ungated/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
printf 'B=9\n' >"$CONTROL_ROOT/scripts/b.sh"
control_replace scripts/a.sh 1 'A=1' 'A=2'
CONTROL

rc="$(run_roster "$TMP/ungated.log" "$ungated")"
assert_ne "a control that edits its copy unnumbered fails the run" "$rc" 0
assert_file_contains "the ungated report names its suite" \
    "$TMP/ungated.log" "UNGATED  alpha.test.sh"
assert_file_contains "the ungated report says what it refuses" \
    "$TMP/ungated.log" "edits its copy outside a numbered mutation"
assert_file_contains "the ungated control is counted, not just printed" \
    "$TMP/ungated.log" "1 controls, 1 failing, 0 orphaned"

# --- a suite that writes inside its own copy -------------------------------
# The guard above compares against a snapshot taken after the unmutated suite
# has run, not against the source, so what it measures is the control's edits
# and not the suite's own residue. This roster is cache-, lock- and sync-heavy,
# so a suite writing under its own tree is ordinary and must not be reported as
# its control editing outside a mutation.
residue="$TMP/residue"
fixture "$residue" residue
cat >"$residue/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=2'
CONTROL

rc="$(run_roster "$TMP/residue.log" "$residue")"
assert_eq "a suite writing in its own copy leaves its control passing" "$rc" 0
assert_file_contains "the control of a suite that writes residue is reported ok" \
    "$TMP/residue.log" "ok       alpha.test.sh"
assert_file_lacks "a suite's residue is not read as the control's edit" \
    "$TMP/residue.log" "UNGATED"

# --- an expectation with no mutation after it ------------------------------
# Both mutations name an assertion their own run reddens, so nothing above
# catches this control. The third expectation trails: no mutation follows it,
# so control_mutation_wanted never drains it and the next pass truncates it,
# and the claim would be dropped in silence. Declaring an expectation after its
# mutation is the natural reading order, so the mistake is one an author makes.
trailing="$TMP/trailing"
fixture "$trailing"
cat >"$trailing/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/a.sh 1 'A=1' 'A=2'
control_expect "b is one"
control_replace scripts/b.sh 1 'B=1' 'B=2'
control_expect "c is one"
CONTROL

rc="$(run_roster "$TMP/trailing.log" "$trailing")"
assert_ne "an expectation no mutation claims fails the run" "$rc" 0
assert_file_contains "the trailing report names its suite" \
    "$TMP/trailing.log" "NOEXPECT alpha.test.sh"
assert_file_contains "the trailing report names the expectation nothing claims" \
    "$TMP/trailing.log" "an expectation follows the last mutation and names none: c is one"
assert_file_contains "the trailing control is counted, not just printed" \
    "$TMP/trailing.log" "1 controls, 1 failing, 0 orphaned"

# --- a control naming a prefix of an assertion that reddened ---------------
# The suite's fourth claim starts with the text of its first. This mutation
# reddens only the longer one, and names the shorter; a substring match would
# read that as proof, so the match is whole-line. The mutation names an
# assertion its own run did not redden, which is what WRONG is.
prefix="$TMP/prefix"
fixture "$prefix"
cat >"$prefix/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "a is one"
control_replace scripts/e.sh 1 'E=1' 'E=2'
CONTROL

rc="$(run_roster "$TMP/prefix.log" "$prefix")"
assert_ne "a control naming a prefix of what reddened fails the run" "$rc" 0
assert_file_contains "the prefix report names its suite" \
    "$TMP/prefix.log" "WRONG    alpha.test.sh"
assert_file_contains "the prefix report names the assertion the mutation did not redden" \
    "$TMP/prefix.log" "mutation 1 did not redden: a is one"
assert_file_contains "the prefix control is counted, not just printed" \
    "$TMP/prefix.log" "1 controls, 1 failing, 0 orphaned"
