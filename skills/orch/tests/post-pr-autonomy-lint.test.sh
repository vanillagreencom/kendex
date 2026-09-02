#!/usr/bin/env bash
# Automatic post-PR choices continue to their budget, then record one stop.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

SETTINGS="$SKILL_DIR/kendex.settings.toml.example" COMMENTS="$SKILL_DIR/workflows/review-pr-comments.md" SUBMIT="$SKILL_DIR/workflows/submit-pr.md" START="$SKILL_DIR/workflows/start-worktree.md" MERGE="$SKILL_DIR/workflows/merge-pr.md" CI="$SKILL_DIR/workflows/ci-fix.md"
echo "=== orch post-PR autonomy lint ==="
rule "decision mode defaults to automatic continuation" "$SETTINGS" "" 'ORCH_DECISION_MODE = "auto-recommended"'
rule "merge consent defaults to automatic after gates" "$SETTINGS" "" 'ORCH_MERGE_AUTONOMY = "auto"'
rule "reviewer silence defaults to proceed" "$SETTINGS" "" 'PR_REVIEW_ON_TIMEOUT = "proceed"'
rule "the skill owns the named-stop record" "$SKILL_DIR/SKILL.md" "## The Cycle" '**Post-PR autonomy.**' '`workflow-state post-pr-stop record`' '`ORCH_MERGE_AUTONOMY` controls merge consent only'
rule_fenced "comment triage reads the decision mode" "$COMMENTS" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule "comment triage continues to section 8 automatically" "$COMMENTS" "" 'logs `Continue`, clears any stop, and goes to § 8' '`ask` stops here'
rule_fenced "submission reads the decision mode" "$SUBMIT" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule "submission spends review retries before its cap" "$SUBMIT" "## 4. Review Gate" '`continue` restarts step 1' '`at-cap` records `review-round-cap`'
rule_fenced "submission spends the review-wait budget" "$SUBMIT" "## 4. Review Gate" 'head-budget take' 'review-wait'
rule_fenced "submission records the review-round cap" "$SUBMIT" "## 4. Review Gate" 'post-pr-stop record' 'review-round-cap'
rule "start-worktree preserves the upstream stop before summaries" "$START" "## 5. Finalize" "preserves submit-pr's stop" '`merge-gates-unmet`'
rule_fenced "start-worktree records the unmet merge gates" "$START" "## 5. Finalize" 'post-pr-stop record-if-empty' 'merge-gates-unmet'
rule_fenced "merge reads the decision mode" "$MERGE" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule "merge retry exhaustion has a named stop" "$MERGE" "## 3. Check Merge Readiness" '`merge-check-blocked`'
rule_fenced "ci-fix reads the decision mode" "$CI" "## 3. Classify And Route" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule "ci-fix spends retries before its cap" "$CI" "## 5. Verify" '`continue` reruns § 1' '`at-cap` records and returns `ci-fix-cap`'
rule_fenced "ci-fix spends the ci-fix budget" "$CI" "## 5. Verify" 'head-budget take' 'ci-fix'
rule_fenced "ci-fix records its cycle cap" "$CI" "## 5. Verify" 'post-pr-stop record' 'ci-fix-cap'
rule "an admin answer is the only route to admin merge" "$SUBMIT" "### 6.2 Consumer Admin-Merge Question" 'An admin answer invokes' '`merge_mode: admin`' '§ 1-7'
rule "automatic decisions continue through the gates" "$SUBMIT" "### 6.2 Consumer Admin-Merge Question" 'a question orch poses and never answers' '`auto-recommended`' '`Continue through the gates`'
rule "admin failure ends in a named stop" "$MERGE" "" 'Exit `1` from `--admin`' 'records the named stop `merge-blocked`'
rule_fenced "merge renders its stops into a bound path" "$MERGE" "## 1. Identify Candidates" 'post-pr-stop record' '[MAIN_REPO_ROOT]/tmp/post-pr-stop-[STATE_KEY].md'
retired_opened='not merely open''ed'
retired_wait='Stop and wait for the us''er'
forbid "the retired brief-level stop prompt stays gone" \
  "$retired_opened|$retired_wait" \
  "$retired_wait." "$SKILL_DIR/workflows"/*.md "$SKILL_DIR/scripts/open-terminal"

md_report
