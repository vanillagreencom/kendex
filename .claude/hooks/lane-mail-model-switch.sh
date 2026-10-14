#!/usr/bin/env bash
# ---
# name: lane-mail-model-switch
# event: PostModelSwitch
# matcher:
# description: Runs the installed lane-mail-check hook after Claude Code changes a launched lane session model. That hook owns model comparison, session records and recovery. Not run on codex: no PostModelSwitch event. Not run on pi: no PostModelSwitch event. Not run on copilot: no PostModelSwitch event. Not run on opencode: no PostModelSwitch event. Not run on cursor: no PostModelSwitch event. Not run on gemini: no PostModelSwitch event. Not run on antigravity: no PostModelSwitch event.
# summary: Delivers Claude model-switch events to the existing lane self-check.
# safety: Runs only the lane-mail-check hook installed beside this one. That hook owns the payload and recovery checks.
# timeout: 30
# harnesses: [claude]
# requires: [lane-mail-check]
# ---

set -euo pipefail

HOOK_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)" || exit 1
JUDGE="$HOOK_DIR/lane-mail-check.sh"
if [[ ! -x "$JUDGE" ]]; then
  printf 'lane-mail-model-switch: judge=%s\n' "$JUDGE"
  exit 0
fi
exec "$BASH" "$JUDGE"
