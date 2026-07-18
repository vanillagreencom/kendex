#!/usr/bin/env bash
# Regression test for tracker-conditional audit routing (#655).
# These workflows are markdown contracts, so this test statically verifies that
# audit-issues resolves tracker context once, keeps Linear preflight/mutations
# out of the GitHub path, gives every section 7 action a GitHub execution route,
# degrades missing Linear concepts explicitly, and that the schema and orch
# callers carry tracker context into the audit input.
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

# --- Schema: audit-issues-input.md carries tracker context ---

schema="$SKILL_DIR/schemas/audit-issues-input.md"
[[ -f "$schema" ]] || fail "schema not found: schemas/audit-issues-input.md"
require_fixed "$schema" '"tracker": {"type": "linear|github", "repository": "owner/repo"}' 'tracker block in schema example'
require_pattern "$schema" '\| `tracker` \| No \|' 'tracker field definition row'
require_pattern "$schema" 'infers the tracker from `parent_issue`' 'tracker inference default'
require_pattern "$schema" 'GitHub mode must not require Linear sync, session status, project inventory, or Linear mutation commands' 'GitHub-without-Linear guarantee'

# --- audit-issues: tracker resolution happens once, before any tracker command ---

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require_pattern "$audit_issues" '1\.2\.1 Resolve Tracker' 'tracker resolution section'
require_pattern "$audit_issues" 'Input file `tracker`' 'input-file tracker precedence'
require_pattern "$audit_issues" 'starting with `issue-` → `github`; otherwise `linear`' 'issue-id inference fallback'
require_fixed "$audit_issues" 'gh repo view --json nameWithOwner' 'repository resolution for inferred github tracker'
require_fixed "$audit_issues" 'Project audits are Linear-only; GitHub repositories have no project inventory in this workflow.' 'project-mode halt for github tracker'
require_pattern "$audit_issues" 'Linear installation/authentication is not a prerequisite' 'no-Linear prerequisite for github audits'

# --- audit-issues 1.2: preflight is tracker-conditional; GitHub branch is Linear-free ---

require_pattern "$audit_issues" '1\.2\.2 Preflight .* \(TRACKER=linear\)' 'Linear preflight branch'
require_pattern "$audit_issues" '1\.2\.3 Preflight .* \(TRACKER=github\)' 'GitHub preflight branch'
require_fixed "$audit_issues" '.agents/skills/linear/scripts/linear.sh sync --reconcile' 'Linear sync retained in Linear branch'
require_fixed "$audit_issues" 'gh label list --repo [OWNER/REPO] --limit 200 --json name,description' 'GitHub live label inventory'
require_fixed "$audit_issues" 'gh issue list --repo [OWNER/REPO] --state open --limit 200 --json number,title,labels' 'GitHub open-issue inventory'

github_preflight="$tmp/github-preflight.md"
sed -n '/^#### 1\.2\.3 /,/^### 1\.3 /p' "$audit_issues" > "$github_preflight"
[[ -s "$github_preflight" ]] || fail 'GitHub preflight section could not be extracted'
if grep -Fq 'linear.sh' "$github_preflight"; then
  fail 'GitHub preflight branch contains a Linear command'
fi

# --- audit-issues 7: every approved action has a GitHub execution route ---

require_pattern "$audit_issues" '\*\*Linear route \(TRACKER=linear\)\*\*' 'Linear execution route'
require_pattern "$audit_issues" '\*\*GitHub route \(TRACKER=github\)\*\*' 'GitHub execution route'
require_fixed "$audit_issues" 'gh issue create --repo [OWNER/REPO] --title "[TITLE]" --body-file [BODY_FILE] --label "[VALIDATED_FINAL_LABELS]"' 'GitHub create route with validated labels'
require_fixed "$audit_issues" 'gh issue edit [N] --repo [OWNER/REPO] --body-file [BODY_FILE]' 'GitHub body-edit route'
require_fixed "$audit_issues" 'github.sh label-add [N] "[LABEL]" --issue' 'label add via github skill'
require_fixed "$audit_issues" 'github.sh label-remove [N] "[LABEL]" --issue' 'label remove via github skill'
require_fixed "$audit_issues" 'gh issue close [N] --repo [OWNER/REPO] --reason "not planned"' 'GitHub cancel/supersede close route'
require_fixed "$audit_issues" 'gh issue view [N] --repo [OWNER/REPO] --json labels' 'GitHub label preflight fetch'

github_route="$tmp/github-route.md"
sed -n '/^\*\*GitHub route (TRACKER=github)\*\*/,/^\*\*Create template\*\*/p' "$audit_issues" > "$github_route"
[[ -s "$github_route" ]] || fail 'GitHub route section could not be extracted'
if grep -Fq 'linear.sh' "$github_route"; then
  fail 'GitHub execution route contains a Linear command'
fi

github_supersede="$tmp/github-supersede.md"
sed -n '/^\*\*Superseded issues -- GitHub\*\*/,/^#### 7\.2\.1 /p' "$audit_issues" > "$github_supersede"
[[ -s "$github_supersede" ]] || fail 'GitHub supersede section could not be extracted'
if grep -Fq 'linear.sh' "$github_supersede"; then
  fail 'GitHub supersede route contains a Linear command'
fi

# --- audit-issues: Linear-only concepts degrade explicitly, never silently ---

require_pattern "$audit_issues" 'GitHub hierarchy & relations \(explicit degradation\)' 'hierarchy/relations degradation note'
require_pattern "$audit_issues" 'Do not silently drop an approved hierarchy or relation action' 'no-silent-drop rule'
require_pattern "$audit_issues" 'GitHub repositories have no project state or Todo sort-order model' 'positioning degradation for github'
require_pattern "$audit_issues" 'positioning: n/a \(github\)' 'positioning skip recorded in summary'
require_pattern "$audit_issues" 'Degraded \(github\)' 'degradation line in audit summary'
require_pattern "$audit_issues" 'no recursive child query' 'research-ref child propagation degradation'
require_pattern "$audit_issues" 'Relations -- GitHub' 'post-cancellation cleanup github branch'
require_pattern "$audit_issues" 'Tracker: \[TRACKER\] \[OWNER/REPO\]' 'tracker context in TPM delegation'

# --- tpm-audit: context fetch branches by tracker; project inventory degrades ---

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require_pattern "$tpm_audit" '`TRACKER` \(and `REPOSITORY` for github\)' 'tracker extraction in ISSUES mode'
require_pattern "$tpm_audit" 'PROJECT mode audits Linear projects and is Linear-only' 'PROJECT mode Linear-only note'
require_fixed "$tpm_audit" 'gh label list --repo [REPOSITORY] --limit 200 --json name,description' 'GitHub label inventory in TPM'
require_fixed "$tpm_audit" 'gh issue view [N] --repo [REPOSITORY] --json number,title,body,labels,state,url' 'GitHub issue fetch in TPM'
require_fixed "$tpm_audit" 'gh issue list --repo [REPOSITORY] --state all --limit 200 --json number,title,state,labels' 'GitHub comparison set in TPM'
require_pattern "$tpm_audit" 'github: no project inventory' 'TPM project-placement degradation'

# --- orch callers: audit input carries tracker context (when orch is present) ---

review_pr="$SKILL_DIR/../orch/workflows/review-pr.md"
if [[ -f "$review_pr" ]]; then
  require_pattern "$review_pr" 'Set `tracker\.type` to the resolved `TRACKER`' 'review-pr passes tracker context'
  require_pattern "$review_pr" 'tracker\.repository' 'review-pr passes repository context'
fi

review_pr_comments="$SKILL_DIR/../orch/workflows/review-pr-comments.md"
if [[ -f "$review_pr_comments" ]]; then
  require_pattern "$review_pr_comments" 'set `tracker\.type` to the resolved `TRACKER`' 'review-pr-comments passes tracker context'
fi

echo "all pass"
