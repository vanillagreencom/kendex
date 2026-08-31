#!/usr/bin/env bash
# `orch review` disposes findings by rule, never by prompt. The standalone
# review workflow used to present an `Apply fixes?` multi-select over its own
# blockers and fix suggestions, and a second multi-select over the issue
# candidates. Both are mechanics questions the disposition rules already
# answer, so the menu only added a stall: an unattended run had nothing to
# select with, and an attended one re-litigated a classification the reviewers
# had already made.
#
# Two things are covered. The absence of the menu shape, which is what a
# pattern can honestly decide — a menu has to be written to be present, and no
# rephrasing hides one. And the presence of structural elements: the Declined
# heading, the metric row, the audit-issues route, the recurrence route ahead
# of the round cap. That a section or a route is THERE, never that the prose
# around it reads any particular way.
#
# NOT covered: the disposition rule and the decline-derivation rule themselves.
# Those are claims written in prose, and prose negates or qualifies around any
# literal — `mode-independent` was tried as a pin, and a § 4 reading
# "`mode-independent` only in `auto-recommended`" satisfied it while inverting
# the rule.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

WF="$SKILL_DIR/workflows/review.md"
PR="$SKILL_DIR/workflows/review-pr.md"
MENU='(multi-select|Apply fixes\?|Create issues for these\?|items selected|Fix blockers\?|Apply fix suggestions\?|Ignore and proceed|resolve the decision mode|ORCH_DECISION_MODE ask)'
SAMPLE='Apply fixes? — multi-select the blockers to hand a fix round.'

echo "=== orch review disposition-by-rule lint ==="

# Scoped to the fix-disposition sections, so an unrelated ask elsewhere does
# not trip this and the lint stays honest about WHERE the regression lands.
# Matched case-insensitively: a reintroduced `apply fixes?` menu is the menu
# whatever case its author wrote it in.
# review-pr.md is the PR-gating twin — same findings, same reviewers, same rule
# — and its § 7 handles QA items by explicit reference to the § 4 pattern.
absent_i "review § 4 presents no selection menu over findings" \
  "$WF" "## 4. Present And Fix" "$MENU" "$SAMPLE"
absent_i "review-pr § 4 presents no selection menu over findings" \
  "$PR" "## 4. Handle Review Items" "$MENU" "$SAMPLE"
absent_i "review-pr § 7 presents no selection menu over QA findings" \
  "$PR" "## 7. Handle QA Items" "$MENU" "$SAMPLE"

# The positive statements, so an edit cannot drop the rule and leave only the
# absence of a menu — which a truncated file would satisfy too. Their presence
# is what this establishes; whether a run fills them in is not a fact about
# text, and what audit-issues does with its approval gate is asserted where
# that gate lives.
rule "review-pr § 8 carries the declined report section" \
  "$PR" "## 8. Summary And Issue Audit" '### 🚫 DECLINED'
rule "review § 5 carries the Declined metric row" "$WF" "## 5. Summary" '| Declined |'
rule "review § 5 carries the Declined report section" "$WF" "## 5. Summary" '### Declined'
rule "review § 4 names the audit-issues route" \
  "$WF" "## 4. Present And Fix" 'workflows/audit-issues.md'
rule "review-pr § 4 names the recurrence route" \
  "$PR" "## 4. Handle Review Items" '../references/finding-disposition.md#recurrence'

# The twin's half of the one contract: the recurrence route precedes the round
# cap in document order, so a recurring cause ends the patch sequence before a
# round count ever decides anything.
order "review-pr routes to Recurrence ahead of REVIEW_MAX_CYCLES" "$PR" \
  'references/finding-disposition\.md#recurrence' 'REVIEW_MAX_CYCLES'

md_report
