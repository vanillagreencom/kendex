#!/usr/bin/env bash
# Post-PR choices continue under auto-recommended until their budget ends.
# The workflow then records one named stop instead of asking or claiming done.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

SETTINGS="$SKILL_DIR/kendex.settings.toml.example"
COMMENTS="$SKILL_DIR/workflows/review-pr-comments.md"
SUBMIT="$SKILL_DIR/workflows/submit-pr.md"
START="$SKILL_DIR/workflows/start-worktree.md"
MERGE="$SKILL_DIR/workflows/merge-pr.md"
CI="$SKILL_DIR/workflows/ci-fix.md"

echo "=== orch post-PR autonomy lint ==="

rule "decision mode defaults to automatic continuation" "$SETTINGS" "" \
  'ORCH_DECISION_MODE = "auto-recommended"'
rule "merge consent defaults to automatic after gates" "$SETTINGS" "" \
  'ORCH_MERGE_AUTONOMY = "auto"'
rule "reviewer silence defaults to proceed" "$SETTINGS" "" \
  'PR_REVIEW_ON_TIMEOUT = "proceed"'
rule "the skill owns the named-stop record" "$SKILL_DIR/SKILL.md" "## The Cycle" \
  '**Post-PR autonomy.**' '.post_pr_stop' '`ORCH_MERGE_AUTONOMY` controls merge consent only'

rule_fenced "comment triage reads the decision mode" "$COMMENTS" "" \
  'orch-env ORCH_DECISION_MODE auto-recommended'
rule "managed comment triage returns without a question" "$COMMENTS" "" \
  '**Managed or `auto-recommended`:**' '§ 8'
rule_fenced "submission reads the decision mode" "$SUBMIT" "" \
  'orch-env ORCH_DECISION_MODE auto-recommended'
rule "submission names its review cap stop" "$SUBMIT" "## 4. Review Gate" \
  '`auto-recommended` records `review-round-cap`'
rule "a failed merge gate becomes visible" "$START" "### 5.5 Merge" \
  '`merge-gates-unmet`' 'session status'
rule_fenced "merge reads the decision mode" "$MERGE" "" \
  'orch-env ORCH_DECISION_MODE auto-recommended'
rule "merge retry exhaustion has a named stop" "$MERGE" "## 3. Check Merge Readiness" \
  '`merge-check-blocked`'
rule_fenced "ci-fix reads the decision mode" "$CI" "## 3. Classify And Route" \
  'orch-env ORCH_DECISION_MODE auto-recommended'
rule "ci-fix exhaustion has a named stop" "$CI" "## 5. Verify" \
  '`ci-fix-cap`'

rule "kendex never receives the admin merge offer" "$SUBMIT" "### 2.1 Consumer Admin-Merge Offer" \
  '`vanillagreencom/kendex`'
rule "automatic decisions never select admin merge" "$SUBMIT" "### 2.1 Consumer Admin-Merge Offer" \
  '`ORCH_DECISION_MODE` never selects admin merge'
rule "merge accepts only a recorded admin decision" "$MERGE" "" \
  '`admin_merge_authorized`' '`submit-pr.md` § 2.1' 'PR body'

retired_opened='not merely open''ed'
retired_wait='Stop and wait for the us''er'
forbid "the retired brief-level stop prompt stays gone" \
  "$retired_opened|$retired_wait" \
  "$retired_wait." "$SKILL_DIR/workflows"/*.md "$SKILL_DIR/scripts/open-terminal"

md_report
