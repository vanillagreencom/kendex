#!/usr/bin/env bash
# The roadmap pipeline is spec-driven and asks once. This test pins the
# STRUCTURE that pipeline is built from — schema fields and rows, JSON
# literals, template lines, section labels, mode names, status values —
# never the sentences that state what those pieces mean. review-bots.md: a
# token pin establishes that a structural element is present, never that a
# behavioral claim written in prose is true.
#
# Every rule below therefore has NO lint, because each lives only in prose
# and carries no token present exactly while it holds. On the plan side:
# that an @path input or a § 1 disk match is classified as a SPEC and both
# go through the same classifier; that a selected disk artifact ends the
# gate and the tracker is queried only when the disk search finds nothing;
# that Approve authorizes the presented creation set and the existing-work
# actions as presented; that the creation set never contains Deferred-project
# entries; that a non-major plan records the review as not required; that
# major is the ten-entries / two-domains / breaking-change / high-risk
# predicate; that the architecture fold stops at the spec boundary, invents
# no issue fields, and sends every standalone addition back through § 2;
# that an unavailable cross-model review carries its reason; and that the
# deferred spike path never omits its value. On the create side: that the
# spec path reaches every created issue unconditionally; that actions
# unchanged since the plan gate execute without re-asking; that the flag is
# bound to same-session provenance and is false only when provenance fails;
# that omitted entries never void approval for unchanged survivors; that
# entries § 2 executed or skipped are omitted from the audit input and
# cannot be overridden downstream; that an executed supersession still files
# its replacement; that conflict resolutions are applied before conversion
# and only changed ones are re-asked; that references to omitted entries
# retarget or re-enter § 5 rather than dangle; and that existing-work carry
# needs the same provenance. On the audit side: that § 6 partitions by
# reapprove rather than set equality, excludes cancellations already decided
# at § 2, grants no authority to a foreign or stale flag, and fails closed
# without interactive capability, and that SKILL.md states the carry goes
# through § 6 rather than around it. On the TPM side: that spec mode binds
# the plan's approach, workstreams and phases. And that the two audit-output
# flags travel together, and that conversion is scripted for every plan.
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

require_fixed "$plan" 'Slicing mode (SPEC in hand)' 'slicing mode for specialists'
require_fixed "$plan" '`<delegation_format>`' 'slicing delegates keep the structured output contract'
require_fixed "$plan" '`**Research**`' 'the spec path renders as the Research template line'
require_fixed "$create" '`**Research**`' 'create side renders the same Research template line'
require_fixed "$plan" '`@[path]`' 'the @path input is documented'

# --- One approval: carried from the plan gate, admitted at § 6, honored at § 7

require_fixed "$plan" 'EXISTING WORK AFFECTED' 'the plan report has an existing-work section'
require_fixed "$create" '"approved_at_plan_gate": [true|false]' 'carried-approval flag in the audit input'
audit_schema="$SKILL_DIR/schemas/audit-output.md"
require_fixed "$audit_schema" '"approved_at_plan_gate": false,' 'schema carries the carried-approval flag'
require_fixed "$audit_schema" '"reapprove": false,' 'schema carries the per-entry reapprove field'
require_fixed "$audit" '`reapprove`' '§ 6 reads the reapprove field'
require_fixed "$create" '"reapprove": true' 'the re-ask flag has a true form'
require_fixed "$audit" 'Carried approval (roadmap-create only)' 'the § 6 carried-approval section'
require_fixed "$audit" '`approved_at_plan_gate`' '§ 7 names the carried-approval flag'

# --- Conversion is scripted; research is inline; cross-model review degrades

require_fixed "$plan" '**Research inline (recommended)**' 'inline research is the default option'
require_fixed "$spike" '`auto_execute`' 'the spike takes auto_execute'
require_fixed "$plan" '`auto_execute`' 'the plan gate passes auto_execute'
schema="$SKILL_DIR/schemas/roadmap-plan-input.md"
tpm="$SKILL_DIR/workflows/tpm-roadmap-plan.md"
require_fixed "$schema" '| `spec_path` | No |' 'spec_path row in the input schema'
require_fixed "$schema" '`@[path]`' 'the schema names the @path input'
require_fixed "$create" '`supersedes`' 'the create side carries the supersedes field'
require_fixed "$plan" '`spec_path`' 'the plan writes spec_path into the TPM input'
require_fixed "$tpm" '**Spec mode**' 'the TPM has a spec mode'
require_fixed "$tpm" '`out_of_scope`' 'the TPM has an out_of_scope status'
require_fixed "$create" '`Deferred`' 'the create side knows the Deferred project'
require_fixed "$skill" 'optional: [decider, second-opinion]' 'second-opinion declared as an optional dependency'
require_fixed "$plan" '· Cross-model review: [verdict summary | unavailable — <reason> | skipped — reviewed spec | skipped — not required]' 'report template carries every cross-model review state'
require_fixed "$plan" '`risk_assessment.level: high`' 'the major predicate reads the risk level'
require_fixed "$plan" 'Spec: [SPEC_PATH or "None"]' 'the delegation template carries the spec boundary'
require_fixed "$plan" '`recommendation: out_of_scope`' 'architecture gaps take the out_of_scope recommendation'
require_fixed "$plan" '`out_of_spec[]`' 'architecture review returns a structured out-of-spec array'
require_fixed "$plan" '6. Out-of-spec work (spec mode only)' 'delegated review asks for out-of-spec work'
require_fixed "$plan" '`action: "create"`' 'the report renders create entries'
require_fixed "$create" '`hierarchy.parent`' 'the create side carries the hierarchy parent field'
require_fixed "$plan" '**Conflicts** ([N])' 'report renders conflicts before approval'

echo "all pass"
