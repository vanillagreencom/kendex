#!/bin/bash

set -euo pipefail

# Expected completion state(s) for an issue, keyed by its ROLE in the validation.
#
#   bundle-child  A sub-issue processed under its parent session as part of a
#                 bundle. It is marked Done per-sub-issue while the parent
#                 session aggregates it, so it must be "Done".
#
#   session-root  The managed top-level issue of a worktree session (a single
#                 delegation / decomposition child worked directly). Whether or
#                 not it has a parent, it follows the managed lifecycle and
#                 stays pre-merge until PR merge (see orch start-worktree.md
#                 § 5.3), so it may be "In Progress" OR "In Review" at
#                 validation time. This is the default role.
#
# Emits one accepted state per line.
completion_expected_states() {
	local role="${1:-session-root}"

	if [[ "$role" == "bundle-child" ]]; then
		printf 'Done\n'
		return 0
	fi

	printf 'In Progress\n'
	printf 'In Review\n'
}

# True when $state is one of the accepted states for the given role.
completion_state_matches() {
	local state="${1:-}"
	local role="${2:-session-root}"
	local expected

	while IFS= read -r expected; do
		[[ -n "$expected" ]] || continue
		if [[ "$state" == "$expected" ]]; then
			return 0
		fi
	done < <(completion_expected_states "$role")

	return 1
}

# Build the completion-validation result JSON for one issue.
#
# Args: issue_id state parent_id has_summary [role]
#
# The distinguishing "role" is supplied explicitly by the caller (positional
# target => session-root; bundle-expanded child => bundle-child); it — not
# parent_id — drives the expected-state decision, so a parented issue run as
# the managed session root is no longer forced to Done. It is the last,
# defaulted argument so the first four positions stay compatible with the
# original signature. parent_id is retained for call-site provenance and to
# keep the record shape self-describing.
#
# Output shape is stable: {id, state, state_ok, has_summary, ok}
build_completion_validation_result() {
	local issue_id="$1"
	local state="$2"
	# shellcheck disable=SC2034  # provenance only; role (not parent_id) decides expected state
	local parent_id="$3"
	local has_summary="$4"
	local role="${5:-session-root}"
	local state_ok="false"
	local ok="false"

	if completion_state_matches "$state" "$role"; then
		state_ok="true"
	fi

	if [[ "$state_ok" == "true" && "$has_summary" == "true" ]]; then
		ok="true"
	fi

	jq -n \
		--arg id "$issue_id" \
		--arg state "$state" \
		--argjson state_ok "$state_ok" \
		--argjson has_summary "$has_summary" \
		--argjson ok "$ok" \
		'{id: $id, state: $state, state_ok: $state_ok, has_summary: $has_summary, ok: $ok}'
}
