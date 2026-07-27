#!/usr/bin/env bash
# Regression tests for Codex orch delegation guidance. Codex must spawn the
# generated vstack agent as the runtime agent type instead of using worker and
# relying on prompt text to simulate identity.

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

echo "=== Codex orch runtime agent type guidance ==="

skill="$REPO_ROOT/skills/orch/SKILL.md"
codex_runtime_ref="$REPO_ROOT/skills/orch/references/codex-runtime.md"
review_pr="$REPO_ROOT/skills/orch/workflows/review-pr.md"
review="$REPO_ROOT/skills/orch/workflows/review.md"
dev_start="$REPO_ROOT/skills/orch/workflows/dev-start.md"
handoff="$REPO_ROOT/skills/orch/workflows/handoff.md"
readme="$REPO_ROOT/skills/orch/README.md"
development="$REPO_ROOT/skills/orch/DEVELOPMENT.md"

assert_not_contains "$skill" "Spawn workers with \`fork_context: false\`" "Codex top-level guidance does not default to worker"
# vstack#900 moved the spawn mechanics out of this prose and into
# `scripts/spawn-adapter`, so the six assertions that used to pin literal
# sentences here now live as BEHAVIOURAL tests in `spawn_adapter.sh`:
# agent_type resolves to the canonical name, worker only on an explicit
# --fallback-reason, the record keys on the canonical identity, and the runtime
# spelling plus fallback reason are confined to runtime_metadata.
#
# What remains worth pinning in the doc is that it still ROUTES to the adapter
# and still states the identity rule — a workflow that stopped saying either
# would leave orchestrators hand-rolling the translation again, which is the
# regression this issue existed to prevent.
assert_contains "$skill" "spawn-adapter spawn" "Codex guidance routes spawns through the adapter"
assert_contains "$skill" "canonical hyphenated" "Codex guidance tells the caller to pass the canonical name"
assert_contains "$skill" "identity everywhere orch records anything" "Codex guidance states the identity rule"
assert_contains "$skill" "runtime_metadata" "Codex guidance says where the runtime spelling belongs"
assert_contains "$skill" "fallback-reason" "Codex guidance names the explicit fallback path"
assert_contains "$skill" "never one" "Codex guidance keeps a schema rejection out of the fallback path"

assert_contains "$review_pr" "first call the harness spawn API with \`agent_type\` equal to that reviewer name" "review-pr requires reviewer runtime agent_type first"
assert_contains "$review_pr" "unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated \`agent_type\`" "review-pr permits generated-agent unavailable fallback"
assert_contains "$review_pr" "persist the returned id under \`review_agent_ids[reviewer-name]\`" "review-pr keeps id keyed by reviewer name"
assert_contains "$review_pr" "record runtime metadata under \`review_agent_runtime_types[reviewer-name]\`" "review-pr records reviewer fallback metadata"
assert_contains "$review_pr" "review_agent_runtime_types: (.review_agent_runtime_types // {})" "review-pr loads existing reviewer runtime metadata"
assert_contains "$review_pr" "\`review_agent_runtime_types\` as \`EXISTING_REVIEW_AGENT_RUNTIME_TYPES\` from the JSON object." "review-pr names existing runtime metadata state"
assert_contains "$review_pr" "carry forward any \`EXISTING_REVIEW_AGENT_RUNTIME_TYPES[reviewer-name]\` entry into \`AGENT_RUNTIME_TYPE_MAP_JSON\`" "review-pr preserves reusable reviewer runtime metadata"
assert_contains "$review_pr" "When writing \`review_agent_runtime_types\`, include preserved entries for reused reviewers and new/updated entries for reviewers launched in this step." "review-pr writes preserved and new runtime metadata"
assert_contains "$review_pr" "**Do NOT spawn or delegate yet.** Continue to § 2.1 to resolve external review availability before launching reviewers." "review-pr resolves external availability before reviewer launch"
assert_contains "$review_pr" "For each reviewer in \`REVIEWERS_TO_LAUNCH\`, spawn it now." "review-pr launches missing reviewers in section 2.2"
assert_contains "$review_pr" "**Record delegation timestamp immediately before the actual delegation batch**" "review-pr timestamp is tied to actual delegation"
assert_contains "$review_pr" "output produced during reviewer spawn/bootstrap" "review-pr timestamp excludes spawn/bootstrap output"
assert_contains "$review_pr" "Start the coordinated delegation batch:" "review-pr labels actual delegation batch"
assert_order "$review_pr" ".agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.review_agents = [AGENT_LIST_JSON]" ".agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at" "review-pr records timestamp after reviewer state writes"
assert_order "$review_pr" ".agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] review_delegated_at" "Delegate to each active reviewer in \`[AGENTS]\` in parallel." "review-pr records timestamp before reviewer delegation"

assert_contains "$review" "first call the harness spawn API with \`agent_type\` equal to that reviewer name" "review requires reviewer runtime agent_type first"
assert_contains "$review" "unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated \`agent_type\`" "review permits generated-agent unavailable fallback"
assert_contains "$review" "persist the returned id under \`review_agent_ids[reviewer-name]\`" "review keeps id keyed by reviewer name when state exists"
assert_contains "$review" "record runtime metadata under \`review_agent_runtime_types[reviewer-name]\`" "review records reviewer fallback metadata"

assert_contains "$dev_start" "The selected \`[AGENT_TYPE]\` is the Codex \`agent_type\` for the first harness spawn call" "dev-start maps selected agent to Codex agent_type first"
assert_contains "$dev_start" "unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated \`agent_type\`" "dev-start permits generated-agent unavailable fallback"
assert_contains "$dev_start" "keep the logical selected agent name in bootstrap/delegation text, reports, and workflow-state keys" "dev-start preserves logical dev identity"
assert_contains "$dev_start" "\"runtime_agent_type\": \"[RUNTIME_AGENT_TYPE]\"" "dev-start records runtime agent type"
assert_contains "$dev_start" "\"agent_type_fallback\": [FALLBACK_REASON_JSON_OR_NULL]" "dev-start records fallback reason"

# The app-handoff mechanism moved to references/codex-runtime.md (issue #902);
# SKILL.md keeps the route. Same guarantees, new home.
assert_contains "$skill" "references/codex-runtime.md" "SKILL.md routes Codex app handoff to the runtime reference"
assert_contains "$codex_runtime_ref" "target a worktree environment whose \`startingState\` is \`type=\"branch\"\`" "Codex app handoff uses branch starting state in the runtime reference"
assert_contains "$codex_runtime_ref" "If preflight reports a warning, present the exact message and continue only after explicit user acceptance" "Codex app handoff warning requires user acceptance"
assert_contains "$handoff" "Use the output as \`BASE_BRANCH\`" "handoff resolves base branch before app thread creation"
assert_contains "$handoff" ".agents/skills/orch/scripts/codex-app-agent-preflight ." "handoff invokes generated-agent preflight helper"
assert_contains "$handoff" "Continue only after the user explicitly accepts" "handoff permits warning only after user acceptance"
assert_contains "$handoff" "Set the worktree \`startingState\` to \`{type: \"branch\", branchName: \"[BASE_BRANCH]\"}\`" "handoff requires branchName starting state"
assert_contains "$handoff" "Do not use \`{type: \"working-tree\"}\` for orch handoff" "handoff forbids normal working-tree app launch"
assert_contains "$readme" "startingState: {type: \"branch\", branchName: \"[BASE_BRANCH]\"}" "README documents branchName app handoff"
assert_contains "$readme" "run \`skills/orch/scripts/codex-app-agent-preflight .\`" "README documents app handoff preflight"
assert_contains "$readme" "continue only after the user explicitly accepts the risk" "README documents warning acceptance"
assert_contains "$development" "setup hooks, \`WORKTREE_SYMLINKS\`, and \`codex-setup\` run too late" "development docs record setup timing failure mode"
assert_contains "$development" "warning gate, not a hard blocker" "development docs record non-blocking preflight"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
