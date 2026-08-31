#!/usr/bin/env bash
# The Linear-loop janitor template (docs/linear-loops.md) embeds rules that
# mirror this skill's parent-issue contract. This test pins the STRUCTURE
# those rules live in — a table row, a heading, the title marker, the handoff
# comment format — never the sentences that state them. review-bots.md: a
# token pin establishes that a structural element is present, never that a
# behavioral claim written in prose is true.
#
# A template this cannot find is a failure, not a skip: these pins are the
# only thing holding that structure, so a run that cannot reach the file
# proves nothing and must say so.
#
# The bundle rules themselves are prose and have no lint. Nothing here checks
# that a bundle parent is born in Backlog rather than Triage, carries its
# project's complete label set, takes its children's highest priority, takes
# the union of non-exclusive child labels, refuses a bundle when no exclusive
# value is common, carries a combined estimate held to the 1-5 scale, or
# inherits a parented trigger's project. Nor that the oldest member leads,
# that a non-leader creates nothing, that the leader re-checks for unparented
# children and a covering parent before creating, that boundary pruning runs
# to a fixed point and a dropped trigger skips the task, that issues under
# ten minutes old outside Triage are not candidates, that the handoff comment
# precedes the trigger label, or that a wrong-team flag stops Task 1 alone.
# Each of those lives in a sentence with no token present only while it holds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The repository root, not the skill's parent: this file is committed under
# skills/ and again under .agents/skills/, and both copies pin the one doc.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" ||
  fail "not inside a git repository, so docs/linear-loops.md cannot be located"
loops="$REPO_ROOT/docs/linear-loops.md"

require_fixed() {
  local needle="$1" desc="$2"
  grep -Fq -- "$needle" "$loops" || fail "$desc missing in docs/linear-loops.md"
}

[[ -f "$loops" ]] || fail "docs/linear-loops.md not found at $loops"

require_fixed '`(one PR)`' 'the single-PR title marker'
require_fixed '| Filter: Status | **Triage only** |' 'Loop 1 trigger row is Triage-only'
require_fixed '## First action — disarm the trigger' 'Loop 2 self-disarm section'
require_fixed '`bundle-handoff from <ID>`' 'the bundle-handoff comment format'

echo "all pass"
