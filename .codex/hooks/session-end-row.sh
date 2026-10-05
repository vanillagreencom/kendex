#!/usr/bin/env bash
# ---
# name: session-end-row
# event: SessionEnd
# matcher:
# description: Records that a session ended, as one JSON row the fleet's overseer judgement reads instead of the session's pane: `oversee-watch` judges an overseer whose last row is a SessionEnd for any reason but `clear` or `resume` as exited only where its pane's process is a bare shell with nothing under it, and as live over a running process, whatever its screen shows. The row is written by the lane-mail-check hook, run from beside this one with the argument `row`, through the orch skill's `lib/session-rows.sh` from that hook's own install: it carries the time, the event, the harness, the payload's `session_id`, `transcript_path`, `cwd` and `reason`, and the account directory this hook's own environment names. It lands in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl` at the main checkout, the file the oversee state's `overseer.session_rows` names, under the mailbox's own lock, and only where that directory already stands; a session outside tmux, a session with a lane of its own, a harness another harness started in the same pane, whose process ancestry reaches the pane's shell through two processes that are no shell, and an install with no orch reader write nothing and say nothing. A row that could not be written is reported under `lane-mail-check: rows-unwritten=<checkout>`, a library this install has not got under `lane-mail-check: rows-skipped=<path>`, and the session ends either way. A lane-mail-check missing from beside this hook is reported under `session-end-row: judge=<path>`. Its timeout is 3 s, the longest Codex runs a SessionEnd hook (Codex hooks reference, CLI 0.160.0). On codex: `oversee-watch` judges no Codex row and reads that session's pane instead. On Pi it runs at `session_shutdown` through the pi-hooks carrier from 0.18.0, which says Pi's reason in Claude Code's words: `prompt_input_exit` for `quit`, `clear` for `new` and `fork`, and `resume` for `resume` and `reload`. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses `oversee-watch --harness` takes, so a row on gemini would have no reader. On Copilot it runs at sessionEnd, which Copilot CLI 1.0.91 fires for the lead session alone and never for a subagent, with a `reason` of complete, error, abort, timeout or user_exit, and the row takes the payload's `sessionId`; `oversee-watch` judges Claude Code's rows, and a Pi row only where it is a SessionEnd or a StopFailure with a `message`, and reads the pane of a session whose last row is any other. On copilot: `oversee-watch` judges no Copilot row and reads that session's pane instead. Not run on antigravity: it has no SessionEnd event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses `oversee-watch --harness` takes, so a row on antigravity would have no reader.
# summary: Writes down that a session ended, so a fleet's overseer that exits is seen to have exited without anyone reading its screen.
# safety: Runs only the lane-mail-check hook installed in its own directory, which appends one row to a file in the overseer mailbox directory under that directory's lock and reads the tmux pane id, server pid and pane shell pid, its own process ancestry through `ps`, the payload and its own environment. It refuses nothing and exits 0.
# timeout: 3
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# requires: [lane-mail-check]
# ---

set -euo pipefail

# The writer is the lane-mail-check hook installed beside this one, which
# resolves the orch install the row library comes from. A session's end is
# never held on its own record, so a writer that is not there is said and
# passed. The event is named for a payload that spells none, as Copilot's.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'session-end-row: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so this session's end is not recorded and the overseer judgement reads its pane, the named fallback; install lane-mail-check in the same scope" >&2
  exit 0
fi
exec "$BASH" "$JUDGE" row SessionEnd
