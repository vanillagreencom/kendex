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
