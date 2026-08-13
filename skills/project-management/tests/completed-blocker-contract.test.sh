#!/usr/bin/env bash
# A blocking relation pointing at a Done/Cancelled issue is satisfied history:
# the tracker already treats the dependent issue as unblocked, so removing the
# relation destroys valid provenance. These workflows are markdown contracts,
# so this test statically pins the rule end to end — the reference states the
# semantics, the analysis workflow forbids removal and stale framing and emits
# a scheduling signal instead, and the output schema carries that signal.
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
  grep -Eqi -- "$pattern" "$file" || fail "$desc missing in ${file#"$SKILL_DIR"/}"
}

forbid() {
  local file="$1" pattern="$2" desc="$3"
  ! grep -Eqi -- "$pattern" "$file" || fail "$desc present in ${file#"$SKILL_DIR"/}"
}

deps="$SKILL_DIR/references/dependencies.md"
require "$deps" 'auto-satisfied' 'auto-satisfied semantics'
require "$deps" 'satisfied history' 'satisfied-history framing'
require "$deps" 'never remove.*because its blocker is done' 'removal prohibition'
require "$deps" 'never list one under a stale-metadata heading' 'stale-heading prohibition'
require "$deps" 'ready.to.schedule' 'scheduling signal as the only legitimate output'

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" 'auto-satisfied, never stale' 'completed-blocker rule in the relation checks'
require "$tpm_audit" 'do NOT add such relations to .remove_relations' 'remove_relations prohibition'
require "$tpm_audit" 'do NOT report them under any stale-metadata heading' 'stale-heading prohibition'
require "$tpm_audit" 'ready_to_schedule' 'ready-to-schedule signal instruction'
require "$tpm_audit" 'no completed-blocker relation appears in .remove_relations' 'pre-output invariant'

schema="$SKILL_DIR/schemas/audit-output.md"
require "$schema" '`ready_to_schedule\[\]`.*`cleared_blockers\[\]`' 'ready_to_schedule fields'
require "$schema" 'scheduling signal only' 'signal-only semantics'
require "$schema" 'never stale metadata' 'schema-level non-stale framing'
require "$schema" '"ready_to_schedule": \[\]' 'ready_to_schedule in the findings template'
require "$schema" '"ready_to_schedule": 0' 'ready_to_schedule in the summary counts'

# The inverse must stay absent everywhere: no doc may direct an agent to emit a
# completed-blocker relation as a defect or as a removal.
for doc in "$deps" "$tpm_audit" "$schema" "$SKILL_DIR/workflows/audit-issues.md"; do
  forbid "$doc" '(flag|report|list|classify|treat) .*(completed|done)[- ]blocker relations? as stale' \
    'completed-blocker relation treated as stale metadata'
  forbid "$doc" 'stale (blocked_by|blocker|relation) metadata (section|heading|report)' \
    'stale-metadata output shape'
done

echo "all pass"
