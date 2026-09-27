#!/usr/bin/env bash
# The lane-output switch, ../references/skill-rules.md § Lane Output: the rule
# resolves it through `orch-env`, the settings example ships its default, and a
# block ahead of an ask gate travels as `lane-mail ask --file`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

LANE_OUTPUT='## Lane Output'
RULES="$SKILL_DIR/references/skill-rules.md"

echo "=== orch lane-output lint ==="

rule "the switch resolves through orch-env" "$RULES" "$LANE_OUTPUT" \
  'orch-env ORCH_LANE_OUTPUT quiet'
rule "a block ahead of an ask gate is that ask's file" "$RULES" "$LANE_OUTPUT" \
  'lane-mail ask --file [PATH]'
rule "the package default is quiet" "$SKILL_DIR/kendex.settings.toml.example" "" \
  'ORCH_LANE_OUTPUT = "quiet"'

md_report
