#!/usr/bin/env bash
# The lane status file, which ../workflows/oversee.md § 3 names in a lane's
# brief and `oversee-watch` reads to tell a working lane from a stalled one.
# Each workflow a lane opens with carries the write as a step of its own § 1;
# ../workflows/small.md runs ../workflows/start-worktree.md § 1 and so carries
# it through that file.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

OPEN='## 1. Open The Session'
STATUS_FILE='tmp/lane-status-[ISSUE_ID].md'

echo "=== orch lane-status step lint ==="

rule "start-worktree writes the status file in its § 1" "$SKILL_DIR/workflows/start-worktree.md" "$OPEN" \
  "$STATUS_FILE"
rule "micro writes the status file in its § 1" "$SKILL_DIR/workflows/micro.md" "$OPEN" \
  "$STATUS_FILE"

md_report
