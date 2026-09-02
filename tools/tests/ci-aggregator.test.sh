#!/usr/bin/env bash
# The aggregator job in .github/workflows/skill-tests.yml carries `if:
# always()`, which is what keeps a skipped required context from satisfying the
# ruleset — and is also what stops GitHub from skipping the job when a `needs`
# entry goes red. So the assertion that a need succeeded lives in a step, and a
# `needs` entry no step asserts is a fail-open: the required context is green
# while the suite it named is red.
#
# This suite reads the workflow and reports any such entry. The failing
# direction runs after the clean read, so a green pass is evidence rather than
# a reader that matches nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/skill-tests.yml"
JOB="skill-suites"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Prints one line per `needs` entry of the aggregator that no step compares
# against "success"; prints nothing when every entry is asserted. A workflow
# whose aggregator carries no `needs` list at all fails here too — that is the
# reader losing its subject, not a clean result.
unasserted() { # WORKFLOW_FILE
  awk -v job="$JOB" '
    # Job keys sit at indent 2. Every other line belongs to the job last seen,
    # so the block ends where the next key begins.
    /^  [A-Za-z][A-Za-z0-9_-]*:[ \t]*$/ { inblock = ($0 == "  " job ":"); next }
    !inblock { next }
    $0 ~ /^    needs: \[/ {
      list = $0; sub(/^[^[]*\[/, "", list); sub(/\].*$/, "", list)
      n = split(list, entries, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", entries[i])
        if (entries[i] != "") { needed[entries[i]] = 1; order[++count] = entries[i] }
      }
      next
    }
    # `VAR: ${{ needs.<job>.result }}` — the env binding a step reads.
    match($0, /^[ \t]+[A-Z_]+: \$\{\{ needs\.[A-Za-z0-9_-]+\.result \}\}$/) {
      var = $0; sub(/^[ \t]+/, "", var); sub(/:.*$/, "", var)
      dep = $0; sub(/^.*needs\./, "", dep); sub(/\.result.*$/, "", dep)
      bound[dep] = var
      next
    }
    # The comparison itself, as the step writes it.
    match($0, /\[ "\$[A-Z_]+" = "success" \]/) {
      var = substr($0, RSTART, RLENGTH); sub(/^\[ "\$/, "", var); sub(/" = .*$/, "", var)
      asserted[var] = 1
      next
    }
    END {
      if (count == 0) { print job ": no needs list read from the workflow — this reader lost its subject"; exit }
      for (i = 1; i <= count; i++) {
        dep = order[i]
        if (!(dep in bound)) { print dep ": no step reads needs." dep ".result" }
        else if (!(bound[dep] in asserted)) { print dep ": needs." dep ".result is read into $" bound[dep] " and never compared against success" }
      }
    }
  ' "$1"
}

fail() { printf 'ci-aggregator: %s\n' "$1" >&2; exit 1; }

out="$(unasserted "$WORKFLOW")"
[ -z "$out" ] || fail "the real workflow leaves a needs entry unasserted:
$out"

# An author who adds a `needs` entry and forgets the step: the entry gates
# nothing and the aggregator stays green while that job is red.
grep -v 'UI_RESULT' "$WORKFLOW" >"$SCRATCH/no-step.yml"
cmp -s "$WORKFLOW" "$SCRATCH/no-step.yml" && fail "the no-step mutation matched nothing — it no longer removes the step it names"
[ "$(unasserted "$SCRATCH/no-step.yml")" = "ui-tests: no step reads needs.ui-tests.result" ] \
  || fail "a needs entry with no step reading its result was not reported"

# The step exists and echoes the result, but the comparison is gone: a red job
# reads as a green one, printed in the log.
grep -v '\[ "\$UI_RESULT" = "success" \]' "$WORKFLOW" >"$SCRATCH/no-compare.yml"
cmp -s "$WORKFLOW" "$SCRATCH/no-compare.yml" && fail "the no-compare mutation matched nothing — it no longer removes the comparison it names"
[ "$(unasserted "$SCRATCH/no-compare.yml")" = 'ui-tests: needs.ui-tests.result is read into $UI_RESULT and never compared against success' ] \
  || fail "a needs entry whose result is read but never compared was not reported"

echo "ci-aggregator: every job the aggregator needs is asserted by name"
