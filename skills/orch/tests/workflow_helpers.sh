#!/usr/bin/env bash
# Regression tests for Codex-safe orch helper commands.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

echo "=== orch Codex-safe helper commands ==="

state_dir="$TMP_ROOT/state"
ORCH_STATE_DIR="$state_dir" "$REPO_ROOT/skills/orch/scripts/workflow-state" init issue-353 --worktree "$REPO_ROOT" --branch issue-353 >/dev/null

exists_json="$(ORCH_STATE_DIR="$state_dir" "$REPO_ROOT/skills/orch/scripts/workflow-state" exists --json issue-353)"
assert_eq "$(jq -r '.exists' <<<"$exists_json")" "true" "workflow-state exists --json reports existing state"
assert_eq "$(jq -r '.issue_id' <<<"$exists_json")" "issue-353" "workflow-state exists --json includes issue id"

missing_json="$(ORCH_STATE_DIR="$state_dir" "$REPO_ROOT/skills/orch/scripts/workflow-state" exists --json issue-404)"
assert_eq "$(jq -r '.exists' <<<"$missing_json")" "false" "workflow-state exists --json reports missing state"

default_branch="$(WORKTREE_DEFAULT_BRANCH=trunk "$REPO_ROOT/skills/orch/scripts/resolve-base-branch" "$REPO_ROOT")"
assert_eq "$default_branch" "trunk" "resolve-base-branch honors WORKTREE_DEFAULT_BRANCH"

fallback_branch="$("$REPO_ROOT/skills/orch/scripts/resolve-base-branch" "$TMP_ROOT/not-a-git-repo")"
assert_eq "$fallback_branch" "main" "resolve-base-branch falls back to main"

assert_eq "$("$REPO_ROOT/skills/orch/scripts/tracker-for-issue" issue-353)" "github" "tracker-for-issue detects GitHub ids"
assert_eq "$("$REPO_ROOT/skills/orch/scripts/tracker-for-issue" CC-353)" "linear" "tracker-for-issue detects Linear ids"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
