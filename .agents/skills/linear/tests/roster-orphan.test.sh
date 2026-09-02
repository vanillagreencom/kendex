#!/usr/bin/env bash
# The roster contract of tests/must-fail-controls.sh, both directions, driven
# against a synthetic one-suite skill rather than this one.
#
# Why a fixture and not this skill's own roster: that roster is matched, so
# the orphan branch is never taken by a run over skills/linear and deleting it
# would leave every committed suite green. The fixture is the only place the
# condition is constructible.
#
#   - a matched suite/control pair exits 0 and prints no ORPHAN line, so a
#     case here cannot pass by always reporting a failure
#   - a control no suite owns exits non-zero and the diagnostic names it
#   - a targeted single-stem run reads the roster too: a selection cannot
#     hide an orphan
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
RUNNER="$SCRIPT_DIR/must-fail-controls.sh"
assert_tmpdir TMP

# A one-suite skill whose suite reads a value its control flips: enough for the
# runner to stage, mutate and red, and no more, so what these cases measure is
# the roster and not the control machinery.
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
    echo "  ok    the value is green"
    exit 0
fi
echo "  FAIL  the value is green"
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
