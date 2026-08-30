#!/usr/bin/env bash
# The library's verdict, exercised from outside it.
#
# assert.sh decides a suite's exit status in __assert_on_exit, and every other
# suite here reaches that code with assertions already executed — so the branch
# that fails a suite for executing NONE is the one thing in this change that
# nothing else covers. Delete it and every other suite stays green, which is
# precisely the shape this whole change exists to remove.
#
# Each case is a child suite: a real file that sources the library and runs to
# completion, so the trap fires the way it does in production rather than being
# simulated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
LIB="$SCRIPT_DIR/lib/assert.sh"

assert_tmpdir TMP_ROOT

# run_child NAME BODY — write a child suite around BODY, run it, and leave its
# status in <NAME>_rc and its combined output in <NAME>_out. The child is its
# own process, so its errexit and its EXIT trap are untouched by ours.
run_child() {
	local name="$1" body="$2" path="$TMP_ROOT/$1.sh" rc=0 out
	{
		printf '#!/usr/bin/env bash\n'
		printf 'set -euo pipefail\n'
		printf 'source %q\n' "$LIB"
		printf '%s\n' "$body"
	} >"$path"

	out="$(bash "$path" 2>&1)" || rc=$?

	printf -v "${name}_rc" '%s' "$rc"
	printf -v "${name}_out" '%s' "$out"
}

# --- the branch nothing else reaches: a suite that checked nothing ----------
run_child none 'true'

assert_ne "a suite that executes no assertion fails" "$none_rc" 0
assert_contains "and the diagnostic says that is why" \
	"$none_out" "FAIL: suite ended without executing an assertion"

# A suite can end with no assertion after doing plenty of work; the verdict is
# about what was checked, never about what ran.
run_child busy 'x=0; for i in 1 2 3; do x=$((x + i)); done; printf "%s\n" "$x"'

assert_ne "work without a single assertion still fails" "$busy_rc" 0
assert_contains "however much the suite did" \
	"$busy_out" "FAIL: suite ended without executing an assertion"

# --- the other three branches, so the verdict is covered whole --------------
run_child passing 'assert_eq "a claim that holds" 1 1'

assert_eq "a suite whose assertions all pass exits zero" "$passing_rc" 0
assert_contains "and reports how many ran" "$passing_out" "ok: 1 assertions"

run_child failing 'assert_eq "a claim that does not hold" 1 2'

assert_ne "a suite with a failed assertion fails" "$failing_rc" 0
assert_contains "and names the assertion" "$failing_out" "FAIL: a claim that does not hold"
assert_contains "and reports the tally" "$failing_out" "1 of 1 assertions failed"

run_child aborting 'false'

assert_ne "a suite that aborts before asserting fails" "$aborting_rc" 0
assert_contains "and says it aborted rather than checked nothing" \
	"$aborting_out" "suite aborted with status 1 after 0 assertions"

