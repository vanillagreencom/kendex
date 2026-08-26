#!/usr/bin/env bash
# The TPM's job is to keep the backlog small and true, not to file everything
# noticed. Three rules carry that and are easy to lose in an edit: an issue is
# filed only when it clears the creation bar, an audit that creates also closes,
# and the user is asked about work rather than about metadata mechanics. These
# workflows are markdown contracts, so this test pins each rule at the place
# that acts on it, and pins the retired parallelism ceremony as absent.
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

# --- The bar is stated once, canonically ------------------------------------

skill="$SKILL_DIR/SKILL.md"
require "$skill" '## Disposition' 'disposition section'
require "$skill" 'Creation bar' 'creation bar rule'
require "$skill" 'all three hold' 'all three tests must hold'
require "$skill" 'changes what a user or operator experiences' 'user-visible-effect test'
require "$skill" 'no open issue, active branch, or one-line fix already covers it' 'already-covered test'
require "$skill" 'without a new investigation' 'finishable-as-written test'
require "$skill" 'declined with one line' 'declined items get one line, not an issue'
require "$skill" 'severe-sounding edge case that no real input reaches' 'severe-edge-case exclusion'
require "$skill" 'Burn down more than you create' 'burn-down rule'
require "$skill" 'created N / closed M' 'net reporting obligation'
require "$skill" 'Ask about work, never about mechanics' 'question-scope rule'
require "$skill" '[Ll]abels, priorities, relations, hierarchy, sort order, and project moves' 'mechanics applied without asking'

# --- The analysis workflows apply it ----------------------------------------

for rel in workflows/tpm-audit.md workflows/tpm-roadmap-plan.md; do
  file="$SKILL_DIR/$rel"
  require "$file" '[Hh]old the creation bar' 'creation bar invoked'
  require "$file" 'Disposition' 'pointer to the canonical rule'
  require "$file" 'one-line reason|one line each|one-line `reason`' 'declined items carry a one-line reason'
done

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" '10\.1 Apply the Creation Bar' 'creation bar gate before action assignment'
require "$tpm_audit" 'naming the test it failed|naming the failed creation-bar test' 'skip reason names the failing test'
require "$tpm_audit" 'cancellation sweep' 'cancellation sweep is a named obligation'
require "$tpm_audit" 'A gap that nothing depends on and no user would notice is declined' 'architecture gaps face the same bar'

# --- The wrapper asks about work only ---------------------------------------

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require "$audit_issues" 'Ask only about work, never about mechanics' 'gate scope rule'
require "$audit_issues" '"Create these issues\?"' 'creation question'
require "$audit_issues" '"Cancel these issues\?"' 'cancellation question'
require "$audit_issues" 'applied in § 7 without a question' 'corrections are not questions'
require "$audit_issues" 'Corrections applied automatically' 'corrections reported, not asked'
require "$audit_issues" 'created \[N\] / closed \[M\]' 'net headline in the report'
require "$audit_issues" 'Declined' 'declined items are reported'

# The mechanical categories must NOT reappear as approval questions.
gate="$(mktemp)"
trap 'rm -f "$gate"' EXIT
sed -n '/^## 6\. /,/^## 7\. /p' "$audit_issues" >"$gate"
[[ -s "$gate" ]] || fail 'could not extract the approval gate section'
for mechanic in 'Fix priorities' 'Fix agent labels' 'Fix missing labels' \
                'Add relations' 'Apply hierarchy changes' 'Move to project'; do
  if grep -Fq -- "$mechanic" "$gate"; then
    fail "the approval gate still asks a mechanics question: $mechanic"
  fi
done

# --- The parallelism ceremony is gone ---------------------------------------

if grep -rInE 'parallel-check|parallel-groups|parallel_groups' "$SKILL_DIR" \
     --include='*.md' --include='*.sh' | grep -v "$(basename "${BASH_SOURCE[0]}")"; then
  fail 'a retired parallelism-ceremony reference remains'
fi

echo "all pass"
