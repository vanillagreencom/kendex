#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_SH="$(cd "$TEST_DIR/.." && pwd)/scripts/github.sh"

PASS=0
FAIL=0

assert_token() {
  local output="$1" token="$2" name="$3"
  if grep -qF -- "$token" <<<"$output"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing token: %s\n' "$name" "$token"
  fi
}

echo "=== github.sh help owns configuration and error contracts ==="
github_help="$($GITHUB_SH --help)"
for token in \
  'Configuration:' \
  'GH_TOKEN' \
  'GITHUB_TOKEN' \
  'GH_BOT_TOKEN' \
  'GH_BOT_USERNAME' \
  'GH_ISSUE_PATTERN' \
  'GH_VERIFY_CMD' \
  'KENDEX_GITHUB_OP_TIMEOUT' \
  'KENDEX_GITHUB_AUTH_TIMEOUT' \
  'KENDEX_GITHUB_PR_VIEW_TIMEOUT' \
  'KENDEX_GITHUB_GIT_HTTPS_FALLBACK' \
  'kendex.settings.toml' \
  '.kendex/settings.toml' \
  '.env.local' \
  'op://' \
  'gh api user' \
  'gh auth status' \
  '{"error": "message"}' \
  'pr-view --json' \
  '3 attempts'; do
  assert_token "$github_help" "$token" "github.sh help carries $token"
done

echo
echo "=== pr-merge help owns merge outcomes and checks ==="
merge_help="$($GITHUB_SH pr-merge --help)"
for token in \
  'Exit codes:' \
  'ALREADY MERGED PR #N' \
  'QUEUED IN MERGE QUEUE PR #N' \
  'AUTO-MERGE ENABLED PR #N' \
  'CLOSED (not merged) PR #N' \
  'queue-wait <N>' \
  'pr-watch.sh' \
  'await-mergeable' \
  '--match-head-commit' \
  'isInMergeQueue' \
  'required_conversation_resolution' \
  'gh pr merge' \
  'can_merge' \
  'issues' \
  'transient' \
  'state' \
  'merged_at' \
  'head_runs' \
  'checks' \
  'ci-classify-refusal' \
  'unknown:' \
  'ci_pending:' \
  'ci_unconfigured:' \
  'ci_fetch_failed:' \
  'ci_failed:'; do
  assert_token "$merge_help" "$token" "pr-merge help carries $token"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
