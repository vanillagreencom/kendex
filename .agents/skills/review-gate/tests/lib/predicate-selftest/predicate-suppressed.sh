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
