#!/usr/bin/env bash
# Regression lint for KEN-768. The reviewer package told a re-review to "scope
# the pass to the fix diff", and no delegation carried that diff: review.md
# resolved an absent `Diff-range` by diffing origin/<base>...HEAD, so every
# re-review round read the whole branch while believing itself scoped.
#
# Only the orchestrator can supply the boundary. It stamps `pre_delegate_sha`
# at the fix delegation and reads it back at Bounded Re-Review; a reviewer has
# no route to that value, and origin/<base>...HEAD — the one range it can
# compute alone — is precisely the wrong one. So the contract is a wire
# between four sites:
#
#   review-pr § 2.2   sends § 4's pre_delegate_sha read as Diff-range
#   review.md § 1     routes on Diff-range and owns the absent-boundary case
#   reviewer SKILL    names Diff-range as the thing it scopes to
#   workflow-state    documents pre_delegate_sha as that line's source
#
# The failure mode this pins is a SILENT fallback: a full-branch pass that
# looks identical to a scoped one. So the absent-boundary case travels as one
# literal token — the sender fills it, the reviewer recognises it — and both
# ends must spell it the same way or the signal is lost in transit. The
# reviewer then declares it in the artifact field the orchestrator reads back.
#
# What this pins are IDENTIFIERS and their relationships, never sentences:
# review-bots.md bans sentence-pinning lints on markdown, and an editorial
# rephrase must not fail a suite while the contract holds. Each control derives
# its mutation from the structure a check reads — a region dropped, one pinned
# token substituted — so no control carries a copy of the prose it guards.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
STATE_SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
REVIEWER_SKILL="$SKILL_DIR/../reviewer/SKILL.md"
REVIEW_WF="$SKILL_DIR/../reviewer/workflows/review.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== re-review scope boundary lint (KEN-768) ==="

# HTML comment regions are stripped from EVERY line before any region gate, so
# a comment opened above a marker blanks the marker too and the region never
# opens: a commented-out instruction is not an instruction.
strip_comments() {
  awk '
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (incomment) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          incomment = 0
          line = substr(line, p + 3)
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1)
          incomment = 1
          line = substr(line, p + 4)
        }
      }
      print out
    }
  ' "$1"
}

# Every grep reads a herestring, never a pipe: `grep -q` exits at the first
# match, SIGPIPE would kill the extractor, and `pipefail` would promote its 141
# into a false failure.
has() { grep -qE -e "$2" <<<"$1"; }

# $1 = file, $2 = ERE opening the region (its line is included), $3 = ERE
# closing it (its line is excluded).
slice() {
  strip_comments "$1" | awk -v head="$2" -v tail="$3" '
    !on && $0 ~ head { on = 1 }
    on && printed && $0 ~ tail { on = 0 }
    !on { next }
    { print; printed = 1 }
  '
}

# --- the four sites ---------------------------------------------------------
# Each is a region of a file, opened and closed by structural markers. The
# prose regions close on ANY later heading of their own level: closing on a
# heading that merely starts with some other letter widens the region silently
# the day a heading starting with that letter is added below it.
launch_region()   { slice "${1:-$REVIEW_PR_WF}" '^### 2[.]2 Launch And Delegate$' '^## '; }
delegation_of()   { slice "${1:-$REVIEW_PR_WF}" '^<delegation_format>$' '^</delegation_format>$'; }
rereview_block()  { slice "${1:-$REVIEW_PR_WF}" '^<if re-review cycle>$' '^</if>$'; }
bounded_region()  { slice "${1:-$REVIEW_PR_WF}" '^### Bounded Re-Review$' '^## '; }
# The one line the whole wire hangs on, isolated from the block around it: a
# token found anywhere in the region proves nothing about the field a reviewer
# parses.
range_line()      { grep -E -e "$FIELD_LINE" <<<"$1" || true; }
diff_region()     { slice "${1:-$REVIEW_WF}" '^## 1[.] Diff$' '^## '; }
rounds_region()   { slice "${1:-$REVIEWER_SKILL}" '^## Re-Review Rounds$' '^## '; }
schema_row()      { strip_comments "${1:-$STATE_SCHEMA}" | grep -F -- '| `pre_delegate_sha` |' || true; }

# --- the wire's identifiers -------------------------------------------------
# The delegation field name. Word-bounded on both ends so `Diff-ranges` or a
# `Diff-range-hint` cannot stand in for the field review.md actually reads.
FIELD='(^|[^[:alnum:]-])Diff-range([^[:alnum:]-]|$)'
# The same identifier as a delegation line: name, then its colon.
FIELD_LINE='(^|[^[:alnum:]-])Diff-range:'
# The state key that sources it, and the placeholder the format fills from it.
STATE_KEY='pre_delegate_sha'
PLACEHOLDER='\[PRE_SHA\]'
# The one literal both ends spell for "no boundary". Sender and reader must
# agree on it or the signal is lost between them.
ABSENT='unavailable'
# The artifact field the reviewer declares an unscoped pass in — the one the
# orchestrator reads back off the return.
DECLARE_FIELD='summary'

# --- review-pr § 2.2 sends the boundary ------------------------------------
DELEG="$(delegation_of)"
RANGE="$(range_line "$(rereview_block)")"
BOUNDED="$(bounded_region)"

# The range rides the existing re-review block, and the block is conditional on
# `cycles`, which a pre-loop fix round raises without any reviewer having seen
# the branch. Scoping THAT pass to the pre-loop diff would hide the branch from
# its own first review, so the line states its own condition rather than
# inheriting the block's.
sends_range()      { [[ -n "$(range_line "$1")" ]]; }
range_is_bound()   { has "$(range_line "$1")" "$PLACEHOLDER"; }
names_source()     { has "$(range_line "$1")" "$STATE_KEY"; }
names_absent()     { has "$(range_line "$1")" "$ABSENT"; }
# A pointer to a value some other section read is only as good as that read.
reads_state_key()  {
  local l
  l="$(grep -E 'workflow-state get \[ISSUE_ID\]' <<<"$1" || true)"
  has "$l" "$STATE_KEY"
}
binds_placeholder(){ has "$1" "$PLACEHOLDER"; }

if sends_range "$DELEG"; then
  pass "the re-review delegation sends a Diff-range line"
else
  fail "the re-review delegation sends the reviewer no Diff-range"
fi

if range_is_bound "$DELEG"; then
  pass "the Diff-range is filled from a placeholder, not a literal range"
else
  fail "the Diff-range carries no placeholder any read binds"
fi

if names_source "$DELEG"; then
  pass "the Diff-range line names the state key it is filled from"
else
  fail "the Diff-range line points at no source for its placeholder"
fi

if names_absent "$DELEG"; then
  pass "the Diff-range line names the literal it carries when the boundary is missing"
else
  fail "the Diff-range sends nothing distinguishable when the boundary is missing"
fi

if reads_state_key "$BOUNDED"; then
  pass "§ 4 Bounded Re-Review reads the .pre_delegate_sha the line points at"
else
  fail "the Diff-range points at a read no section performs"
fi

if binds_placeholder "$BOUNDED"; then
  pass "§ 4 binds the placeholder the delegation fills from"
else
  fail "§ 4 names no [PRE_SHA] for the delegation to fill from"
fi

# --- review.md § 1 resolves an absent boundary ------------------------------
DIFF="$(diff_region)"

# Both routes have to stay: the scoped one is what a Diff-range buys, and the
# full-branch one is what a first review still needs.
routes_on_range()  { has "$1" 'git .*diff \[DIFF_RANGE\]'; }
routes_full()      { has "$1" 'git .*diff .*BASE_BRANCH.*\.\.\.HEAD'; }
recognises_absent(){ has "$1" "$ABSENT"; }
declares_unscoped(){ has "$1" "$DECLARE_FIELD"; }

if routes_on_range "$DIFF"; then
  pass "§ 1 diffs the delegated range when it has one"
else
  fail "§ 1 has no route that reads the delegated range"
fi

if routes_full "$DIFF"; then
  pass "§ 1 keeps the full-branch route a first review needs"
else
  fail "§ 1 lost the full-branch route"
fi

if recognises_absent "$DIFF"; then
  pass "§ 1 recognises the sender's missing-boundary literal"
else
  fail "§ 1 reads the missing-boundary literal as an ordinary range"
fi

if declares_unscoped "$DIFF"; then
  pass "§ 1 declares an unscoped pass in the artifact field"
else
  fail "§ 1 falls back to a full read with nothing said in the artifact"
fi

# The literal is a wire, not two independent words. Sender and reader spelling
# it differently is the silent fallback returning under a new name. `awk` over
# a herestring, never `grep -o | head`: head closing the pipe early would raise
# the extractor's SIGPIPE into a failure under pipefail.
first_absent() { awk -v re="$ABSENT" '{ if (match($0, re)) { print substr($0, RSTART, RLENGTH); exit } }' <<<"$1"; }
# $1 = sender region, $2 = reader region.
literals_agree() {
  local a b
  a="$(first_absent "$1")"; b="$(first_absent "$2")"
  [[ -n "$a" ]] && [[ "$a" == "$b" ]]
}

if literals_agree "$RANGE" "$DIFF"; then
  pass "sender and reader spell the missing-boundary literal alike"
else
  fail "sender and reader disagree on the missing-boundary literal"
fi

# --- the reviewer package scopes to what it is given ------------------------
ROUNDS="$(rounds_region)"

# The instruction has to name the mechanism. "Scope to the fix diff" names
# something no reviewer can compute, which is the defect this issue is.
scopes_to_field()  { has "$1" "$FIELD"; }
# One owner for the absent-boundary resolution, referenced rather than copied:
# two statements of it drift, and a reviewer obeying the stale one is back to
# a silent full read.
defers_to_workflow(){ has "$1" 'workflows/review\.md'; }

if scopes_to_field "$ROUNDS"; then
  pass "§ Re-Review Rounds scopes to the delegated Diff-range"
else
  fail "§ Re-Review Rounds instructs a scoping the reviewer cannot perform"
fi

if defers_to_workflow "$ROUNDS"; then
  pass "§ Re-Review Rounds sends the no-range case to review.md"
else
  fail "§ Re-Review Rounds states no owner for the no-range case"
fi

# --- the schema names the line the key feeds --------------------------------
ROW="$(schema_row)"
if [[ -n "$ROW" ]] && has "$ROW" "$FIELD"; then
  pass "the pre_delegate_sha row names the Diff-range it feeds"
else
  fail "the pre_delegate_sha row documents no consumer"
fi

# --- the regions cannot widen without saying so -----------------------------
for probe in "§ 1. Diff:$(diff_region):^## " "§ Re-Review Rounds:$(rounds_region):^## " "§ 4 Bounded Re-Review:$(bounded_region):^### "; do
  label="${probe%%:*}"; rest="${probe#*:}"; body="${rest%:*}"; marker="${rest##*:}"
  n="$(grep -cE "$marker" <<<"$body" || true)"
  if [[ "$n" -eq 1 ]]; then
    pass "$label holds its own heading and no other"
  else
    fail "$label spans $n headings"
  fi
done

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

# $1 = file, $2 = head ERE, $3 = tail ERE. Prints the file with the region's
# lines removed.
drop_region() {
  awk -v head="$2" -v tail="$3" '
    !on && $0 ~ head { on = 1; printed = 0 }
    on && printed && $0 ~ tail { on = 0 }
    on { printed = 1; next }
    { print }
  ' "$1"
}

# $1 = file, $2 = head, $3 = tail, $4 = ERE to replace, $5 = replacement,
# $6 = optional ERE narrowing it to matching lines. Write a literal bracket or
# pipe as a bracket expression — awk warns on a backslash escape in a dynamic
# regex and the warning reaches the suite's output.
sub_region() {
  awk -v head="$2" -v tail="$3" -v from="$4" -v to="$5" -v only="${6:-}" '
    !on && $0 ~ head { on = 1; printed = 0 }
    on && printed && $0 ~ tail { on = 0 }
    on { printed = 1; if (only == "" || $0 ~ only) gsub(from, to) }
    { print }
  ' "$1"
}

# $1 = control file, $2 = source file, $3 = predicate, $4 = the region
# extractor to feed it, $5 = what the mutation removed.
#
# The predicate is checked against the SOURCE first. A check already red on the
# source would go green here for the wrong reason — the mutation proves nothing
# about a predicate that was never satisfied — and the control would credit
# itself for catching a defect it cannot see.
judge() {
  local ctrl="$1" src="$2" predicate="$3" extractor="$4" what="$5"
  if ! "$predicate" "$("$extractor" "$src")"; then
    fail "control for $what is vacuous — its predicate is already false on the source"
  elif cmp -s "$ctrl" "$src"; then
    fail "control planted nothing for $what — the mutation matched no text"
  elif "$predicate" "$("$extractor" "$ctrl")"; then
    fail "lint MISSED $what"
  else
    pass "lint flags $what"
  fi
}

C="$TMP_ROOT/c1.md"
sub_region "$REVIEW_PR_WF" '^<if re-review cycle>$' '^</if>$' "$FIELD_LINE" 'Range:' > "$C"
judge "$C" "$REVIEW_PR_WF" sends_range delegation_of "a re-review delegation that sends no Diff-range"

C="$TMP_ROOT/c2.md"
sub_region "$REVIEW_PR_WF" '^<if re-review cycle>$' '^</if>$' '[[]PRE_SHA[]]' 'origin/main' > "$C"
judge "$C" "$REVIEW_PR_WF" range_is_bound delegation_of "a Diff-range hardcoding a range no read sourced"

C="$TMP_ROOT/c2b.md"
sub_region "$REVIEW_PR_WF" '^<if re-review cycle>$' '^</if>$' "$STATE_KEY" 'recorded head' > "$C"
judge "$C" "$REVIEW_PR_WF" names_source delegation_of "a Diff-range naming no source for its placeholder"

C="$TMP_ROOT/c3.md"
sub_region "$REVIEW_PR_WF" '^### Bounded Re-Review$' '^## ' "$STATE_KEY" 'review_delegated_at' 'workflow-state get' > "$C"
judge "$C" "$REVIEW_PR_WF" reads_state_key bounded_region "a Diff-range pointing at a read no section performs"

C="$TMP_ROOT/c3b.md"
sub_region "$REVIEW_PR_WF" '^### Bounded Re-Review$' '^## ' '[[]PRE_SHA[]]' '[SHA]' > "$C"
judge "$C" "$REVIEW_PR_WF" binds_placeholder bounded_region "a § 4 that binds no [PRE_SHA]"

C="$TMP_ROOT/c4.md"
sub_region "$REVIEW_PR_WF" '^<if re-review cycle>$' '^</if>$' "$ABSENT" 'omitted' > "$C"
judge "$C" "$REVIEW_PR_WF" names_absent delegation_of "a sender whose missing-boundary literal drifted"

C="$TMP_ROOT/c5.md"
sub_region "$REVIEW_WF" '^## 1[.] Diff$' '^## ' "$ABSENT" 'absent' > "$C"
judge "$C" "$REVIEW_WF" recognises_absent diff_region "a reader whose missing-boundary literal drifted"

C="$TMP_ROOT/c6.md"
sub_region "$REVIEW_WF" '^## 1[.] Diff$' '^## ' "$DECLARE_FIELD" 'notes' > "$C"
judge "$C" "$REVIEW_WF" declares_unscoped diff_region "an unscoped pass declared in no artifact field"

C="$TMP_ROOT/c7.md"
sub_region "$REVIEW_WF" '^## 1[.] Diff$' '^## ' 'diff [[]DIFF_RANGE[]]' 'diff HEAD~1' > "$C"
judge "$C" "$REVIEW_WF" routes_on_range diff_region "§ 1 ignoring the range it was delegated"

C="$TMP_ROOT/c8.md"
sub_region "$REVIEWER_SKILL" '^## Re-Review Rounds$' '^## ' 'Diff-range' 'fix diff' > "$C"
judge "$C" "$REVIEWER_SKILL" scopes_to_field rounds_region "a scoping instruction naming no derivable range"

C="$TMP_ROOT/c9.md"
sub_region "$REVIEWER_SKILL" '^## Re-Review Rounds$' '^## ' 'workflows/review[.]md' 'your own judgement' > "$C"
judge "$C" "$REVIEWER_SKILL" defers_to_workflow rounds_region "a no-range case with no owner"

C="$TMP_ROOT/c10.md"
sed 's/| `pre_delegate_sha` | string |[^|]*|/| `pre_delegate_sha` | string | HEAD before delegation |/' "$STATE_SCHEMA" > "$C"
judge "$C" "$STATE_SCHEMA" scopes_to_field schema_row "a state row documenting no consumer"

# Inert-text control: the Diff-range line preserved word for word but commented
# out. A commented instruction is not an instruction.
C="$TMP_ROOT/c11.md"
awk -v re="Diff-range:" '$0 ~ re && !done { print "<!-- " $0 " -->"; done = 1; next } { print }' "$REVIEW_PR_WF" > "$C"
if ! grep -qF '<!--' "$C"; then
  fail "inert control planted nothing — no comment was opened"
else
  judge "$C" "$REVIEW_PR_WF" sends_range delegation_of "a Diff-range that sits inside an HTML comment"
fi

# Region-widening control: a second heading inside § 1. Diff must not let the
# slice swallow the sections below it.
C="$TMP_ROOT/c12.md"
awk '
  /^## 1[.] Diff$/ && !done { print; print ""; print "## 1a. Ranges"; done = 1; next }
  { print }
' "$REVIEW_WF" > "$C"
w="$(grep -cE '^## ' <<<"$(diff_region "$C")" || true)"
if cmp -s "$C" "$REVIEW_WF"; then
  fail "widening control planted nothing — no heading was inserted"
elif [[ "$w" -gt 1 ]]; then
  fail "lint credits a § 1 region that spans a second heading"
else
  pass "lint flags a § 1 region widened past its own heading"
fi

# The full-branch route removed: a delegation with no range then leaves the
# reviewer with no diff at all, and § 1 stops serving a first review.
C="$TMP_ROOT/c13.md"
sub_region "$REVIEW_WF" '^## 1[.] Diff$' '^## ' 'BASE_BRANCH_FROM_PREVIOUS_COMMAND' 'DIFF_RANGE' > "$C"
judge "$C" "$REVIEW_WF" routes_full diff_region "§ 1 with the full-branch route gone"

# The wire's two ends drifting apart while each still names SOME literal: the
# sender keeps its word, the reader is given another. Both halves pass their
# own check and the signal is lost between them.
C="$TMP_ROOT/c14.md"
sub_region "$REVIEW_WF" '^## 1[.] Diff$' '^## ' "$ABSENT" 'unset' > "$C"
if cmp -s "$C" "$REVIEW_WF"; then
  fail "drift control planted nothing — the mutation matched no text"
elif literals_agree "$RANGE" "$(diff_region "$C")"; then
  fail "lint MISSED a reader spelling the literal its sender never sends"
else
  pass "lint flags a reader spelling the literal its sender never sends"
fi

# The field match is bounded, so a longer identifier does not stand in for the
# field review.md reads. Run against the predicate, not a file.
if scopes_to_field 'scope the pass to the Diff-range-hint you were sent'; then
  fail "the Diff-range match is satisfied by a longer identifier"
else
  pass "the Diff-range match rejects a longer identifier"
fi

if scopes_to_field 'scope the pass to the delegation'"'"'s `Diff-range`.'; then
  pass "the Diff-range match still reads a real field citation"
else
  fail "the Diff-range match rejects a real field citation"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
