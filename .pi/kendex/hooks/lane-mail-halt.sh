#!/usr/bin/env bash
# ---
# name: lane-mail-halt
# event: PreToolUse
# matcher:
# description: Refuses every tool call in a lane while its overseer mailbox holds an unread directive sent with `lane-mail send --halt`, so a halted lane stops at its next tool call. The judgement is the lane-mail-check hook's, run from beside this one with the argument `halt`: its refusal opens `lane-mail-check: halt=<id>` and carries the directive and the one `lane-mail inbox` command that reads it. That command alone passes, and the halt stands until a plain inbox read acknowledges it. A subagent's call, whose payload carries a non-empty `agent_id` or `agent_type`, is refused whatever it runs and is told to report to its lead, never shown the command. The lane is judged from the root lane-mail-check resolves: the directory Claude Code started the session in, else the root the launch marker for `LANE_MAIL_ITEM` binds, else the directory the hook runs in, which on Codex and Pi is the session's start directory; so a lane working from the main clone meets its halt wherever one of the first two is set, or the harness runs hooks in its start directory. A root its launch marker binds that has no mailbox directory is refused too, opening `lane-mail-check: mailbox-missing=<path>` with the one `mkdir` command that restores it, which alone passes. In a launched lane with no unread halt it refuses the harness question tool, Claude Code's `AskUserQuestion` and `EnterPlanMode`, Codex's `request_user_input` and Pi's `question`, under the judge's `lane-mail-check: question-tool=<name>`, naming `lane-mail ask --item <ID> --file <PATH>` and `lane-mail wait` as the route, because a lane asks its overseer only through lane mail and a dialog on the pane reaches nobody; a subagent's such call is refused and told to report its question to the lead. A session that is no lane, and a lane calling any other tool with no unread halt, passes silently. A lane-mail-check missing from beside this hook is refused, opening `lane-mail-halt: judge=<path>`. On Copilot the event is `preToolUse`, the command arrives as `toolArgs.command`, and the judge's refusal is also the documented deny, `{"permissionDecision":"deny","permissionDecisionReason":<the refusal text>}` on stdout under exit 2, so the call is refused and the words reach the model; the decision is the mailbox peek alone, made inside the hook's deadline, because a Copilot preToolUse hook that times out lets the call through. A Copilot call names no agent, so the judge reads it as the lead's only where its `sessionId` is a lead session it recorded at the session's start or at a turn end its transcript proved the lead's, and that call's refusal shows the `lane-mail inbox` command. A call from any other session, a custom subagent's among them, is refused without that command, which the lead's turn end, session start and prompt name, and a call of such a session running that command passes, because the reader's `--ack` stops short of an unread halt and a lead whose record could not be written would otherwise be refused for good. A custom subagent's call was measured on Copilot CLI 1.0.88 carrying its own session id, which nothing recorded; whether a built-in task-tool subagent's calls carry their own session id or the lead's is a pending live-lane proof, and one whose calls carry the lead's is read as the lead and, under a halt, shown the read that clears it. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. Not run on antigravity: the lane-mail-check hook it runs is not installed there, and its command arrives as `toolCall.args.CommandLine`.
# summary: Stops a lane at its next tool call when its overseer sends a halt, until the lane reads it, and refuses the harness question tool in a lane, naming lane mail as the route.
# safety: Runs only the lane-mail-check hook installed in its own directory, whose safety line covers the payload, mailbox and reader it reads. A judge that is not there is refused, never skipped.
# timeout: 30
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# requires: [lane-mail-check]
# ---

set -euo pipefail

# The judge is the lane-mail-check hook installed beside this one: the one
# reader of the lane mailbox. A halt it cannot read is never passed.
JUDGE=""
if HOOK_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'lane-mail-halt: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so whether the overseer halted this lane is unknown; install lane-mail-check in the same scope" >&2
  exit 2
fi
exec "$BASH" "$JUDGE" halt
