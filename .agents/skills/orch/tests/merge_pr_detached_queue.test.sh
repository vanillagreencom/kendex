#!/usr/bin/env bash
# KEN-829: an armed merge releases the lane, and the lane owns every later
# verdict through the existing merge-pr recovery and post-merge paths.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MERGE="$SKILL_DIR/workflows/merge-pr.md"
ORCH="$SKILL_DIR/SKILL.md"
OVERSEE="$SKILL_DIR/workflows/oversee.md"
SCHEMA="$SKILL_DIR/schemas/workflow-state.md"

PASS=0
FAIL=0

has() {
  local file="$1" text="$2" name="$3"
  if grep -Fq -- "$text" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing: %s\n' "$name" "$text"
  fi
}

lacks() {
  local file="$1" text="$2" name="$3"
  if grep -Fq -- "$text" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden: %s\n' "$name" "$text"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

route_has() {
  local verdict="$1" action="$2" name="$3" row count
  row=$(grep -F "| \`$verdict\` |" "$MERGE" || true)
  count=$(grep -Fc "| \`$verdict\` |" "$MERGE" || true)
  if [[ "$count" == 1 && "$row" == *"| $action |" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        row: %s\n' "$name" "$row"
  fi
}

echo "=== merge-pr detached queue contract ==="

has "$MERGE" 'merge_queue_watch' \
  "armed merge records its resumable state"
has "$MERGE" 'queue-wait [PR_NUMBER] 30 2400 --json --detach --output [VERDICT_PATH]' \
  "merge-pr launches one detached queue watch"
has "$MERGE" 'Return immediately after the detached launch succeeds' \
  "armed merge returns the lane immediately"
has "$ORCH" 'At every lane boundary' \
  "orch checks detached verdicts at lane boundaries"
has "$ORCH" '`ejected`, `disarmed`, or `dequeued` resumes the matching recovery row in `merge-pr.md` § 5' \
  "later failures resume merge-pr recovery"
route_has ejected 'Recovery cycle below' \
  "ejected artifact maps exactly to CI recovery"
route_has disarmed 'Recovery cycle below' \
  "disarmed artifact maps exactly to CI recovery"
route_has dequeued 'Late-findings triage below' \
  "dequeued artifact maps exactly to review triage"
route_has merged '→ step 2' \
  "merged artifact maps exactly to post-merge step 2"
has "$ORCH" '`merged` resumes `merge-pr.md` § 5 at step 2' \
  "later merge runs post-merge work in the lane"
has "$MERGE" 'linear.sh issues complete [ISSUE]' \
  "post-merge lane completes the tracker item"
has "$MERGE" 'scripts/sync-base [MAIN_REPO_ROOT]' \
  "post-merge lane syncs the base checkout"
has "$MERGE" 'post-merge flow still owns every project-specific build, install, and' \
  "merge-pr returns build/install verification to the outer lane flow"
lacks "$MERGE" 'ORCH_POST_MERGE_' \
  "merge-pr adds no generic post-merge command setting"
lacks "$MERGE" 'cargo build' \
  "merge-pr hardcodes no project build command"
has "$MERGE" '.merge_queue_watch.status = "complete"' \
  "post-merge lane closes its durable state"
has "$MERGE" 'scripts/worktree remove "[ISSUE_ID]"' \
  "post-merge lane owns worktree cleanup"
has "$OVERSEE" 'only confirms the lane completed those steps' \
  "overseer does not steal lane post-merge work"
has "$SCHEMA" '`merge_queue_watch`' \
  "workflow-state schema documents detached merge state"
has "$SCHEMA" '`pr_number`, `head_sha`, `verdict_path`, `main_repo_root`, `status`' \
  "detached merge state binds PR, head, artifact, root, and status"

printf 'merge-pr-detached-queue: %d pass, %d fail\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
