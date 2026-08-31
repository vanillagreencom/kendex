#!/usr/bin/env bash
# Two failure modes stand behind this suite. (a) The Linear CLI replaces the
# whole label set and warn-and-skips unknown labels, so a workflow that mutates
# labels without loading the live inventory and computing a full final set
# silently strips labels or ships an unlabeled issue. (b) The research workflow
# label is project-defined; a hard-coded `research` finds nothing in a repo
# that names it otherwise.
#
# What this pins is STRUCTURE — the inventory and issue-fetch commands, the
# labels.md route, the two bolded rules other documents cite, the
# RESEARCH_WORKFLOW_LABEL placeholder, and the relation fields the cached
# payload carries.
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

# --- Every mutating workflow loads inventory and halts on a bad set ---------

for rel in workflows/roadmap-create.md workflows/audit-issues.md \
           workflows/research-issue.md workflows/research-complete.md \
           workflows/cycle-plan.md; do
  file="$SKILL_DIR/$rel"
  require "$file" 'cache labels list --format=safe' 'issue-label inventory load'
  require "$file" 'labels\.md|[Ll]abel [Pp]reflight|label policy' 'label preflight reference'
done

# --- The reference states the replace-the-whole-set hazard ------------------

labels="$SKILL_DIR/references/labels.md"
require "$labels" 'Never create a label unprompted' 'no unprompted label creation'
require "$labels" 'issue labels only|Issue labels only' 'issue labels, never project labels'

# --- The research workflow label is resolved, never hard-coded --------------

for rel in workflows/roadmap-plan.md workflows/research-spike.md workflows/research-issue.md; do
  require "$SKILL_DIR/$rel" 'RESEARCH_WORKFLOW_LABEL' 'taxonomy-resolved research label'
done

if grep -RnE -- '--label(=|[[:space:]]+)"?research"?([[:space:]]|$)' "$SKILL_DIR/workflows"; then
  fail 'a hard-coded --label research remains in the workflows'
fi

# --- No doc cites a Linear cache relation subcommand that does not exist ----
# Split so this file never contains the bad form it forbids.
unsupported="cache issues relation""s"
if grep -Rn --fixed-strings -- "$unsupported" \
    "$SKILL_DIR/workflows" "$SKILL_DIR/references" "$SKILL_DIR/schemas" \
    "$SKILL_DIR/SKILL.md" "$SKILL_DIR/README.md"; then
  fail 'an unsupported Linear cache relation subcommand remains in the docs'
fi

# --- Artifact return contract: child returns inline, caller writes ----------

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" 'cache issues get \[ISSUE_ID\]' 'supported cached issue fetch for relation analysis'
require "$tpm_audit" 'blocks`, `blocked_by`, and `related`' 'relation fields come from the cached issue payload'

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
if grep -Fq 'Agent returns `.JSON` file. If missing, halt.' "$audit_issues"; then
  fail 'audit-issues assumes a child-written JSON artifact'
fi

echo "all pass"
