#!/usr/bin/env bash
# Contract tests for Codex spawn identity and the delegation-timestamp ordering.
#

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

# shellcheck source=lib/md.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

assert_order() {
  local file="$1" first="$2" second="$3" name="$4"
  local first_line second_line
  first_line=$(grep -nF "$first" "$file" | head -n 1 | cut -d: -f1 || true)
  second_line=$(grep -nF "$second" "$file" | head -n 1 | cut -d: -f1 || true)
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass "$name"
  else
    fail "$name" "order: $first before $second"
    printf '        file:  %s\n' "$file"
  fi
}

echo "=== Codex spawn identity and delegation ordering ==="

skill="$REPO_ROOT/skills/orch/SKILL.md"
codex_runtime_ref="$REPO_ROOT/skills/orch/references/codex-runtime.md"
review_pr="$REPO_ROOT/skills/orch/workflows/review-pr.md"
review="$REPO_ROOT/skills/orch/workflows/review.md"
codebase="$REPO_ROOT/skills/orch/workflows/review-codebase.md"
dev_start="$REPO_ROOT/skills/orch/workflows/dev-start.md"
handoff="$REPO_ROOT/skills/orch/workflows/handoff.md"

# --- Identity: routed through the adapter, canonical name is the identity ----
assert_file_contains "$skill" "spawn-adapter" "SKILL.md routes Codex spawns through the adapter"
assert_file_contains "$codex_runtime_ref" "spawn-adapter spawn" "Codex reference routes spawns through the adapter"

# Every workflow that spawns reviewers or dev agents must route through the
# adapter too — a workflow that hand-rolls the translation is the failure.
for doc in "$review_pr" "$review" "$codebase"; do
  assert_file_contains "$doc" "spawn-adapter spawn" "$(basename "$doc") routes reviewer spawns through the adapter"
done
assert_file_contains "$dev_start" "spawn-adapter spawn" "dev-start routes dev spawns through the adapter"

# --- Runtime spelling stays metadata, never an identity key -----------------
assert_file_contains "$review_pr" "review_agent_runtime_types: (.review_agent_runtime_types // {})" \
  "review-pr loads existing reviewer runtime metadata before spawning"
assert_file_contains "$review_pr" ".review_agent_runtime_types = [AGENT_RUNTIME_TYPE_MAP_JSON]" \
  "review-pr persists reviewer runtime metadata alongside the ids"
assert_file_contains "$dev_start" "\"runtime_agent_type\": \"[RUNTIME_AGENT_TYPE]\"" "dev-start records the runtime agent type"
assert_file_contains "$dev_start" "\"agent_type_fallback\": [FALLBACK_REASON_JSON_OR_NULL]" "dev-start records the fallback reason"
assert_file_contains "$dev_start" "\"status\": \"active\"" "dev-start stamps the session live for slot accounting"

# --- Delegation-timestamp ordering ------------------------------------------
# review_delegated_at is the freshness boundary artifact acceptance is gated on.
# Stamped before the reviewer-state write it would also cover spawn/bootstrap
# output; stamped after the delegation it would accept a stale prior-cycle
# artifact. Only the position between them gates exactly the in-flight round.
assert_order "$review_pr" \
  ".agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [AGENT_LIST_JSON]" \
  ".agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at" \
  "review-pr stamps the freshness boundary after the reviewer-state write"
freshness_stamp=".agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at"
delegation_boundary=".agents/skills/orch/scripts/review-artifact-check --path [WORKTREE_PATH] [AGENT]"
assert_order "$review_pr" "$freshness_stamp" "$delegation_boundary" \
  "review-pr stamps the freshness boundary before the delegation batch"

# Path minting is immediately before each selected reviewer's delegation.
# Keep both commands in the control; only their order is wrong.
[[ "$(grep -cFx -- "$freshness_stamp" "$review_pr")" == 1 ]]
[[ "$(grep -cFx -- "$delegation_boundary" "$review_pr")" == 1 ]]
awk -v stamp="$freshness_stamp" -v boundary="$delegation_boundary" '
  $0 == stamp { pending = $0; next }
  { print }
  $0 == boundary { print pending; pending = "" }
  END { if (pending != "") exit 1 }
' "$review_pr" > "$MD_TMP/late-stamp.md"
if cmp -s "$review_pr" "$MD_TMP/late-stamp.md"; then
  fail "freshness-order control changed no input"
elif (
  FAIL=0
  assert_order "$MD_TMP/late-stamp.md" "$freshness_stamp" "$delegation_boundary" "late-stamp control"
  [[ "$FAIL" -eq 0 ]]
) > "$MD_TMP/late-stamp.log"; then
  fail "freshness-order control accepted a stamp after delegation"
else
  pass "control: delegation ordering rejects a late freshness stamp"
fi

# --- Codex Desktop app handoff ----------------------------------------------
# A working-tree starting state can begin the child before generated agents are
# visible, silently degrading every subagent to a generic worker.
assert_file_contains "$skill" "references/codex-runtime.md" "SKILL.md routes Codex app handoff to the runtime reference"
assert_file_contains "$codex_runtime_ref" "targeting a worktree environment whose \`startingState\` is \`{type: \"branch\"" \
  "Codex app handoff uses a branch starting state"
assert_file_contains "$codex_runtime_ref" "tracked under \`.codex/agents/*.toml\` in the saved project branch" \
  "Codex app handoff states the agent-visibility precondition"
assert_file_contains "$handoff" "Set the worktree \`startingState\` to \`{type: \"branch\", branchName: \"[BASE_BRANCH]\"}\`" \
  "handoff requires the branchName starting state"
assert_file_contains "$handoff" "resolve-base-branch" "handoff resolves the base branch before app thread creation"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
