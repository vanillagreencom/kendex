#!/usr/bin/env bash
# A root cause that recurs at a new site ends the patch sequence, and the check
# runs before the round cap.
#
# The spiral it closes: a round meets a new site of one cause, a fix round
# answers it, the next round meets the next site, and the diff outgrows the
# reported symptom while the cap, which counts rounds, sees nothing wrong.
# Derive the shape of a PR that ran that way rather than transcribing counts
# into this header, where nothing rechecks them:
#
#   gh pr view [N] --json commits \
#     --jq '[.commits[].messageHeadline | select(startswith("Address PR review"))] | length'
#   gh api repos/[OWNER]/[REPO]/pulls/[N]/reviews --jq '.[0].commit_id'
#   git diff --shortstat [THAT_COMMIT] HEAD
#
# The rule has one home, `references/finding-disposition.md` § Recurrence, and
# two routers: `workflows/review-pr-comments.md`, pinned below, and
# `workflows/review-pr.md`, pinned in `review-disposition-by-rule-lint.test.sh`
# alongside the rest of that twin's contract. `workflows/oversee.md` § End
# spirals points at the section instead of restating it.
#
# NARROWER SURFACE THAN THE PREDECESSOR, deliberately: it also ran
# `scripts/workflow-state` to prove the file channel these writes use. The
# cause carrying an apostrophe and the one carrying a double quote are
# round-tripped through the real script by the `append-file` section of
# `workflow-state-cycle-cap.sh`, which is what shows the channel works rather
# than that a doc describes it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

DISP="$SKILL_DIR/references/finding-disposition.md"
CM="$SKILL_DIR/workflows/review-pr-comments.md"
DEV_FIX="$SKILL_DIR/workflows/dev-fix.md"
OVERSEE="$SKILL_DIR/workflows/oversee.md"
SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
REC="## Recurrence"
S6="## 6. Apply Fixes And Loop"

echo "=== orch recurrence/freeze lint ==="

# The two dispositions, and the reply form that binds freeze to a filed issue.
rule "Recurrence names the structural-close disposition" "$DISP" "$REC" '`structural-close`'
rule "Recurrence names the freeze disposition" "$DISP" "$REC" '`freeze`'
rule "Recurrence binds freeze to a Tracked reply" "$DISP" "$REC" '`Tracked: <ID>`'
rule "Recurrence declines a later finding on a frozen cause" "$DISP" "$REC" '`decline`'

# The trigger is a cause a prior round PATCHED, and `patched_causes` is the
# record that says so — the question `fixed_items` cannot answer. A cause
# merely answered, a decline or a filing, has no patch sequence to end and
# stays with the decision flow.
rule "Recurrence triggers on the record that proves a patch" "$DISP" "$REC" '`patched_causes`'
rule "Recurrence routes a never-patched cause back to the decision flow" "$DISP" "$REC" 'decision flow'
# freeze cannot answer a defect this diff introduced or armed.
rule "Recurrence carries the introduced-or-armed carve-out" "$DISP" "$REC" 'introduces' 'arms'
rule "the signals table routes a recurring root cause to § Recurrence" "$DISP" "" '| § Recurrence'

# The router, and the order that gives it force: a recurring cause ends the
# patch sequence before a round count decides anything.
rule "the comment loop links the Recurrence section" "$CM" "" \
  '../references/finding-disposition.md#recurrence'
order "the recurrence check is routed ahead of the iterations cap" "$CM" \
  'references/finding-disposition\.md#recurrence' 'REVIEW_MAX_EXTERNAL_ROUNDS'


# What consumes the rule. The auto-fix skip list carries the bucket name as an
# inline literal; the report heading below is plain.
rule "a recurrence item is excluded from the auto-fix bucket" "$CM" "" '`RECURRENCE`'
rule "§ 5's triage report has a RECURRENCE bucket" "$CM" "## 5. Triage Report" '### ♻️ RECURRENCE'

# Membership, not branches: what may be fixed is one set, and the step that
# opens the delegation reads that set rather than the Fixing rows alone.
rule "§ 6 states eligibility as one fix set" "$CM" "$S6" '`fix set`' '`structural-close`'
rule "§ 6 makes freeze and declined rows reply-only" "$CM" "$S6" '`reply-only`' '`freeze`' '`declined`'
rule "§ 6.1 delegates the fix set, not the Fixing rows" "$CM" "### 6.1 Delegate Fixes" \
  '[For each item in the fix set:]'
absent "§ 6.1 re-derives no membership of its own" "$CM" "### 6.1 Delegate Fixes" \
  'For each item marked "Fixing"' '[For each item marked "Fixing":]'
rule "an empty fix set still routes the pass to the reply step" "$CM" "### 6.1 Delegate Fixes" \
  '`fix set` is empty' '`reply step`'
rule "the reply step closes the pass" "$CM" "### 6.3 Re-Triage Or Exit" '**Reply step.**'

# One ordered obligation set, stated once in § 6 and performed by the order the
# subsections appear in. The routing it replaced named a jump target per call
# site and leaked at whichever site the next pass took. Document order is what
# performs the first obligation: a `Tracked:` body names
# an id the pass has already filed only while the section that files precedes
# the one reply step. Stated in prose and contradicted by the layout, it read
# as an order the document did not execute, and a freeze pass replied first.
order "issue creation precedes the reply step in document order" "$CM" \
  '^### 6\.2 Create Issues' '\*\*Reply step\.\*\*'

# The two records the recurrence check reads, and the channel they cross. A
# resolved thread is invisible to the next pass, so a cause is recurrence only
# if a pass wrote it down — and reviewer text never crosses argv.
rule_fenced "§ 6 records a patched cause in workflow state" "$CM" "$S6" \
  'append-file [ISSUE_ID] pr_comment_review.patched_causes [WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json'
rule_fenced "§ 6 records a frozen cause in workflow state" "$CM" "$S6" \
  'append-file [ISSUE_ID] pr_comment_review.frozen_causes [WORKTREE_PATH]/tmp/frozen-cause-[ISSUE_ID].json'
absent "neither cause write puts reviewer text on the command line" "$CM" "$S6" \
  'append \[ISSUE_ID\] pr_comment_review\.(patched|frozen)_causes' \
  '.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.patched_causes "[CAUSE]"'
rule_fenced "§ 5 reads both records before triaging a pass" "$CM" "## 5. Triage Report" \
  'workflow-state get [ISSUE_ID]' '.pr_comment_review.patched_causes // []' \
  '.pr_comment_review.frozen_causes // []'

# The other writer of the record § 5 reads. The comment loop fills it from its
# own reply step; the pr-review, qa-review and review rounds reach it through
# dev-fix.md § 2, the only thing standing between those loops and a recurrence
# check reading an empty history.
rule_fenced "dev-fix records a patched cause in workflow state" "$DEV_FIX" "## 2. Delegate" \
  'append-file [ISSUE_ID] pr_comment_review.patched_causes tmp/patched-cause-[ISSUE_ID].json'

rule "the schema documents both records on the pr_comment_review row" "$SCHEMA" "" \
  '| `pr_comment_review` |' '`patched_causes[]`' '`frozen_causes[]`'

# One home: oversee.md points at the section instead of restating the rule. A
# second statement names its branches, whatever words carry it.
rule "oversee points at the Recurrence section" "$OVERSEE" "" \
  '../references/finding-disposition.md#recurrence'
absent "oversee keeps no second statement of the rule" "$OVERSEE" "" \
  'structural-close|`freeze`|Tracked:' \
  'Past the cap a recurring cause takes `structural-close` or a `freeze` reply of `Tracked: <ID>`.'

md_report
