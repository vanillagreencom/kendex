#!/usr/bin/env bash
# Three cache reads answer with something other than what was asked for and say
# nothing about it: `cache issues bulk-get` returns the rows it matched and exits
# 0 whatever it missed, `cache issues children --recursive` stops at three levels
# with one frontier row per branch, and every issues read answers workspace-wide
# because the cache carries no team filter. A workflow reading any of those as
# complete audits a subset while reporting a whole, or reaches another team's
# backlog with a cancellation. This test pins the ANCHORS those rules hang on:
# the batch fetch command, the section that owns the subtree continuation rule
# and the call sites that defer to it, and the team-scope sections and table.
#
# What this pins is STRUCTURE — the bulk-get, auth-check, teams-get and
# recursive-children commands, the `Reading a Full Subtree`, `Resolve Team
# Scope`, `Team Scope` and `Scope by Path` sections, the project-order route,
# the `--all-projects` flag, the TEAM_PREFIX placeholder, and each mode's row
# in the scope table.
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

# --- The batch input fetch proves it got everything it asked for ------------

tpm_audit="$SKILL_DIR/workflows/tpm-audit.md"
require "$tpm_audit" 'cache issues bulk-get' 'batch input fetch'

# --- The subtree continuation rule is stated once, and deferred to ----------

deps="$SKILL_DIR/references/dependencies.md"
require "$deps" 'Reading a Full Subtree' 'the continuation rule has an owning section'

# Every caller defers to that statement; none restates or narrows it.

for rel in workflows/audit-issues.md workflows/research-complete.md \
           workflows/tpm-roadmap-plan.md; do
  file="$SKILL_DIR/$rel"
  require "$file" 'children \[[A-Z_]+\] --recursive' 'recursive children call'
  require "$file" 'Reading a Full Subtree' \
    "$rel does not defer to the continuation rule"
  if grep -Fq 'rooted at the deepest child' "$file"; then
    fail "$rel continues from a single deepest child, dropping sibling subtrees"
  fi
done

# --- Every cached issue read is scoped to the configured team --------------

require "$tpm_audit" '1\.1\.1 Resolve Team Scope' 'the team scope has a resolving section'
require "$tpm_audit" 'auth-check' 'the configured team is read from the tracker'
require "$tpm_audit" 'teams get \[TEAM\]' \
  'the prefix comes from the team record, not from an issue'
require "$tpm_audit" '.project-order. → § 1\.1\.1, then § 11' \
  'project-order resolves scope before it reads or reorders'
require "$tpm_audit" 'TEAM_PREFIX' \
  'out-of-team rows are named by their identifier prefix'
require "$tpm_audit" '[-][-]all-projects' \
  'the input fetch states that it is workspace-wide'

skill="$SKILL_DIR/SKILL.md"

# Every path states its own scope status, so a mode added later cannot inherit
# silence -- the omission that produced an unscoped path in three rounds running.
require "$skill" '## Scope by Path' 'the per-path enumeration has one home'
for path in 'tpm-audit .project., .team.' 'tpm-audit .issues., Linear' \
            'tpm-audit .issues., GitHub' 'tpm-audit .project-order.' \
            'tpm-roadmap-plan' 'tpm-cycle-plan' 'audit-issues §§ 7\.2-7\.5' \
            'audit-issues § 1\.2\.1, § 3' 'research-complete' 'research-issue'; do
  grep -Eq -- "\| $path \|" "$skill" \
    || fail "the scope enumeration does not carry a row for: $path"
done

# The sibling analysis workflow proposes cancellations from the same set.
roadmap="$SKILL_DIR/workflows/tpm-roadmap-plan.md"
require "$roadmap" '1\.1 Team Scope' 'the roadmap analysis resolves a team scope'
require "$roadmap" 'tpm-audit.md\) § 1\.1\.1' 'it defers to the one resolving section'

echo "all pass"
