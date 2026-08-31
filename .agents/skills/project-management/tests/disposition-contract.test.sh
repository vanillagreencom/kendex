#!/usr/bin/env bash
# The TPM's job is to keep the backlog small and true, not to file everything
# noticed. Three rules carry that and are easy to lose in an edit: an issue is
# filed only when it clears the creation bar, an audit that creates also closes,
# and the user is asked about work rather than about metadata mechanics. This
# test pins each rule's NAME at the place that cites it — the names are what
# other documents reference — and pins the retired parallelism ceremony as
# absent.
#
# What this pins is STRUCTURE — the `## Disposition` heading, the three
# bolded rule labels other documents cite by name, the § 10.1 heading, the
# below_bar evidence fields, the two gate questions verbatim, and the report
# template lines.
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
require "$skill" 'Burn down more than you create' 'burn-down rule'
require "$skill" 'created N / closed M' 'net reporting obligation'
require "$skill" 'Ask about work, never about mechanics' 'question-scope rule'

# --- The analysis workflows apply it ----------------------------------------

for rel in workflows/tpm-audit.md workflows/tpm-roadmap-plan.md; do
  file="$SKILL_DIR/$rel"
  require "$file" '[Hh]old the creation bar' 'creation bar invoked'
  require "$file" 'Disposition' 'pointer to the canonical rule'
done

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" '10\.1 Apply the Creation Bar' 'creation bar gate before action assignment'
require "$tpm_audit" 'below_bar: true, test, who_hits_it' 'below-bar evidence shape'
require "$tpm_audit" 'cancellation sweep' 'cancellation sweep is a named obligation'

# --- The wrapper asks about work only ---------------------------------------

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require "$audit_issues" '"Create these issues\?"' 'creation question'
require "$audit_issues" '"Cancel these issues\?"' 'cancellation question'
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
