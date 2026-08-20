#!/usr/bin/env bash
# A GitHub-tracked audit must never reach for Linear. Tracker context resolves
# once, both preflight branches stay disjoint, every approved action has a
# GitHub execution route, and each Linear concept GitHub lacks degrades in a
# reported note rather than silently vanishing. These workflows are markdown
# contracts, so this test statically pins that separation — including a
# mechanical check that the GitHub-only regions contain no Linear command.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require() {
  local file="$1" pattern="$2" desc="$3"
  [[ -f "$file" ]] || fail "file not found: ${file#"$SKILL_DIR"/}"
  grep -Eq -- "$pattern" "$file" || fail "$desc missing in ${file#"$SKILL_DIR"/}"
}

require_fixed() {
  local file="$1" needle="$2" desc="$3"
  grep -Fq -- "$needle" "$file" || fail "$desc missing in ${file#"$SKILL_DIR"/}"
}

# extract <file> <start-pattern> <end-pattern> <label> → prints scratch path;
# nonzero when the region is empty. Patterns are ERE (`sed -E`), the same
# dialect as `require`'s `grep -E`: write `\(` for a literal parenthesis.
extract() {
  local file="$1" start="$2" end="$3" label="$4"
  local out="$tmp/$label.md"
  sed -En "/$start/,/$end/p" -- "$file" >"$out"
  printf '%s' "$out"
  [[ -s "$out" ]]
}

# An empty region is a failed extraction, never a vacuously Linear-free one:
# `fail` inside the caller's $(...) only leaves that subshell.
assert_linear_free() {
  local region="$1" label="$2"
  [[ -s "$region" ]] || fail "could not extract the $label region"
  ! grep -Fq 'linear.sh' "$region" || fail "$label contains a Linear command"
}

# --- Schema carries tracker context into the audit --------------------------

schema="$SKILL_DIR/schemas/audit-issues-input.md"
require_fixed "$schema" '"tracker": {"type": "linear|github", "repository": "owner/repo"}' 'tracker block in the example'
require "$schema" '\| `tracker` \| No \|' 'tracker field definition'
require "$schema" 'infers the tracker from `parent_issue`' 'inference default'
require "$schema" 'GitHub mode must not require Linear sync, session status, project inventory, or Linear mutation commands' 'no-Linear guarantee'

# --- Tracker resolves once, before any tracker command ----------------------

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require "$audit_issues" '1\.2 Resolve Tracker' 'tracker resolution section'
require "$audit_issues" 'input file.s `tracker` block' 'input-file precedence'
require "$audit_issues" 'starting with `issue-` → `github`, otherwise `linear`' 'inference fallback'
require "$audit_issues" 'Resolve once, before any tracker command' 'resolve-once ordering rule'
require_fixed "$audit_issues" 'gh repo view --json nameWithOwner' 'repository resolution for an inferred github tracker'
require_fixed "$audit_issues" 'Project audits are Linear-only; GitHub repositories have no project inventory in this workflow.' 'project-mode halt for github'
require "$audit_issues" 'Linear installation/authentication is not a prerequisite' 'no-Linear prerequisite'

# --- Preflight branches are tracker-conditional and disjoint ----------------

require "$audit_issues" '1\.2\.2 Preflight — Linear \(TRACKER=linear\)' 'Linear preflight branch'
require "$audit_issues" '1\.2\.3 Preflight — GitHub \(TRACKER=github\)' 'GitHub preflight branch'
require_fixed "$audit_issues" '.agents/skills/linear/scripts/linear.sh sync --reconcile' 'Linear sync in the Linear branch'
require_fixed "$audit_issues" 'gh label list --repo [OWNER/REPO] --limit 200 --json name,description' 'GitHub live label inventory'
require_fixed "$audit_issues" 'gh issue list --repo [OWNER/REPO] --state open --limit 200 --json number,title,labels' 'GitHub open-issue inventory'
assert_linear_free "$(extract "$audit_issues" '^#### 1\.2\.3 ' '^### 1\.3 ' github-preflight)" 'GitHub preflight branch'

# --- Every approved action has a GitHub execution route --------------------

require "$audit_issues" '\*\*Linear route \(TRACKER=linear\)\*\*' 'Linear execution route'
require "$audit_issues" '\*\*GitHub route \(TRACKER=github\)\*\*' 'GitHub execution route'

# --- Pipeline creates are born in Backlog, never the team-default Triage -----
# The workspace's Linear-native triage loop fires on Triage-state creations
# and once re-routed fully triaged pipeline output into other projects; the
# Backlog state on every create route is the mechanical half of that fix.

linear_create_row="$(extract "$audit_issues" '^\*\*Linear route \(TRACKER=linear\)\*\*' '^\| expand, update' linear-create-row)" || fail "could not extract the Linear create row"
grep -Fq -- '--state "Backlog"' "$linear_create_row" || fail 'Linear create route does not require --state "Backlog"'
research_issue="$SKILL_DIR/workflows/research-issue.md"
merge_pr="$SKILL_DIR/../orch/workflows/merge-pr.md"
plan_issues="$SKILL_DIR/../orch/workflows/plan-issues.md"
start_new="$SKILL_DIR/../orch/workflows/start-new.md"
workflow_actions="$SKILL_DIR/../linear/patterns/workflow-actions.md"
if [[ -f "$workflow_actions" ]]; then
  wa_create_cmd="$(extract "$workflow_actions" 'issues create' '^```$' wa-create-cmd)" || fail "could not extract the workflow-actions follow-up create"
  grep -Fq -- '--state "Backlog"' "$wa_create_cmd" || fail 'workflow-actions follow-up create does not pass --state "Backlog"'
fi
if [[ -f "$start_new" ]]; then
  start_create_cmd="$(extract "$start_new" 'issues create' '^```$' start-create-cmd)" || fail "could not extract the start-new create command"
  grep -Fq -- '--state "Backlog"' "$start_create_cmd" || fail 'start-new create does not pass --state "Backlog"'
fi
if [[ -f "$plan_issues" ]]; then
  plan_create_cmd="$(extract "$plan_issues" 'issues create' '^```$' plan-create-cmd)" || fail "could not extract the plan-issues create command"
  grep -Fq -- '--state "Backlog"' "$plan_create_cmd" || fail 'plan-issues create does not pass --state "Backlog"'
  require_fixed "$plan_issues" 'validate the complete label set' 'plan-issues preflights labels before a Backlog create'
fi
if [[ -f "$merge_pr" ]]; then
  merge_create_cmd="$(extract "$merge_pr" 'issues create' '^```$' merge-create-cmd)" || fail "could not extract the merge-pr rebundle create command"
  grep -Fq -- '--state "Backlog"' "$merge_create_cmd" || fail 'merge-pr rebundle create does not pass --state "Backlog"'
fi
research_create_cmd="$(extract "$research_issue" 'issues create \\$' '^```$' research-create-cmd)" || fail "could not extract the research-issue create command"
grep -Fq -- '--state "Backlog"' "$research_create_cmd" || fail 'research-issue create command does not pass --state "Backlog"'
require "$audit_issues" 'Never mix routes within one audit' 'single-route rule'
require_fixed "$audit_issues" 'gh issue create --repo [OWNER/REPO] --title "[TITLE]" --body-file [BODY_FILE] --label "[VALIDATED_FINAL_LABELS]"' 'GitHub create with validated labels'
require_fixed "$audit_issues" 'gh issue edit [N] --repo [OWNER/REPO] --body-file [BODY_FILE]' 'GitHub body-edit route'
require_fixed "$audit_issues" 'github.sh label-add [N] "[LABEL]" --issue' 'label add via the github skill'
require_fixed "$audit_issues" 'label-remove' 'label remove via the github skill'
require_fixed "$audit_issues" 'gh issue close [N] --repo [OWNER/REPO] --reason "not planned"' 'GitHub cancel/supersede close'
require_fixed "$audit_issues" 'gh issue view [N] --repo [OWNER/REPO] --json labels' 'GitHub label preflight fetch'
assert_linear_free "$(extract "$audit_issues" '^\*\*GitHub route \(TRACKER=github\)\*\*' '^\*\*Create template\*\*' github-route)" 'GitHub execution route'

# --- Linear-only concepts degrade explicitly, never silently ---------------

require "$audit_issues" 'GitHub degradation \(explicit, never silent\)' 'degradation note'
require "$audit_issues" 'Never drop an approved hierarchy or relation action' 'no-silent-drop rule'
require "$audit_issues" 'positioning: n/a \(github\)' 'positioning skip is recorded'
require "$audit_issues" 'Degraded \(github\)' 'degradation line in the summary'
require "$audit_issues" 'no recursive child query' 'research-ref propagation degradation'
require "$audit_issues" 'there are no relation objects' 'post-cancellation cleanup degradation'
require "$audit_issues" 'Tracker: \[TRACKER\] \[OWNER/REPO\]' 'tracker context reaches the TPM delegation'

# --- Analysis branches by tracker; project inventory degrades ---------------

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" '`TRACKER` \(plus `REPOSITORY` for github\)' 'tracker extraction in issues mode'
require "$tpm_audit" 'Linear only — this mode audits Linear projects' 'project mode is Linear-only'
require_fixed "$tpm_audit" 'gh label list --repo [REPOSITORY] --limit 200 --json name,description' 'GitHub label inventory'
require_fixed "$tpm_audit" 'gh issue view [N] --repo [REPOSITORY] --json number,title,body,labels,state,url' 'GitHub issue fetch'
require_fixed "$tpm_audit" 'gh issue list --repo [REPOSITORY] --state all --limit 200 --json number,title,state,labels' 'GitHub comparison set'
require "$tpm_audit" 'github: no project inventory' 'project-placement degradation reason'
require "$tpm_audit" 'Never invent a placement' 'no invented placement'

echo "all pass"
