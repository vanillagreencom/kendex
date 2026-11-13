#!/bin/bash

set -euo pipefail

# Expected completion state(s) for an issue, keyed by its ROLE in the validation.
#
#   bundle-child  A sub-issue processed under its parent session as part of
#                 the review audit's in-PR bundle (`in_pr_bundle`). A
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
# --summary` at completion time, after this validation runs. Its row also
# reports the checklist facts container-close decides the close on; they do
# not gate `ok`, because that decision, and the remedy for each refusal, is
# container-close's.
#
# A session root's `ok` also needs its description's checklist to parse with
# no errors; its row lists each error's box number, rule and box text.
#
# Output shape is stable: {id, state, state_type, state_ok, has_summary, ok},
# plus the container's checklist fields or the session root's errors.
build_completion_validation_result() {
	local issue_id="$1"
	local state="$2"
	# shellcheck disable=SC2034  # provenance only; role (not parent_id) decides expected state
	local parent_id="$3"
	local has_summary="$4"
	local role="${5:-session-root}"
	local state_type="${6:-}"
	local description="${7:-}" checklist='{}'
	local state_ok="false"
	local ok="false"

	if [[ "$role" == "container" ]]; then
		if [[ -n "$state_type" && "$state_type" != "canceled" ]]; then
			state_ok="true"
			ok="true"
		fi
		checklist=$(done_when_parse "$description" '[]') || return 1
	else
		if completion_state_matches "$state" "$role" "$state_type"; then
			state_ok="true"
		fi
		if [[ "$role" == "bundle-child" && "$state_ok" == true ]]; then
			checklist=$(done_when_parse "$description" '[]') || return 1
			# A started child passes on the parser's own completion answer, so
			# the post-merge `issues complete` cannot refuse a child this passed.
			state_ok=$(jq -r --arg state "$state" '
				if $state == "Done" then .completion_state == "Done"
				else (.boxes | length) > 0 and .completion_state != null end
			' <<<"$checklist") || return 1
		elif [[ "$role" == "session-root" ]]; then
			# With no merge time the parser reports only the errors the
			# description alone decides; they refuse the root here, before
			# submission, rather than at the post-merge `issues complete`.
			checklist=$(done_when_parse "$description" '[]') || return 1
		fi

		if [[ "$state_ok" == "true" && "$has_summary" == "true" ]] \
			&& jq -e '(.errors // []) == []' <<<"$checklist" >/dev/null; then
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
		--arg role "$role" \
		--argjson checklist "$checklist" \
		'{id: $id, state: $state, state_type: $state_type, state_ok: $state_ok, has_summary: $has_summary, ok: $ok}
		| if $role == "container" then
			. + ($checklist | {errors, unmet_branch_boxes, missing_evidence_boxes, child_box, container_open_boxes})
		  elif $role == "session-root" then
			. + {errors: [$checklist.errors[] | .box as $n
				| . + {text: ([$checklist.boxes[] | select(.number == $n) | .text] | first)}]}
		  else . end'
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
# call, a description with no `Reached by:` line or no `Supersession:`
# record — an unsubstituted placeholder and a null token counting as absent.
# Whether the line names a real producer is the author's judgement, not this
# guard's. Unset is on, the value the settings template ships.
# The reach bar is project-management SKILL.md, § Disposition; the
# supersession form is project-management audit-output.md, § ISSUE Mode.

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

	local supersession
	supersession=$(issue_marked_value "$description" '[Ss]upersession')
	if ! issue_supersession_valid "$supersession"; then
		jq -cn --arg rule "$SUPERSESSION_RULE" --arg value "$supersession" \
			'{error: ((if $value == "" then "Refusing to create an issue with no \"Supersession:\" line. " else "Refusing to create an issue whose \"Supersession:\" line is no supersession record: \"" + $value + "\". " end) + $rule + " Write the line under Filing record, as project-management issue-description-template.md does, and retry.")}' >&2
		return 1
	fi

	return 0
}

# The supersession half of the filing bar: the record the comparison that
# admitted the filing wrote (project-management tpm-audit § 6 and § 14),
# checked for presence and shape only. Whether the search was adequate is
# the comparison's judgement, not this guard's.
SUPERSESSION_RULE='A filing records the search that admitted it: each matched open item as "superseded", "duplicate" or "re-scoped" with its identifier, entries separated by ";", or "none found; searched: <terms>".'

# Both forms are read lowercased. An entry's identifier is a Linear issue
# identifier; text after it is the author's note on the action.
SUPERSESSION_NONE='^none[[:space:]]+found[^[:alnum:]]*searched[[:space:]]*:?[[:space:]]*(.*)$'
SUPERSESSION_ENTRY='^(superseded|duplicate|re-scoped)[[:space:]]+[a-z][a-z0-9]*-[0-9]+([^[:alnum:]-]|$)'

# issue_supersession_valid VALUE — 0 when VALUE, as issue_marked_value
# returns it, is a "none found" record naming its searched terms or one or
# more action entries; 1 otherwise, an empty VALUE included. Searched terms
# that are a placeholder or a null token name no search.
issue_supersession_valid() {
	local lower entry terms seen=false
	local -a entries=()
	if ! lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') || [ -z "$lower" ]; then
		return 1
	fi

	if [[ "$lower" =~ $SUPERSESSION_NONE ]]; then
		terms="${BASH_REMATCH[1]}"
		terms="${terms%"${terms##*[![:space:]]}"}"
		[ -n "$terms" ] || return 1
		[[ ! "$terms" =~ $REACH_ABSENT_TOKENS ]] || return 1
		[[ ! "$terms" =~ ^\[[a-z_]+\]$ ]] || return 1
		return 0
	fi

	IFS=';' read -ra entries <<<"$lower"
	for entry in ${entries[@]+"${entries[@]}"}; do
		entry="${entry#"${entry%%[![:space:]]*}"}"
		[ -n "$entry" ] || continue
		[[ "$entry" =~ $SUPERSESSION_ENTRY ]] || return 1
		seen=true
	done
	[ "$seen" = true ]
}

# require_issue_header_shape DESCRIPTION [STORED] — 0 to proceed, 1 + a JSON
# error on stderr for the caller to return on. A checkbox outside `## Done
# when` is refused, since no completion reader numbers it. A post-merge
# Done-when box whose release trigger names no repository, or whose Deadline
# is outside the window completion enforces, is refused. Nonempty quoted
# Story and Why blocks must open an authored body after an optional owner
# action line: overseer create calls that capture stdout can miss a stderr
# advisory and file no explanation.
# Linear accepts arbitrary text, so this caller holds the opening requirement.
# A header over ISSUE_HEADER_MAX characters prints one advisory on stderr and
# the write proceeds, as does an opening holding machine detail: the
# communication package keeps message-format checks advisory.
# A refused body prints the refusal alone. The reach guard's setting turns the
# filing bar on or off.
#
# STORED is the issue's current description, which `issues update` passes. A
# body equal to it apart from a leading owner action line only places,
# replaces or removes that line, as the mailbox owner ask, its rollback and
# close and the oversee-watch repair do; it is judged on that line's length
# alone, so an ask on a body filed in the older header-first form is written
# without notes on text its writer did not author.
# Every other body, and every body with no STORED, takes the full check.
ISSUE_HEADER_MAX=500
require_issue_header_shape() {
	[[ -n ${LINEAR_REQUIRE_REACH-1} ]] || return 0

	local verdict parsed has_stored=false
	[[ $# -lt 2 ]] || has_stored=true
	parsed=$(done_when_parse "$1" '[]') || return 1
	# One line per advisory, or the refusal alone as one JSON line.
	verdict=$(jq -rn --arg desc "$1" --arg stored "${2-}" --argjson has_stored "$has_stored" \
		--argjson max "$ISSUE_HEADER_MAX" --argjson parsed "$parsed" '
		def header: test("^(\\*\\*[^*]+(\\*\\*:|:\\*\\*)|[Rr]eached [Bb]y:)");
		def owner_action: test("^\\*\\*[^*\\s]+, what you do:\\*\\* [^\\r\\n]*$");
		def without_owner_action: gsub("\r\n"; "\n") | split("\n")
			| if (.[0] // "" | owner_action) then .[1:] | if .[0] == "" then .[1:] else . end else . end
			| join("\n");
		# Project-management templates produce the two quoted blocks. This checks
		# their boundaries and values; authors and reviewers judge their prose.
		def opening_value:
			gsub("\n> ?"; " ") | gsub("^\\s+|\\s+$"; "")
			| length > 0 and (test("^(\\[[^]\\r\\n]+\\]\\s*)+$") | not);
		def opening_parts:
			(try capture("^> \\*\\*Story:\\*\\*(?<story>[^\\n]*(?:\\n>[^\\n]*)*)\\n[ \\t]*\\n(?:[ \\t]*\\n)*> \\*\\*Why this matters:\\*\\*(?<why>[^\\n]*(?:\\n>[^\\n]*)*)(?:\\n[ \\t]*\\n(?:[ \\t]*\\n)*(?:#{1,6}[ \\t]+[\\s\\S]*)?|\\n?)$") catch null) // null;
		def opening: opening_parts | . != null and (.story | opening_value) and (.why | opening_value);
		def long_header($max): "linear: advisory=issue-header-length line=\(.line) length=\(.length) max=\($max) fix=Keep each header to one short sentence and move the detail under a section.";
		# Machine detail the owner, who reads only the opening, cannot use. Only
		# the opening is read: the body keeps its paths and ids. A slack-ts is a
		# message ts, epoch seconds and six digits (docs.slack.dev
		# messaging/retrieving-messages); a mailbox-id is what lane-mail mints,
		# epoch seconds, pid and $RANDOM. A file path has a slash and a
		# letter-led extension, or starts at a root; a URL is not one.
		def opening_detail: [
			{kind: "file-path", pattern: "(?<![\\w:/.~-])(?:(?:~|\\.{1,2})?/[\\w.-]+(?:/[\\w.-]+)*|(?:[\\w.-]+/)+[\\w.-]*\\w\\.[A-Za-z][A-Za-z0-9]{0,7}\\b)"},
			{kind: "slack-ts", pattern: "(?<![\\w.])[0-9]{10}\\.[0-9]{6}(?!\\w|\\.[0-9])"},
			{kind: "mailbox-id", pattern: "(?<![\\w-])[0-9]{10}-[0-9]+-[0-9]+(?![\\w-])"},
			{kind: "utc-time", pattern: "\\b[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\\.[0-9]+)?)?(?:Z|[ ]?UTC)\\b"}];
		def opening_detail_advice($line):
			(.story + "\n" + .why) as $text
			| [opening_detail[] | .pattern as $p | select($text | test($p)) | .kind]
			| select(length > 0)
			| "linear: advisory=issue-opening-detail line=\($line) kinds=\(join(",")) fix=Write the opening for the owner: project-management templates/issue-description-template.md, communication references/reports.md § Work-item descriptions and comments.";
		[$desc | gsub("\r\n"; "\n") | split("\n") | to_entries[]
			| {line: (.key + 1), length: (.value | length), text: .value}] as $lines
		| ($has_stored and ($desc | without_owner_action) == ($stored | without_owner_action)) as $moves_action
		| [$lines[] | select(.text | test("\\S"))] as $content
		| ($content | if length > 0 and (.[0].text | owner_action) then .[1:] else . end | first) as $first
		| [$lines[] | select((.text | header) or (.text | startswith("> **Why this matters:**")))
			| .length -= (if (.text | startswith("> ")) then 2 else 0 end)
			| select(.length > $max)] as $long
		| ([$parsed.boxes[] | select(.post_merge)
			| if (.trigger | test("^release(?: |$)")) and .trigger_kind != "release" then
				{rule: "post-merge-release-repository", box: .number, fix: "Use Trigger: release OWNER/REPO TAG-GLOB."}
			  elif .deadline_rule != null then
				{rule: "post-merge-deadline", box: .number, fix: "Use Deadline: +Nh with N from 1 through 72, or after a merge or time trigger a real UTC time in YYYY-MM-DDTHH:MM:SSZ form at most 72 hours after it."}
			  elif .reading_rule != null then
				{rule: .reading_rule, box: .number, fix: "Write a numeric reading as FIGURE COMPARATOR NUMBER UNIT, such as p95 create latency <= 300 ms."}
			  else empty end] | first) as $post
		| ($parsed.outside_boxes | first) as $outside
		| if $moves_action then
			$lines[:1][] | select((.text | owner_action) and .length > $max) | long_header($max)
		  elif $outside != null then
			{rule: "checkbox-outside-done-when", line: $outside.line, box: $outside.text, fix: "Move the box under ## Done when."}
			| . + {error: (.rule + " line=\(.line) box=\(.box)\nfix=" + .fix)} | tojson
		  elif $post != null then
			$post + {error: ($post.rule + " box=\($post.box)\nfix=" + $post.fix)} | tojson
		  elif ($lines | map(select($first != null and .line >= $first.line) | .text) | join("\n") | opening | not) then
			{rule: "issue-header-opening", line: ($first.line // 1),
			 fix: "Open with nonempty quoted Story and Why this matters blocks, separated by an unquoted blank line, before a blank line and the first heading."}
			| . + {error: (.rule + " line=\(.line)\nfix=" + .fix)} | tojson
		  else
			($lines | map(select(.line >= $first.line) | .text) | join("\n") | opening_parts | opening_detail_advice($first.line)),
			($long[] | long_header($max))
		  end') || return 1
	[[ -n $verdict ]] || return 0
	printf '%s\n' "$verdict" >&2
	# A refusal is a JSON line; every advisory line starts with `linear:`.
	[[ $verdict != "{"* ]]
}

# One parser owns checklist numbering, ticking, triggers, and post-merge deadlines.
# merge-pr supplies GitHub's mergedAt; watch and reconcile consume the same
# per-box deadline in the description without a second tracker field.
# `child_box` is the number of a parent's one box, "Every child Done or
# cancelled" (project-management parent-issue-template.md), or null; a
# container's closer ticks it. `container_open_boxes` lists every other box
# still open or missing its Evidence: on a container, an outcome that belongs
# in its own child item.
# `outside_boxes` lists each checkbox outside the section by line, so the
# write check and every completion reader see the same boxes: one under a
# `## Post-merge` heading is otherwise read by nothing (FLT-1650). A quoted
# line or a line inside a fenced block is not a box there; the section's own
# grammar is left as it was.
# A post-merge reading holding a comparator before a number is numeric and
# must name its figure, comparator, number and unit; any other reading is an
# outcome check whose pass condition is its text. RETIRE_JSON maps a box
# number to `waived` or `superseded`, with its EVIDENCE_JSON text as the
# authority and reason, or the replacement ID and the criterion it now holds.
# A retired box loses its checkbox and keeps its text, so it is never read as
# passed and holds no completion state. A ticked box cannot retire, and an
# open branch box still refuses as unmet: only an open post-merge box retires.
# A retired line followed by its deeper Reason: or Replacement: line keeps its
# number as a slot no selection reaches, so every later box keeps the number a
# caller read before the retirement. Naming the same retirement again is a
# no-op, which lets a retry of a written completion finish; any other
# selection of a slot refuses as done-when-retirement.
# Usage: done_when_parse DESCRIPTION MET_JSON [MERGED_AT] [EVIDENCE_JSON] [RETIRE_JSON]
done_when_parse() {
    local evidence='{}' retire='{}'
    [[ $# -lt 4 ]] || evidence="$4"
    [[ $# -lt 5 ]] || retire="$5"
    jq -cn --arg desc "$1" --argjson met "$2" --arg merged "${3:-}" --argjson evidence "$evidence" --argjson retire "$retire" '
        def fence_run: (try capture("^[ \\t]*(?<run>`{3,}|~{3,})").run catch null) // null;
        def utc_epoch:
            . as $stamp
            | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then
                (try (fromdateiso8601 | select((todateiso8601) == $stamp)) catch null) // null
              else null end;
        ($merged | if . == "" then null else utc_epoch end) as $merge_epoch
        | ($desc | gsub("\r\n"; "\n") | split("\n")) as $lines
        | reduce range(0; $lines | length) as $i
            ({out: [], section: false, boxes: [], slots: 0, retired: [], outside: [], fence: null, ticked: 0, changed: false, skip: -1};
            $lines[$i] as $line
            | if $i == .skip then . else
            (if ($line | test("^## Done when\\s*$")) then .section = true
             elif ($line | startswith("## ")) then .section = false
             else . end)
            | ($line | fence_run) as $run
            | if .fence != null then
                (if $run != null and $run[0:1] == .fence[0:1] and ($run | length) >= (.fence | length)
                    and ($line | test("^[ \\t]*[`~]+[ \\t]*$")) then .fence = null else . end)
              elif $run != null then .fence = $run
              elif (.section | not) and ($line | test("^\\s*[-*] \\[[ xX]\\](\\s|$)")) then
                .outside += [{line: ($i + 1), checked: ($line | test("^\\s*[-*] \\[[xX]\\]")),
                              text: ($line | sub("^\\s*[-*] \\[[ xX]\\]\\s*"; ""))}]
              else . end
            # A slot-shaped line without its deeper reason line is an ordinary
            # line: every branch yields one value, so the reduce state is never
            # emptied by a failed match.
            | (if .section | not then null else
                ((try ($line | capture("^(?<indent>[ \t]*)[-*] (?<kind>Waived|Superseded): \\S")) catch null) // null) as $slot
                | if $slot == null then null else
                    (($lines[$i + 1] // "" | try capture("^(?<indent>[ \t]+)" + (if $slot.kind == "Waived" then "Reason" else "Replacement" end) + ": (?<text>.*)$") catch null) // null) as $reason
                    | if $reason != null and ($reason.indent | length) > ($slot.indent | length)
                      then {kind: ($slot.kind | ascii_downcase), text: $reason.text} else null end end end) as $slot_record
            | if $slot_record != null then
                .slots += 1 | .retired += [$slot_record + {number: .slots}] | .out += [$line]
              elif .section and ($line | test("^\\s*[-*] \\[[ xX]\\](\\s|$)")) then
                (.slots + 1) as $n
                | .slots = $n
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
                | (($fields.reading // "")
                    | if test("(<=|>=|<|>|=)\\s*-?[0-9]") then
                        capture("^(?<figure>.*?)\\s*(?<comparator><=|>=|<|>|=)\\s*(?<value>-?[0-9]+(?:\\.[0-9]+)?)(?:\\s*(?<unit>[^\\s0-9.,;:<>=][^\\s,;]*))?")
                        | .value |= tonumber
                      else null end) as $numeric
                | (if $numeric != null and (($numeric.figure | test("\\S") | not) or $numeric.unit == null)
                   then "post-merge-numeric" else null end) as $reading_rule
                | ($retire[$n | tostring] // null
                    | if . == null then null else
                        {kind: ., text: ($evidence[$n | tostring] // "")}
                        | if .kind == "superseded" then
                            . + ((try (.text | capture("^(?<replacement>[A-Z][A-Z0-9]*-[1-9][0-9]*) (?<criterion>\\S.*)$")) catch null) // {})
                          else . end end) as $retired
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
                               deadline_rule: $deadline_rule, numeric: $numeric, reading_rule: $reading_rule,
                               retired: $retired} + $fields + {trigger: $trigger} + $trigger_fields)]
                | if $retired != null then
                    .out += [($line | sub("\\[ \\]\\s*"; (if $retired.kind == "waived" then "Waived: " else "Superseded: " end))),
                             $indent + (if $retired.kind == "waived" then "  Reason: " else "  Replacement: " end) + $retired.text]
                    | .changed = true
                  elif $tick then .out += [$line | sub("\\[ \\]"; "[x]")] | .ticked += 1
                  else .out += [$line] end
                | if $selected and ($evidence | has($n | tostring)) then
                    .out += [$indent + "  Evidence: " + $proof] | .changed = true
                    | if $following != null and ($following.indent | length) > ($indent | length) then .skip = ($i + 1) else . end
                  else . end
              else .out += [$line] end end)
        | . as $r
        | {description: ($r.out | join("\n")), ticked: $r.ticked, changed: ($r.changed or $r.ticked > 0), boxes: $r.boxes,
           outside_boxes: $r.outside,
           unmet_branch_boxes: [$r.boxes[] | select(.checked == false and .post_merge == false) | .number],
           missing_evidence_boxes: [$r.boxes[] | select(.checked and (.evidence | test("\\S") | not)) | .number],
           missing: ([if $met == "all" then empty else $met[] end, ($retire | keys[] | tonumber)]
                | map(select(. > $r.slots)) | unique),
           errors: ([$r.boxes[] | select(.post_merge)
                | if .trigger_kind == null or ((.why // "") | contains("; Trigger:")) or any([.reading, .where, .why][]; (. // "") | test("\\S") | not)
                     or .deadline_rule == "post-merge-fields"
                    then {box: .number, rule: "post-merge-fields"}
                  elif .deadline_rule != null
                       or (.trigger_kind != "release" and $merged != "" and ($merge_epoch == null or (.trigger_kind == "time" and .trigger_epoch < $merge_epoch)))
                    then {box: .number, rule: "post-merge-window"}
                  elif .reading_rule != null then {box: .number, rule: .reading_rule}
                  else empty end]
                + [$r.boxes[] | select(.retired != null)
                    | select(.checked or (.retired.text | test("\\S") | not)
                        or (.retired.kind == "superseded" and (.retired | has("replacement") | not)))
                    | {box: .number, rule: "done-when-retirement"}]
                + [$r.retired[] | . as $s | ($s.number | tostring) as $key
                    | select(($met != "all" and any($met[]; . == $s.number))
                        or ($retire | has($key) and ($retire[$key] != $s.kind or ($evidence[$key] // "") != $s.text)))
                    | {box: $s.number, rule: "done-when-retirement"}])}
        | .child_box = ([.boxes[] | select(.text | test("^every child (is )?done or cancell?ed\\.?\\s*$"; "i")) | .number] | first)
        | .missing_evidence_boxes as $missing | .child_box as $child
        | .container_open_boxes = [.boxes[] | select(.number != $child)
            | select((.checked | not) or (.number as $n | $missing | index($n)) != null) | .number]
        | .completion_state = (if (.errors | length) > 0 or (.unmet_branch_boxes | length) > 0 or (.missing_evidence_boxes | length) > 0
                or any(.outside_boxes[]; .checked | not) then null
            elif any(.boxes[]; .post_merge and (.checked | not) and .retired == null) then "Verifying" else "Done" end)'
}
