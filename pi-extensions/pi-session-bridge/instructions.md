## pi-session-bridge — `pi-bridge` CLI

To control other interactive Pi sessions (different tmux windows, terminals, hosts), use the `pi-bridge` CLI. Do not use `tmux send-keys` or `tmux capture-pane` — the bridge is JSON in/JSON out and avoids ANSI noise, alt-screen issues, and stream collisions. Bridge addresses peer Pi sessions you did not spawn; child panes from `subagent` are addressed with `subagent`/`steer_subagent`/`stop_subagent` instead.

Discovery: `pi-bridge list` returns `(PID, IDLE, SESSION, NAME, CWD, SOCKET)`. Filters: `--pid`, `--cwd`, `--session`, `--name`, `--socket`. If exactly one bridge is active, target flags are optional.

Commands:

- `state` — structured snapshot (idle, model, cwd, session id, paths).
- `send "msg"` — deliver a prompt; auto-queues if the target is busy. Slash dispatch is hybrid: `/skill:<name>` and prompt templates expand client-side, including `${N:-default}`, `${@:-default}`, and `${ARGUMENTS:-default}` defaults, extension/TUI commands paste into the target Pi pane, and plain text uses normal `sendUserMessage`. Repeated `/skill:<name>` sends in one Pi session use a short previously-loaded reminder unless the `SKILL.md` content hash changes; session shutdown evicts that session, bridge restart loses the in-memory cache, and the bridge keeps only the 100 most recent sessions.
- `steer "msg"` / `follow-up "msg"` / `abort` — interrupt-and-redirect / queue-after-turn / cancel.
- `history N` / `stream` — structured events, among them input, message_start, message_update, message_end, tool_execution_start, tool_execution_update, tool_execution_end, agent_end, bridge_pong, question and `kendex_activity`. More arrive than that list names. Activity rows are non-chat bridge events emitted by the local activity broker. History returns compact envelopes by default. The reductions you meet most often: `input` is reduced to source/streamingBehavior/images count/text byte count + preview, `message_update` to role/contentIndex/delta length + preview (the delta alone, never rehydratable), `tool_execution_start` and `tool_execution_end` to name/id/status/byte counts/artifact paths, `tool_execution_update` to the call name and id alone with `originalBytes` 0 because it retains nothing of the growing partial result, and `agent_end` to status/usage/final-text preview. Pass `--raw` (alias `--verbose`) to rehydrate from the per-session JSONL sidecar, which holds whole payloads for terminal events such as `message_end` and `tool_execution_end` but nothing for the streaming ones; `--event NAME`, `--since TS`, and `--max-bytes N` narrow the response.
- `questions` + `answer --request-id … --answers '[[...]]'` / `reject --request-id …` — drive `pi-questions` popups.
- `commands` — list slash commands the target session exposes.
- `/bridge:ping <text>` (via `send`) — no-LLM connectivity probe.

Installed at `~/.pi/agent/bin/pi-bridge` (global) or `<project>/.pi/bin/pi-bridge` (project).
