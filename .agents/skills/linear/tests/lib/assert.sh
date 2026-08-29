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

__assert_ran() {
	ASSERT_COUNT=$((ASSERT_COUNT + 1))
}

__assert_failed() {
	local desc="$1" line
	shift
	ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
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

# run_status VARNAME CMD [ARG...] — run CMD with errexit suspended and put its
# exit status in VARNAME. `set -e` does not apply inside an `if` condition or a
# `&&`/`||` operand, so a command whose status a suite means to inspect is
# captured here and asserted on, never branched on in place.
run_status() {
	local __var="$1" __rc=0
	shift
	"$@" || __rc=$?
	printf -v "$__var" '%s' "$__rc"
}

__assert_on_exit() {
	local rc=$? cmd dir
	for cmd in ${ASSERT_CLEANUP_CMDS[@]+"${ASSERT_CLEANUP_CMDS[@]}"}; do
		eval "$cmd" || true
	done
	for dir in ${ASSERT_TMPDIRS[@]+"${ASSERT_TMPDIRS[@]}"}; do
		rm -rf -- "${dir:?}"
	done

	if ((ASSERT_FAILURES > 0)); then
		printf '%d of %d assertions failed\n' "$ASSERT_FAILURES" "$ASSERT_COUNT" >&2
		exit 1
	fi
	if ((rc != 0)); then
		printf 'suite aborted with status %d after %d assertions\n' "$rc" "$ASSERT_COUNT" >&2
		exit "$rc"
	fi
	if ((ASSERT_COUNT == 0)); then
		printf 'FAIL: suite ended without executing an assertion\n' >&2
		exit 1
	fi
	printf 'ok: %d assertions\n' "$ASSERT_COUNT"
	exit 0
}

trap __assert_on_exit EXIT
