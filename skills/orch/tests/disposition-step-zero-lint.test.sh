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
# WHAT THIS COVERS, stated as the token facts it checks rather than the rules
# they belong to, because a token pin establishes that a structural element is
# present and nothing more (`review-bots.md`, the markdown-contract bullet):
#
#   * the Step 0 opener and the `decline` literal share a line
#   * the opener's line precedes Step 1's in document order
#   * § Filing bar names Step 0 beside `category: "issue"`
#   * § Recurrence names Step 0
#   * the line naming `REVIEW_MAX_EXTERNAL_ROUNDS` also names Step 0
#   * neither § Filing bar nor project-management's § Disposition carries a
#     phrase from the class list
#
# WHAT IT DOES NOT COVER, and none is asked for, since each is a claim about
# direction or behavior that co-occurrence cannot establish: that Step 0's
# verdict IS the decline rather than a route to one; that it answers before the
# claim is verified; that the diff's authorship does not reopen it; that
# § Recurrence runs behind rather than ahead of it; that the three doors named
# in § Filing bar run it rather than bypass it; the membership of the class
# list; the two exceptions' route to Step 1; and Step 1's remedy for code
# the Done-when does not name. Each was mutated with every pinned token kept
# and this suite stayed green. The `order` rule pins document position, not the
# sentence claiming it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

DISP="$SKILL_DIR/references/finding-disposition.md"
PM="$SKILLS_ROOT/project-management/SKILL.md"
FLOW="## Decision flow"
BAR="## Filing bar"
REC="## Recurrence"
PM_SEC="## Disposition"
CLASSES='a race between two invocations|a crash between two writes|no shipped producer emits|hole in a mechanism that itself came from a review round|second writer who already holds'
CLASS_SAMPLE='Never for a race between two invocations on one machine: declined, not filed.'

echo "=== orch disposition step-zero lint ==="

rule "the Step 0 opener names the decline literal" \
  "$DISP" "$FLOW" '0. **Is it one of the excluded classes?**' '`decline`'

order "the Step 0 opener precedes the defect question" "$DISP" \
  '^0\. \*\*Is it one of the excluded classes' '^1\. \*\*Does it claim a defect'

# One home, measured as the three sections that would otherwise carry a copy
# naming Step 0 instead. The filing-bar pin carries a second token so the
# control lands on the routing line rather than a later mention.
rule "the filing bar names Step 0 beside \`category: \"issue\"\`" "$DISP" "$BAR" \
  'Step 0' '`category: "issue"`'
rule "Recurrence names Step 0" "$DISP" "$REC" 'Step 0'
rule "the line naming the round cap also names Step 0" "$DISP" "$FLOW" \
  '`REVIEW_MAX_EXTERNAL_ROUNDS`' 'Step 0'

# The two copies of the class list that drifted, one before this contract and
# one under it. Both are measured, in the same form, one file apart.
absent "the filing bar carries no class-list phrase" "$DISP" "$BAR" \
  "$CLASSES" "$CLASS_SAMPLE"
absent "project-management's Disposition carries no class-list phrase" \
  "$PM" "$PM_SEC" "$CLASSES" "$CLASS_SAMPLE"

md_report
