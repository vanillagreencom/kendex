#!/usr/bin/env bash
# orch runs one simple command per tool call (../SKILL.md § Harness-Safe Shell),
# and its docs write a backtick in a fenced command's search pattern with the
# regex hex escape \x60 in single quotes, in regex mode
# (../references/codex-runtime.md § Substitutes). So no fenced ```bash/```sh
# command line in the orch or dev docs may carry a literal backtick. Prose
# and inline-code backticks are untouched: Markdown is full of them, and only a
# fenced command line is an agent-runnable shape.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch/dev literal-backtick command lint ==="

forbid_fenced "no fenced command carries a literal backtick" '`' \
  'grep -rn "`workflow-state`" skills/' \
  "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md \
  "$SKILLS_ROOT/dev/SKILL.md" "$SKILLS_ROOT"/dev/workflows/*.md

permits_fenced "the canonical \\x60 hex escape is not a backtick" '`' \
  'grep -rn "`workflow-state`" skills/' \
  'grep -rnE '"'"'\x60workflow-state\x60'"'"' skills/' \
  "$SKILL_DIR/SKILL.md"

md_report
