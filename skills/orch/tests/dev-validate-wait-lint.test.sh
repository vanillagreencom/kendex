#!/usr/bin/env bash
# Pins the Claude Code route through dev-validate-run in the dev skill. A dev
# subagent whose turn ends on a backgrounded start is not woken when the run
# ends, so the round stops before its commit and artifact. The bullet runs the
# start command in the foreground and polls with --wait --run-dir, and never
# names the `run_in_background` parameter that moves the start out of the turn.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

DEV="$SKILLS_ROOT/dev/SKILL.md"
SECTION="### Long-Running Validation"

echo "=== dev-validate-run Claude Code wait lint ==="

rule "the Claude Code bullet starts the run and polls it with --wait --run-dir" \
  "$DEV" "$SECTION" '- **Claude Code.**' \
  '`.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH]`' \
  '`.agents/skills/orch/scripts/dev-validate-run --wait --run-dir [RUN_DIR]`' \
  '`state=running`'

forbid "the Claude Code bullet never backgrounds the start" \
  '^- \*\*Claude Code\.\*\*.*run_in_background' \
  '- **Claude Code.** Background the BARE command `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH]` via `run_in_background` and wait for the completion notice.' \
  "$DEV"

md_report
