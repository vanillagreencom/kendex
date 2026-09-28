#!/usr/bin/env bash
# ---
# name: session-start-row
# event: SessionStart
# matcher:
# description: Records that a session started, as one JSON row the fleet's overseer judgement reads instead of the session's pane. The row is written by the lane-mail-check hook, run from beside this one with the argument `row`, through the orch skill's `lib/session-rows.sh` from that hook's own install: it carries the time, the event, the harness this hook's install directory names, the payload's `session_id`, `transcript_path`, `cwd`, `source` and `model` as the harness emitted them, and the account directory the session runs on, read from this hook's own environment, which is the harness's. It lands in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl` at the main checkout, the file the oversee state's `overseer.session_rows` names, under the mailbox's own lock, and only where that directory already stands; a session outside tmux, a session with a lane of its own, a harness another harness started in the same pane, whose process ancestry reaches the pane's shell through two processes that are no shell, and an install with no orch reader write nothing and say nothing. A row that could not be written is reported under `lane-mail-check: rows-unwritten=<checkout>`, a library this install has not got under `lane-mail-check: rows-skipped=<path>`, and the session starts either way. A lane-mail-check missing from beside this hook is reported under `session-start-row: judge=<path>` and the session starts. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. Not run on copilot: the lane-mail-check hook it runs is not installed there, its agentStop also firing at each subagent's end. Not run on antigravity: it has no SessionStart event.
# summary: Writes down that a session started, and on which account and model, so the fleet's overseer is judged from what its harness said rather than from its screen.
# safety: Runs only the lane-mail-check hook installed in its own directory, which appends one row to a file in the overseer mailbox directory under that directory's lock and reads the tmux pane id, server pid and pane shell pid, its own process ancestry through `ps`, the payload and its own environment. It refuses nothing and exits 0.
# timeout: 30
# harnesses: [claude, codex, pi, opencode, cursor]
# requires: [lane-mail-check]
# ---

set -euo pipefail

# The writer is the lane-mail-check hook installed beside this one, which
# resolves the orch install the row library comes from. A session's start is
# never held on its own record, so a writer that is not there is said and
# passed.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'session-start-row: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so this session's start is not recorded and the overseer judgement reads its pane, the named fallback; install lane-mail-check in the same scope" >&2
  exit 0
fi
exec "$BASH" "$JUDGE" row
