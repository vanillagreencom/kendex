#!/usr/bin/env bash
# A research decomposition that names its children is binding, not advisory:
# without that, per-item duplicate analysis folds a domain back into the parent
# and the decomposition silently collapses. These workflows are markdown
# contracts, so this test statically pins the chain — the input schema defines
# the block, research-complete emits it, tpm-audit treats it as a directive
# that bypasses inference, and audit-issues refuses non-compliant output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require() {
  local file="$1" pattern="$2" desc="$3"
  [[ -f "$file" ]] || fail "file not found: ${file#"$SKILL_DIR"/}"
  grep -Eq -- "$pattern" "$file" || fail "$desc missing in ${file#"$SKILL_DIR"/}"
}

# --- Schema defines the block and its obligations ---------------------------

schema="$SKILL_DIR/schemas/audit-issues-input.md"
require "$schema" 'hierarchy_contract' 'hierarchy_contract field'
require "$schema" 'decompose-under-parent' 'the one defined mode'
require "$schema" 'child_indexes' 'child_indexes field'
require "$schema" 'sequencing' 'sequencing field'
require "$schema" 'binding directive, not a hint' 'binding contract language'
require "$schema" 'MUST be created as a sub-issue of `hierarchy_contract\.parent_issue`' 'same-project child obligation'
require "$schema" 'MUST NOT be resolved to `skip`, `update`, `expand`, or `combine`' 'action-downgrade prohibition'
require "$schema" 'coordination-only' 'coordination-only parent conversion'
require "$schema" 'research-complete' 'research-complete as a source'

# --- Producer emits it with the right membership ----------------------------

research_complete="$SKILL_DIR/workflows/research-complete.md"
require "$research_complete" '`hierarchy_contract` \(required when `parent_issue` is non-null\)' 'contract emitted when a parent exists'
require "$research_complete" 'decompose-under-parent' 'mode in the emitted contract'
require "$research_complete" 'MUST create every listed item as a same-project child' 'binding emit language'
require "$research_complete" 'MUST NOT fold any domain back into the parent' 'parent-as-leaf prohibition'
require "$research_complete" 'exclude step 7 `origin: "discovered"` refactor items' 'discovered refactors excluded from child_indexes'
require "$research_complete" 'NOT listed in `hierarchy_contract\.child_indexes`' 'refactor items stay outside the contract'

# --- Analysis treats it as a directive, not a hint --------------------------

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" '`hierarchy_contract` \(binding' 'contract extracted as binding in issues mode'
require "$tpm_audit" '7\.0 Hierarchy Contract \(Binding\)' 'binding contract section at the § 7.0 anchor cited by audit-issues'
require "$tpm_audit" 'directive, not a hint' 'directive framing'
require "$tpm_audit" 'are BYPASSED' 'inference bypass for covered items'
require "$tpm_audit" 'MUST be `action: "create"` with `hierarchy' 'create-as-child output rule'
require "$tpm_audit" 'MUST NOT resolve to `skip`, `expand`, `update`, `combine`, or `cancel`' 'downgrade prohibition'
require "$tpm_audit" 'Never emit an update of the existing issue in place of the child create' 'scope moves into the child'
require "$tpm_audit" 'Hierarchy contract override \(MUST\)' 'action-assignment override'
require "$tpm_audit" 'regardless of duplicate/overlap findings' 'override outranks duplicate analysis'
require "$tpm_audit" 'Hierarchy-contract items .*are never `skip`' 'creation-bar exemption for covered items'
require "$tpm_audit" 'Every `hierarchy_contract\.child_indexes` item is `action: create`' 'pre-output compliance invariant'

# --- Caller refuses non-compliant output before presenting or executing -----

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require "$audit_issues" '[Hh]ierarchy contract' 'contract exception to TPM placement'
require "$audit_issues" 'Enforce the hierarchy contract' 'caller-side enforcement step'
require "$audit_issues" 'do NOT present or execute it' 'non-compliant output is neither presented nor executed'
require "$audit_issues" 'request a TPM rerun citing tpm-audit\.md § 7\.0' 'violation routes back to the binding section'
require "$audit_issues" 'never downgrade to standalone' 'standalone fallback prohibited for covered items'

echo "all pass"
