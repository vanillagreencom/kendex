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
#                 stays pre-merge until PR merge, so it may be "In Progress"
#                 OR "In Review" at validation time. This is the default role.
#
#   container     A bundle parent whose children are each worked as their own
#                 PR unit; the container itself is never orchestrated and
#                 closes LAST, after its final child. Its own state name is
#                 not checked here (see build_completion_validation_result:
#                 the container role gates on state_type instead), so this
#                 helper emits nothing for it.
#
# Emits one accepted state per line.
completion_expected_states() {
	local role="${1:-session-root}"

	if [[ "$role" == "bundle-child" ]]; then
		printf 'Done\n'
		return 0
	fi

	if [[ "$role" == "container" ]]; then
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
# Args: issue_id state parent_id has_summary [role] [state_type]
#
# The distinguishing "role" is supplied explicitly by the caller (positional
# target => session-root; bundle-expanded child => bundle-child; positional
# target under --container => container); it — not parent_id — drives the
# expected-state decision, so a parented issue run as the managed session root
# is no longer forced to Done. It is a late, defaulted argument so the first
# four positions stay compatible with the original signature. parent_id is
# retained for call-site provenance and to keep the record shape
# self-describing.
#
# The container role inverts the bundle contract: children complete first,
# each as its own PR unit, and the container closes LAST. Its state check is
# therefore keyed on state_type, not state name — any live state passes, a
# canceled container (or one with no state_type evidence) fails closed — and
# has_summary does not gate `ok`: the summary is posted by `issues complete
# --summary` at completion time, after this validation runs.
#
# Output shape is stable: {id, state, state_type, state_ok, has_summary, ok}
build_completion_validation_result() {
	local issue_id="$1"
	local state="$2"
	# shellcheck disable=SC2034  # provenance only; role (not parent_id) decides expected state
	local parent_id="$3"
	local has_summary="$4"
	local role="${5:-session-root}"
	local state_type="${6:-}"
	local state_ok="false"
	local ok="false"

	if [[ "$role" == "container" ]]; then
		if [[ -n "$state_type" && "$state_type" != "canceled" ]]; then
			state_ok="true"
			ok="true"
		fi
	else
		if completion_state_matches "$state" "$role"; then
			state_ok="true"
		fi

		if [[ "$state_ok" == "true" && "$has_summary" == "true" ]]; then
			ok="true"
		fi
	fi

	jq -n \
		--arg id "$issue_id" \
		--arg state "$state" \
		--arg state_type "$state_type" \
		--argjson state_ok "$state_ok" \
		--argjson has_summary "$has_summary" \
		--argjson ok "$ok" \
		'{id: $id, state: $state, state_type: $state_type, state_ok: $state_ok, has_summary: $has_summary, ok: $ok}'
}

# --- Blocking-relation hierarchy guard (add-relation / block) ---
#
# Invariant: a blocking relation connects peers of one bundle — two issues
# with the SAME direct parent, or two top-level issues. An issue never blocks
# its own ancestor or descendant: the parent-child hierarchy already encodes
# that dependency. Cross-subtree dependencies are expressed between the peers
# that own the ordering.
#
# The rule reads one level: each issue's own direct parent identifier, empty
# for a top-level issue.

# blocking_level_ok BLOCKER_PARENT BLOCKED_PARENT
# The single acceptance predicate for the blocking-level rule; the rejection
# message below states the same rule.
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

# blocking_level_violation_message BLOCKER BLOCKED BLOCKER_PARENT BLOCKED_PARENT
# Compose the plain-text rejection message for a blocking-level violation.
# Two outcomes: a parent/child pair gets its own explanation, because the
# hierarchy already encodes that dependency and no replacement pair exists;
# every other pair gets the rule it failed.
blocking_level_violation_message() {
	local blocker="$1" blocked="$2" p1="$3" p2="$4"

	local ancestor="" descendant=""
	if [[ -n "$p1" && "$p1" == "$blocked" ]]; then
		ancestor="$blocked" descendant="$blocker"
	elif [[ -n "$p2" && "$p2" == "$blocker" ]]; then
		ancestor="$blocker" descendant="$blocked"
	fi
	if [[ -n "$ancestor" ]]; then
		printf 'Hierarchy violation: %s is the parent of %s — an issue cannot carry a blocking relation against its own ancestor; the parent-child hierarchy already encodes that dependency. No relation is needed while %s stays under %s; use '"'"'%s --related %s'"'"' for traceability. A true sequencing gate belongs between sibling issues at the level that owns the ordering.' \
			"$ancestor" "$descendant" "$descendant" "$ancestor" "$descendant" "$ancestor"
		return 0
	fi

	printf 'Blocking-level violation: %s and %s sit in different bundles; a blocking relation must connect peers of one bundle (same direct parent, or both top-level). Express the dependency between the peers that own the ordering, or use '"'"'%s --related %s'"'"' for traceability.' \
		"$blocker" "$blocked" "$blocker" "$blocked"
}

# --- Reach guard (create-time filing bar) ---
#
# The reply grammar makes filing the cheap disposition: `Declined:` needs a
# disproof a gate checks, `Tracked: <ID>` needs only an issue to exist, so a
# hypothetical gets an issue where it should have got a decline. Every Linear
# `Tracked:` passes through this create, so it is where the filing bar can be
# held on this tracker; a `Tracked: #<n>` filed with `gh issue create` never
# reaches here and is unguarded. Under LINEAR_REQUIRE_REACH
# (kendex.settings.toml [env]) a create refuses, before any API call, a
# description with no `Reached by:` line — an unsubstituted placeholder and a
# null token counting as absent. Whether the line names a real producer is the
# author's judgement, not this guard's. Empty or unset keeps the guard off.
# The bar itself is project-management SKILL.md, § Disposition.

# The rule the refusal quotes, so message and rule cannot drift apart.
REACH_RULE='An issue names what reaches it: the user action, run, check, or shipped producer that arrives at the defect (an owner-directed item names the ask). An unsubstituted placeholder or a null token is no value at all.'

# An unsubstituted template placeholder, and a token whose whole meaning is
# "nothing here", name no more than a blank line does. Both resolve to the
# absent case so the caller's missing-line refusal is what the author reads.
REACH_ABSENT_PLACEHOLDER='^\[[A-Z_]+\]$'
REACH_ABSENT_TOKENS='^(tbd|n/a|na|none|unknown|-|\?)$'

# issue_marked_value DESCRIPTION MARKER — the first `Marker:` value in the
# body, or empty where the line is absent or names nothing. MARKER is a POSIX
# bracket-case pattern, not a literal, because BSD sed has no case-insensitive
# `s///` flag. A leading list marker and markdown emphasis are tolerated:
# `Reached by:`, `- **Reached by**:` and `**Reached by:**` are one form, and a
# whole-line bold leaves its closing `**` on the value.
issue_marked_value() {
	local value lower
	value=$(sed -n "s/^[[:space:]]*[-*+]*[[:space:]]*\**[[:space:]]*$2[[:space:]]*\**[[:space:]]*:[[:space:]]*\**[[:space:]]*//p" <<<"$1" | head -1)
	value="${value%"${value##*[!*[:space:]]}"}"
	lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
	if [[ "$value" =~ $REACH_ABSENT_PLACEHOLDER ]] || [[ "$lower" =~ $REACH_ABSENT_TOKENS ]]; then
		value=""
	fi
	printf '%s' "$value"
}

# require_issue_reach DESCRIPTION PRIORITY REVIEW_BORN — 0 to proceed, 1 + a
# JSON error on stderr for the caller to return on.
#
# The symptom check is bound to REVIEW_BORN ("1" from `--review-born`). A
# review finding files as priority 2 only with a reported symptom; priority 2
# minted structurally — a TPM planner, a roadmap layer, the merge-pr rebundle,
# a research spike — reports no symptom by construction and creates unchecked.
require_issue_reach() {
	local description="$1" priority="$2" review_born="${3:-}"
	[ -n "${LINEAR_REQUIRE_REACH:-}" ] || return 0

	local reach
	reach=$(issue_marked_value "$description" '[Rr]eached[[:space:]][Bb]y')
	if [ -z "$reach" ]; then
		jq -cn --arg rule "$REACH_RULE" \
			'{error: ("Refusing to create an issue with no \"Reached by:\" line. " + $rule + " Add the line to the description (project-management issue-description-template.md carries it) and retry - an item with nothing to name is a decline, not an issue.")}' >&2
		return 1
	fi

	if [ "$review_born" = "1" ] && [ "$priority" = "2" ] &&
		[ -z "$(issue_marked_value "$description" '[Ss]ymptom')" ]; then
		jq -cn '{error: "Refusing to create a review-born priority-2 issue with no \"Symptom:\" line. Priority 2 is the reported tier: name the run, the user, or the red check that already showed the defect. Without one the item is normal work - create it at --priority 3."}' >&2
		return 1
	fi

	return 0
}
