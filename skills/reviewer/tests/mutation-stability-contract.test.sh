#!/usr/bin/env bash
# Contract test for the mutation-stability pairing: any test a reviewer
# mutation-validates also gets N repeat runs at elevated parallelism, both
# numbers are reported in one fixed format, and a mutation-pass +
# stability-fail is a finding, never a pass. The contract is markdown, so
# this test statically pins the canonical section in SKILL.md, the hooks
# that make it binding at validation time in both review workflows, and the
# duty mirror in the reviewer-test agent file (when the canonical agents
# directory is present alongside the skill).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_pattern() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    fail "$desc missing in ${file#$SKILL_DIR/}"
  fi
}

require_fixed() {
  local file="$1" needle="$2" desc="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$desc missing in ${file#$SKILL_DIR/}"
  fi
}

skill="$SKILL_DIR/SKILL.md"
review="$SKILL_DIR/workflows/review.md"
qa_review="$SKILL_DIR/workflows/qa-review.md"
[[ -f "$skill" ]] || fail "SKILL.md not found"
[[ -f "$review" ]] || fail "workflow not found: workflows/review.md"
[[ -f "$qa_review" ]] || fail "workflow not found: workflows/qa-review.md"

# --- canonical contract in SKILL.md ---

require_pattern "$skill" '^## Mutation-Stability Pairing' 'canonical Mutation-Stability Pairing section'
require_fixed "$skill" 'then reverting' 'mutation is reverted before reporting'
# The whole clause, not fragments: the version this replaced contained both
# `git archive` and a shared-tree prohibition while reading "a mutation that
# cannot be runs on a copy", which does not parse — and an instruction that
# cannot be parsed cannot be followed. Pin the two halves that carry the rule.
require_fixed "$skill" 'Plant and revert a mutation inside a single tool call' 'the default: plant and revert in one call'
require_fixed "$skill" 'when that is not possible, run it on a `git archive [SHA]` copy outside the worktree' 'the fallback names what to do and where'
require_fixed "$skill" 'never in the shared tree' 'the shared worktree is named as off limits'
require_fixed "$skill" 'default N=10' 'default repeat count'
require_fixed "$skill" '--test-threads' 'concrete elevated-parallelism example'
require_fixed "$skill" 'mutation: killed X/X; stability: Y/N at T threads' 'fixed two-number report format'

# The rule that PRODUCES the citation has to name the carrier the gate SCOPES
# to, or a reviewer following the pairing rule writes its own numbers into the
# finding they validate — where they are read as quoted evidence and never
# checked. That is the original incident shape reading green by placement.
require_fixed "$skill" "artifact's \`summary\`" 'pairing citation is required in the summary'
require_fixed "$skill" 'is not checked' 'pairing rule says a finding-only citation is unchecked'
require_fixed "$SKILL_DIR/schemas/review-finding.md" 'Mutation-Stability Pairing' 'schema doc points back at the producing rule'
require_fixed "$SKILL_DIR/schemas/review-finding.md" 'belongs in `.summary`' 'schema doc names the carrier for the pairing citation'
require_fixed "$skill" 'concurrency-sensitive' 'finding classification for stability failures'
require_fixed "$skill" 'never a pass' 'stability-fail-is-a-finding rule'

# --- the pairing binds at validation time in both review workflows ---

require_fixed "$review" 'Mutation-Stability Pairing' 'pairing hook in code-review workflow'
require_fixed "$qa_review" 'Mutation-Stability Pairing' 'pairing hook in QA-review workflow'

# --- reviewer-test agent mirrors the duty (when the canonical agents dir is present) ---

agent_file="$SKILL_DIR/../../agents/reviewer-test.md"
if [[ -f "$agent_file" ]]; then
  require_fixed "$agent_file" 'Mutation-Stability Pairing' 'duty mirror in reviewer-test agent'
  require_fixed "$agent_file" 'finding, not a pass' 'finding-not-pass rule in reviewer-test agent'
fi

echo "all pass"
