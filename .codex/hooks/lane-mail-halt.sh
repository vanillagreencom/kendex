#!/usr/bin/env bash
# ---
# name: lane-mail-halt
# event: PreToolUse
# matcher:
# description: Refuses every tool call in a lane while its overseer mailbox holds an unread directive sent with `lane-mail send --halt`, so a halted lane stops at its next tool call. The judgement is the lane-mail-check hook's, run from beside this one with the argument `halt`: its refusal opens `lane-mail-check: halt=<id>` and carries the directive and the one `lane-mail inbox` command that reads it. That command alone passes, and the halt stands until a plain inbox read acknowledges it. A subagent's call, whose payload carries a non-empty `agent_id` or `agent_type`, is refused whatever it runs and is told to report to its lead, never shown the command. A session that is no lane, and a lane with no unread halt, passes silently. A lane-mail-check missing from beside this hook is refused, opening `lane-mail-halt: judge=<path>`. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. Not run on copilot: its preToolUse refusal reaches the model without the hook's words, so the lane never learns the halt or the command that acknowledges it. Not run on antigravity: the lane-mail-check hook it runs is not installed there, and its command arrives as `toolCall.args.CommandLine`.
# summary: Stops a lane at its next tool call when its overseer sends a halt, until the lane reads it.
# safety: Runs only the lane-mail-check hook installed in its own directory, whose safety line covers the payload, mailbox and reader it reads. A judge that is not there is refused, never skipped.
# timeout: 30
# harnesses: [claude, codex, pi, opencode, cursor]
# requires: [lane-mail-check]
# ---

set -euo pipefail

# The judge is the lane-mail-check hook installed beside this one: the one
# reader of the lane mailbox. A halt it cannot read is never passed.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'lane-mail-halt: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so whether the overseer halted this lane is unknown; install lane-mail-check in the same scope" >&2
  exit 2
fi
exec "$BASH" "$JUDGE" halt
