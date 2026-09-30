#!/usr/bin/env bash
# ---
# name: lane-mail-deliver
# event: PostToolUse
# matcher:
# description: Hands a lane the lines its overseer mailbox holds unread once a tool call finishes, so a directive reaches a working lane at its next tool call rather than at its turn end. The judgement is the lane-mail-check hook's, run from beside this one with the argument `deliver`: it exits 0 with `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":...}}` on stdout, the context opening `lane-mail-check: unread=<count>` with one JSON envelope per line under it, and acknowledges them once that is written; the tool's own output stands. A subagent's call, whose payload carries a non-empty `agent_id` or `agent_type`, is handed nothing and acknowledges nothing. The lane is judged from the root lane-mail-check resolves: the directory Claude Code started the session in, else the root the launch marker for `LANE_MAIL_ITEM` binds, else the directory the hook runs in, which on Codex and Pi is the session's start directory. A root its launch marker binds that has no mailbox directory is refused under the judge's `lane-mail-check: mailbox-missing=<path>` after the lead's call; a subagent's finished call is refused nothing here, and its next call is refused by the lane-mail-halt hook. A session that is no lane is handed the checkout's overseer mailbox instead, by the judge's own rule, only where the checkout's oversee workflow state names its tmux pane under `.overseer`, a single-pass fleet's own overseer or a session `oversee register` named, and no live repeat watch holds that state, so a note `lane-mail peer send --repo` wrote to a checkout where no repeat watch runs reaches that session and no other session working there. The same run judges the context mark of the session that checkout's record names as its overseer after each of its tool calls, and hands a reached mark, or a judgement that could not run, over as that same context at exit 0, as the judge's description states, so an overseer that crosses its mark mid-turn is told at its next tool call. A lane with nothing unread, and a session with neither mailbox, passes silently. A lane-mail-check missing from beside this hook is refused, opening `lane-mail-deliver: judge=<path>`. On Copilot the event is `postToolUse`, whose reference reads a top-level `additionalContext` and appends it to the tool result the model sees on the same turn, so there the judge exits 0 with `{"additionalContext":...}` carrying the same context and acknowledges it, for a call whose `sessionId` is a lead session the judge recorded at the session's start or at a turn end its transcript proved the lead's. A Copilot tool call names no agent, so a call from any session the judge has no record of is handed nothing and acknowledges nothing, with `lane-mail-check: session-unrecorded=<id>` on stderr, and the lines stay unread for the lead's turn end, which hands them over and acknowledges them. A custom subagent's call was measured on Copilot CLI 1.0.88 carrying its own session id, which nothing recorded; whether a built-in task-tool subagent's calls carry their own session id or the lead's is a pending live-lane proof, and one whose calls carry the lead's is read as the lead and handed the lead's mail after its calls, which marks it read. A refusal the judge makes there is the same answer at exit 0, since Copilot reads a postToolUse answer only at exit 0. A live-lane capture of that delivery is a proof still pending. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. Not run on antigravity: any PostToolUse output replaces the tool result the model reads.
# summary: Hands a working lane the messages its overseer sent as soon as a tool call finishes, and the notes another repository's overseer sent to the one session the checkout's fleet record names. It also tells the session running the fleet, at its next tool call, that it has used enough of its context to hand over.
# safety: Runs only the lane-mail-check hook installed in its own directory, whose safety line covers the payload, mailbox and reader it reads. A judge that is not there is refused, never skipped.
# timeout: 30
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# requires: [lane-mail-check]
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
