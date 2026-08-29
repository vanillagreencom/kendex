#!/usr/bin/env bash
# A research decomposition that names its children is binding, not advisory.
# This test pins the STRUCTURE that chain is built from — schema fields, the
# mode and status values, the § 7.0 heading, the two bolded rule labels, the
# rerun route — never the sentences that state what they oblige.
# review-bots.md: a token pin establishes that a structural element is
# present, never that a behavioral claim written in prose is true.
#
# So these rules have no lint. The schema's own framing of the block as a
# binding directive rather than a hint, and its prohibition on downgrading a
# covered item to skip, update, expand or combine. research-complete's
# obligation to create every listed item as a same-project child and to fold
# no domain back into the parent. tpm-audit's framing of the contract as a
# directive, its statement that inference is bypassed for covered items, its
# ban on emitting an update in place of the child create, the override
# outranking duplicate and overlap findings, covered items never being skip,
# and the pre-output invariant that every child_indexes item is a create.
# audit-issues' rule that non-compliant output is neither presented nor
# executed, and that a covered item never downgrades to standalone. Each
# lives in a sentence with no token present exactly while it holds.
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
require "$schema" 'hierarchy_contract\.parent_issue' 'the parent_issue field the children hang off'
require "$schema" 'coordination-only' 'coordination-only parent conversion'
require "$schema" 'research-complete' 'research-complete as a source'

# --- Producer emits it with the right membership ----------------------------

research_complete="$SKILL_DIR/workflows/research-complete.md"
require "$research_complete" '`parent_issue`' 'the emitted contract names its parent field'
require "$research_complete" 'decompose-under-parent' 'mode in the emitted contract'
require "$research_complete" 'origin: "discovered"' 'the discovered origin the membership rule excludes'
require "$research_complete" 'hierarchy_contract\.child_indexes' 'the membership field'

# --- Analysis carries the contract's own anchors ----------------------------

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" 'hierarchy_contract' 'the contract is extracted in issues mode'
require "$tpm_audit" '7\.0 Hierarchy Contract \(Binding\)' 'binding contract section at the § 7.0 anchor cited by audit-issues'
require "$tpm_audit" 'action: "create"' 'the create action covered items take'
require "$tpm_audit" 'Hierarchy contract override \(MUST\)' 'action-assignment override'

# --- Caller carries the enforcement step and the rerun route ----------------

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require "$audit_issues" '[Hh]ierarchy contract' 'the caller knows the contract'
require "$audit_issues" 'Enforce the hierarchy contract' 'caller-side enforcement step'
require "$audit_issues" 'tpm-audit\.md § 7\.0' 'the rerun route names the binding section anchor'

echo "all pass"
