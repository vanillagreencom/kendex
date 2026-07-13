#!/usr/bin/env bash
# Regression test for vstack #519.
#
# completion_expected_state() used to return "Done" for ANY issue with a parent,
# so a decomposition child run as the managed top-level session (kept In Review
# until PR merge per orch start-worktree.md § 5.3) failed validate-completion's
# state_ok gate. The lib now keys the expected state on an explicit call-site
# "role":
#   - bundle-child : a sub-issue processed under its parent session -> expects Done.
#   - session-root : the managed top-level issue (parented or not) -> expects a
#                    pre-merge managed state (In Progress OR In Review).
#
# This exercises the pure function lib directly (no network). The pre-fix lib
# fails the case-2 assertions below (a parented session root in In Review/In
# Progress yielded state_ok=false).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/lib/issue-validation.sh"

# shellcheck disable=SC1090
source "$LIB"

pass=0
fail=0

# assert_result LABEL WANT_STATE_OK WANT_OK -- <args to build_completion_validation_result>
# Defensive against a build failure (e.g. a pre-fix signature mismatch): a
# nonzero/invalid result is recorded as a clean FAIL rather than aborting.
assert_result() {
	local label="$1" want_state_ok="$2" want_ok="$3"
	shift 3

	local out rc got_state_ok got_ok
	set +e
	out=$(build_completion_validation_result "$@" 2>/dev/null)
	rc=$?
	set -e
	if [[ $rc -ne 0 || -z "$out" ]]; then
		out='{}'
	fi

	# Use has() rather than `// "ERR"` — jq's // treats boolean false as empty.
	got_state_ok=$(echo "$out" | jq -r 'if has("state_ok") then (.state_ok | tostring) else "ERR" end')
	got_ok=$(echo "$out" | jq -r 'if has("ok") then (.ok | tostring) else "ERR" end')

	if [[ "$got_state_ok" == "$want_state_ok" && "$got_ok" == "$want_ok" ]]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL: $label"
		echo "  want state_ok=$want_state_ok ok=$want_ok"
		echo "  got  state_ok=$got_state_ok ok=$got_ok"
		echo "  output: $out"
	fi
}

# Args order: issue_id state parent_id has_summary role

# --- Case 1: bundled sub-issue (validated as a child under a parent session) ---
# Still expects Done.
assert_result "case1 bundle-child Done"       true  true  "CC-C1" "Done"      "CC-PARENT" "true" "bundle-child"
assert_result "case1 bundle-child In Review"  false false "CC-C1" "In Review" "CC-PARENT" "true" "bundle-child"
assert_result "case1 bundle-child In Progress" false false "CC-C1" "In Progress" "CC-PARENT" "true" "bundle-child"

# --- Case 2: managed session-root issue WITH a parent (the #519 fix) ---
# No longer forced to Done; accepts the pre-merge managed state.
assert_result "case2 parented root In Review"   true  true  "CC-R1" "In Review"   "CC-PARENT" "true" "session-root"
assert_result "case2 parented root In Progress" true  true  "CC-R1" "In Progress" "CC-PARENT" "true" "session-root"
assert_result "case2 parented root Backlog"     false false "CC-R1" "Backlog"     "CC-PARENT" "true" "session-root"
assert_result "case2 parented root Todo"        false false "CC-R1" "Todo"        "CC-PARENT" "true" "session-root"

# --- Case 3: managed session-root issue WITHOUT a parent ---
assert_result "case3 standalone root In Progress" true  true  "CC-R2" "In Progress" "" "true" "session-root"
assert_result "case3 standalone root In Review"   true  true  "CC-R2" "In Review"   "" "true" "session-root"
# A session root is pre-merge, so Done is NOT an accepted pre-merge state.
assert_result "case3 standalone root Done"        false false "CC-R2" "Done"        "" "true" "session-root"
assert_result "case3 standalone root Backlog"     false false "CC-R2" "Backlog"     "" "true" "session-root"

# --- Case 4: ok is true only when state_ok AND has_summary ---
assert_result "case4 state ok but no summary"  true  false "CC-R3" "In Review" "" "false" "session-root"
assert_result "case4 summary but bad state"    false false "CC-R3" "Backlog"   "" "true"  "session-root"
assert_result "case4 state ok and summary"     true  true  "CC-R3" "In Review" "" "true"  "session-root"
assert_result "case4 bundle child ok"          true  true  "CC-C2" "Done"      "CC-PARENT" "true"  "bundle-child"

echo "pass: $pass fail: $fail"
[[ "$fail" -eq 0 ]]
