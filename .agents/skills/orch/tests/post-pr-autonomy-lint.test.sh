#!/usr/bin/env bash
# Automatic post-PR choices continue to their budget, then record one stop.
# What is pinned is what a script reads: the settings keys and defaults, the
# `orch-env`, `head-budget`, `post-pr-stop` and `workflow-state set` commands
# the workflows run, the handoff path the oversee scripts read, and the
# `pr-merge` flag the retired admin route used.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

SETTINGS="$SKILL_DIR/kendex.settings.toml.example" COMMENTS="$SKILL_DIR/workflows/review-pr-comments.md" SUBMIT="$SKILL_DIR/workflows/submit-pr.md" START="$SKILL_DIR/workflows/start-worktree.md" MERGE="$SKILL_DIR/workflows/merge-pr.md" CI="$SKILL_DIR/workflows/ci-fix.md"
echo "=== orch post-PR autonomy lint ==="
rule "decision mode defaults to automatic continuation" "$SETTINGS" "" 'ORCH_DECISION_MODE = "auto-recommended"'
rule "merge consent defaults to automatic after gates" "$SETTINGS" "" 'ORCH_MERGE_AUTONOMY = "auto"'
rule "reviewer silence defaults to proceed" "$SETTINGS" "" 'PR_REVIEW_ON_TIMEOUT = "proceed"'
rule 'overseer handoff default' "$SKILL_DIR/workflows/oversee.md" \
  '## 1. Resolve The Launch Surface' 'tmp/handoffs/OVERSEER-HANDOFF.md'
rule_fenced "comment triage reads the decision mode" "$COMMENTS" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule_fenced "submission reads the decision mode" "$SUBMIT" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule_fenced "submission spends the review-wait budget" "$SUBMIT" "## 4. Review Gate" 'head-budget take' 'review-wait'
rule_fenced "submission records the review-round cap" "$SUBMIT" "## 4. Review Gate" 'post-pr-stop record' 'review-round-cap'
rule_fenced "submission records a forced merge" "$SUBMIT" "## 4. Review Gate" 'workflow-state set' 'pr_approval.forced true'
rule_fenced "start-worktree records the unmet merge gates" "$START" "## 5. Finalize" 'post-pr-stop record-if-empty' 'merge-gates-unmet'
rule_fenced "merge reads the decision mode" "$MERGE" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule_fenced "ci-fix reads the decision mode" "$CI" "## 3. Classify And Route" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule_fenced "ci-fix spends the ci-fix budget" "$CI" "## 5. Verify" 'head-budget take' 'ci-fix'
rule_fenced "ci-fix records its cycle cap" "$CI" "## 5. Verify" 'post-pr-stop record' 'ci-fix-cap'
rule_fenced "merge renders its stops into a bound path" "$MERGE" "## 1. Identify Candidates" 'post-pr-stop record' '[MAIN_REPO_ROOT]/tmp/post-pr-stop-[STATE_KEY].md'
# The admin route is retired (kendex decision D003): no workflow sets a merge
# mode or passes --admin to pr-merge.
forbid "the retired admin merge route stays gone" \
  'merge_mode|pr-merge [^`]*--admin([^-]|$)' \
  'run `pr-merge [PR_NUMBER] --admin` with `merge_mode: admin`.' \
  "$SKILL_DIR"/*.md "$SKILL_DIR/workflows"/*.md "$SKILL_DIR/references"/*.md

md_report
