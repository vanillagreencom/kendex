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

# hierarchy_chains_overlap CANDIDATES EXISTING — true when any non-empty
# candidate is already present in the existing newline-separated chain.
hierarchy_chains_overlap() {
	local candidates="$1" existing="$2" candidate
	while IFS= read -r candidate; do
		if [[ -n "$candidate" ]] && hierarchy_chain_contains "$existing" "$candidate"; then
			return 0
		fi
	done <<<"$candidates"
	return 1
}

# validate_parent_chain_shape ISSUE_JSON SELECTED_DEPTH CONTEXT
# A selected parent field is trustworthy only when the current issue is an
# object and the field is explicitly present. A literal null proves a root;
# an edge must be an object with non-empty GraphQL id/identifier fields. At
# SELECTED_DEPTH the query intentionally stops selecting another parent field.
validate_parent_chain_shape() {
	local issue_json="$1" selected_depth="$2" context="$3"
	if ! jq -e --argjson selected_depth "$selected_depth" '
		def valid_chain($remaining):
			(type == "object")
			and ((.id | type) == "string" and (.id | length) > 0)
			and ((.identifier | type) == "string" and (.identifier | length) > 0)
			and (
				if $remaining == 0 then true
				elif (has("parent") | not) then false
				elif .parent == null then true
				elif (.parent | type) == "object" then
					(.parent | valid_chain($remaining - 1))
				else false
				end
			);
		valid_chain($selected_depth)
	' <<<"$issue_json" >/dev/null; then
		echo "{\"error\": \"Hierarchy validation failed closed: Linear returned incomplete or malformed parent data for '$context'.\"}" >&2
		return 1
	fi
	if ! jq -e '
		def unique_chain_field($field):
			[recurse(.parent; . != null) | .[$field]] as $values
			| ($values | length) == ($values | unique | length);
		unique_chain_field("id") and unique_chain_field("identifier")
	' <<<"$issue_json" >/dev/null; then
		echo "{\"error\": \"Hierarchy validation failed closed: parent cycle detected from repeated ancestor identity for '$context'.\"}" >&2
		return 1
	fi
}

# validate_issue_project_shape ISSUE_JSON CONTEXT
# The top-level validation query selects project explicitly. Literal null is a
# supported no-project value; otherwise the project must carry the fields used
# by the same-project check and its diagnostic.
validate_issue_project_shape() {
	local issue_json="$1" context="$2"
	if ! jq -e '
		(type == "object")
		and has("project")
		and (
			.project == null
			or (
				(.project | type) == "object"
				and ((.project.id | type) == "string" and (.project.id | length) > 0)
				and ((.project.name | type) == "string" and (.project.name | length) > 0)
			)
		)
	' <<<"$issue_json" >/dev/null; then
		echo "{\"error\": \"Hierarchy validation failed closed: Linear returned missing or malformed project data for '$context'.\"}" >&2
		return 1
	fi
}

# hoist_to_lca_child CHAIN OTHER_CHAIN
# Print two lines: the entry of CHAIN whose parent is the lowest common
# ancestor of both chains (the subtree root where the chains separate), then
# that entry's parent (empty line when the entry is a root, i.e. the chains
# share no ancestor). Callers must have excluded ancestor/descendant pairs.
hoist_to_lca_child() {
	local chain="$1" other="$2"
	# Read the newline-separated chain without an extra subprocess.
	local -a entries=()
	local line
	while IFS= read -r line; do
		entries+=("$line")
	done <<<"$chain"

	local i parent
	for ((i = 0; i < ${#entries[@]}; i++)); do
		parent="${entries[i + 1]:-}"
		if [[ -z "$parent" ]] || hierarchy_chain_contains "$other" "$parent"; then
			printf '%s\n%s\n' "${entries[i]}" "$parent"
			return 0
		fi
	done
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

	# hoist_to_lca_child prints "candidate\nparent"; command substitution
	# strips the trailing newline of an empty parent line.
	local hoist1 hoist2
	hoist1=$(hoist_to_lca_child "$chain1" "$chain2")
	hoist2=$(hoist_to_lca_child "$chain2" "$chain1")
	local cand1 cand1_parent cand2 cand2_parent
	cand1=$(sed -n '1p' <<<"$hoist1")
	cand1_parent=$(sed -n '2p' <<<"$hoist1")
	cand2=$(sed -n '1p' <<<"$hoist2")
	cand2_parent=$(sed -n '2p' <<<"$hoist2")

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
