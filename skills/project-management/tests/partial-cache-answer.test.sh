#!/usr/bin/env bash
# Three cache reads answer with something other than what was asked for and say
# nothing about it: `cache issues bulk-get` returns the rows it matched and exits
# 0 whatever it missed, `cache issues children --recursive` stops at three levels
# with one frontier row per branch, and every issues read answers workspace-wide
# because the cache carries no team filter. A workflow reading any of those as
# complete audits a subset while reporting a whole, or reaches another team's
# backlog with a cancellation. These workflows are markdown contracts, so this
# test statically pins the completeness check at the batch fetch, the one
# statement of the subtree continuation rule its call sites defer to, and the
# team scope every cached read is filtered by.
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
require "$tpm_audit" 'exits 0 whether or not it matched them all' \
  'the batch fetch names its fail-open'
require "$tpm_audit" \
  'compare the returned .id. values against every requested identifier' \
  'the batch fetch is reconciled against the requested set'
require "$tpm_audit" 'halt naming any that came back missing' \
  'an unmatched target halts instead of being dropped'

# --- The subtree continuation rule is stated once, and deferred to ----------

deps="$SKILL_DIR/references/dependencies.md"
require "$deps" 'Reading a Full Subtree' 'the continuation rule has an owning section'
require "$deps" 'every row at the maximum depth returned is a frontier' \
  'a branching tree has many frontier rows'
require "$deps" 'Repeat the call rooted at \*\*every\*\* frontier row' \
  'continuation covers every frontier row'
require "$deps" 'deduplicate identifiers across calls' 'frontier rows are deduplicated'
require "$deps" 'stop when a round returns nothing new' 'continuation terminates'

# Every caller defers to that statement; none restates or narrows it.
audit_issues="$SKILL_DIR/workflows/audit-issues.md"

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
require "$tpm_audit" 'a team with none yet resolves' \
  'an empty team resolves instead of blocking the audit'
require "$tpm_audit" 'must not run unscoped' 'an unresolvable scope halts'
require "$tpm_audit" '.project-order. → § 1\.1\.1, then § 11' \
  'project-order resolves scope before it reads or reorders'
require "$tpm_audit" 'exemption from the sweep is never exemption from scope' \
  'the sweep exemption is not a scope exemption'
require "$tpm_audit" 'Every project, initiative, and issue read below is filtered' \
  'project-order mode filters what it reads'
require "$tpm_audit" 'resolves outside the § 1\.1\.1 scope halts' \
  'a caller-named input issue outside the scope halts'
require "$tpm_audit" 'does not start with .TEAM_PREFIX-.' \
  'out-of-team rows are named by their identifier prefix'
require "$tpm_audit" 'Both .--all-projects. fetches return every team' \
  'the input fetch states that it is workspace-wide'
require "$tpm_audit" \
  'Discard every row outside the § 1\.1\.1 team scope' \
  'the comparison set the sweep cancels from is scoped'
require "$tpm_audit" 'carries the § 1\.1\.1 team prefix' \
  'the pre-output invariant checks the scope'

skill="$SKILL_DIR/SKILL.md"
require "$skill" 'cache holds the whole workspace' 'the cache scope is stated once'
require "$skill" 'The two analysis workflows resolve the configured team' \
  'the scoping rule names the workflows that implement it'
require "$skill" 'Every other workflow reads the cache workspace-wide' \
  'the rule discloses what it does not cover'

# Every path states its own scope status, so a mode added later cannot inherit
# silence -- the omission that produced an unscoped path in three rounds running.
require "$skill" '## Scope by Path' 'the per-path enumeration has one home'
require "$skill" 'Silence is not inheritance: a new mode adds its row' \
  'a new mode must state its own row'
for path in 'tpm-audit .project., .team.' 'tpm-audit .issues., Linear' \
            'tpm-audit .issues., GitHub' 'tpm-audit .project-order.' \
            'tpm-roadmap-plan' 'tpm-cycle-plan' 'audit-issues §§ 7\.2-7\.5' \
            'audit-issues § 1\.2\.2, § 3' 'research-complete' 'research-issue'; do
  grep -Eq -- "\| $path \|" "$skill" \
    || fail "the scope enumeration does not carry a row for: $path"
done

# The wrapper's Linear-only modes reject a GitHub tracker rather than running empty.
require "$audit_issues" '.project., .team., and .project-order. audit Linear projects' \
  'team joins the Linear-only mode constraint'

# The sibling analysis workflow proposes cancellations from the same set.
roadmap="$SKILL_DIR/workflows/tpm-roadmap-plan.md"
require "$roadmap" '1\.1 Team Scope' 'the roadmap analysis resolves a team scope'
require "$roadmap" 'tpm-audit.md\) § 1\.1\.1' 'it defers to the one resolving section'
require "$roadmap" 'drop everything outside the scope' 'its comparison set is scoped'

echo "all pass"
