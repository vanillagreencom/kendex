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

# --- Blocking-relation hierarchy guard (add-relation / block) ---
#
# Invariant: a blocking relation connects peers of one bundle — two issues
# with the SAME direct parent, or two top-level issues. An issue never blocks
# its own ancestor or descendant: the parent-child hierarchy already encodes
# that dependency. Cross-subtree dependencies are expressed at the level
# where the subtrees separate (the children of the lowest common ancestor).
#
# Ancestor chains are newline-separated identifier lists, self first, root
# last (e.g. "CC-766\nCC-763\nCC-761").

# blocking_level_ok BLOCKER_PARENT BLOCKED_PARENT
# The single acceptance predicate for the blocking-level rule. Both the guard
# and the remediation generator use it, so a prescribed replacement command is
# accepted by construction.
blocking_level_ok() {
	local p1="${1:-}" p2="${2:-}"

	if [[ -z "$p1" && -z "$p2" ]]; then
		return 0 # both top-level
	fi
	if [[ -n "$p1" && "$p1" == "$p2" ]]; then
		return 0 # siblings under the same parent
	fi
	return 1
}

# hierarchy_chain_contains CHAIN ID — true when ID is an entry of CHAIN.
hierarchy_chain_contains() {
	local chain="$1" id="$2"
	[[ -n "$id" ]] && grep -qxF "$id" <<<"$chain"
}

# fetch_complete_issue_hierarchy ISSUE_ID
# Walk one parent edge per query until Linear returns an explicit root. This is
# intentionally iterative: GraphQL has no recursive selection, and a fixed
# nested parent shape cannot distinguish a real root from query truncation.
# Prints {identifier, project_id, project_name, chain} on success. Any missing
# node/identity/project/parent ID or repeated node fails closed before callers
# can create a relation.
fetch_complete_issue_hierarchy() {
	local current_id="$1"
	local query='
	query ValidateBlockingIssue($id: String!) {
		issue(id: $id) {
			id
			identifier
			project { id name }
			parent { id }
		}
	}'
	local chain="" seen_ids=""
	local issue_identifier="" project_id="" project_name=""

	while [[ -n "$current_id" ]]; do
		local result node_id identifier node_project_id node_project_name
		local parent_present parent_id
		if ! result=$(graphql_query "$query" "{\"id\": \"$current_id\"}"); then
			return 1
		fi
		node_id=$(jq -r '.issue.id // empty' <<<"$result")
		identifier=$(jq -r '.issue.identifier // empty' <<<"$result")
		node_project_id=$(jq -r '.issue.project.id // empty' <<<"$result")
		node_project_name=$(jq -r '.issue.project.name // "none"' <<<"$result")
		parent_present=$(jq -r 'if .issue.parent == null then "false" else "true" end' <<<"$result")
		parent_id=$(jq -r '.issue.parent.id // empty' <<<"$result")

		if [[ -z "$node_id" || -z "$identifier" ]]; then
			echo "{\"error\": \"Hierarchy validation failed closed: Linear returned incomplete issue data for '$current_id'.\"}" >&2
			return 1
		fi
		if [[ "$parent_present" == "true" && -z "$parent_id" ]]; then
			echo "{\"error\": \"Hierarchy validation failed closed: Linear returned an incomplete parent edge for '$identifier'.\"}" >&2
			return 1
		fi
		if hierarchy_chain_contains "$seen_ids" "$node_id"; then
			echo "{\"error\": \"Hierarchy validation failed closed: parent cycle detected at '$identifier'.\"}" >&2
			return 1
		fi

		if [[ -z "$issue_identifier" ]]; then
			issue_identifier="$identifier"
			project_id="$node_project_id"
			project_name="$node_project_name"
		fi
		if [[ -z "$chain" ]]; then
			chain="$identifier"
			seen_ids="$node_id"
		else
			chain="${chain}"$'\n'"${identifier}"
			seen_ids="${seen_ids}"$'\n'"${node_id}"
		fi
		current_id="$parent_id"
	done

	jq -n \
		--arg identifier "$issue_identifier" \
		--arg project_id "$project_id" \
		--arg project_name "$project_name" \
		--arg chain "$chain" \
		'{identifier: $identifier, project_id: $project_id, project_name: $project_name, chain: $chain}'
}

# hoist_to_lca_child CHAIN OTHER_CHAIN
# Print two lines: the entry of CHAIN whose parent is the lowest common
# ancestor of both chains (the subtree root where the chains separate), then
# that entry's parent (empty line when the entry is a root, i.e. the chains
# share no ancestor). Callers must have excluded ancestor/descendant pairs.
hoist_to_lca_child() {
	local chain="$1" other="$2"
	local child="" parent

	while IFS= read -r parent; do
		if [[ -n "$child" ]] && hierarchy_chain_contains "$other" "$parent"; then
			printf '%s\n%s\n' "$child" "$parent"
			return 0
		fi
		child="$parent"
	done <<<"$chain"

	# No shared ancestor: the root is the candidate and has no parent.
	[[ -n "$child" ]] && printf '%s\n\n' "$child"
}

# blocking_level_violation_message BLOCKER BLOCKED CHAIN1 CHAIN2
# Compose the plain-text rejection message for a blocking-level violation.
# Ancestor/descendant pairs get a single explanation (no replacement command
# exists). Cross-subtree pairs get the one hoisted pair that satisfies
# blocking_level_ok; the candidate is re-checked through that same predicate
# before it is printed, so the prescription is never itself rejected.
blocking_level_violation_message() {
	local blocker="$1" blocked="$2" chain1="$3" chain2="$4"

	if [[ "$blocker" == "$blocked" ]]; then
		printf 'Hierarchy violation: %s cannot block itself.' "$blocker"
		return 0
	fi

	local ancestor="" descendant=""
	if hierarchy_chain_contains "$chain1" "$blocked"; then
		ancestor="$blocked" descendant="$blocker"
	elif hierarchy_chain_contains "$chain2" "$blocker"; then
		ancestor="$blocker" descendant="$blocked"
	fi
	if [[ -n "$ancestor" ]]; then
		printf 'Hierarchy violation: %s is an ancestor of %s — an issue cannot carry a blocking relation against its own ancestor; the parent-child hierarchy already encodes that dependency. No relation is needed while %s stays under %s; use '\''%s --related %s'\'' for traceability. A true sequencing gate belongs between sibling issues at the level that owns the ordering.' \
			"$ancestor" "$descendant" "$descendant" "$ancestor" "$descendant" "$ancestor"
		return 0
	fi

	local hoist1 hoist2 cand1 cand1_parent cand2 cand2_parent
	hoist1=$(hoist_to_lca_child "$chain1" "$chain2")
	hoist2=$(hoist_to_lca_child "$chain2" "$chain1")
	cand1="${hoist1%%$'\n'*}"
	cand2="${hoist2%%$'\n'*}"
	cand1_parent=""
	cand2_parent=""
	if [[ "$hoist1" == *$'\n'* ]]; then
		cand1_parent="${hoist1#*$'\n'}"
	fi
	if [[ "$hoist2" == *$'\n'* ]]; then
		cand2_parent="${hoist2#*$'\n'}"
	fi

	if [[ -n "$cand1" && -n "$cand2" && "$cand1" != "$cand2" ]] \
		&& blocking_level_ok "$cand1_parent" "$cand2_parent"; then
		printf 'Blocking-level violation: %s and %s sit in different bundles; a blocking relation must connect peers of one bundle (same direct parent, or both top-level). Express the dependency where the subtrees separate: use '\''%s --blocks %s'\'', and '\''%s --related %s'\'' for traceability.' \
			"$blocker" "$blocked" "$cand1" "$cand2" "$blocker" "$blocked"
		return 0
	fi

	# Defensive fallback: no candidate satisfies the guard's own predicate.
	printf 'Blocking-level violation: %s and %s sit in different bundles; a blocking relation must connect peers of one bundle (same direct parent, or both top-level). No replacement pair satisfies the rule; restructure the hierarchy or use '\''%s --related %s'\'' for traceability.' \
		"$blocker" "$blocked" "$blocker" "$blocked"
}
