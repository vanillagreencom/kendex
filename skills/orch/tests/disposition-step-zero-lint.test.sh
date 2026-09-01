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
# WHAT THIS COVERS is structure, which is all a token pin can establish
# (`review-bots.md`, the markdown-contract bullet): the step opener exists, it
# routes to `decline`, it sits ahead of Step 1 in document order, the filing bar
# and § Recurrence point at it rather than restating it, the cap paragraph names
# it, and the filing bar carries no second copy of the class list.
#
# WHAT IT DOES NOT COVER, and none is asked for: every behavioral claim the
# section makes. That a decline precedes examining the claim, that the diff's
# authorship does not reopen the step, the membership of the class list, the
# security exception's route to Step 1, and Step 1's remedy for code the
# Done-when does not name all live only in prose, and prose negates and
# qualifies around any literal — a suite pinning those sentences passes over a
# Step 0 rewritten to file what it declines. The `order` rule pins the document
# position, not the sentence claiming it: a rewrite that keeps Step 0 first and
# denies the ordering in words is outside what this can decide.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

DISP="$SKILL_DIR/references/finding-disposition.md"
FLOW="## Decision flow"
BAR="## Filing bar"
REC="## Recurrence"

echo "=== orch disposition step-zero lint ==="

# The step, and the verdict it routes to. `decline` is the inline literal that
# separates this step from one that files or fixes the same classes.
rule "the decision flow opens with the excluded classes and declines them" \
  "$DISP" "$FLOW" '0. **Is it one of the excluded classes?**' '`decline`'

# The placement that gives the step its force. Without it the list is prose
# sitting behind a branch that already answered.
order "the excluded classes precede the defect question" "$DISP" \
  '^0\. \*\*Is it one of the excluded classes' '^1\. \*\*Does it claim a defect'

# One home. Each of the three sections that would otherwise carry a second copy
# routes to Step 0 by name instead.
rule "the filing bar routes candidates through Step 0" "$DISP" "$BAR" \
  'Step 0' '`category: "issue"`'
rule "Recurrence orders itself behind Step 0" "$DISP" "$REC" 'Step 0'
rule "the round cap's carve-out names Step 0" "$DISP" "$FLOW" \
  '`REVIEW_MAX_EXTERNAL_ROUNDS`' 'Step 0'

# The copy that was there before this contract, whose drift is what put a
# filing pass on a different list from the deciding pass.
absent "the filing bar restates no excluded class" "$DISP" "$BAR" \
  'a race between two invocations|a crash between two writes|no shipped producer emits|hole in a mechanism that itself came from a review round|second writer who already holds' \
  'Never for a race between two invocations on one machine: declined, not filed.'

md_report
