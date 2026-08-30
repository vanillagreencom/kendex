#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
MERGE="$ORCH/workflows/merge-pr.md"
LANE="$ORCH/workflows/lane-postmerge.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

section() { awk '/^## 5[.] /{on=1} /^## 6[.] /{on=0} on' "$1"; }
audit() {
  local file="$1" body line previous=0 at
  body=$(section "$file")
  for line in \
    '.agents/skills/orch/scripts/merge-queue-watch prepare --worktree [WORKTREE_PATH] --issue [STATE_KEY] --repo [OWNER/REPO] --pr [PR_NUMBER] --head [PREPARED_HEAD] --root [MAIN_REPO_ROOT] --gate-mode [GATE_MODE] --recovery-count [RECOVERY_COUNT] --cleanup-worktree [CLEANUP_WORKTREE]' \
    '[MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] [--force] --expected-head [PREPARED_HEAD]' \
    '[MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto --expected-head [PREPARED_HEAD]' \
    '.agents/skills/orch/scripts/merge-queue-watch launch --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]' \
    '.agents/skills/orch/scripts/merge-queue-watch direct-merged --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]' \
    '.agents/skills/orch/scripts/merge-queue-watch consume --root [MAIN_REPO_ROOT] --issue [STATE_KEY]' \
    '[MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [ISSUE]' \
    '[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]' \
    '.agents/skills/orch/scripts/merge-queue-watch merge-pr-complete --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]'; do
    [[ $(grep -Fxc -- "   $line" <<<"$body") -eq 1 ]] || return 1
    at=$(grep -Fn -- "   $line" <<<"$body" | cut -d: -f1)
    [[ "$at" -gt "$previous" ]] || return 1
    previous="$at"
  done
  for line in \
    '| `postmerge` | Step 2 |' \
    '| `resume_launch` | Fix the persisted setup failure and rerun launch for the same watch; never hand back |' \
    '| `restack`, `resume_restack` | Run or resume the guarded Restack cycle below |' \
    '| `recovery` | Recovery cycle below, using the persisted gate mode and recovery count |' \
    '| `triage` | Late-findings triage below |' \
    '| `manual_dequeue` | Confirm dequeue or disarm before late-findings triage |' \
    '| `rewatch` | Prepare and launch a new watch without re-arming |' \
    '| `rearm` | Prepare, re-arm the exact head once, and launch |' \
    '| `resume_rewatch`, `resume_rearm` | Resume the claimed next-generation setup without replaying consume |'; do
    [[ $(grep -Fxc -- "   $line" <<<"$body") -eq 1 ]] || return 1
  done
}
audit_lane() {
  local body previous=0 line at
  body=$(cat "$1")
  for line in \
    '   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/merge-queue-watch cleanup --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]' \
    '   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/merge-queue-watch acknowledge --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID] --result pass'; do
    [[ $(grep -Fxc -- "$line" <<<"$body") -eq 1 ]] || return 1
    at=$(grep -Fn -- "$line" <<<"$body" | cut -d: -f1); [[ "$at" -gt "$previous" ]] || return 1; previous="$at"
  done
}

echo "=== merge queue workflow command ownership ==="
if audit "$MERGE"; then ok "live prepare, exact-head arm, launch, consume, and completion commands are executable and ordered"; else bad "workflow command chain"; fi
if grep -Fq '.agents/skills/orch/scripts/merge-queue-watch init --worktree [WORKTREE_PATH] --issue [STATE_KEY] --branch [PR_BRANCH]' "$MERGE" && \
  grep -Fq 'otherwise use `pr-[PR_NUMBER]`' "$MERGE" && \
  grep -Fq '`MERGED` → set `[ALREADY_MERGED]=true`' "$MERGE"; then ok "standalone and already-merged routes initialize a collision-safe lifecycle state"; else bad "standalone or already-merged lifecycle route"; fi
if audit_lane "$LANE"; then ok "lane cleanup precedes final acknowledgment"; else bad "lane cleanup and acknowledgment chain"; fi
if grep -Fq '`cleanup_pending` when resuming an interrupted cleanup claim' "$LANE" && \
  grep -Fq 'safety-preserving `kept` dispositions are complete' "$LANE"; then ok "lane resumes cleanup and acknowledges kept worktrees"; else bad "lane cleanup resume or kept acknowledgment doctrine"; fi
if grep -Fq '[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/merge-queue-watch acknowledge --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID] --result fail' "$LANE"; then ok "failed lane acknowledgment also uses the surviving main repository"; else bad "failed acknowledgment can use a deleted cwd"; fi
if [[ ! -e "$ORCH/scripts/lib/queue-wait-help.sh" ]] && ! grep -Fq 'queue-wait-help.sh' "$ORCH/scripts/queue-wait"; then ok "dead queue-wait help library is absent"; else bad "dead queue-wait help library remains"; fi
if grep -Fq 'workflows/lane-postmerge.md' "$ORCH/workflows/start-worktree.md" && \
  grep -Fq 'workflows/lane-postmerge.md' "$ORCH/workflows/submit-pr.md"; then ok "managed callers run the lane acknowledgment workflow"; else bad "managed continuation wiring"; fi
if grep -Fq '`workflows/merge-pr-restack.md`' "$MERGE" && \
  grep -Fq 'auto-merge first' "$ORCH/workflows/merge-pr-restack.md" && \
  grep -Fq 'dequeuePullRequest' "$ORCH/workflows/merge-pr-restack.md"; then ok "conflicts route through guarded disarm-then-dequeue restack"; else bad "guarded restack workflow wiring"; fi

cp "$MERGE" "$TMP/noop.md"
count=$(grep -Fc '.agents/skills/orch/scripts/merge-queue-watch consume --root [MAIN_REPO_ROOT] --issue [STATE_KEY]' "$TMP/noop.md")
[[ "$count" -eq 1 ]] || { bad "consume mutation fixture count"; exit 1; }
sed -i.bak 's|^   \.agents/skills/orch/scripts/merge-queue-watch consume|   true # .agents/skills/orch/scripts/merge-queue-watch consume|' "$TMP/noop.md"
rm -f "$TMP/noop.md.bak"
if audit "$TMP/noop.md"; then bad "no-op command mutant survived"; else ok "no-op command mutant is killed"; fi

cp "$MERGE" "$TMP/decoy.md"
sed -i.bak 's|^   \.agents/skills/orch/scripts/merge-queue-watch launch|   # .agents/skills/orch/scripts/merge-queue-watch launch|' "$TMP/decoy.md"
rm -f "$TMP/decoy.md.bak"
printf '\n## Decoy\n.agents/skills/orch/scripts/merge-queue-watch launch --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]\n' >> "$TMP/decoy.md"
if audit "$TMP/decoy.md"; then bad "outside-section decoy survived"; else ok "outside-section decoy cannot replace the live command"; fi

cp "$MERGE" "$TMP/rows.md"
sed -i.bak 's/| `recovery` | Recovery cycle below, using the persisted gate mode and recovery count |/| `recovery-mutant` | Recovery cycle below, using the persisted gate mode and recovery count |/' "$TMP/rows.md"
rm -f "$TMP/rows.md.bak"
printf '\n## Decoy\n   | `recovery` | Recovery cycle below, using the persisted gate mode and recovery count |\n' >> "$TMP/rows.md"
if audit "$TMP/rows.md"; then bad "action-row decoy survived"; else ok "action-row swap and outside decoy are killed"; fi

cp "$MERGE" "$TMP/poststep.md"
sed -i.bak 's|^   \[MAIN_REPO_ROOT\]/.agents/skills/linear/scripts/linear.sh issues complete|   true # [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete|' "$TMP/poststep.md"
rm -f "$TMP/poststep.md.bak"
if audit "$TMP/poststep.md"; then bad "poststep no-op survived"; else ok "poststep true-comment mutant is killed"; fi

cp "$MERGE" "$TMP/fallback.md"
sed -i.bak 's/otherwise use `pr-\[PR_NUMBER\]`/otherwise leave it empty/' "$TMP/fallback.md"
rm -f "$TMP/fallback.md.bak"
if grep -Fq 'otherwise use `pr-[PR_NUMBER]`' "$TMP/fallback.md"; then bad "empty state-key mutant survived"; else ok "empty state-key mutant is killed"; fi

cp "$LANE" "$TMP/resume.md"
sed -i.bak 's/`cleanup_pending` when resuming an interrupted cleanup claim/`cleanup_complete` only/' "$TMP/resume.md"
rm -f "$TMP/resume.md.bak"
if grep -Fq '`cleanup_pending` when resuming an interrupted cleanup claim' "$TMP/resume.md"; then bad "cleanup resume mutant survived"; else ok "cleanup resume mutant is killed"; fi

cp "$MERGE" "$TMP/restack.md"
sed -i.bak 's/| `restack`, `resume_restack` |/| `restack-disabled` |/' "$TMP/restack.md"
rm -f "$TMP/restack.md.bak"
if audit "$TMP/restack.md"; then bad "restack action mutant survived"; else ok "restack action mutant is killed"; fi

cp "$LANE" "$TMP/relative-ack.md"
count=$(grep -Fc '[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/merge-queue-watch acknowledge' "$TMP/relative-ack.md")
[[ "$count" -eq 2 ]] || { bad "absolute acknowledgment mutation fixture count"; exit 1; }
sed -i.bak 's|\[MAIN_REPO_ROOT\]/\.agents/skills/orch/scripts/merge-queue-watch acknowledge|.agents/skills/orch/scripts/merge-queue-watch acknowledge|g' "$TMP/relative-ack.md"
rm -f "$TMP/relative-ack.md.bak"
if audit_lane "$TMP/relative-ack.md"; then bad "relative acknowledgment mutant survived"; else ok "relative acknowledgment mutant is killed"; fi

printf 'merge-queue-workflow: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
