#!/usr/bin/env bash
# Regression test for the research-complete hierarchy contract (#551).
# These workflows are markdown contracts, so this test statically verifies that
# pervasive research decomposition is binding end-to-end: the input schema
# documents `hierarchy_contract`, research-complete § 6.5 emits it, tpm-audit
# treats it as a directive that bypasses duplicate/hierarchy inference, and
# audit-issues enforces compliance before presenting or executing TPM output.
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

# --- Schema: schemas/audit-issues-input.md documents the contract block ---

schema="$SKILL_DIR/schemas/audit-issues-input.md"
[[ -f "$schema" ]] || fail "schema not found: schemas/audit-issues-input.md"
require_pattern "$schema" 'hierarchy_contract' 'hierarchy_contract field'
require_pattern "$schema" 'decompose-under-parent' 'decompose-under-parent mode'
require_pattern "$schema" 'child_indexes' 'child_indexes field'
require_pattern "$schema" 'sequencing' 'sequencing field'
require_pattern "$schema" 'binding directive, not a hint' 'binding (non-hint) contract language'
require_pattern "$schema" 'MUST be created as a sub-issue of `hierarchy_contract\.parent_issue`' 'same-project child MUST rule'
require_pattern "$schema" 'MUST NOT be resolved to `skip`, `update`, `expand`, or `combine`' 'action-downgrade prohibition'
require_pattern "$schema" 'coordination-only parent' 'coordination-only parent conversion'
require_pattern "$schema" 'research-complete\|roadmap' 'research-complete source enum value'

# --- Producer: research-complete § 6.5 emits the contract ---

research_complete="$SKILL_DIR/workflows/research-complete.md"
require_pattern "$research_complete" '`hierarchy_contract` \(required when `parent_issue` is non-null\)' 'audit-input hierarchy_contract construction'
require_pattern "$research_complete" 'decompose-under-parent' 'contract mode in audit-input construction'
require_pattern "$research_complete" 'MUST create every listed item as a same-project child' 'binding decomposition emit language'
require_pattern "$research_complete" 'MUST NOT fold any domain back into the parent' 'parent-as-leaf prohibition'
require_pattern "$research_complete" 'exclude step 7 `origin: "discovered"` refactor items' 'discovered refactors excluded from child_indexes'

# --- TPM: tpm-audit extracts the contract and treats it as binding ---

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require_pattern "$tpm_audit" 'HIERARCHY_CONTRACT` from `hierarchy_contract` field' 'contract extraction in ISSUES mode'
require_pattern "$tpm_audit" '7\.0 Hierarchy Contract \(Binding\)' 'binding hierarchy contract section'
require_pattern "$tpm_audit" 'duplicate/overlap action downgrades \(§ 6\.1\) are BYPASSED' 'inference bypass for contract items'
require_pattern "$tpm_audit" 'MUST be `action: "create"` with `hierarchy' 'create-as-child MUST output rule'
require_pattern "$tpm_audit" 'MUST NOT resolve to `skip`, `expand`, `update`, `combine`, or `cancel`' 'contract-item downgrade prohibition'
require_pattern "$tpm_audit" 'never emit an update of the existing issue in place of the child create' 'scope moves into child, not update'
require_pattern "$tpm_audit" 'Hierarchy contract override \(MUST\)' 'action-determination override rule'
require_pattern "$tpm_audit" 'never resolves to `skip`, `expand`, `update`, `combine`, or `cancel`, regardless of duplicate/overlap findings' 'override supremacy over steps 1-6'
require_pattern "$tpm_audit" 'Hierarchy-contract items.*are never `skip`' 'actionability skip guard for contract items'
require_pattern "$tpm_audit" 'except `hierarchy_contract`, which is binding per § 7\.0' 'hint vs directive distinction in § 7.1'
require_pattern "$tpm_audit" '7\.0/10\.2: Every `hierarchy_contract\.child_indexes` item has `action: create`' 'pre-output contract compliance checklist'

# --- Caller: audit-issues enforces compliance deterministically ---

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require_pattern "$audit_issues" 'Exception — hierarchy contract' 'hierarchy-contract exception to TPM placement'
require_pattern "$audit_issues" 'Enforce hierarchy contract' 'caller-side contract enforcement step'
require_pattern "$audit_issues" 'do NOT present or execute it' 'non-compliant output execution block'
require_pattern "$audit_issues" 'request a TPM rerun citing tpm-audit\.md § 7\.0' 'contract-violation rerun requirement'
require_pattern "$audit_issues" 'never downgrade to standalone' 'standalone fallback prohibition for contract items'

echo "all pass"
