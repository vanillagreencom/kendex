#!/usr/bin/env bash
# The github router has no `ci-wait` command. A handoff once told an agent to
# run `github.sh ci-wait 296 --json`; CI waiting is the orch script
# `.agents/skills/orch/scripts/ci-wait`. No canonical doc carried the bad form
# — the orch Codex guidance named `ci-wait` bare, with no path, which an
# orchestrator relaying it beside `github.sh` commands could resolve to the
# wrong wrapper. dev and github are required orch dependencies, so both trees
# are present wherever orch is installed and both are scanned.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch/dev/github ci-wait routing lint ==="

# The surface is every markdown file in the three skills, two levels deep, the
# same set the predecessor read: a README, a DEVELOPMENT note or a schema can
# relay a bad route as readily as a workflow can, and this lint's claim is
# about any doc. Built by `find` rather than by a glob list so a new directory
# is covered the day it appears; a `find` that returns nothing leaves the list
# empty, which `forbid` refuses.
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

rule_fenced "submit-pr invokes ci-wait by its orch path" \
  "$SKILL_DIR/workflows/submit-pr.md" "" '.agents/skills/orch/scripts/ci-wait'
rule "the Codex guidance names the orch ci-wait path" \
  "$SKILL_DIR/SKILL.md" "" 'Codex' '.agents/skills/orch/scripts/ci-wait'
rule "github points CI waiting at the orch script" \
  "$SKILLS_ROOT/github/SKILL.md" "" 'CI waiting' '.agents/skills/orch/scripts/ci-wait'

md_report
