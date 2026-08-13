#!/usr/bin/env bash
# Two failure modes this pins. (a) The Linear CLI replaces the whole label set
# and warn-and-skips unknown labels, so a workflow that mutates labels without
# loading the live inventory and computing a full final set silently strips
# labels or ships an unlabeled issue. (b) The research workflow label is
# project-defined; a hard-coded `research` finds nothing in a repo that names
# it otherwise. These workflows are markdown contracts, so the checks are
# static. It also pins the artifact-return contract: the TPM child returns JSON
# inline and the caller writes the file, since assuming a child-written file
# leaves the caller reading a path nothing created.
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
  require "$file" 'halt before mutation|halt before .* mutation|halts before mutation' 'strict halt on an invalid final set'
done

# --- The reference states the replace-the-whole-set hazard ------------------

labels="$SKILL_DIR/references/labels.md"
require "$labels" 'replaces' 'update replaces the full label set'
require "$labels" 'preserving unrelated labels|[Pp]reserve.*unrelated|preserve everything else' 'unrelated labels are preserved'
require "$labels" 'strips every other label' 'the bare-update hazard is named'
require "$labels" 'Never rely on the CLI.s warn-and-skip' 'warn-and-skip is not a validator'
require "$labels" 'Never create a label unprompted' 'no unprompted label creation'
require "$labels" 'issue labels only|Issue labels only' 'issue labels, never project labels'

# --- The research workflow label is resolved, never hard-coded --------------

for rel in workflows/roadmap-plan.md workflows/research-spike.md workflows/research-issue.md; do
  require "$SKILL_DIR/$rel" 'RESEARCH_WORKFLOW_LABEL' 'taxonomy-resolved research label'
done
require "$SKILL_DIR/workflows/roadmap-plan.md" 'do not query a hard-coded fallback label' 'no hard-coded fallback on lookup'
require "$SKILL_DIR/workflows/research-spike.md" 'do not query a hard-coded fallback label' 'no hard-coded fallback on lookup'
require "$SKILL_DIR/workflows/research-issue.md" 'do not assume the literal name `research` exists' 'no literal research label on create'

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
require "$tpm_audit" 'Return the JSON inline' 'inline JSON return contract'
require "$tpm_audit" 'Do not write the artifact yourself' 'child does not write the artifact'

audit_issues="$SKILL_DIR/workflows/audit-issues.md"
require "$audit_issues" 'destination hint only' 'File: line is a hint, not a promise'
require "$audit_issues" 'write the inline JSON exactly to the resolved path' 'caller writes the artifact'
require "$audit_issues" 'already exists and is readable' 'readable-artifact fallback'
require "$audit_issues" 'request a TPM rerun with inline JSON' 'halt when neither path is available'
if grep -Fq 'Agent returns `.JSON` file. If missing, halt.' "$audit_issues"; then
  fail 'audit-issues assumes a child-written JSON artifact'
fi

echo "all pass"
