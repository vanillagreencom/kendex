#!/usr/bin/env bash
# An assertion the suite cannot see is refused, not counted.
#
# A subshell — a command substitution, a pipeline element, a backgrounded or
# parenthesised block — gets its own copy of every variable. An assertion made
# there increments a counter the suite never sees and records a failure nobody
# reads, so a helper that looks like it is checking something is checking
# nothing. The counters cannot notice on their own: they are exactly what the
# subshell copied. The verdict compares them against a ledger the subshell
# shares with its parent, and refuses the shape rather than leaving authors to
# avoid it.
#
# Each case is a child suite: a real file that sources the library and runs to
# completion, so the trap fires the way it does in production.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
LIB="$SCRIPT_DIR/lib/assert.sh"

assert_tmpdir TMP_ROOT

# run_child NAME BODY — write a child suite around BODY, run it, and leave its
# status in <NAME>_rc and its combined output in <NAME>_out.
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

run_child in_substitution 'assert_eq "in the parent" 1 1; x="$(assert_eq "in a subshell" 1 1)"'

assert_ne "an assertion made in a command substitution fails the suite" "$in_substitution_rc" 0
assert_contains "and the diagnostic says the suite could not see it" \
	"$in_substitution_out" "1 assertion(s) ran in a subshell"

# A failure recorded in a subshell is discarded by the counters entirely; the
# ledger is what stops it passing silently.
run_child failing_in_subshell 'assert_eq "in the parent" 1 1; x="$(assert_eq "in a subshell" 1 2)"'

assert_ne "a failure recorded in a subshell still fails the suite" "$failing_in_subshell_rc" 0

# Every subshell form loses the record, not just command substitution. All four
# are named in DEVELOPMENT.md, so all four are pinned here.
run_child in_pipeline 'assert_eq "in the parent" 1 1; assert_eq "in a pipeline" 1 1 | cat'

assert_ne "an assertion made in a pipeline element fails the suite" "$in_pipeline_rc" 0
assert_contains "for the same reason" "$in_pipeline_out" "ran in a subshell"

run_child in_parens 'assert_eq "in the parent" 1 1; ( assert_eq "in a paren block" 1 1 )'

assert_ne "an assertion made in a parenthesised block fails the suite" "$in_parens_rc" 0

# Waited for, so nothing is outstanding at the verdict — and still refused,
# because the record was made in a copy either way.
run_child in_background 'assert_eq "in the parent" 1 1; ( assert_eq "in a background block" 1 1 ) & wait $!'

assert_ne "an assertion made in a backgrounded block fails the suite" "$in_background_rc" 0
assert_contains "even when the suite waited for it" "$in_background_out" "ran in a subshell"

