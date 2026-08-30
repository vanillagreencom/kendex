#!/usr/bin/env bash
# A suite that ends with work still running has not finished being a suite.
#
# The ledger closes the hole where a subshell COPIES the counter. This is the
# hole one level out: a background job still running when the suite ends writes
# its record after the totals are computed and after the ledger is removed, so
# a failure there is discarded rather than merely late.
#
# The verdict fails closed on the job's presence rather than waiting for it.
# Waiting is the other option and it can hang forever on a job that never
# exits, and a suite that never returns is worse than one that refuses.
#
# This lives apart from assert-subshell because the harness runs one control
# per suite, and each branch of the verdict needs a control that proves it
# alone: a single control breaking both would not show either was load-bearing.

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

run_child delayed_background 'assert_eq "in the parent" 1 1; ( sleep 1; assert_eq "delayed" 1 2 ) &'

assert_ne "a suite that ends with a background job still running fails" \
	"$delayed_background_rc" 0
assert_contains "and the diagnostic says the job would land after the verdict" \
	"$delayed_background_out" "background job(s) still running"
assert_not_contains "rather than reporting the assertions it did see" \
	"$delayed_background_out" "ok: 1 assertions"

# A job the suite waited for is finished, not outstanding, and is not refused —
# which is what keeps run_status usable, since it backgrounds its subject.
run_child awaited_background 'assert_eq "in the parent" 1 1; ( sleep 0.1 ) & wait $!'

assert_eq "a background job the suite waited for is not refused" "$awaited_background_rc" 0
assert_contains "and the suite reports its own assertions" "$awaited_background_out" "ok: 1 assertions"
