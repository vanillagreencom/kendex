# shellcheck shell=bash
#
# Assertions for the linear skill's suites.
#
# Every claim a suite makes runs through a helper here, and sourcing this file
# installs the EXIT trap that turns those claims into the suite's verdict. A
# suite that reaches its end without executing an assertion fails: an exit code
# reports on the process, not on anything that was checked.
#
# Helpers never return non-zero and never exit. A failed assertion is recorded
# and the suite runs on, so one run reports every failure and no assertion can
# be skipped by an errexit abort. `assert_stop` ends the suite where continuing
# would be meaningless.
#
# Cleanup goes through `assert_tmpdir` and `assert_at_exit`. Installing another
# EXIT trap replaces this one and disarms the verdict.

if [[ -n "${ASSERT_LIB_LOADED:-}" ]]; then
	return 0
fi
ASSERT_LIB_LOADED=1

ASSERT_COUNT=0
ASSERT_FAILURES=0
ASSERT_TMPDIRS=()
ASSERT_CLEANUP_CMDS=()
ASSERT_SCRATCH_DIR=""

# A subshell — a command substitution, a pipeline element, a backgrounded or
# parenthesised block — gets its own copy of every variable, so an assertion
# made there increments a counter the suite never sees and records a failure
# nobody reads. The counters alone cannot notice: they are exactly what the
# subshell copied. So every assertion also appends to a file, which a subshell
# shares with its parent, and the verdict compares the two. A count that
# disagrees is the shape, and it is refused rather than left to authors to
# avoid.
printf -v ASSERT_LEDGER '%s' "$(mktemp)"
if [[ -z "$ASSERT_LEDGER" ]]; then
	printf 'FAIL: could not create the assertion ledger\n' >&2
	exit 1
fi

__assert_ran() {
	ASSERT_COUNT=$((ASSERT_COUNT + 1))
	printf 'ran\n' >>"$ASSERT_LEDGER"
}

__assert_failed() {
	local desc="$1" line
	shift
	ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
	printf 'failed\t%s\n' "$desc" >>"$ASSERT_LEDGER"
	printf 'FAIL: %s\n' "$desc" >&2
	for line in "$@"; do
		printf '      %s\n' "$line" >&2
	done
}

# assert_tmpdir VARNAME — make a scratch directory, name it in VARNAME, and
# remove it at exit. Takes a variable name rather than printing the path so the
# registration happens in the suite's own shell.
assert_tmpdir() {
	printf -v "$1" '%s' "$(mktemp -d)"
	# A library cannot impose errexit on its callers, so the one failure mode
	# that matters — mktemp failing and leaving the name empty — is checked
	# here rather than left to the caller's shell options.
	if [[ -z "${!1}" ]]; then
		printf 'FAIL: could not create a scratch directory\n' >&2
		exit 1
	fi
	ASSERT_TMPDIRS+=("${!1}")
}

# assert_at_exit COMMAND — run COMMAND (eval'd) before the scratch directories
# go, for teardown a plain remove cannot do.
assert_at_exit() {
	ASSERT_CLEANUP_CMDS+=("$1")
}

# assert DESC CMD [ARG...] — CMD must exit zero. The command's own output is
# captured, not printed: redirecting an assertion at the call site would
# silence the failure report too.
assert() {
	local desc="$1" out="" rc=0
	shift
	__assert_ran
	out="$("$@" 2>&1)" || rc=$?
	if ((rc == 0)); then
		return 0
	fi
	__assert_failed "$desc" "command failed with status $rc: $*" ${out:+"output: $out"}
}

# assert_not DESC CMD [ARG...] — CMD must exit non-zero.
assert_not() {
	local desc="$1" out="" rc=0
	shift
	__assert_ran
	out="$("$@" 2>&1)" || rc=$?
	if ((rc != 0)); then
		return 0
	fi
	__assert_failed "$desc" "command unexpectedly succeeded: $*" ${out:+"output: $out"}
}

# assert_eq DESC GOT WANT
assert_eq() {
	__assert_ran
	if [[ "$2" == "$3" ]]; then
		return 0
	fi
	__assert_failed "$1" "want: $3" "got:  $2"
}

# assert_ne DESC GOT UNWANTED
assert_ne() {
	__assert_ran
	if [[ "$2" != "$3" ]]; then
		return 0
	fi
	__assert_failed "$1" "got the value it must not have: $3"
}

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() {
	__assert_ran
	if [[ "$2" == *"$3"* ]]; then
		return 0
	fi
	__assert_failed "$1" "missing substring: $3" "in: $2"
}

# assert_not_contains DESC HAYSTACK NEEDLE
assert_not_contains() {
	__assert_ran
	if [[ "$2" != *"$3"* ]]; then
		return 0
	fi
	__assert_failed "$1" "forbidden substring: $3" "in: $2"
}

# assert_matches DESC SUBJECT ERE
assert_matches() {
	__assert_ran
	if [[ "$2" =~ $3 ]]; then
		return 0
	fi
	__assert_failed "$1" "no match for: $3" "in: $2"
}

# assert_jq DESC JSON FILTER — FILTER must select a true, non-null value.
assert_jq() {
	__assert_ran
	if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then
		return 0
	fi
	__assert_failed "$1" "filter: $3" "json: $2"
}

# assert_file_contains DESC PATH NEEDLE — NEEDLE is a literal, not a pattern.
assert_file_contains() {
	__assert_ran
	if [[ ! -f "$2" ]]; then
		__assert_failed "$1" "no such file: $2"
		return 0
	fi
	if grep -qF -- "$3" "$2"; then
		return 0
	fi
	__assert_failed "$1" "missing substring: $3" "in file: $2"
}

# assert_file_lacks DESC PATH NEEDLE
assert_file_lacks() {
	__assert_ran
	if [[ ! -f "$2" ]]; then
		__assert_failed "$1" "no such file: $2"
		return 0
	fi
	if grep -qF -- "$3" "$2"; then
		__assert_failed "$1" "forbidden substring: $3" "in file: $2"
		return 0
	fi
	return 0
}

# assert_fail DESC [DIAGNOSTIC...] — an unconditional failure, for a branch the
# suite must not reach.
assert_fail() {
	__assert_ran
	__assert_failed "$@"
}

# assert_stop DESC [DIAGNOSTIC...] — assert_fail, then end the suite.
assert_stop() {
	assert_fail "$@"
	exit 1
}

# run_status VARNAME CMD [ARG...] — run CMD and put its exit status in VARNAME.
#
# bash suspends errexit for the whole body of a command whose status is being
# tested — an `if` condition, a `&&`/`||` operand, a `!` — and the suspension
# reaches into a shell function called there and into every function it calls.
# `func || rc=$?` therefore reports 0 for a function that relied on errexit and
# was meant to abort partway: the exact fail-open this suite family exists to
# catch. Neither `set +e` around the call nor an explicit `set -e` inside a
# subshell restores it.
#
# So the subject is never put in a tested position. It runs in a background
# subshell, forked before any test, and `wait` reports the status it already
# finished with.
run_status() {
	local __var="$1" __rc=0
	shift

	# The suspension is inherited by a background subshell too, so errexit is
	# proved in force rather than assumed: under errexit this canary dies at
	# `false`, and only where errexit is suspended — or absent — does it live
	# to reach `exit 0`.
	( false; exit 0 ) &
	if wait $!; then
		assert_stop "run_status needs errexit in force at the call site" \
			"it is suspended inside an if condition, a &&/|| operand or a !," \
			"and absent in a suite that does not set -e"
	fi

	( "$@" ) &
	wait $! || __rc=$?
	printf -v "$__var" '%s' "$__rc"
}

# run_output OUTVAR RCVAR CMD [ARG...] — run_status, plus CMD's stdout in
# OUTVAR. Command substitution cannot be used for this: `out=$(func) || rc=$?`
# puts the subject back in a tested position, which is what run_status exists
# to avoid. The output goes through a file the background subshell writes.
run_output() {
	local __out_var="$1" __rc_var="$2" __file
	shift 2
	if [[ -z "$ASSERT_SCRATCH_DIR" ]]; then
		assert_tmpdir ASSERT_SCRATCH_DIR
	fi
	__file="$ASSERT_SCRATCH_DIR/run-output"

	run_status "$__rc_var" "$@" >"$__file"

	printf -v "$__out_var" '%s' "$(cat "$__file")"
}

__assert_on_exit() {
	local rc=$? cmd dir ledger_ran=0 ledger_failed=0 lost=0

	# The ledger is read before cleanup removes it, and it is the true count:
	# it survives the subshells the counters do not.
	if [[ -f "$ASSERT_LEDGER" ]]; then
		ledger_ran="$(grep -c '^ran$' "$ASSERT_LEDGER" || true)"
		ledger_failed="$(grep -c '^failed' "$ASSERT_LEDGER" || true)"
	fi
	lost=$((ledger_ran - ASSERT_COUNT))

	for cmd in ${ASSERT_CLEANUP_CMDS[@]+"${ASSERT_CLEANUP_CMDS[@]}"}; do
		eval "$cmd" || true
	done
	for dir in ${ASSERT_TMPDIRS[@]+"${ASSERT_TMPDIRS[@]}"}; do
		rm -rf -- "${dir:?}"
	done
	rm -f -- "${ASSERT_LEDGER:?}"

	if ((lost > 0)); then
		printf 'FAIL: %d assertion(s) ran in a subshell, where the suite cannot see them\n' "$lost" >&2
		printf '      a command substitution, pipeline element or backgrounded block gets its\n' >&2
		printf '      own copy of the counters, so the result is discarded — capture the status\n' >&2
		printf '      in the suite and assert on it there\n' >&2
		exit 1
	fi
	if ((ledger_failed > 0)); then
		printf '%d of %d assertions failed\n' "$ledger_failed" "$ledger_ran" >&2
		exit 1
	fi
	if ((rc != 0)); then
		printf 'suite aborted with status %d after %d assertions\n' "$rc" "$ledger_ran" >&2
		exit "$rc"
	fi
	if ((ledger_ran == 0)); then
		printf 'FAIL: suite ended without executing an assertion\n' >&2
		exit 1
	fi
	printf 'ok: %d assertions\n' "$ledger_ran"
	exit 0
}

trap __assert_on_exit EXIT
