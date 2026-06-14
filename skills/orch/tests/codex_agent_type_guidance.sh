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
assert_contains "$skill" "Reviewers returned by \`list-review-agents\` must spawn as \`agent_type=<reviewer-name>\`" "Codex top-level guidance names reviewer agent_type"
assert_contains "$skill" "dev agents selected from \`agent:X\` labels must spawn as \`agent_type=X\`" "Codex top-level guidance names dev agent_type"
assert_contains "$skill" "Use \`worker\` only for an intentional generic-worker fallback" "Codex top-level guidance documents worker fallback"

assert_contains "$review_pr" "call the harness spawn API with \`agent_type\` equal to that reviewer name" "review-pr requires reviewer runtime agent_type"
assert_contains "$review_pr" "Do not launch \`worker\` and simulate reviewer identity in the prompt" "review-pr forbids prompt-only reviewer identity"
assert_contains "$review_pr" "Persist the returned agent id under \`review_agent_ids[reviewer-name]\`" "review-pr keeps id keyed by reviewer name"

assert_contains "$review" "call the harness spawn API with \`agent_type\` equal to that reviewer name" "review requires reviewer runtime agent_type"
assert_contains "$review" "Do not launch \`worker\` and simulate reviewer identity in the prompt" "review forbids prompt-only reviewer identity"
assert_contains "$review" "persist the returned agent id under \`review_agent_ids[reviewer-name]\`" "review keeps id keyed by reviewer name when state exists"

assert_contains "$dev_start" "The selected \`[AGENT_TYPE]\` is the Codex \`agent_type\` for the harness spawn call" "dev-start maps selected agent to Codex agent_type"
assert_contains "$dev_start" "Do not launch \`worker\` and simulate the selected dev identity in the prompt" "dev-start forbids prompt-only dev identity"
assert_contains "$dev_start" "Use \`worker\` only when no matching custom agent exists or when the selected agent is intentionally generic" "dev-start documents worker fallback"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
