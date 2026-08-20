#!/usr/bin/env bash
# The Linear-loop janitor template (docs/linear-loops.md, catalog repo only)
# embeds rules that mirror this skill's parent-issue contract: a Task 6
# bundle parent ships as one PR, is born outside Triage, carries its
# project's full label set, and takes its children's highest priority —
# backlog ordering reads the parent, not the children. These are markdown
# contracts, so this test statically pins them; it passes vacuously where
# the template is not shipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
loops="$(cd "$SKILL_DIR/../.." && pwd)/docs/linear-loops.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_fixed() {
  local needle="$1" desc="$2"
  grep -Fq -- "$needle" "$loops" || fail "$desc missing in docs/linear-loops.md"
}

[[ -f "$loops" ]] || { echo "skip: docs/linear-loops.md not shipped here"; exit 0; }

require_fixed 'in the Backlog state (never Triage' 'bundle parent is created outside Triage'
require_fixed 'with `(one PR)` at the' 'bundle parent carries the single-PR title marker'
require_fixed 'the parent carries the complete label set its project requires' 'bundle parent carries the full required label set'
require_fixed 'the parent takes the highest priority' 'bundle parent takes the highest child priority'
require_fixed 'the UNION of the children'"'"'s labels for a non-exclusive one' 'required non-exclusive categories take the union'
require_fixed 'no common
value means no bundle' 'no common exclusive value means no bundle'
require_fixed 'combined estimate of its children'"'"'s PR scope' 'single-PR parent carries a combined estimate'
require_fixed '| Filter: Status | **Triage only** |' 'Loop 1 trigger is Triage-only'

echo "all pass"
