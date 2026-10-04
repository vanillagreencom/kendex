#!/usr/bin/env bash
# ---
# name: stop-failure-row
# event: StopFailure
# matcher:
# description: Records that a turn ended on an API error, as one JSON row the fleet's overseer judgement reads instead of the session's pane: `oversee-watch` judges an overseer whose last row is a StopFailure with error `rate_limit` as walled, Claude Code's own word for a usage limit, or on Pi, which names no error kind, one whose `message` the orch skill's `lane_limit_banner` reads as the account's limit, whatever its pane shows, and the lane-mail-check hook writes a Stop row over it at the overseer's next turn end, which lifts it. The row is written by the lane-mail-check hook, run from beside this one with the argument `row`, through the orch skill's `lib/session-rows.sh` from that hook's own install: it carries the time, the event, the harness, the payload's `session_id`, `transcript_path`, `cwd`, `error` and `error_details`, its `last_assistant_message` as `message`, which holds the harness's own text of the limit and its reset, and the account directory this hook's own environment names. A subagent's failure, whose payload carries an `agent_id`, writes nothing. It lands in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl` at the main checkout, the file the oversee state's `overseer.session_rows` names, under the mailbox's own lock, and only where that directory already stands; a session outside tmux, a session with a lane of its own, a harness another harness started in the same pane, whose process ancestry reaches the pane's shell through two processes that are no shell, and an install with no orch reader write nothing and say nothing. A row that could not be written is reported under `lane-mail-check: rows-unwritten=<checkout>`, a library this install has not got under `lane-mail-check: rows-skipped=<path>`. A lane-mail-check missing from beside this hook is reported under `stop-failure-row: judge=<path>`. Not run on codex: it has no StopFailure event (Codex hooks reference, CLI 0.160.0). For an overseer on codex the fleet watch judges a failed turn from the overseer's pane and its account headroom instead. On Pi it runs at `agent_before_settle` through the pi-hooks carrier, only on a run whose outcome is `error`, never on a completed or aborted one: the payload carries no `error`, and its `last_assistant_message` is the failed response's `errorMessage` where the carrier sends one. `oversee-watch` judges a Pi row only from the evidence it carries, a SessionEnd or a StopFailure with a `message`, and reads the pane of a Pi session whose last row is any other, its SessionStart, its Stop or a StopFailure with no `message`. Not run on gemini: it has no StopFailure event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses `oversee-watch --harness` takes, so a row on gemini would have no reader. Not run on copilot: errorOccurred fires once per recoverable model-call retry, six times for one failed turn, and Copilot has no turn-failure event (Copilot hooks reference, CLI 1.0.91). For an overseer on copilot the fleet watch judges a failed turn from the overseer's pane and its account headroom instead. Not run on antigravity: it has no StopFailure event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses `oversee-watch --harness` takes, so a row on antigravity would have no reader.
# summary: Writes down that a turn stopped on an error such as a usage limit, so a fleet's overseer that hits its limit is seen to be stuck without anyone reading its screen.
# safety: Runs only the lane-mail-check hook installed in its own directory, which appends one row to a file in the overseer mailbox directory under that directory's lock and reads the tmux pane id, server pid and pane shell pid, its own process ancestry through `ps`, the payload and its own environment. It refuses nothing and exits 0.
# timeout: 30
# harnesses: [claude, pi, opencode, cursor]
# requires: [lane-mail-check]
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
exec "$BASH" "$JUDGE" row StopFailure
