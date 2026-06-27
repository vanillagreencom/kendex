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

reject_fixed_string() {
  local file="$1" needle="$2" desc="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$desc remains in ${file#$SKILL_DIR/}"
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

unsupported_relations_cmd="cache issues relation""s"
if grep -R --line-number --fixed-strings -- "$unsupported_relations_cmd" "$SKILL_DIR/workflows" "$SKILL_DIR/README.md" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references" "$SKILL_DIR/schemas"; then
  fail 'unsupported Linear cache relation lookup subcommand remains in project-management docs'
fi

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require_pattern "$tpm_audit" 'cache issues get \[ISSUE_ID\]' 'supported cached issue fetch for relation analysis'
require_pattern "$tpm_audit" 'blocks`, `blocked_by`, and `related`' 'relation fields from cached issue JSON'
require_pattern "$tpm_audit" 'Return the JSON inline' 'TPM inline audit JSON return contract'
require_pattern "$tpm_audit" 'Do not write the artifact yourself' 'TPM child-does-not-write artifact contract'

tpm_audit_project_order="$SKILL_DIR/workflows/tpm-audit-project-order.md"
require_pattern "$tpm_audit_project_order" 'Return the JSON inline' 'TPM project-order inline JSON return contract'
require_pattern "$tpm_audit_project_order" 'Do not write the artifact yourself' 'TPM project-order child-does-not-write artifact contract'

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require_pattern "$audit_issues" 'Treat `File:` as a destination hint only' 'audit parent File hint handling'
require_pattern "$audit_issues" '[Ww]rite the inline JSON exactly to the resolved absolute path in the caller worktree' 'audit parent writes child JSON artifact'
require_pattern "$audit_issues" 'already-readable artifact inside the caller worktree' 'audit parent readable artifact fallback'
require_pattern "$audit_issues" 'request a TPM rerun with inline JSON' 'audit parent inline JSON rerun halt'
reject_fixed_string "$audit_issues" 'Agent returns `.JSON` file. If missing, halt.' 'audit parent assumes child-written JSON artifact'

echo "all pass"
