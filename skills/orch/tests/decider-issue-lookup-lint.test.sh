#!/usr/bin/env bash
# The decider CLI has no `issue` action. A dev-fix delegation once told a
# specialist to run `decisions issue CC-125`, which the CLI rejects; the
# supported issue lookup is `decisions search --issue CC-125`. Guidance text is
# what an agent relays, so every line of the orch docs is scanned — prose,
# inline code and fences alike.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch decider issue-lookup lint ==="

# `decisions search --issue` never matches: `search` sits between the two
# tokens, so the supported form and this rule coexist.
forbid "orch docs use no unsupported decisions issue-lookup shape" \
  'decisions[[:space:]]+(issues?([^a-zA-Z0-9_-]|$)|show[[:space:]]+--issue)' \
  'Check decisions: run `decisions issue CC-125` first.' \
  "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md

rule_fenced "dev-fix carries the supported lookup" \
  "$SKILL_DIR/workflows/dev-fix.md" "" 'decisions search --issue'

md_report
