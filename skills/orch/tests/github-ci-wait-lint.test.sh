#!/usr/bin/env bash
# The github router has no `ci-wait` command; CI waiting is the orch script
# `.agents/skills/orch/scripts/ci-wait`. A doc naming `ci-wait` bare, with no
# path, lets an orchestrator relaying it beside `github.sh` commands resolve it
# to the wrong wrapper. dev and github are required orch dependencies, so both
# trees are present wherever orch is installed and both are scanned.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch/dev/github ci-wait routing lint ==="

# The surface is every markdown file in the three skills, two levels deep: a
# README, a DEVELOPMENT note or a schema can relay a bad route as readily as a
# workflow can, and this lint's claim is about any doc. Built by `find` rather
# than by a glob list so a directory is covered the day it appears; a `find`
# that returns nothing leaves the list empty, which `forbid` refuses.
DOCS=()
while IFS= read -r -d '' doc; do
  DOCS+=("$doc")
done < <(find "$SKILL_DIR" "$SKILLS_ROOT/dev" "$SKILLS_ROOT/github" \
  -maxdepth 2 -type f -name '*.md' -not -path '*/tests/*' -print0 | LC_ALL=C sort -z)

# Whitespace is matched by class, not by one literal space: a run of spaces or
# a tab between the router and the subcommand is the same bad route.
forbid "no doc routes ci-wait through github.sh" \
  'github\.sh[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?ci[-_]?wait' \
  'Wait for CI with `github.sh  ci-wait 296 --json`.' \
  ${DOCS+"${DOCS[@]}"}

# Register the required-only token first so the shared fenced-rule control
# drops the mode flag and proves that the real merge caller cannot omit it.
for workflow in workflows/ci-fix.md workflows/submit-pr.md references/merge-attempt.md; do
  rule_fenced "$workflow waits only for required CI" \
    "$SKILL_DIR/$workflow" "" '--required-only' '.agents/skills/orch/scripts/ci-wait'
done

md_report
