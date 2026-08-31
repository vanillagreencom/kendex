#!/usr/bin/env bash
# A blocking relation pointing at a Done/Cancelled issue is satisfied history:
# the tracker already treats the dependent issue as unblocked, so removing the
# relation destroys valid provenance. This test pins the rule's ANCHORS, not
# the rule end to end: the reference's defined term, the field the analysis
# scopes its removals by, and the scheduling signal the output schema carries.
#
# What this pins is STRUCTURE — the `auto-satisfied` defined term, the
# `ready_to_schedule` and `cleared_blockers` schema fields, `remove_relations`,
# and the JSON template and summary literals.
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
require "$deps" 'ready_to_schedule' 'the scheduling signal field'

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" 'remove_relations' 'the relation-removal field the rule scopes'
require "$tpm_audit" 'ready_to_schedule' 'ready-to-schedule signal instruction'

schema="$SKILL_DIR/schemas/audit-output.md"
require "$schema" '`ready_to_schedule\[\]`.*`cleared_blockers\[\]`' 'ready_to_schedule fields'
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
