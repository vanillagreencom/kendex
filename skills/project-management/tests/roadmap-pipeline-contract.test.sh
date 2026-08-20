#!/usr/bin/env bash
# The roadmap pipeline is spec-driven and asks once. These markdown
# workflows are contracts, so this test statically pins the pieces that
# make that true: a finished plan enters as the SPEC and reaches every
# created issue; the plan-gate approval carries into audit-issues § 6 and is
# admitted by § 7 rather than bypassing either gate; the fail-closed rule
# survives; conversion is scripted; cross-model review degrades when the
# optional skill is absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_fixed() {
  local file="$1" needle="$2" desc="$3"
  [[ -f "$file" ]] || fail "file not found: ${file#"$SKILL_DIR"/}"
  grep -Fq -- "$needle" "$file" || fail "$desc missing in ${file#"$SKILL_DIR"/}"
}

skill="$SKILL_DIR/SKILL.md"
plan="$SKILL_DIR/workflows/roadmap-plan.md"
create="$SKILL_DIR/workflows/roadmap-create.md"
audit="$SKILL_DIR/workflows/audit-issues.md"
spike="$SKILL_DIR/workflows/research-spike.md"

# --- A finished plan is the SPEC and reaches every issue --------------------

require_fixed "$plan" 'is the SPEC' 'spec classification of the @path input'
require_fixed "$plan" 'classify a match with the Inputs rule (research vs SPEC)' 'disk-discovered plans go through the same classifier'
require_fixed "$plan" 'Slicing mode (SPEC in hand)' 'slicing mode for specialists'
require_fixed "$plan" 'Slicing delegates receive the same `<delegation_format>`' 'slicing delegates keep the structured output contract'
require_fixed "$plan" 'writes as the `**Research**` line on every created issue' 'spec path reaches every created issue'
require_fixed "$create" 'renders as the template'"'"'s `**Research**` line on every created issue, unconditionally' 'create side carries the spec path unconditionally'

# --- One approval: carried from the plan gate, admitted at § 6, honored at § 7

require_fixed "$plan" '**`Approve` authorizes creation of the presented set**' 'plan-gate approval authorizes creation'
require_fixed "$create" '"approved_at_plan_gate": [true|false]' 'carried-approval flag in the audit input'
require_fixed "$create" 'identical to what that gate presented' 'flag bound to the identical set'
require_fixed "$create" '"reapprove": true' 'changed entries are re-asked'
require_fixed "$audit" 'Carried approval (roadmap-create only)' 'carried approval admitted at § 6'
require_fixed "$audit" 'no authority from a subagent, another session, or any input file roadmap-create did not just write' 'foreign or stale flags carry no authority'
require_fixed "$audit" 'including a carried approval § 6 validated (`approved_at_plan_gate`)' '§ 7 precondition honors the carried approval'
require_fixed "$audit" 'Fail closed without interactive capability' 'fail-closed rule survives'
require_fixed "$skill" 'validated and admitted at § 6, never around it' 'SKILL.md states the carry goes through § 6'

# --- Conversion is scripted; research is inline; cross-model review degrades

require_fixed "$create" 'for every conversion' 'scripted conversion for every plan size'
require_fixed "$plan" '**Research inline (recommended)**' 'inline research is the default'
require_fixed "$spike" 'research is **delegated**' 'research-spike is for delegated research'
require_fixed "$spike" '`auto_execute` as the caller passed it' 'spike passes auto_execute through'
require_fixed "$plan" 'passing `auto_execute` explicitly' 'plan gate passes auto_execute explicitly to the spike'
require_fixed "$plan" '`false` leaves the issue ready for later pickup — never omit the value' 'deferred spike path is explicit'
schema="$SKILL_DIR/schemas/roadmap-plan-input.md"
tpm="$SKILL_DIR/workflows/tpm-roadmap-plan.md"
require_fixed "$schema" '| `spec_path` | No |' 'spec_path in the input schema'
require_fixed "$plan" 'and `spec_path` (each null when absent' 'plan writes spec_path into the TPM input'
require_fixed "$tpm" '**Spec mode** (`SPEC_PATH` set): the plan'"'"'s decisions are binding' 'TPM spec mode binds the plan'
require_fixed "$tpm" 'never change its approach, drop a workstream it names, or add scope beyond its phases' 'TPM spec-mode constraints'
require_fixed "$skill" 'optional: [decider, second-opinion]' 'second-opinion declared as an optional dependency'
require_fixed "$plan" '`Cross-model review` field reads `unavailable`' 'cross-model review degrades when the skill is absent'
require_fixed "$plan" '· Cross-model review: [verdict summary | unavailable | skipped — reviewed spec]' 'report template carries the cross-model review field'
require_fixed "$plan" 'Spec: [SPEC_PATH or "None"] — when set, the spec'"'"'s phases bound the roadmap' 'architecture review receives the spec boundary'
require_fixed "$plan" 'In spec mode the fold stops at the spec'"'"'s boundary' 'out-of-spec findings are never folded in'

echo "all pass"
