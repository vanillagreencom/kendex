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

echo "=== Codex orch runtime agent type guidance ==="

skill="$REPO_ROOT/skills/orch/SKILL.md"
review_pr="$REPO_ROOT/skills/orch/workflows/review-pr.md"
review="$REPO_ROOT/skills/orch/workflows/review.md"
dev_start="$REPO_ROOT/skills/orch/workflows/dev-start.md"

assert_not_contains "$skill" "Spawn workers with \`fork_context: false\`" "Codex top-level guidance does not default to worker"
assert_contains "$skill" "Spawn generated vstack agents with \`agent_type\` set to the actual generated agent name" "Codex top-level guidance requires generated agent_type"
assert_contains "$skill" "Reviewers returned by \`list-review-agents\` must first spawn as \`agent_type=<reviewer-name>\`" "Codex top-level guidance names reviewer agent_type first"
assert_contains "$skill" "dev agents selected from \`agent:X\` labels must first spawn as \`agent_type=X\`" "Codex top-level guidance names dev agent_type first"
assert_contains "$skill" "after the generated-agent spawn is attempted and the Codex spawn API rejects or does not expose that generated \`agent_type\`" "Codex top-level guidance permits rejected generated-agent fallback"
assert_contains "$skill" "preserve the logical selected agent name in reports and workflow-state keys" "Codex top-level guidance preserves logical agent identity"
assert_contains "$skill" "record the runtime \`agent_type=worker\` and fallback reason separately" "Codex top-level guidance records fallback separately"

assert_contains "$review_pr" "first call the harness spawn API with \`agent_type\` equal to that reviewer name" "review-pr requires reviewer runtime agent_type first"
assert_contains "$review_pr" "unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated \`agent_type\`" "review-pr permits generated-agent unavailable fallback"
assert_contains "$review_pr" "persist the returned id under \`review_agent_ids[reviewer-name]\`" "review-pr keeps id keyed by reviewer name"
assert_contains "$review_pr" "record runtime metadata under \`review_agent_runtime_types[reviewer-name]\`" "review-pr records reviewer fallback metadata"

assert_contains "$review" "first call the harness spawn API with \`agent_type\` equal to that reviewer name" "review requires reviewer runtime agent_type first"
assert_contains "$review" "unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated \`agent_type\`" "review permits generated-agent unavailable fallback"
assert_contains "$review" "persist the returned id under \`review_agent_ids[reviewer-name]\`" "review keeps id keyed by reviewer name when state exists"
assert_contains "$review" "record runtime metadata under \`review_agent_runtime_types[reviewer-name]\`" "review records reviewer fallback metadata"

assert_contains "$dev_start" "The selected \`[AGENT_TYPE]\` is the Codex \`agent_type\` for the first harness spawn call" "dev-start maps selected agent to Codex agent_type first"
assert_contains "$dev_start" "unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated \`agent_type\`" "dev-start permits generated-agent unavailable fallback"
assert_contains "$dev_start" "keep the logical selected agent name in bootstrap/delegation text, reports, and workflow-state keys" "dev-start preserves logical dev identity"
assert_contains "$dev_start" "\"runtime_agent_type\": \"[RUNTIME_AGENT_TYPE]\"" "dev-start records runtime agent type"
assert_contains "$dev_start" "\"agent_type_fallback\": [FALLBACK_REASON_JSON_OR_NULL]" "dev-start records fallback reason"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
