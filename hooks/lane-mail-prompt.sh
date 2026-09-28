#!/usr/bin/env bash
# ---
# name: lane-mail-prompt
# event: UserPromptSubmit
# matcher:
# description: Hands a Copilot lane the lines its overseer mailbox holds unread each time it is handed a prompt, so a lane idle at its prompt reads its mail with the next prompt rather than at its first tool call or turn end. The judgement is the lane-mail-check hook's, run from beside this one with the argument `prompt`: it exits 0 with `{"additionalContext":...}` on stdout, the context opening `lane-mail-check: unread=<count>` with one JSON envelope per line under it, and acknowledges them only once that is written, so a write that fails leaves them unread for the next point that delivers them. Copilot registers it as `userPromptSubmitted`, whose hooks reference documents only `modifiedPrompt` and says a config-file hook's output is dropped; the owner's own probe, a repository hook in a fresh `copilot -p` run against a negative control, is what shows the `additionalContext` reaching the model, and a live-lane capture of that delivery is a proof still pending. The lane, its mailbox, the overseer mailbox a lead session that is no lane reads where no live repeat watch holds the checkout's oversee workflow state, and the subagent rule are the judge's own, as for the lane-mail-deliver hook: a payload carrying a non-empty `agent_id` or `agent_type` is handed nothing and acknowledges nothing. It never refuses a prompt: a session that is no lane, a lane with nothing unread and a subagent get no output, and every refusal the judge names is its keyed line on stderr at exit 0, with nothing on stdout and nothing acknowledged, as is a lane-mail-check missing from beside this hook, opening `lane-mail-prompt: judge=<path>`. Not run on claude: a lane there arms a `lane-mail watch` monitor that wakes it at an idle prompt. Not run on codex: the overseer wakes a Codex lane idle at its prompt with `open-terminal --wake`. Not run on pi: a lane there arms a `lane-mail watch` monitor under `bg_task` that wakes it at an idle prompt. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. Not run on antigravity: the lane-mail-check hook it runs is not installed there, its Stop payload carrying no `stop_hook_active`. Not run on opencode: it runs no hooks, and a delivery point taken as an instruction delivers nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a delivery point taken as an instruction delivers nothing.
# summary: Hands a Copilot lane the messages its overseer sent with each prompt it is handed, and a lead session in a checkout with no running repeat fleet watch the notes another repository's overseer sent it.
# safety: Runs only the lane-mail-check hook installed in its own directory, whose safety line covers the payload, mailbox and reader it reads. A judge that is not there is reported on stderr, never run from elsewhere.
# timeout: 30
# harnesses: [copilot]
# requires: [lane-mail-check]
# ---

set -euo pipefail

# The judge is the lane-mail-check hook installed beside this one: the one
# reader of the lane mailbox. A prompt is never refused, so a judge that is not
# there is reported and passed, and the mail stays unread for the next point
# that delivers it.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'lane-mail-prompt: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so whether the overseer sent this lane mail is unknown, and it waits for the next point that delivers it; install lane-mail-check in the same scope" >&2
  exit 0
fi
exec "$BASH" "$JUDGE" prompt
