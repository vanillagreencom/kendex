#!/usr/bin/env bash
# Surface: workflow commands consumed by review-artifact-check --file.
# Inputs: skills/orch/workflows/review-pr.md skills/orch/workflows/submit-pr.md
# This checks command construction, not whether a model follows the workflow.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/md.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== review-artifact-check: workflow freshness arguments ==="

# --file without a freshness argument can accept an earlier round's artifact.
# Put that argument first so md_report's control removes it while retaining
# the command that would otherwise accept the stale artifact.
rule_fenced "external artifact command supplies its freshness boundary" \
  "$SKILL_DIR/workflows/review-pr.md" "" \
  '[REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]' \
  'review-artifact-check --file "$EXTERNAL_OUTPUT" [WORKTREE_PATH]'
rule_fenced "local artifact command supplies its freshness boundary" \
  "$SKILL_DIR/workflows/submit-pr.md" "" \
  '[LOCAL_STARTED_AT]' \
  'review-artifact-check --file "$LOCAL_OUTPUT" [WORKTREE_PATH]'

md_report
