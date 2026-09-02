#!/usr/bin/env bash
# The verdict contract of tests/must-fail-controls.sh, driven against a
# synthetic one-suite skill rather than this one.
#
# Why a fixture and not this skill's own roster: that roster is matched and
# every one of its controls works, so neither the orphan branch nor the
# failing-control branch is ever taken by a run over skills/linear, and
# deleting either would leave every committed suite green. The fixture is the
# only place those conditions are constructible.
#
#   - a matched suite/control pair exits 0 and prints no ORPHAN line, so a
#     case here cannot pass by always reporting a failure
#   - a control no suite owns exits non-zero and the diagnostic names it
#   - a targeted single-stem run reads the roster too: a selection cannot
#     hide an orphan
#   - a control that does not red its suite is counted and fails the run,
#     which is the whole regime: without it the 50 controls over this skill
#     could all rot and the runner would still exit 0
#   - a junk job width is refused rather than run at some silent default
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
RUNNER="$SCRIPT_DIR/must-fail-controls.sh"
assert_tmpdir TMP

# A one-suite skill whose suite reads a value its control flips: enough for the
# runner to stage, mutate and red, and no more, so what these cases measure is
# the roster and not the control machinery. It names its failure the way
# tests/lib/assert.sh does, since the runner refuses a mutation that reddens
# without naming an assertion.
fixture() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/tests/controls"
    printf 'VALUE=green\n' >"$root/scripts/value.sh"
    cat >"$root/tests/alpha.test.sh" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$D/../scripts/value.sh"
if [ "$VALUE" = green ]; then
    echo "ok: the value is green"
    exit 0
fi
echo "FAIL: the value is green" >&2
exit 1
SUITE
    cat >"$root/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "the value is green"
control_replace scripts/value.sh 1 'VALUE=green' 'VALUE=red'
CONTROL
    cp "$RUNNER" "$root/tests/must-fail-controls.sh"
}

# run_roster LOGFILE ROOT [STEM...] — run the fixture's copy of the runner,
# combined output to LOGFILE. Echoes its status; the caller asserts on that
# rather than branching, so no assertion runs inside a subshell.
run_roster() {
    local log="$1" root="$2"
    shift 2
    bash "$root/tests/must-fail-controls.sh" "$@" >"$log" 2>&1
    echo "$?"
}

# --- the matched pair is the baseline --------------------------------------
matched="$TMP/matched"
fixture "$matched"
rc="$(run_roster "$TMP/matched.log" "$matched")"
assert_eq "a roster whose every control owns a suite exits 0" "$rc" 0
assert_file_lacks "a matched roster prints no ORPHAN line" "$TMP/matched.log" "ORPHAN"
assert_file_contains "the matched run reports no orphan" \
    "$TMP/matched.log" "1 controls, 0 failing, 0 orphaned"

# --- a control no suite owns fails the full run ----------------------------
orphaned="$TMP/orphaned"
fixture "$orphaned"
printf 'control_expect "nothing runs this"\n' \
    >"$orphaned/tests/controls/ghost.control.sh"

rc="$(run_roster "$TMP/orphan-full.log" "$orphaned")"
assert_ne "a control no suite owns fails the full run" "$rc" 0
assert_file_contains "the full run names the orphaned control" \
    "$TMP/orphan-full.log" "ORPHAN   controls/ghost.control.sh"
assert_file_contains "the diagnostic names the suite that would own it" \
    "$TMP/orphan-full.log" "no ghost.test.sh owns it"
assert_file_contains "the full run counts the orphan" \
    "$TMP/orphan-full.log" "1 controls, 0 failing, 1 orphaned"
assert_file_contains "the orphan is what failed: the matched pair still passed" \
    "$TMP/orphan-full.log" "ok       alpha.test.sh"

# --- and fails a targeted single-stem run too ------------------------------
# The case a selection-scoped roster read would have missed: with the orphan
# check inside the per-suite loop, naming a stem would walk past it.
rc="$(run_roster "$TMP/orphan-one.log" "$orphaned" alpha)"
assert_ne "a targeted run fails on an orphan outside its selection" "$rc" 0
assert_file_contains "the targeted run names the orphaned control" \
    "$TMP/orphan-one.log" "ORPHAN   controls/ghost.control.sh"
assert_file_contains "the targeted run counts the orphan" \
    "$TMP/orphan-one.log" "1 controls, 0 failing, 1 orphaned"

# --- a control that does not red its suite is a failure --------------------
# The runner judges each control in a background job and turns its status into
# the verdict when that batch is reaped. Nothing above reaches that path: every
# control there works, so the count is always "0 failing" and the line could be
# deleted with all of it still green. Here the mutation lands (the tree really
# changes, so it is not NOOP) on a file the suite never reads, which leaves the
# suite passing over its own broken subject — GREEN, the case the whole regime
# exists to catch.
green="$TMP/green"
fixture "$green"
printf 'INERT=1\n' >"$green/scripts/inert.sh"
cat >"$green/tests/controls/alpha.control.sh" <<'CONTROL'
control_expect "the value is green"
control_replace scripts/inert.sh 1 'INERT=1' 'INERT=2'
CONTROL

rc="$(run_roster "$TMP/green.log" "$green")"
assert_ne "a control that leaves its suite passing fails the run" "$rc" 0
assert_file_contains "the diagnostic names the suite that stayed green" \
    "$TMP/green.log" "GREEN    alpha.test.sh"
assert_file_contains "the failing control is counted, not just printed" \
    "$TMP/green.log" "1 controls, 1 failing, 0 orphaned"

# --- a junk job width is refused ------------------------------------------
# Not clamped and not defaulted. Left to reach the batching predicate, a width
# outside the grammar decides two ways and neither is the one the caller asked
# for: on Bash 4.4 and newer arithmetic honours set -u, so the unbound name
# aborts the run with controls already launched, and on 4.0 through 4.2 the
# same name reads as 0, the batch collapses to one, and the whole roster runs
# serially.
jobs_log="$TMP/jobs.log"
CONTROL_JOBS=some bash "$matched/tests/must-fail-controls.sh" >"$jobs_log" 2>&1
rc=$?
assert_eq "a non-numeric CONTROL_JOBS exits 2" "$rc" 2
assert_file_contains "the refusal names the setting and the value" \
    "$jobs_log" "CONTROL_JOBS must be a positive integer, got: some"
assert_file_lacks "a refused width judges nothing" "$jobs_log" "controls, "

# A width outside signed 64-bit arithmetic is junk of the same kind: the
# batching predicate compares against the wrap, reads 2^64 as zero, and reaps
# after every launch, so the roster runs one control at a time.
wide_log="$TMP/jobs-wide.log"
CONTROL_JOBS=18446744073709551616 bash "$matched/tests/must-fail-controls.sh" >"$wide_log" 2>&1
rc=$?
assert_eq "a CONTROL_JOBS too wide for the arithmetic exits 2" "$rc" 2
assert_file_contains "the refusal names the setting and the over-wide value" \
    "$wide_log" "CONTROL_JOBS must be a positive integer, got: 18446744073709551616"
