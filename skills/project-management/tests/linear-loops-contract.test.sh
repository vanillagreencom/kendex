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
require_fixed 'on the 1–5 scale — estimate
the whole PR, never a sum past 5' 'combined estimate stays on the 1-5 scale'
require_fixed '| Filter: Status | **Triage only** |' 'Loop 1 trigger is Triage-only'
require_fixed '## First action — disarm the trigger' 'Loop 2 self-disarm section exists'
require_fixed 'Before anything else, remove the "re-triage" label from the triggering' 'Loop 2 removes its trigger label before any other mutation'
require_fixed 'stop
only this task — Tasks 2–6 still run' 'a wrong-team flag stops only Task 1'

# --- Task 6 concurrency and boundary guards ---------------------------------
require_fixed 'Duplicate-bundle guard (concurrent runs have no lock)' 'duplicate-bundle guard exists'
require_fixed 'simply its oldest member' 'the oldest member leads the bundle'
require_fixed 'issue is NOT the leader, do not create anything' 'only the leader creates the parent'
require_fixed '(a) re-check that every selected child still has no parent' 'pre-create recheck: children still unparented'
require_fixed '(b) search for an existing coordination parent already covering any of' 'pre-create recheck: no covering parent exists'
require_fixed 'repeatedly drop any member (including the trigger)' 'cross-boundary pruning is iterative'
require_fixed 'pass drops nobody' 'pruning runs to a fixed point'
require_fixed 'If the trigger itself drops, skip this task' 'a dropped trigger skips bundling'
require_fixed 'are at least 10 minutes old' 'in-flight pipeline issues are never bundle candidates'
require_fixed '(the trigger itself is' 'a creation-time pass can still bundle'

echo "all pass"
