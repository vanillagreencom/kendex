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

require_fixed "$plan" '**`Approve` authorizes the presented creation set**' 'plan-gate approval authorizes creation'
require_fixed "$plan" '**and the EXISTING WORK AFFECTED actions as presented**' 'plan-gate approval covers existing-work actions'
require_fixed "$create" 'unchanged since roadmap-plan § 5 `Approve` execute as presented without re-asking' 'roadmap-create § 2 does not re-ask approved actions'
require_fixed "$plan" 'a selected artifact ends this gate → § 2. Only when the disk search finds nothing, query the tracker' 'a disk artifact is not overwritten by a tracker match'
require_fixed "$plan" 'the `@[path]` input or the § 1 disk match — classified as a SPEC' 'spec_path is set for disk-discovered specs too'
require_fixed "$create" '"approved_at_plan_gate": [true|false]' 'carried-approval flag in the audit input'
require_fixed "$create" 'identical to the creation set that gate presented' 'flag bound to the identical creation set'
require_fixed "$create" '`Deferred`-project entries were never part of it' 'deferred filtering keeps the approved set identical'
require_fixed "$plan" 'which never contains `Deferred`-project entries' 'plan gate presents a creation set without deferred gaps'
require_fixed "$create" '"reapprove": true' 'changed entries are re-asked'
require_fixed "$create" 'their absence never voids the flag for the unchanged survivors' 'omissions keep approval for unchanged entries'
require_fixed "$create" 'the flag is false only when provenance fails' 'only failed provenance voids the carried approval'
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
require_fixed "$schema" 'the `@[path]` input or the roadmap-plan § 1 disk match' 'schema admits disk-discovered specs'
require_fixed "$create" 'is OMITTED from `issues[]` (never `skip`' 'executed existing-work actions are omitted from the audit input'
require_fixed "$create" 'an action § 2 skipped — globally or per action — is omitted as well, a skipped supersession dropping its replacement too' 'skipped § 2 decisions cannot be overridden downstream'
require_fixed "$create" 'enters as a plain `create` with `supersedes` cleared' 'an executed supersession still files its replacement'
require_fixed "$audit" 'cancellations not already decided at roadmap-create § 2' '§ 6 excludes cancellations decided at § 2'
require_fixed "$plan" 'and `spec_path` (each null when absent' 'plan writes spec_path into the TPM input'
require_fixed "$tpm" '**Spec mode** (`SPEC_PATH` set): the plan'"'"'s decisions are binding' 'TPM spec mode binds the plan'
require_fixed "$tpm" 'never change its approach, drop a workstream it names, or add scope beyond its phases' 'TPM spec-mode constraints'
require_fixed "$tpm" 'anything outside the spec'"'"'s phases is `out_of_scope` — never `defer`' 'out-of-spec gaps never enter organized_issues'
require_fixed "$create" 'skipping entries whose `project` is `Deferred`' 'deferred gaps are never created in the roadmap project'
require_fixed "$skill" 'optional: [decider, second-opinion]' 'second-opinion declared as an optional dependency'
require_fixed "$plan" 'or is installed but cannot complete (no eligible target, missing external CLI, timeout, nonzero exit)' 'cross-model review degrades when the skill is absent or unusable'
require_fixed "$plan" '`Cross-model review` field reads `unavailable — <reason>`' 'unavailable review carries its reason'
require_fixed "$plan" '· Cross-model review: [verdict summary | unavailable — <reason> | skipped — reviewed spec | skipped — not required]' 'report template carries every cross-model review state'
require_fixed "$plan" 'a non-major plan records `skipped — not required`' 'non-major plans report the review as not required'
require_fixed "$plan" 'Spec: [SPEC_PATH or "None"] — when set, the spec'"'"'s phases bound the roadmap' 'architecture review receives the spec boundary'
require_fixed "$plan" 'In spec mode the fold stops at the spec'"'"'s boundary' 'out-of-spec findings are never folded in'
require_fixed "$plan" 'becomes an `architecture_gaps[]` row with `recommendation: out_of_scope` — never `defer`' 'architecture-review stage uses the same out_of_scope status as the TPM'
require_fixed "$plan" 're-enters the pipeline as a proposed issue — § 2'"'"'s delegation table for its domain, then § 3' 'needed out-of-spec work gets the structured planning pass'
require_fixed "$plan" 'the fold never invents issue fields' 'architecture fold never fabricates issue data'
require_fixed "$plan" '`risk_assessment`, `out_of_spec[]`)' 'architecture review returns a structured out-of-spec array'
require_fixed "$plan" '6. Out-of-spec work (spec mode only)' 'delegated review asks for out-of-spec work'
require_fixed "$plan" 'creation-bearing entries only — `action: "create"` and `"supersede"`' 'report renders create and supersede replacements before approval'
require_fixed "$create" 'A reference to any entry § 2 omitted — a relation or a `hierarchy.parent` — retargets' 'relation and hierarchy references to omitted entries retarget'
require_fixed "$create" 'the dependent re-enters § 5 marked `"reapprove": true` — never a dangling `#N`' 'references to skipped entries are removed and re-approved'
require_fixed "$create" 'when that parent was omitted at § 2, of its existing `target` id' 'children of an omitted bundle parent reparent to the existing issue'
require_fixed "$plan" '**Conflicts** ([N])' 'report renders conflicts before approval'
require_fixed "$plan" 'Spec: [SPEC_PATH or "None"] — when set, its approach and workstreams are binding' 'specialist delegation carries the spec constraint'
require_fixed "$create" 'only under the same provenance as `approved_at_plan_gate`' 'existing-work carry requires same-session provenance'

echo "all pass"
