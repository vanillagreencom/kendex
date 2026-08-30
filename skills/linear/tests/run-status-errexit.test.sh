#!/usr/bin/env bash
# run_status keeps errexit in force inside a shell-function subject.
#
# bash suspends errexit for the whole body of a command whose status is being
# tested, and the suspension reaches into a shell function called there. A
# function that relied on errexit to stop partway therefore runs on to its own
# `return 0`, and `func || rc=$?` reports success for a subject that failed —
# the shape that let a failed comments query stamp a complete pull. The suites
# here capture a subject's status constantly, so the helper that does it has to
# hold this property, and this pins it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

assert_tmpdir TMP_ROOT

# The subject shape under test: product code sourced into a suite, relying on
# errexit to stop at a failed step rather than checking it.
subject_aborts() {
	false
	printf 'ran-past-the-failure\n'
	return 0
}

subject_succeeds() {
	printf 'subject-output\n'
	return 0
}

subject_returns_7() {
	return 7
}

# --- the property: an aborting function reports non-zero ---------------------
run_status abort_rc subject_aborts >"$TMP_ROOT/abort.out" 2>&1

assert_ne "a shell function that aborts internally reports non-zero" "$abort_rc" 0
assert_file_lacks "the aborted function did not run past its failure" \
	"$TMP_ROOT/abort.out" "ran-past-the-failure"

# --- the contrast: the idiom run_status replaces reports success -------------
# Pinned rather than described, because it is the reason the helper exists: if
# bash ever stopped suspending errexit here, the helper could be a one-liner.
naive_rc=0
subject_aborts >"$TMP_ROOT/naive.out" 2>&1 || naive_rc=$?

assert_eq "the idiom run_status replaces reports success for the same subject" \
	"$naive_rc" 0
assert_file_contains "and lets that subject run past its failure" \
	"$TMP_ROOT/naive.out" "ran-past-the-failure"

# --- the helper is not simply reporting failure for everything --------------
run_status ok_rc subject_succeeds >"$TMP_ROOT/ok.out" 2>&1
assert_eq "a function that succeeds reports zero" "$ok_rc" 0

run_status seven_rc subject_returns_7 >/dev/null 2>&1
assert_eq "an explicit return status is passed through" "$seven_rc" 7

run_status external_rc bash -c 'set -e; false; echo unreached' >/dev/null 2>&1
assert_ne "an external process subject still reports its own failure" "$external_rc" 0

# --- run_output carries the subject's stdout with the same guarantee --------
run_output out_text out_rc subject_succeeds 2>/dev/null
assert_eq "run_output reports the subject's status" "$out_rc" 0
assert_eq "run_output captures the subject's stdout" "$out_text" "subject-output"

run_output aborted_text aborted_rc subject_aborts 2>/dev/null
assert_ne "run_output reports non-zero for a function that aborts internally" "$aborted_rc" 0
assert_eq "run_output captures nothing past the failure" "$aborted_text" ""

# --- the canary refuses a call site it cannot make the guarantee for --------
# A suspended errexit is inherited by the background subshell as well, so the
# helper proves the state rather than assuming it. Driven in a child shell
# because the refusal ends the suite it fires in.
canary_rc=0
bash -c '
	set -euo pipefail
	# shellcheck disable=SC1090
	source "$1"
	subject() { return 0; }
	if run_status rc subject; then :; fi
' _ "$SCRIPT_DIR/lib/assert.sh" >"$TMP_ROOT/canary.out" 2>&1 || canary_rc=$?

assert_ne "run_status refuses a call site where errexit is suspended" "$canary_rc" 0
assert_file_contains "the refusal names the requirement it could not meet" \
	"$TMP_ROOT/canary.out" "run_status needs errexit in force at the call site"
