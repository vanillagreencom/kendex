#!/usr/bin/env bash
# Regression test for harness-safe comparison-set loading (#676).
# Under restricted harness approval policies (Codex AskForApproval=Never) a
# per-project shell loop over `cache issues list --project` is rejected on
# command shape alone, so the cross-project comparison-set loads in tpm-audit
# and tpm-roadmap-plan must stay ONE simple `--all-projects` command. These
# workflows are markdown contracts, so this test statically pins that shape.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

require_fixed() {
  local file="$1" needle="$2" desc="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$desc missing in ${file#$SKILL_DIR/}"
  fi
}

forbid_fixed() {
  local file="$1" needle="$2" desc="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$desc present in ${file#$SKILL_DIR/}"
  fi
}

batch_cmd='.agents/skills/linear/scripts/linear.sh cache issues list --all-projects --state "Backlog,Todo,In Progress,In Review,Done" --max'

# --- tpm-audit 1.5: comparison set is one --all-projects command ---

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
[[ -f "$tpm_audit" ]] || fail "workflow not found: workflows/tpm-audit.md"

section="$tmp/tpm-audit-1.5.md"
sed -n '/^### 1\.5 /,/^### 1\.6 /p' "$tpm_audit" > "$section"
[[ -s "$section" ]] || fail 'tpm-audit section 1.5 could not be extracted'

require_fixed "$section" "$batch_cmd" 'single --all-projects comparison-set command'
require_pattern "$section" 'Never loop `--project`' 'no-loop instruction'
forbid_fixed "$section" 'Run for each project' 'per-project loop instruction'
forbid_fixed "$section" '--project "[PROJECT_NAME]"' 'per-project fetch command'
forbid_fixed "$section" 'for p in' 'shell loop shape'

# --- tpm-roadmap-plan 1.5: same single-command contract ---

roadmap_plan="$SKILL_DIR/workflows/tpm-roadmap-plan.md"
[[ -f "$roadmap_plan" ]] || fail "workflow not found: workflows/tpm-roadmap-plan.md"

section="$tmp/tpm-roadmap-plan-1.5.md"
sed -n '/^### 1\.5 /,/^### 1\.6 /p' "$roadmap_plan" > "$section"
[[ -s "$section" ]] || fail 'tpm-roadmap-plan section 1.5 could not be extracted'

require_fixed "$section" "$batch_cmd" 'single --all-projects all-issues command'
forbid_fixed "$section" 'for each project' 'per-project fetch instruction'
forbid_fixed "$section" '--project "[PROJECT_NAME]"' 'per-project fetch command'
forbid_fixed "$section" 'for p in' 'shell loop shape'

# --- linear skill: the batch flag the workflows depend on is documented ---

linear_skill="$SKILL_DIR/../linear/SKILL.md"
[[ -f "$linear_skill" ]] || fail "linear SKILL.md not found next to project-management"
require_fixed "$linear_skill" '--all-projects' 'batch enumeration flag documentation'

echo "PASS: comparison-set contract"
