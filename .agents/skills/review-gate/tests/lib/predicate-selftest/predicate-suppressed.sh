# shellcheck shell=bash
# Findings a reviewer writes into its OWN review body create no review
# thread, so the thread term reads zero and every other term is silent. The
# bodies below are the live Copilot shape, trailer and all: the block sits
# inside <details>, a bold "Previously missed (N)" line separates the groups
# without being an entry, and a "- **Files reviewed:**" list item follows the
# entries without joining them.
SUPP_FIRST='src/model/naming.ts:106'
SUPP_SECOND='src/ui/agents.tsx:257'
SUPP_ENTRIES="**$SUPP_FIRST**
* Blocking: a generated name can equal a row already carrying it.
**$SUPP_SECOND**
* Blocking: selected can exceed the list length after a lane exits."
supp_body() { # HEADING [ENTRIES]
  printf '### Needs a closer look\n\nUnresolved selection and naming defects.\n\n<details>\n<summary>Review details</summary>\n\n%s\n\n**Previously missed (2)** — in code that has not changed since the last review.\n\n%s\n\n- **Files reviewed:** 26/26 changed files\n- **Comments generated:** 0 new\n</details>\n' "$1" "${2-}"
}
supp_case() { # HEADING, ENTRIES, MIN_STATE, VERDICT, NAME
  reset
  CFG_TRUSTED_LOGINS=""
  CFG_MIN_STATE="$3"
  CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
  reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body "$1" "$2")")"
  run "$5" "$4"
}
supp_carries() { # NAME, NEEDLE, HAYSTACK
  cases=$((cases + 1))
  case "$3" in
    *"$2"*) echo "ok    $1" ;;
    *)
      rg_message error selftest-suppressed-detail "$1" "FAIL  $1: '$2' missing from: $3" >&2
      failures=$((failures + 1))
      ;;
  esac
}
supp_omits() { # NAME, NEEDLE, HAYSTACK
  cases=$((cases + 1))
  case "$3" in
    *"$2"*)
      rg_message error selftest-suppressed-detail "$1" "FAIL  $1: '$2' present in: $3" >&2
      failures=$((failures + 1))
      ;;
    *) echo "ok    $1" ;;
  esac
}

# The deliverable: the count and the file:line list, in the status detail a
# reader sees and in the log that holds the whole list.
supp_case '### Suppressed comments (2)' "$SUPP_ENTRIES" any suppressed-findings \
  "a counted suppressed block at head fails the gate"
supp_carries "the detail names the finding count" "detail=2 suppressed finding(s)" "$LAST_LINE"
supp_carries "the detail names the first file:line" "$SUPP_FIRST" "$LAST_LINE"
supp_carries "the detail names the second file:line" "$SUPP_SECOND" "$LAST_LINE"
supp_carries "the log carries the file:line list whole" "$(printf '%s\n%s' "$SUPP_FIRST" "$SUPP_SECOND")" "$LAST_ERROR"

# The must-fail control: the same review, the same evidence, the block
# removed. It is what reds when the term over-matches, and it approves only
# because nothing else in the fixture blocks.
supp_case '### Review notes' "$SUPP_ENTRIES" any approved \
  "must-fail control: the same review with no suppressed block approves"

# Shape refusals. Neither degrades to a smaller number, and neither approves.
supp_case '### Suppressed comments (several)' "$SUPP_ENTRIES" any suppressed-findings \
  "a heading whose count is not a number refuses"
supp_carries "the unreadable-count detail says so" "names no readable count" "$LAST_LINE"

supp_case '### Suppressed comments (3)' "$SUPP_ENTRIES" any suppressed-findings \
  "a count disagreeing with the entries under it refuses"
supp_carries "the mismatch detail reports both numbers" \
  "declares 3 finding(s) but 2 entry line(s) parsed" "$LAST_LINE"

# The term reads the rows the evidence select accepts, BEFORE the min_state
# reduction: under min_state=approved a COMMENTED row is not evidence, so a
# term placed after the reduction would answer awaiting and let the findings
# it carries merge on the next evidence form.
supp_case '### Suppressed comments (2)' "$SUPP_ENTRIES" approved suppressed-findings \
  "a COMMENTED row's block counts under min_state=approved"

# Carried evidence carries its findings with it. Carry accepts a review row
# at an ANCESTOR when nothing reviewed the head, and its candidate select is
# this term's with `.commit_id != $sha` in place of `== $sha` — so the row
# whose body carries the block is itself an eligible carry candidate. Reading
# head alone would refuse at one commit and approve at the next with nothing
# reviewed at the new head.
supp_carry_case() { # STATUS, FILES, NAME
  reset
  CFG_TRUSTED_LOGINS=""
  CFG_MIN_STATE=any
  CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
  CFG_CARRY=docs
  CFG_CARRY_EXCLUDE=""
  reviews_set "$(review reviewer APPROVED "2026-08-02T18:00:00Z" "$OTHER" "$(supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES")")"
  compare_fix "$1" "$2"
  run "$3" suppressed-findings
}
SUPP_DOCS_DELTA="$(delta_file "README.md" modified '@@ -1 +1 @@
-old prose
+new prose')"
supp_carry_case ahead "[$SUPP_DOCS_DELTA]" \
  "a carried ancestor review's suppressed block still fails the gate"
supp_carries "the carried detail names the file:line list" "$SUPP_FIRST" "$LAST_LINE"
supp_carry_case identical '[]' \
  "an identical-tree carry brings the block with it"

# The control: with carry off, the same ancestor row is not evidence at all,
# so the gate answers awaiting and the rows above are proving carry, not the
# ancestor row's mere presence.
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
CFG_CARRY=""
reviews_set "$(review reviewer APPROVED "2026-08-02T18:00:00Z" "$OTHER" "$(supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES")")"
compare_fix ahead "[$SUPP_DOCS_DELTA]"
run "control: with carry off the same ancestor row is not evidence" awaiting

# A reviewer pastes the offending code under each entry, and this repo's
# snippets are full of shell comments. Without a fence state a '#' line
# inside the snippet reads as the heading that ends the block, and every
# entry after it is lost from the list the overseer wakes a lane with.
SUPP_FENCED_ENTRIES="**$SUPP_FIRST**
* Blocking: a generated name can equal a row already carrying it.
\`\`\`sh
# harness-smoke names the lane it could not reach
run_lane \"\$name\"
\`\`\`
**$SUPP_SECOND**
* Blocking: selected can exceed the list length after a lane exits."
supp_case '### Suppressed comments (2)' "$SUPP_FENCED_ENTRIES" any suppressed-findings \
  "a fenced snippet between two entries hides neither of them"
supp_carries "the fenced case counts both entries" "detail=2 suppressed finding(s)" "$LAST_LINE"
supp_carries "the fenced case names the entry after the snippet" "$SUPP_SECOND" "$LAST_LINE"

# The detail lands in a commit-status description review-writer.sh cuts at
# its 140th character, and that cut would land on the tail — destroying the
# very `+K more` that keeps a short list from reading as the whole one. Real
# repository paths are long enough to reach it, so the budget is checked
# against the finished string rather than the bare name list.
SUPP_LONG='skills/review-gate/tests/lib/predicate-selftest/predicate-suppressed.sh:121'
supp_budget_case() { # ENTRY_ONE, ENTRY_TWO, NAME
  reset
  CFG_TRUSTED_LOGINS=""
  CFG_MIN_STATE=any
  CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
  reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (2)' "**$1**
* Blocking: the first finding.
**$2**
* Blocking: the second finding.")")"
  run "$3" suppressed-findings
  SUPP_DETAIL="${LAST_LINE#verdict=* detail=}"
}
supp_fits() { # NAME
  cases=$((cases + 1))
  if [ "${#SUPP_DETAIL}" -le 140 ]; then
    echo "ok    $1"
  else
    rg_message error selftest-suppressed-budget "$1" "FAIL  $1: detail is ${#SUPP_DETAIL} characters, past the description budget: $SUPP_DETAIL" >&2
    failures=$((failures + 1))
  fi
}

supp_budget_case "$SUPP_FIRST" "$SUPP_LONG" \
  "an entry that would overshoot the description budget is counted, not named"
supp_fits "the two-entry detail fits the description budget"
supp_carries "it still names the entry that fits" "$SUPP_FIRST" "$SUPP_DETAIL"
supp_carries "it counts the entry it dropped" "+1 more" "$SUPP_DETAIL"
supp_omits "it does not name the entry it dropped" "$SUPP_LONG" "$SUPP_DETAIL"

# The degenerate arm: not even the first entry fits, so the detail counts
# every finding rather than showing half a path.
supp_budget_case "$SUPP_LONG" "$SUPP_LONG" \
  "a first entry too long to fit leaves a bare count, never half a path"
supp_fits "the degenerate detail fits the description budget"
supp_carries "the degenerate detail counts every finding" "+2 more" "$SUPP_DETAIL"
supp_omits "the degenerate detail names no path" "predicate-suppressed.sh" "$SUPP_DETAIL"

# Fence state ahead of the block must not be able to hide it. A reviewer
# quoting this repository's own markdown wraps the snippet in four backticks
# so three-backtick fences can sit inside, and an unbalanced-looking run of
# fence lines before the heading is the ordinary result. The heading is the
# sentinel: it is read whatever the fence state, and it closes any fence it
# finds open, so nothing earlier in the body can mask the block that follows.
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(printf 'Review prose quoting a markdown file.\n\n````markdown\n```\n````\n\n### Suppressed comments (1)\n\n**%s**\n* Blocking: a real finding.\n' "$SUPP_FIRST")")"
run "a fence run before the heading cannot hide the block" suppressed-findings
supp_carries "the masked-block detail names the count" "detail=1 suppressed finding(s)" "$LAST_LINE"
supp_carries "the masked-block detail names the file:line" "$SUPP_FIRST" "$LAST_LINE"

# ------------------------------------------------- the disposition replies ---
# A body finding carries no thread, so its reply is a PR comment by the
# author: one that binds this head and opens a line with the entry's own
# `file:line` token, bare as the status prints it or bold as the review body
# does. The reply itself is read by the SHARED reply forms, so what answers
# no thread answers no body entry either — and a reply written for another
# head, or by anyone but the author, is not the author's disposition of this
# head.
#
# A `Fixed in <sha>` sha is not a binding. Commit the fix, write the reply
# citing it, push, and that sha IS the head: a comment written for the
# earlier head would otherwise bind itself to the new one and carry its other
# replies across a diff no reviewer re-read. The two rows below take that in
# both directions — the Fixed-in sha alone binds nothing, and a comment that
# says the head elsewhere still answers the entry its Fixed-in reply names.
supp_reply_case() { # COMMENT_AUTHOR, COMMENT_BODY, VERDICT, NAME
  reset
  CFG_TRUSTED_LOGINS=""
  CFG_MIN_STATE=any
  CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
  reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES")")"
  comment "$1" "$(printf '%b' "$2")" >"$fixtures/comments.json"
  run "$4" "$3"
}
SUPP_REASON='Declined: the generator draws its name from the row set, so a collision is unreachable.'
SUPP_BOTH="**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400"
while IFS='|' read -r name author bound body want; do
  supp_reply_case "$author" "Dispositions at $bound:\n$body" "$want" "$name"
done <<EOF
a bound reasoned decline and a tracked entry clear the block|$AUTHOR|${HEAD:0:7}|$SUPP_BOTH|approved
a reply naming the entries bare, as the status prints them, clears the block|$AUTHOR|${HEAD:0:7}|$SUPP_FIRST - $SUPP_REASON\n$SUPP_SECOND - Tracked: KEN-1400|approved
a comment tied to the head only by its own Fixed-in sha answers nothing|$AUTHOR|${OTHER:0:7}|**$SUPP_FIRST** - Fixed in $HEAD\n**$SUPP_SECOND** - $SUPP_REASON|suppressed-findings
a comment naming the head elsewhere still answers a Fixed-in entry|$AUTHOR|${HEAD:0:7}|**$SUPP_FIRST** - Fixed in $HEAD\n**$SUPP_SECOND** - $SUPP_REASON|approved
a label-only decline answers nothing|$AUTHOR|${HEAD:0:7}|**$SUPP_FIRST** - Declined: out of scope\n**$SUPP_SECOND** - Declined: pre-existing|suppressed-findings
a tracking claim naming no issue answers nothing|$AUTHOR|${HEAD:0:7}|**$SUPP_FIRST** - Tracking this separately.\n**$SUPP_SECOND** - Tracking this separately.|suppressed-findings
a reply bound to another head answers nothing|$AUTHOR|${OTHER:0:7}|$SUPP_BOTH|suppressed-findings
a reply by another login answers nothing|other-user|${HEAD:0:7}|$SUPP_BOTH|suppressed-findings
EOF

# The subtraction is per entry, not per block: the answered entry leaves the
# count and the list, and the one nobody wrote about still fails the gate.
supp_reply_case "$AUTHOR" "Dispositions at ${HEAD:0:7}:\n**$SUPP_FIRST** - $SUPP_REASON" \
  suppressed-findings "an answered entry is subtracted and the unanswered one still blocks"
supp_carries "the partial detail counts only what is left" "detail=1 suppressed finding(s)" "$LAST_LINE"
supp_carries "the partial detail names the unanswered entry" "$SUPP_SECOND" "$LAST_LINE"
supp_omits "the partial detail drops the answered entry" "$SUPP_FIRST" "$LAST_LINE"

# The scan is the ONE definition of an entry token, and it admits a space:
# `[^*]+:[0-9]+` inside the bold markers, stored and printed bare. A reply
# line is matched by EQUALITY with a scanned entry rather than by a token
# pattern of its own, so a path the status prints is a path the author can
# copy back, whatever is in it. A second grammar here refused this one.
SUPP_SPACED='docs/release notes.md:12'
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (1)' "**$SUPP_SPACED**
* Blocking: the note names a version that never shipped.")")"
comment "$AUTHOR" "$(printf 'Dispositions at %s:\n%s - %s\n' "${HEAD:0:7}" "$SUPP_SPACED" "$SUPP_REASON")" >"$fixtures/comments.json"
run "a bare entry whose path carries a space is answered" approved

# A shorter entry must not claim a longer one's line. The character after the
# token has to be no letter or digit, and a tracking reply is what makes that
# load-bearing: `tracking` and `names_issue` read the WHOLE reply, so the
# junk remainder a prefix match leaves ("2 - Tracked: ...") carries the track
# word and the id, and the entry nobody wrote about would be answered.
SUPP_SHORT='src/lane.ts:1'
SUPP_LONGER='src/lane.ts:12'
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (2)' "**$SUPP_SHORT**
* Blocking: the first finding.
**$SUPP_LONGER**
* Blocking: the second finding.")")"
comment "$AUTHOR" "$(printf 'Dispositions at %s:\n%s - Tracked: KEN-1400\n' "${HEAD:0:7}" "$SUPP_LONGER")" >"$fixtures/comments.json"
run "a shorter entry does not claim a longer entry's line" suppressed-findings
supp_carries "the longer entry's answer left the shorter one standing" "$SUPP_SHORT" "$LAST_LINE"
supp_carries "only one finding is left" "detail=1 suppressed finding(s)" "$LAST_LINE"

# The comment binds by saying so, and a sha-shaped run it merely carries is
# not saying so. This body holds a head prefix in the one place an author
# never means as an assertion, the entry token of a path that opens with hex,
# and no `Dispositions at` line: it answers nothing.
SUPP_HEXPATH="${HEAD:0:8}.ts:1"
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (1)' "**$SUPP_HEXPATH**
* Blocking: the lane name can collide with a row already carrying it.")")"
comment "$AUTHOR" "$(printf 'Dispositions:\n%s - %s\n' "$SUPP_HEXPATH" "$SUPP_REASON")" >"$fixtures/comments.json"
run "a head prefix with no marker in front of it binds nothing" suppressed-findings

# The entry list changes with every review, so a comment outlives the block it
# answered: at one head the author disposes two findings, pushes, and the new
# review drops the one that was fixed and re-prints the other. The stale line
# is then text no entry claims. Nothing about it says which commit this
# comment answers, and the comment's own marker names the OLD head, so the
# decline beside it must not ride to a diff it was never written against.
SUPP_GONE='src/model/lanes.ts:9'
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES")")"
comment "$AUTHOR" "$(printf 'Dispositions at %s:\n%s - Fixed in %s\n**%s** - %s\n**%s** - Tracked: KEN-1400\n' \
  "${OTHER:0:7}" "$SUPP_GONE" "$HEAD" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")" >"$fixtures/comments.json"
run "a comment marked for an older head answers nothing at this one" suppressed-findings

# The marker OPENS a line. A comment quoting the phrase — from another pull
# request, inside a fenced example, mid-sentence — is not an author saying
# which commit this comment answers, and a body scan took all of those.
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES")")"
comment "$AUTHOR" "$(printf 'The other PR says Dispositions at %s, which is this head.\n**%s** - %s\n**%s** - Tracked: KEN-1400\n' \
  "${HEAD:0:7}" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")" >"$fixtures/comments.json"
run "a marker quoted mid-line binds nothing" suppressed-findings

# A path may carry a colon of its own, so one entry can open another entry's
# line at a separator the bare arm allows. The remainder still holds a track
# word and an id, so without a longest-match rule one reply answers both.
SUPP_STEM='src/foo:1'
SUPP_EXTENDS='src/foo:1.ts:2'
reset
CFG_TRUSTED_LOGINS=""
CFG_MIN_STATE=any
CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
reviews_set "$(review copilot COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(supp_body '### Suppressed comments (2)' "**$SUPP_STEM**
* Blocking: the first finding.
**$SUPP_EXTENDS**
* Blocking: the second finding.")")"
comment "$AUTHOR" "$(printf 'Dispositions at %s:\n%s - Tracked: KEN-1400\n' "${HEAD:0:7}" "$SUPP_EXTENDS")" >"$fixtures/comments.json"
run "a line names one entry, the longest it opens with" suppressed-findings
supp_carries "the entry the line extends is still standing" "$SUPP_STEM" "$LAST_LINE"
supp_carries "only the extending entry was answered" "detail=1 suppressed finding(s)" "$LAST_LINE"
