#!/usr/bin/env bash
# The user mode resolves through the settings ladder: every gate that reads it
# runs `orch-env` on the one key, and the settings example ships the default.
# orch-env applies the mode's composition itself, so a gate reading the key
# any other way strands it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

MODES="$SKILL_DIR/references/communication-modes.md"
# The audit lives in a sibling skill, and md.sh resolves SKILL_DIR to orch.
AUDIT="$SKILLS_ROOT/project-management/workflows/audit-issues.md"
OVERSEE="$SKILL_DIR/workflows/oversee.md"
SETTINGS="$SKILL_DIR/kendex.settings.toml.example"

echo "=== orch communication modes lint ==="

rule_fenced "the mode is read through the settings ladder" "$MODES" "" \
  'orch-env ORCH_USER_MODE ceo'
rule_fenced "the audit gate reads the key through the ladder" "$AUDIT" \
  "## 6. Approve Creations and Cancellations" 'orch-env PM_CREATE_AUTONOMY ask'
rule_fenced "the overseer resolves the mode before it relays" "$OVERSEE" \
  "## 3. Launch" 'orch-env ORCH_USER_MODE ceo'
rule "the settings example ships the package default" "$SETTINGS" "" \
  'ORCH_USER_MODE = "ceo"'

md_report
