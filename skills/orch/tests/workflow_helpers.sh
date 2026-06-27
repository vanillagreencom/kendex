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

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  fi
}

assert_file_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
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

issue_repo="$TMP_ROOT/issue-repo"
git init -q "$issue_repo"
git -C "$issue_repo" checkout -q -b cc-536
assert_eq "$("$REPO_ROOT/skills/orch/scripts/git-context" issue-from-branch "$issue_repo")" "CC-536" "git-context uppercases lower-case Linear branch ids"

git -C "$issue_repo" checkout -q --orphan issue-369
assert_eq "$("$REPO_ROOT/skills/orch/scripts/git-context" issue-from-branch "$issue_repo")" "issue-369" "git-context keeps GitHub issue branch ids lowercase"

preflight_repo="$TMP_ROOT/preflight-repo"
git init -q "$preflight_repo"
git -C "$preflight_repo" config user.name "Test User"
git -C "$preflight_repo" config user.email "test@example.com"
git -C "$preflight_repo" config commit.gpgsign false
mkdir -p "$preflight_repo/.codex/agents"
cat >"$preflight_repo/.gitignore" <<'EOF'
/.codex/**
EOF
cat >"$preflight_repo/.codex/agents/reviewer-test.toml" <<'EOF'
name = "reviewer-test"
EOF

preflight_untracked="$("$REPO_ROOT/skills/orch/scripts/codex-app-agent-preflight" "$preflight_repo")"
assert_eq "$(jq -r '.status' <<<"$preflight_untracked")" "untracked" "codex app preflight warns for ignored generated agents"
assert_eq "$(jq -r '.severity' <<<"$preflight_untracked")" "warning" "codex app preflight classifies ignored generated agents as warning"
assert_eq "$(jq -r '.ok' <<<"$preflight_untracked")" "false" "codex app preflight still marks ignored generated agents not ok"
assert_eq "$(jq -r '.requires_confirmation' <<<"$preflight_untracked")" "true" "codex app preflight asks for confirmation on warning"
assert_eq "$(jq -r '.tracked_agents' <<<"$preflight_untracked")" "0" "codex app preflight reports no tracked agents"
assert_eq "$(jq -r '.visible_agents' <<<"$preflight_untracked")" "1" "codex app preflight reports visible ignored agent"

cat >"$preflight_repo/.gitignore" <<'EOF'
/.codex/**
!/.codex/
!/.codex/agents/
!/.codex/agents/*.toml
EOF
git -C "$preflight_repo" add .gitignore .codex/agents/reviewer-test.toml
git -C "$preflight_repo" commit -q -m 'track codex agent' >/dev/null

preflight_ok="$("$REPO_ROOT/skills/orch/scripts/codex-app-agent-preflight" "$preflight_repo")"
assert_eq "$(jq -r '.status' <<<"$preflight_ok")" "ok" "codex app preflight accepts tracked generated agents"
assert_eq "$(jq -r '.severity' <<<"$preflight_ok")" "info" "codex app preflight classifies tracked generated agents as info"
assert_eq "$(jq -r '.requires_confirmation' <<<"$preflight_ok")" "false" "codex app preflight does not ask confirmation when tracked agents exist"
assert_eq "$(jq -r '.tracked_agents' <<<"$preflight_ok")" "1" "codex app preflight reports tracked agent count"

orch_skill="$REPO_ROOT/skills/orch/SKILL.md"
submit_workflow="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
comments_workflow="$REPO_ROOT/skills/orch/workflows/review-pr-comments.md"
merge_workflow="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
qa_workflow="$REPO_ROOT/skills/reviewer/workflows/qa-review.md"

assert_file_contains "$orch_skill" "#### Harness-Safe Shell" "orch skill documents Harness-Safe Shell section"
assert_file_contains "$orch_skill" 'Avoid inline `$(...)`, shell `for`/`while` loops' "Harness-Safe Shell section bans unsafe shell helper shapes"

for workflow in "$submit_workflow" "$comments_workflow"; do
  workflow_name="$(basename "$workflow")"
  assert_file_not_contains "$workflow" 'BOT_WAIT_ARGS' "$workflow_name avoids bot wait arrays"
  assert_file_not_contains "$workflow" "IFS=',' read -ra REVIEW_BOTS" "$workflow_name avoids IFS reviewer splitting"
  assert_file_not_contains "$workflow" 'for BOT in "${REVIEW_BOTS[@]}"' "$workflow_name avoids reviewer shell loops"
  assert_file_not_contains "$workflow" '--reviewers "$BOT_REVIEWERS"' "$workflow_name avoids required BOT_REVIEWERS expansion"
  assert_file_not_contains "$workflow" 'printenv BOT_REVIEWERS' "$workflow_name avoids optional reviewer probing"
done

assert_file_not_contains "$merge_workflow" "fetch --all --prune" "merge-pr avoids all-remote fetch during sync"
assert_file_not_contains "$merge_workflow" "git-https-auth -C [MAIN_REPO_ROOT] pull" "merge-pr avoids pull during post-merge sync"
assert_file_not_contains "$merge_workflow" "git -C [MAIN_REPO_ROOT] pull" "merge-pr avoids plain git pull during post-merge sync"
assert_file_not_contains "$merge_workflow" "git-https-auth -C [MAIN_REPO_ROOT] merge" "merge-pr keeps local merge outside HTTPS credential wrapper"
assert_file_contains "$merge_workflow" 'If `CHECK.transient == true`, route by the transient issue prefix' "merge-pr routes transient readiness before prompting"
assert_file_contains "$merge_workflow" '`ci_pending:` (checks still running)' "merge-pr treats pending CI as transient readiness"
assert_file_contains "$merge_workflow" 'Treat `CHECK.transient` as the' "merge-pr uses pr-merge transient contract"
assert_file_contains "$merge_workflow" '.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 600' "merge-pr uses bounded CI wait for pending checks"
assert_file_contains "$merge_workflow" 'Do not repeat § 3.1 indefinitely' "merge-pr forbids unbounded transient wait loops"
assert_file_contains "$merge_workflow" 'git-https-auth -C [MAIN_REPO_ROOT] fetch --prune origin "+refs/heads/[BASE_BRANCH]:refs/remotes/origin/[BASE_BRANCH]"' "merge-pr sync fetches explicit origin base branch through HTTPS auth helper"
assert_file_contains "$merge_workflow" 'git -C [MAIN_REPO_ROOT] merge --ff-only "origin/[BASE_BRANCH]"' "merge-pr sync fast-forwards to quoted fetched origin base branch with plain git"

assert_file_not_contains "$qa_workflow" "Pipe benchmark output" "qa-review avoids pipe-based benchmark recording"
assert_file_not_contains "$qa_workflow" "pipe results" "qa-review avoids pipe-based perf capture guidance"
assert_file_contains "$qa_workflow" "Do not use shell pipelines" "qa-review bans Codex-unsafe benchmark shell plumbing"
assert_file_contains "$qa_workflow" "benchmark recorder fails closed on all-zero counters" "qa-review documents all-zero recorder fallback"
assert_file_contains "$qa_workflow" "targeted regression command reports numeric regressions" "qa-review reports targeted numeric regressions"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
