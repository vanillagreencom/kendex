#!/usr/bin/env bash
# The excluded classes are Step 0 of the decision flow, ahead of Step 1.
#
# The spiral it closes: every hole in new code is by construction introduced by
# the diff, so Step 1's introduced-or-armed branch answered `fix` before the
# exclusion list — which lived in the filing bar, governing filing only — was
# ever consulted. A whole class of review-grown machinery entered that way.
# Derive the shape of a PR that ran it rather than transcribing counts here:
#
#   gh api repos/[OWNER]/[REPO]/pulls/[N]/reviews --jq '.[0].commit_id'
#   git diff --shortstat [THAT_COMMIT] HEAD
#
# The list has one home, `references/finding-disposition.md` § Decision flow.
# The filing bar points at it and restates nothing, so the two cannot disagree.
#
# NOT covered: that a run actually consults Step 0 first. Document order is what
# this file can decide — the step's presence, its classes, and its placement
# ahead of Step 1 — and `dev/tests/engineering-rules-lint.test.sh` holds the
# dev-side half where the same deferral is stated.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

DISP="$SKILL_DIR/references/finding-disposition.md"
FLOW="## Decision flow"
BAR="## Filing bar"

echo "=== orch disposition step-zero lint ==="

# The step itself, and the two properties that make it an exclusion rather than
# a verdict: it runs before the claim is examined, and the diff's authorship
# does not reopen it.
rule "the decision flow opens with the excluded classes" "$DISP" "$FLOW" \
  '0. **Is it one of the excluded classes?**'
rule "Step 0 declines before the claim is examined" "$DISP" "$FLOW" \
  "before the claim's truth is examined"
rule "Step 0 holds whatever the diff introduced" "$DISP" "$FLOW" \
  'whatever this diff introduced or armed'

# The classes, one rule each: a list that loses a member silently is the shape
# that let the machinery in.
rule "Step 0 excludes a race between two invocations" "$DISP" "$FLOW" \
  'a race between two invocations on one machine'
rule "Step 0 excludes a crash between two writes" "$DISP" "$FLOW" \
  'a crash between two writes'
rule "Step 0 excludes an input nothing shipped emits" "$DISP" "$FLOW" \
  'an input no shipped producer emits'
rule "Step 0 excludes a hole in review-grown machinery" "$DISP" "$FLOW" \
  'a hole in a mechanism that itself came from a review round'
rule "Step 0 excludes the already-privileged second writer" "$DISP" "$FLOW" \
  "a second writer who already holds the user's privileges"

# The one way past it, and the clause that exception must not reopen.
rule "a shipped security or data-loss defect reaches Step 1" "$DISP" "$FLOW" \
  'security or data-loss defect a shipped path reaches goes to Step 1'
rule "the exception leaves the second-writer clause closed" "$DISP" "$FLOW" \
  'does not reopen the second-writer clause'

# The order that gives the step its force. Without it the list is prose sitting
# beside a branch that already answered.
order "the excluded classes precede the defect question" "$DISP" \
  '^0\. \*\*Is it one of the excluded classes' '^1\. \*\*Does it claim a defect'

# The two sentences elsewhere in the file that would otherwise say the opposite:
# the round cap's carve-out, and Step 1's remedy for code the Done-when does not
# name.
rule "the round cap's carve-out defers to Step 0" "$DISP" "" \
  'and Step 0 does not exclude'
rule "unrequired defective code is deleted, not guarded" "$DISP" "$FLOW" \
  'never by a second mechanism guarding the first'
absent "the flow offers no hardening alternative" "$DISP" "$FLOW" \
  'never by hardening it' \
  '   - Not required → `fix` by deleting that code, never by hardening it.'

# One home. A filing bar that restates a class can drift from Step 0's copy,
# and the drifting copy is the one a filing pass reads.
absent "the filing bar restates no excluded class" "$DISP" "$BAR" \
  'a race between two invocations|a crash between two writes|no shipped producer emits|hole in a mechanism that itself came from a review round|second writer who already holds' \
  'Never for a race between two invocations on one machine: declined, not filed.'
rule "the filing bar points at Step 0 instead" "$DISP" "$BAR" \
  "Step 0's classes never reach the bar"

md_report
