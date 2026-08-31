#!/usr/bin/env bash
# Under Codex `approval=never` an env-assignment prefix (`VAR=value cmd args`,
# e.g. `LC_ALL=C tools/test-ci-changes`) is rejected purely for its prefix
# shape — the inner command is irrelevant. The canonical normalization
# (references/codex-runtime.md § Env-assignment prefixes) happens where a
# required command is ACCEPTED into a workflow: confirm the ambient
# environment satisfies the precondition, then run the bare command. So no
# fenced ```bash/```sh command line in the orch or dev docs may open with one.
#
# A plain assignment with no command after it is a value, not a prefix, and a
# quoted value is a value too; both stay legal, and the docs carry them.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

ENV_PREFIX="^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^\"'[:space:]]+[[:space:]]+[^[:space:]]"

echo "=== orch/dev env-assignment-prefix command lint ==="

forbid_fenced "no fenced command opens with an env-assignment prefix" "$ENV_PREFIX" \
  'LC_ALL=C tools/test-ci-changes' \
  "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md \
  "$SKILLS_ROOT/dev/SKILL.md" "$SKILLS_ROOT"/dev/workflows/*.md

permits_fenced "a bare assignment is a value, not a prefix" "$ENV_PREFIX" \
  'RATCHET_RAISE=1' "$SKILL_DIR/SKILL.md"
permits_fenced "a quoted value is not a prefix" "$ENV_PREFIX" \
  'KEYWORDS="worktree lease"' "$SKILL_DIR/SKILL.md"

md_report
