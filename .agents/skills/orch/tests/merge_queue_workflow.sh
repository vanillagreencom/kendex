#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
MERGE="$ORCH/workflows/merge-pr.md"
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
    '.agents/skills/orch/scripts/merge-queue-watch prepare --worktree [WORKTREE_PATH] --issue [STATE_KEY] --repo [OWNER/REPO] --pr [PR_NUMBER] --head [PREPARED_HEAD] --root [MAIN_REPO_ROOT] --gate-mode [GATE_MODE] --recovery-count [RECOVERY_COUNT]' \
    '[MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto --expected-head [PREPARED_HEAD]' \
    '.agents/skills/orch/scripts/merge-queue-watch launch --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]' \
    '.agents/skills/orch/scripts/merge-queue-watch consume --root [MAIN_REPO_ROOT] --issue [STATE_KEY]' \
    '.agents/skills/orch/scripts/merge-queue-watch merge-pr-complete --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]'; do
    [[ $(grep -Fxc -- "   $line" <<<"$body") -eq 1 ]] || return 1
    at=$(grep -Fn -- "   $line" <<<"$body" | cut -d: -f1)
    [[ "$at" -gt "$previous" ]] || return 1
    previous="$at"
  done
}

echo "=== merge queue workflow command ownership ==="
if audit "$MERGE"; then ok "live prepare, exact-head arm, launch, consume, and completion commands are executable and ordered"; else bad "workflow command chain"; fi
if grep -Fq 'workflows/lane-postmerge.md' "$ORCH/workflows/start-worktree.md" && \
  grep -Fq 'workflows/lane-postmerge.md' "$ORCH/workflows/submit-pr.md"; then ok "managed callers run the lane acknowledgment workflow"; else bad "managed continuation wiring"; fi

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

printf 'merge-queue-workflow: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
