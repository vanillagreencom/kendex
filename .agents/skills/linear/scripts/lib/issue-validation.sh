#!/bin/bash

set -euo pipefail

# Expected completion state(s) for an issue, keyed by its ROLE in the validation.
#
#   bundle-child  A sub-issue processed under its parent session as part of
#                 the review audit's in-PR bundle (`Audit Bundle: yes`). A
#                 started state passes when the shared
#                 parser proves its branch boxes and their evidence.
#   container-child  A separate PR unit. It must finish Done before its
#                    container can close.
#
#   session-root  The managed top-level issue of a worktree session (a single
#                 delegation / decomposition child worked directly). Whether or
#                 not it has a parent, it follows the managed lifecycle and
#                 stays pre-merge until PR merge, so it may be "In Progress"
#                 OR "In Review" at validation time. This is the default role.
#
#   container     A bundle parent whose children are each worked as their own
#                 PR unit; the container itself is never orchestrated and
#                 closes when its last child is Done or Canceled. Its state name is
#                 not checked here (see build_completion_validation_result:
#                 the container role gates on state_type instead), so this
#                 helper emits nothing for it.
#
# Named completion states. Bundle phase acceptance also uses the state type.
completion_expected_states() {
	local role="${1:-session-root}"

	if [[ "$role" == "bundle-child" ]]; then
		printf 'Done\n'
		return 0
	fi
	if [[ "$role" == "container-child" ]]; then
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
	local state_type="${3:-}"
	local expected
	if [[ "$role" == "bundle-child" && "$state_type" == started && "$state" != Verifying ]]; then
		return 0
	fi

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
# Args: issue_id state parent_id has_summary [role] [state_type] [description]
#
# The distinguishing "role" is supplied explicitly by the caller (positional
# target => session-root; bundle-expanded child => bundle-child; positional
# target under --container => container); it — not parent_id — drives the
# expected-state decision, so a parented issue run as the managed session root
# is not forced to Done. It is a late, defaulted argument so the first
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
	local description="${7:-}" checklist
	local state_ok="false"
	local ok="false"

	if [[ "$role" == "container" ]]; then
		if [[ -n "$state_type" && "$state_type" != "canceled" ]]; then
			state_ok="true"
			ok="true"
		fi
	else
		if completion_state_matches "$state" "$role" "$state_type"; then
			state_ok="true"
		fi
		if [[ "$role" == "bundle-child" && "$state_ok" == true ]]; then
			checklist=$(done_when_parse "$description" '[]') || return 1
			state_ok=$(jq -r --arg state "$state" '
				if $state == "Done" then .completion_state == "Done"
				else (.boxes | length) > 0 and .unmet_branch_boxes == []
					and .missing_evidence_boxes == [] and .errors == [] end
			' <<<"$checklist") || return 1
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
# A leaf's wait must not hold its unrelated siblings. The parent-child
# hierarchy already encodes ancestor dependencies; adding a relation there
# would make the hierarchy wait on itself. The owning rule is SKILL.md
# § Blocked Label vs Issue Relations; no architecture decision is needed
# for this local validation choice.

# Read the same bounded ancestry in both mutation routes. The final parent
# has no parent selection: blocking_level_facts refuses if that frontier is
# reached, because Linear has not established where the chain ends.
BLOCKING_PARENT_FIELDS='identifier parent { identifier parent { identifier parent { identifier parent { identifier parent { identifier parent { identifier parent { identifier parent { identifier parent { identifier parent { identifier } } } } } } } } } }'
BLOCKING_CHILD_FIELDS='children(first: 1, includeArchived: true) { nodes { id } pageInfo { hasNextPage } }'

# Linear's relation queries produce these nodes. Missing fields are not proof
# of a leaf or a complete ancestry; structural repair must not delete on them.
blocking_level_facts() {
	local facts
	facts=$(jq -ce '
		def chain:
			if type != "object" or (.identifier | type) != "string" or .identifier == "" or (has("parent") | not)
			then error("incomplete ancestry")
			elif .parent == null then []
			else [.parent.identifier] + (.parent | chain) end;
		.blocker as $a | .blocked as $b
		| ($a | chain) as $ancestors_a | ($b | chain) as $ancestors_b
		| if ($b.children.nodes | type) != "array" or ($b.children.pageInfo.hasNextPage | type) != "boolean"
		  then error("missing children") else
		  {blocker: $a.identifier, blocked: $b.identifier,
		   parent1: ($ancestors_a[0] // ""), parent2: ($ancestors_b[0] // ""),
		   ancestors1: $ancestors_a, ancestors2: $ancestors_b,
		   has_children: (($b.children.nodes | length) > 0 or $b.children.pageInfo.hasNextPage)} end
	' <<<"$1" 2>/dev/null) || {
		jq -cn '{error: "Hierarchy validation failed closed: Linear returned incomplete issue, child or ancestry facts."}' >&2
		return 1
	}
	printf '%s' "$facts"
}

# blocking_level_ok FACTS: the single acceptance predicate.
blocking_level_ok() {
	jq -e '
		. as $f
		| (($f.ancestors1 | index($f.blocked)) == null and ($f.ancestors2 | index($f.blocker)) == null)
		  and (.parent1 == .parent2 or (.has_children | not))
	' <<<"$1" >/dev/null
}

# blocking_level_violation_message FACTS: JSON rejection with its stable error category.
blocking_level_violation_message() {
	jq -c '
		. as $f
		| if ($f.ancestors1 | index($f.blocked)) != null or ($f.ancestors2 | index($f.blocker)) != null then
		    {error: "Hierarchy violation: \(.blocker) and \(.blocked) form an ancestor/descendant pair. An issue cannot carry a blocking relation against its own ancestor; the hierarchy already encodes that dependency. Use --related for traceability."}
		  else {error: "Blocking-level violation: \(.blocker) and \(.blocked) need the same direct parent, both must be top-level, or the blocked issue must be a leaf."}
		  end
	' <<<"$1"
}

# --- Reach guard (create-time filing bar) ---
#
# The reply grammar makes filing the cheap disposition: `Declined:` needs a
# disproof a gate checks, `Tracked: <ID>` needs only an issue to exist, so a
# hypothetical gets an issue where it should have got a decline. Every Linear
# `Tracked:` passes through this create, so it is where the filing bar can be
# held on this tracker; a `Tracked: #<n>` filed with `gh issue create` never
# reaches here and is unguarded. Unless LINEAR_REQUIRE_REACH
# (kendex.settings.toml [env]) is set empty, a create refuses, before any API
# call, a description with no `Reached by:` line — an unsubstituted
# placeholder and a null token counting as absent. Whether the line names a
# real producer is the author's judgement, not this guard's. Unset is on, the
# value the settings template ships.
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
	[ -n "${LINEAR_REQUIRE_REACH-1}" ] || return 0

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

# require_issue_header_shape DESCRIPTION [STORED] — 0 to proceed, 1 + a JSON
# error on stderr naming the line and its length. The issue template puts the
# outcome first, after an optional owner action line, and keeps each header to
# one short sentence; any other header opening, or a header over
# ISSUE_HEADER_MAX characters, is refused. It is held by the reach guard's
# setting so one key turns the filing bar on or off.
#
# STORED is the issue's current description, which `issues update` passes. A
# body equal to it apart from a leading owner action line only places,
# replaces or removes that line, as the mailbox owner ask, its rollback and
# close and the oversee-watch repair do; it is judged on that line's length
# alone, so an ask on a body filed in the older header-first form is written.
# Every other body, and every body with no STORED, takes the full check.
ISSUE_HEADER_MAX=500
require_issue_header_shape() {
	[[ -n ${LINEAR_REQUIRE_REACH-1} ]] || return 0

	local refusal parsed has_stored=false
	[[ $# -lt 2 ]] || has_stored=true
	parsed=$(done_when_parse "$1" '[]') || return 1
	refusal=$(jq -cn --arg desc "$1" --arg stored "${2-}" --argjson has_stored "$has_stored" \
		--argjson max "$ISSUE_HEADER_MAX" --argjson parsed "$parsed" '
		def header: test("^(\\*\\*[^*]+(\\*\\*:|:\\*\\*)|[Rr]eached [Bb]y:)");
		def owner_action: test("^\\*\\*[^*\\s]+, what you do:\\*\\* [^\\r\\n]*$");
		def without_owner_action: gsub("\r\n"; "\n") | split("\n")
			| if (.[0] // "" | owner_action) then .[1:] | if .[0] == "" then .[1:] else . end else . end
			| join("\n");
		def long_header($max): {error: "issue-header-length line=\(.line) length=\(.length) max=\($max)\nRefusing an issue body with a header line over \($max) characters. Keep each header to one short sentence and move the detail under a section.",
			rule: "issue-header-length", line: .line, length: .length};
		[$desc | gsub("\r\n"; "\n") | split("\n") | to_entries[]
			| {line: (.key + 1), length: (.value | length), text: .value}] as $lines
		| ($has_stored and ($desc | without_owner_action) == ($stored | without_owner_action)) as $moves_action
		| [$lines[] | select(.text | test("\\S"))] as $content
		| ($content | if length > 0 and (.[0].text | owner_action) then .[1:] else . end | first) as $first
		| ([$lines[] | select((.text | header) and .length > $max)] | first) as $long
		| ([$parsed.boxes[] | select(.post_merge)
			| if (.trigger | test("^release(?: |$)")) and .trigger_kind != "release" then
				{rule: "post-merge-release-repository", box: .number, fix: "Use Trigger: release OWNER/REPO TAG-GLOB."}
			  elif .deadline_rule != null then
				{rule: "post-merge-deadline", box: .number, fix: "Use Deadline: +Nh with N from 1 through 72, or after a merge or time trigger a real UTC time in YYYY-MM-DDTHH:MM:SSZ form at most 72 hours after it."}
			  else empty end] | first) as $post
		| if $moves_action then
			([$lines[:1][] | select((.text | owner_action) and .length > $max) | long_header($max)] | first // empty)
		  elif $first != null and ($first.text | header) then
			{error: "issue-header-opening line=\($first.line) length=\($first.length)\nRefusing an issue body that opens with a header line. Open with the outcome sentence; the **Key**: and Reached by: headers follow it.",
			 rule: "issue-header-opening", line: $first.line, length: $first.length}
		  elif $long != null then $long | long_header($max)
		  elif $post != null then $post + {error: ($post.rule + " box=\($post.box)\nfix=" + $post.fix)}
		  else empty end') || return 1
	if [ -n "$refusal" ]; then
		printf '%s\n' "$refusal" >&2
		return 1
	fi
}

# One parser owns checklist numbering, ticking, triggers, and post-merge deadlines.
# merge-pr supplies GitHub's mergedAt; watch and reconcile consume the same
# per-box deadline in the description without a second tracker field.
# `child_box` is the number of a parent's one box, "Every child Done or
# cancelled" (project-management parent-issue-template.md), or null; a
# container's closer ticks it. `container_open_boxes` lists every other box
# still open or missing its Evidence: on a container, an outcome that belongs
# in its own child item.
# Usage: done_when_parse DESCRIPTION MET_JSON [MERGED_AT] [EVIDENCE_JSON]
done_when_parse() {
    local evidence='{}'
    [[ $# -lt 4 ]] || evidence="$4"
    jq -cn --arg desc "$1" --argjson met "$2" --arg merged "${3:-}" --argjson evidence "$evidence" '
        def utc_epoch:
            . as $stamp
            | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then
                (try (fromdateiso8601 | select((todateiso8601) == $stamp)) catch null) // null
              else null end;
        ($merged | if . == "" then null else utc_epoch end) as $merge_epoch
        | ($desc | gsub("\r\n"; "\n") | split("\n")) as $lines
        | reduce range(0; $lines | length) as $i
            ({out: [], section: false, boxes: [], ticked: 0, changed: false, skip: -1};
            $lines[$i] as $line
            | if $i == .skip then . else
            (if ($line | test("^## Done when\\s*$")) then .section = true
             elif ($line | startswith("## ")) then .section = false
             else . end)
            | if .section and ($line | test("^\\s*[-*] \\[[ xX]\\](\\s|$)")) then
                ((.boxes | length) + 1) as $n
                | ($line | test("^\\s*[-*] \\[ \\]")) as $open
                | ($met == "all" or ($met | any(.[]; . == $n))) as $selected
                | ($open and $selected) as $tick
                | ($line | capture("^(?<indent>[ \t]*)").indent) as $indent
                | (($lines[$i + 1] // "" | try capture("^(?<indent>[ \t]+)Evidence:[ \t]*(?<text>.*)$") catch null) // null) as $following
                | (if $following != null and ($following.indent | length) > ($indent | length) then $following.text else "" end) as $stored_evidence
                | (if $selected then $evidence[$n | tostring] // (if $open then "" else $stored_evidence end) else $stored_evidence end) as $proof
                | ($line | sub("^\\s*[-*] \\[[ xX]\\]\\s*"; "")) as $body
                | ($body | startswith("Post-merge:")) as $post
                | (if $post then
                    (try ($body | capture("^Post-merge: (?<reading>.+); Where: (?<where>.+); Why after merge: (?<why>.+?); (?:Trigger: (?<trigger>[^;]+); )?Deadline: (?<deadline>[^;]+)$")) catch null) // {}
                   else {} end) as $fields
                | ($fields.trigger // "merge"
                    | gsub("\\\\(?<punct>[\\x21-\\x2f\\x3a-\\x40\\x5b-\\x60\\x7b-\\x7e])"; .punct)) as $trigger
                | (if $trigger == "merge" then {trigger_kind: "merge", trigger_epoch: $merge_epoch}
                   elif ($trigger | utc_epoch) != null then {trigger_kind: "time", trigger_epoch: ($trigger | utc_epoch)}
                   else ((try ($trigger | capture("^release (?<release_repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) (?<release_glob>[^ ;]+)$")) catch null) // {})
                        | if has("release_repo") then . + {trigger_kind: "release", trigger_epoch: null} else {} end
                   end) as $trigger_fields
                | ($fields.deadline // "" | utc_epoch) as $deadline_epoch
                | ((try ($fields.deadline | capture("^\\+(?<hours>[0-9]+)h$").hours | tonumber) catch null) // null) as $deadline_hours
                # The one Deadline rule filing and completion both read: +Nh
                # counts from any trigger; an absolute time follows a merge or
                # time trigger by at most 72 hours, judged once its epoch is known.
                | (if $deadline_hours != null then
                      (if $deadline_hours < 1 or $deadline_hours > 72 then "post-merge-window" else null end)
                   elif $deadline_epoch == null or $trigger_fields.trigger_kind == "release" then "post-merge-fields"
                   elif $trigger_fields.trigger_epoch != null
                        and ($deadline_epoch <= $trigger_fields.trigger_epoch or $deadline_epoch > ($trigger_fields.trigger_epoch + 259200)) then "post-merge-window"
                   else null end) as $deadline_rule
                | .boxes += [({number: $n, checked: (($open | not) or $tick), post_merge: $post,
                               text: $body, evidence: $proof, deadline_epoch: $deadline_epoch, deadline_hours: $deadline_hours,
                               deadline_rule: $deadline_rule} + $fields + {trigger: $trigger} + $trigger_fields)]
                | if $tick then .out += [$line | sub("\\[ \\]"; "[x]")] | .ticked += 1
                  else .out += [$line] end
                | if $selected and ($evidence | has($n | tostring)) then
                    .out += [$indent + "  Evidence: " + $proof] | .changed = true
                    | if $following != null and ($following.indent | length) > ($indent | length) then .skip = ($i + 1) else . end
                  else . end
              else .out += [$line] end end)
        | . as $r
        | {description: ($r.out | join("\n")), ticked: $r.ticked, changed: ($r.changed or $r.ticked > 0), boxes: $r.boxes,
           unmet_branch_boxes: [$r.boxes[] | select(.checked == false and .post_merge == false) | .number],
           missing_evidence_boxes: [$r.boxes[] | select(.checked and (.evidence | test("\\S") | not)) | .number],
           missing: (if $met == "all" then [] else [$met[] | select(. > ($r.boxes | length))] | unique end),
           errors: [$r.boxes[] | select(.post_merge)
                | if .trigger_kind == null or ((.why // "") | contains("; Trigger:")) or any([.reading, .where, .why][]; (. // "") | test("\\S") | not)
                     or .deadline_rule == "post-merge-fields"
                    then {box: .number, rule: "post-merge-fields"}
                  elif .deadline_rule != null
                       or (.trigger_kind != "release" and $merged != "" and ($merge_epoch == null or (.trigger_kind == "time" and .trigger_epoch < $merge_epoch)))
                    then {box: .number, rule: "post-merge-window"}
                  else empty end]}
        | .child_box = ([.boxes[] | select(.text | test("^every child (is )?done or cancell?ed\\.?\\s*$"; "i")) | .number] | first)
        | .missing_evidence_boxes as $missing | .child_box as $child
        | .container_open_boxes = [.boxes[] | select(.number != $child)
            | select((.checked | not) or (.number as $n | $missing | index($n)) != null) | .number]
        | .completion_state = (if (.errors | length) > 0 or (.unmet_branch_boxes | length) > 0 or (.missing_evidence_boxes | length) > 0 then null
            elif any(.boxes[]; .post_merge and (.checked | not)) then "Verifying" else "Done" end)'
}
