#!/usr/bin/env bash
# Contract tests for Codex spawn identity.
#

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

# shellcheck source=lib/md.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== Codex spawn identity ==="

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
