#!/usr/bin/env bash
# Two cache reads answer with less than was asked for and say nothing about it:
# `cache issues bulk-get` returns the rows it matched and exits 0 whatever it
# missed, and `cache issues children --recursive` stops at three levels with one
# frontier row per branch. A workflow that reads either answer as complete
# audits a subset while reporting a whole. These workflows are markdown
# contracts, so this test statically pins the completeness check at the batch
# fetch and the one statement of the subtree continuation rule the call sites
# defer to.
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

echo "all pass"
