#!/usr/bin/env bash
# .github/instructions/skills-and-agents.instructions.md bans issue-number
# citations in the markdown an agent parses to act — every `skills/*/SKILL.md`
# and repo-root `agents/*.md`. Human-facing README.md and DEVELOPMENT.md,
# on-demand `workflows/*.md`, and `schemas/*.md` (established convention: they
# carry issue provenance) are outside it.
#
# A parenthetical is required for the bare form so a hex colour like `#000000`
# never false-positives; the digit count is not load-bearing for that, so a
# short citation like `(#42)` is still caught.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== issue-citation lint (always-loaded skill/agent markdown) ==="

# The rendered copy under `.agents/` sits in a tree carrying `skills/` alone,
# so the agent definitions are scanned where they exist and their absence is
# not a failure. Both trees missing leaves the list empty, which `forbid`
# refuses on its own: an absence check over nothing passes for the wrong
# reason.
SCAN=()
[ -d "$REPO_ROOT/skills" ] && SCAN+=("$REPO_ROOT"/skills/*/SKILL.md)
[ -d "$REPO_ROOT/agents" ] && SCAN+=("$REPO_ROOT"/agents/*.md)

forbid "no issue-number citation in SKILL.md or agents/*.md" \
  'kendex#[0-9]+|\(#[0-9]+\)' \
  'Always ask before merge (kendex#944), same class as (#42).' \
  ${SCAN+"${SCAN[@]}"}

permits "a bare hex colour is not a citation" \
  'kendex#[0-9]+|\(#[0-9]+\)' \
  'Always ask before merge (kendex#944), same class as (#42).' \
  'The default canvas is near-black, not pure #000000.' \
  "$REPO_ROOT/skills/orch/SKILL.md"

md_report
