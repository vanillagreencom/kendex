#!/usr/bin/env bash
# ---
# name: stop-failure-row
# event: StopFailure
# matcher:
# description: Records that a turn ended on an API error, as one JSON row the fleet's overseer judgement reads instead of the session's pane: `oversee-watch` judges an overseer whose last row is a StopFailure with error `rate_limit` as walled, the harness's own word for a usage limit, whatever its pane shows, and the lane-mail-check hook writes a Stop row over it at the overseer's next turn end, which lifts it. The row is written by the lane-mail-check hook, run from beside this one with the argument `row`, through the orch skill's `lib/session-rows.sh` from that hook's own install: it carries the time, the event, the harness, the payload's `session_id`, `transcript_path`, `cwd`, `error` and `error_details`, its `last_assistant_message` as `message`, which holds the harness's own text of the limit and its reset, and the account directory this hook's own environment names. A subagent's failure, whose payload carries an `agent_id`, writes nothing. It lands in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl` at the main checkout, the file the oversee state's `overseer.session_rows` names, under the mailbox's own lock, and only where that directory already stands; a session outside tmux, a session with a lane of its own, a harness another harness started in the same pane, whose process ancestry reaches the pane's shell through two processes that are no shell, and an install with no orch reader write nothing and say nothing. A row that could not be written is reported under `lane-mail-check: rows-unwritten=<checkout>`, a library this install has not got under `lane-mail-check: rows-skipped=<path>`. A lane-mail-check missing from beside this hook is reported under `stop-failure-row: judge=<path>`, and a payload it could not read under `stop-failure-row: payload=unreadable`. On Copilot, which has no StopFailure, it runs at errorOccurred, which also fires for a tool, system or user-input error and, on Copilot CLI 1.0.91, once for each retry of a failed model call: a payload whose `errorContext` is not `model_call` writes nothing, and the row takes the payload's `sessionId` and its `error.message` as `message`; a failure whose session is no lead session the lane-mail-check hook recorded at its start writes nothing, and `oversee-watch` judges Claude Code's rows alone, reading the pane of a session whose last row names another harness. Not run on codex: it has no StopFailure event (Codex hooks reference, CLI 0.160.0). Not run on pi: it has no StopFailure event. Not run on gemini: it has no StopFailure event. Not run on antigravity: it has no StopFailure event.
# summary: Writes down that a turn stopped on an error such as a usage limit, so a fleet's overseer that hits its limit is seen to be stuck without anyone reading its screen.
# safety: Reads the payload with jq where jq is installed and runs only the lane-mail-check hook installed in its own directory, which appends one row to a file in the overseer mailbox directory under that directory's lock and reads the tmux pane id, server pid and pane shell pid, its own process ancestry through `ps`, the payload and its own environment. It refuses nothing and exits 0.
# timeout: 30
# harnesses: [claude, copilot, opencode, cursor]
# requires: [lane-mail-check, lane-mail-start]
# ---

set -euo pipefail

# The writer is the lane-mail-check hook installed beside this one, which
# resolves the orch install the row library comes from. The harness reads
# nothing this hook says, so a writer that is not there is said and passed.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'stop-failure-row: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so this turn's failure is not recorded and the overseer judgement reads its pane, the named fallback; install lane-mail-check in the same scope" >&2
  exit 0
fi

# Copilot registers this hook on errorOccurred, whose errorContext names what
# failed; only a failed model call is a StopFailure. A payload jq cannot read,
# or a jq that is not installed, leaves the context empty and the payload goes
# to the judge, which reports it.
INPUT=$(cat 2>&1) || {
  printf 'stop-failure-row: payload=unreadable\n%s\n%s\n' \
    "the hook payload could not be read from stdin, so this turn's failure is not recorded and the overseer judgement reads its pane, the named fallback" "$INPUT" >&2
  exit 0
}
CONTEXT=""
if command -v jq >/dev/null 2>&1; then
  CONTEXT=$(jq -r '.errorContext // "" | strings' <<<"$INPUT" 2>/dev/null) || CONTEXT=""
fi
case "$CONTEXT" in
  "" | model_call) ;;
  *) exit 0 ;;
esac
exec "$BASH" "$JUDGE" row StopFailure <<<"$INPUT"
