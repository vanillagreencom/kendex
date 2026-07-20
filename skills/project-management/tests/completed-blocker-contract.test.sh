#!/usr/bin/env bash
# Regression test for the completed-blocker relation rule (#745).
# A blocking relation pointing at a Done/Cancelled issue is satisfied history —
# the tracker already treats the issue as unblocked. These workflows are
# markdown contracts, so this test statically verifies the rule end-to-end:
# dependencies.md documents the semantics, tpm-audit's relation checks forbid
# stale-metadata framing and emit a ready-to-schedule signal instead, and the
# output schema carries the ready_to_schedule[] finding array.
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

# --- Reference: references/dependencies.md documents the semantics ---

deps="$SKILL_DIR/references/dependencies.md"
[[ -f "$deps" ]] || fail "reference not found: references/dependencies.md"
require_pattern "$deps" 'Completed Blockers Are Satisfied History' 'completed-blockers section'
require_pattern "$deps" 'auto-satisfied' 'auto-satisfied semantics'
require_pattern "$deps" 'satisfied history, not stale metadata' 'satisfied-history (non-stale) framing'
require_pattern "$deps" 'Never remove or "fix" a relation because its blocker is Done/Canceled' 'removal prohibition'
require_pattern "$deps" 'must never classify completed-blocker relations as stale metadata' 'stale-classification prohibition'
require_pattern "$deps" 'gates cleared, ready to schedule' 'scheduling signal as only legitimate output'
require_pattern "$deps" 'STALE blocked_by METADATA' 'observed failure mode as cautionary rationale'
require_pattern "$deps" 'the relation itself stays as satisfied history' 'resolving-a-blocker checklist keeps the relation'

# --- Workflow: tpm-audit § 4.4 relation checks enforce the rule ---

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require_pattern "$tpm_audit" 'Completed-blocker relations are auto-satisfied, never stale' 'completed-blocker rule in § 4.4'
require_pattern "$tpm_audit" 'Do NOT add such relations to `remove_relations\[\]`' 'remove_relations prohibition'
require_pattern "$tpm_audit" 'do NOT report them under any stale-metadata heading' 'stale-metadata heading prohibition'
require_pattern "$tpm_audit" 'STALE blocked_by METADATA' 'observed failure mode as cautionary rationale'
require_pattern "$tpm_audit" 'scheduling signal: add it to `ready_to_schedule\[\]`' 'ready-to-schedule signal instruction'
require_pattern "$tpm_audit" 'Completed-blocker relations preserved \(surfaced only as ready-to-schedule signals, never flagged as stale or removed\)' 'pre-output verification checklist item'

# --- Schema: audit-output.md carries the ready_to_schedule finding array ---

schema="$SKILL_DIR/schemas/audit-output.md"
require_pattern "$schema" '`ready_to_schedule\[\]` \| `id`, `title`, `cleared_blockers\[\]`, `reason`' 'ready_to_schedule finding array fields'
require_pattern "$schema" 'Scheduling signal only' 'ready_to_schedule signal-only semantics'
require_pattern "$schema" 'never stale metadata' 'schema-level non-stale framing'
require_pattern "$schema" '"ready_to_schedule": \[\]' 'ready_to_schedule in findings template'
require_pattern "$schema" '"ready_to_schedule": 0' 'ready_to_schedule in summary counts'

echo "all pass"
