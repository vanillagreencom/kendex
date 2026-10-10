#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
ORCH="$REPO_ROOT/skills/orch"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

# present FILE TOKEN — `yes` when FILE holds TOKEN as a fixed string; a FILE
# that does not exist aborts the suite, so a renamed document cannot pass an
# absence row. A raw fixed-string read also matches inside a fence or an HTML
# comment, which lib/md.sh's reader excludes; converting these rows to its
# rule forms needs the heading each command sits under and is follow-up.
present() {
  [[ -f "$1" ]] || { printf 'pins: no such file: %s\n' "$1" >&2; exit 1; }
  grep -Fq -- "$2" "$1" && echo yes || echo no
}

# pins ROW... — one assertion per row: `label|file|token|yes-or-no`.
pins() {
  local row label file token want
  for row in "$@"; do
    IFS='|' read -r label file token want <<<"$row"
    [[ -n "$want" ]] || { printf 'pins: a row with no expectation asserts nothing: %s\n' "$row" >&2; exit 1; }
    assert_eq "$(present "$file" "$token")" "$want" "$label"
  done
}

ROUND_STAMP="workflow-state new-round-id [ISSUE_ID] dev_round_id"
ROUND_CHECK="dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]"
# One contiguous command: a flag dropped from the command while left in prose
# would still pass two independent substring checks.
ROUND_CHECK_EXPECT="$ROUND_CHECK --expect-items-from-round"
ROUND_ITEMS_PERSIST="dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID]"
WATCHDOG_STAMP="workflow-state set-now [ISSUE_ID] dev_delegated_at"
ARTIFACT_KEY_LINE="Artifact Key: [ISSUE_ID]"
LEGACY_CHECK="dev-artifact-check [WORKTREE_PATH] [ISSUE_ID] [DEV_DELEGATED_AT_FROM_PREVIOUS_COMMAND]"
DEV_START="$ORCH/workflows/dev-start.md"
DEV_FIX="$ORCH/workflows/dev-fix.md"
REVIEW_PR_COMMENTS="$ORCH/workflows/review-pr-comments.md"
CI_FIX="$ORCH/workflows/ci-fix.md"

echo "=== every dev and QA path mints a fresh round id and accepts through round mode ==="
pins \
  "dev-start stamps dev_delegated_at (watchdog deadline)|$DEV_START|$WATCHDOG_STAMP|yes" \
  "dev-start mints dev_round_id before delegation|$DEV_START|$ROUND_STAMP|yes" \
  "dev-start accepts via dev-artifact-check round mode|$DEV_START|$ROUND_CHECK|yes" \
  "dev-start's delegation carries the Round ID line|$DEV_START|Round ID: [DEV_ROUND_ID]|yes" \
  "dev-start's delegation carries the Artifact Key line|$DEV_START|$ARTIFACT_KEY_LINE|yes" \
  "dev-fix stamps dev_delegated_at|$DEV_FIX|$WATCHDOG_STAMP|yes" \
  "dev-fix mints dev_round_id before delegation|$DEV_FIX|$ROUND_STAMP|yes" \
  "dev-fix accepts with --expect-items-from-round in one command|$DEV_FIX|$ROUND_CHECK_EXPECT|yes" \
  "dev-fix persists the delegated item set at stamp time|$DEV_FIX|$ROUND_ITEMS_PERSIST|yes" \
  "dev-fix's delegation carries the Round ID line|$DEV_FIX|Round ID: [DEV_ROUND_ID]|yes" \
  "dev-fix's delegation carries the Artifact Key line|$DEV_FIX|$ARTIFACT_KEY_LINE|yes" \
  "review-pr-comments stamps dev_delegated_at|$REVIEW_PR_COMMENTS|$WATCHDOG_STAMP|yes" \
  "review-pr-comments mints dev_round_id before delegation|$REVIEW_PR_COMMENTS|$ROUND_STAMP|yes" \
  "review-pr-comments accepts with --expect-items-from-round in one command|$REVIEW_PR_COMMENTS|$ROUND_CHECK_EXPECT|yes" \
  "review-pr-comments persists each group's delegated item set|$REVIEW_PR_COMMENTS|$ROUND_ITEMS_PERSIST|yes" \
  "review-pr-comments' delegation carries the Round ID line|$REVIEW_PR_COMMENTS|Round ID: [DEV_ROUND_ID]|yes" \
  "review-pr-comments' delegation carries the Artifact Key line|$REVIEW_PR_COMMENTS|$ARTIFACT_KEY_LINE|yes" \
  "ci-fix re-stamps dev_delegated_at|$CI_FIX|$WATCHDOG_STAMP|yes" \
  "ci-fix mints a token without a dev stage before delegating|$CI_FIX|workflow-state new-round-id [ISSUE_ID] ci_round_id|yes" \
  "ci-fix never mints an unclosed dev stage|$CI_FIX|$ROUND_STAMP|no" \
  "merge-pr-restack asks worktree-push before the restack|$ORCH/workflows/merge-pr-restack.md|worktree-push --check-live-round --worktree [WT_PATH] --issue [ISSUE]|yes"
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  pins "$wf.md carries no legacy positional dev-artifact-check call|$ORCH/workflows/$wf.md|$LEGACY_CHECK|no"
done

echo "=== the per-wake check and the wall-clock watchdog are mandated and routed ==="
RULES="$ORCH/references/skill-rules.md"
pins \
  "skill-rules names the one-word verdict acceptance reads|$RULES|\`verdict\`|yes" \
  "SKILL.md routes the moved rules to the reference|$ORCH/SKILL.md|references/skill-rules.md|yes"
# The needles are the RESOLVABLE relative path: a bare filename matches an
# unresolvable one too.
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  pins "$wf.md routes the watchdog contract to the canonical section|$ORCH/workflows/$wf.md|../references/skill-rules.md#round-closure|yes"
done
for wf in dev-fix review-pr-comments; do
  pins "$wf.md routes the literal-format rule to the canonical section|$ORCH/workflows/$wf.md|../references/skill-rules.md#format-tags-are-literal|yes"
done

echo "=== the dev workflows key the artifact to the delegation's Artifact Key ==="
DEV_IMPLEMENT="$REPO_ROOT/skills/dev/workflows/dev-implement.md"
DEV_DEV_FIX="$REPO_ROOT/skills/dev/workflows/dev-fix.md"
pins \
  "dev-implement keys the artifact to [ARTIFACT_KEY]|$DEV_IMPLEMENT|dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID]|yes" \
  "dev-fix keys the artifact to [ARTIFACT_KEY]|$DEV_DEV_FIX|dev-return-write --worktree [WORKTREE_PATH] --kind fix --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID]|yes" \
  "dev-fix points a respawned agent at the persisted round record|$DEV_DEV_FIX|dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json|yes"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
