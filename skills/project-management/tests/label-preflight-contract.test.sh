#!/usr/bin/env bash
# Regression test for project-management Linear issue-label contract.
# These workflows are markdown contracts, so this test statically verifies that
# create/update paths load issue-label inventory, require strict preflight, and
# avoid hard-coded project-specific research labels.
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

mutation_workflows=(
  workflows/roadmap-create.md
  workflows/audit-issues.md
  workflows/research-issue.md
  workflows/research-complete.md
  workflows/cycle-plan.md
)

for rel in "${mutation_workflows[@]}"; do
  file="$SKILL_DIR/$rel"
  [[ -f "$file" ]] || fail "workflow not found: $rel"
  require_pattern "$file" 'cache labels list --format=safe' 'issue-label inventory load'
  require_pattern "$file" 'labels\.md|Strict Label Preflight|Label Policy|label policy|preflight' 'label preflight reference'
  require_pattern "$file" 'Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation|unknown labels, parent/group labels, missing required categories, or exclusivity violations halt' 'strict halt behavior'
done

roadmap_plan="$SKILL_DIR/workflows/roadmap-plan.md"
require_pattern "$roadmap_plan" 'RESEARCH_WORKFLOW_LABEL' 'taxonomy-derived research lookup label'
require_pattern "$roadmap_plan" 'do not query a hard-coded fallback label' 'hard-coded research fallback guard'

research_spike="$SKILL_DIR/workflows/research-spike.md"
require_pattern "$research_spike" 'RESEARCH_WORKFLOW_LABEL' 'taxonomy-derived research spike lookup label'
require_pattern "$research_spike" 'do not query a hard-coded fallback label' 'research spike hard-coded fallback guard'

research_issue="$SKILL_DIR/workflows/research-issue.md"
require_pattern "$research_issue" 'RESEARCH_WORKFLOW_LABEL' 'taxonomy-derived research create label'
require_pattern "$research_issue" 'do not assume the literal name `research` exists' 'literal research label guard'

if grep -R --line-number -E -- '--label(=|[[:space:]]+)"?research"?([[:space:]]|$)' "$SKILL_DIR/workflows"; then
  fail 'hard-coded --label research remains in project-management workflows'
fi

if grep -R --line-number --fixed-strings -- '["agent:researcher", "research", DOMAINS...]' "$SKILL_DIR/workflows"; then
  fail 'hard-coded research create label remains in VALIDATED_LABELS'
fi

echo "all pass"
