#!/usr/bin/env bash
# The github router has no `ci-wait` command. A handoff once told an agent to
# run `github.sh ci-wait 296 --json`; CI waiting is the orch script
# `.agents/skills/orch/scripts/ci-wait`. No canonical doc carried the bad form
# — the orch Codex guidance named `ci-wait` bare, with no path, which an
# orchestrator relaying it beside `github.sh` commands could resolve to the
# wrong wrapper. dev and github are required orch dependencies, so both trees
# are present wherever orch is installed and both are scanned.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch/dev/github ci-wait routing lint ==="

forbid "no doc routes ci-wait through github.sh" \
  'github\.sh( -C [^ ]+)? ci[-_]?wait' \
  'Wait for CI with `github.sh ci-wait 296 --json`.' \
  "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md \
  "$SKILLS_ROOT/dev/SKILL.md" "$SKILLS_ROOT"/dev/workflows/*.md \
  "$SKILLS_ROOT/github/SKILL.md"

rule_fenced "submit-pr invokes ci-wait by its orch path" \
  "$SKILL_DIR/workflows/submit-pr.md" "" '.agents/skills/orch/scripts/ci-wait'
rule "the Codex guidance names the orch ci-wait path" \
  "$SKILL_DIR/SKILL.md" "" 'Codex' '.agents/skills/orch/scripts/ci-wait'
rule "github points CI waiting at the orch script" \
  "$SKILLS_ROOT/github/SKILL.md" "" 'CI waiting' '.agents/skills/orch/scripts/ci-wait'

md_report
