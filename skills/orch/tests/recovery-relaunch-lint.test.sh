#!/usr/bin/env bash
# The recovery relaunch, ../references/lane-directive.md § Recovery relaunch,
# which ../workflows/oversee.md § Recovery relaunch points at: open-terminal
# runs the start brief itself where a local or hosted claude relaunch's resume
# finds no session, and a hosted codex or pi relaunch with no session is
# recovered with --cmd, so neither file may carry a rule that forbids --cmd on
# that relaunch. The forbid
# pins that rule's absence, never the wording that replaced it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch recovery relaunch lint ==="

forbid "the recovery relaunch carries no rule forbidding --cmd" \
  '([Dd]o not|[Dd]on.t|[Nn]ever) (pass|use|add|keep)( a)? `?--cmd' \
  'Do not pass `--cmd`, because a custom command bypasses session lookup.' \
  "$SKILL_DIR/references/lane-directive.md" "$SKILL_DIR/workflows/oversee.md"

md_report
