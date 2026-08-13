#!/usr/bin/env bash
# Contract tests for Codex spawn identity and the delegation-timestamp ordering.
#
# Codex must spawn the generated vstack agent as the runtime agent type rather
# than launching a generic worker and simulating identity in prompt text. The
# translation mechanics are BEHAVIOURALLY tested in spawn_adapter.sh; what is
# pinned here is that the docs still route to the adapter, still state the
# identity rule, still record the runtime spelling as metadata, and still stamp
# the review freshness boundary in the one position that makes it meaningful.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

PASS=0
FAIL=0

assert_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -Fq "$needle" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing: %s\n        file:    %s\n' "$name" "$needle" "$file"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -Fq "$needle" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden: %s\n        file:      %s\n' "$name" "$needle" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

assert_order() {
  local file="$1" first="$2" second="$3" name="$4"
  local first_line second_line
  first_line=$(grep -nF "$first" "$file" | head -n 1 | cut -d: -f1 || true)
  second_line=$(grep -nF "$second" "$file" | head -n 1 | cut -d: -f1 || true)
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        order: %s before %s\n        file:  %s\n' "$name" "$first" "$second" "$file"
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
development="$REPO_ROOT/skills/orch/DEVELOPMENT.md"

# --- Identity: routed through the adapter, canonical name is the identity ----
assert_not_contains "$skill" "Spawn workers with \`fork_context: false\`" "Codex guidance does not default to a generic worker"
assert_contains "$skill" "spawn-adapter spawn" "Codex guidance routes spawns through the adapter"
assert_contains "$skill" "canonical hyphenated" "Codex guidance tells the caller to pass the canonical name"
assert_contains "$skill" "identity everywhere orch records anything" "Codex guidance states the identity rule"
assert_contains "$skill" "runtime_metadata" "Codex guidance says where the runtime spelling belongs"
assert_contains "$skill" "fallback-reason" "Codex guidance names the explicit fallback path"
assert_contains "$skill" "never one" "Codex guidance keeps a schema rejection out of the fallback path"

# Every workflow that spawns reviewers or dev agents must route through the
# adapter too — a workflow that hand-rolls the translation is the regression.
for doc in "$review_pr" "$review" "$codebase"; do
  assert_contains "$doc" "spawn-adapter spawn" "$(basename "$doc") routes reviewer spawns through the adapter"
done
assert_contains "$dev_start" "spawn-adapter spawn" "dev-start routes dev spawns through the adapter"

# --- Runtime spelling stays metadata, never an identity key -----------------
assert_contains "$review_pr" "review_agent_runtime_types: (.review_agent_runtime_types // {})" \
  "review-pr loads existing reviewer runtime metadata before spawning"
assert_contains "$review_pr" ".review_agent_runtime_types = [AGENT_RUNTIME_TYPE_MAP_JSON]" \
  "review-pr persists reviewer runtime metadata alongside the ids"
assert_contains "$dev_start" "\"runtime_agent_type\": \"[RUNTIME_AGENT_TYPE]\"" "dev-start records the runtime agent type"
assert_contains "$dev_start" "\"agent_type_fallback\": [FALLBACK_REASON_JSON_OR_NULL]" "dev-start records the fallback reason"
assert_contains "$dev_start" "\"status\": \"active\"" "dev-start stamps the session live for slot accounting"

# --- Delegation-timestamp ordering ------------------------------------------
# review_delegated_at is the freshness boundary artifact acceptance is gated on.
# Stamped before the reviewer-state write it would also cover spawn/bootstrap
# output; stamped after the delegation it would accept a stale prior-cycle
# artifact. Only the position between them gates exactly the in-flight round.
assert_order "$review_pr" \
  ".agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [AGENT_LIST_JSON]" \
  ".agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at" \
  "review-pr stamps the freshness boundary after the reviewer-state write"
assert_order "$review_pr" \
  ".agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at" \
  "Delegate to every reviewer in the active set in parallel." \
  "review-pr stamps the freshness boundary before the delegation batch"
assert_contains "$review_pr" "re-stamp before each wave's batch" "review-pr re-stamps the boundary per wave"

# --- Codex Desktop app handoff ----------------------------------------------
# A working-tree starting state can begin the child before generated agents are
# visible, silently degrading every subagent to a generic worker.
assert_contains "$skill" "references/codex-runtime.md" "SKILL.md routes Codex app handoff to the runtime reference"
assert_contains "$codex_runtime_ref" "targeting a worktree environment whose \`startingState\` is \`{type: \"branch\"" \
  "Codex app handoff uses a branch starting state"
assert_contains "$codex_runtime_ref" "tracked under \`.codex/agents/*.toml\` in the saved project branch" \
  "Codex app handoff states the agent-visibility precondition"
assert_contains "$handoff" "Set the worktree \`startingState\` to \`{type: \"branch\", branchName: \"[BASE_BRANCH]\"}\`" \
  "handoff requires the branchName starting state"
assert_contains "$handoff" "resolve-base-branch" "handoff resolves the base branch before app thread creation"
assert_contains "$development" "setup hooks, \`WORKTREE_SYMLINKS\`, and \`codex-setup\` all run too late" \
  "development notes record the setup-timing failure mode"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
