#!/usr/bin/env bash
# A fenced ```bash/```sh command line in the orch or dev docs is a shape an
# agent runs as written, and a hook that reads the command line reads a
# literal backtick in it as a command boundary (../SKILL.md § Harness-Safe Shell:
# a finding's text never crosses argv for the same reason). So the docs
# write a backtick in a fenced command's search pattern with the regex hex
# escape \x60 in single quotes, in regex mode (../references/codex-runtime.md
# § Substitutes), and no fenced command line may carry a literal backtick.
# Prose and inline-code backticks are untouched: Markdown is full of them, and
# only a fenced command line is an agent-runnable shape.
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
