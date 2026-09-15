#!/usr/bin/env bash
# ---
# name: lane-mail-deliver
# event: PostToolUse
# matcher:
# description: Hands a lane the lines its overseer mailbox holds unread once a tool call finishes, so a directive reaches a working lane at its next tool call rather than at its turn end. The judgement is the lane-mail-check hook's, run from beside this one with the argument `deliver`: it exits 0 with `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":...}}` on stdout, the context opening `lane-mail-check: unread=<count>` with one JSON envelope per line under it, and acknowledges them once that is written; the tool's own output stands. A session that is no lane, and a lane with nothing unread, passes silently. A lane-mail-check missing from beside this hook is refused, opening `lane-mail-deliver: judge=<path>`.
# summary: Hands a working lane the messages its overseer sent as soon as a tool call finishes.
# safety: Runs only the lane-mail-check hook installed in its own directory, whose safety line covers the payload, mailbox and reader it reads. A judge that is not there is refused, never skipped.
# timeout: 30
# harnesses: [claude-code, codex, pi]
# ---

set -euo pipefail

# The judge is the lane-mail-check hook installed beside this one: the one
# reader of the lane mailbox. Mail it cannot read is never passed as none.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'lane-mail-deliver: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so whether the overseer sent this lane mail is unknown; install lane-mail-check in the same scope" >&2
  exit 2
fi
exec "$BASH" "$JUDGE" deliver
