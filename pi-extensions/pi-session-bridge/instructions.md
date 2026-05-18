## pi-session-bridge — `pi-bridge` CLI

To control other interactive Pi sessions (different tmux windows, terminals, hosts), use the `pi-bridge` CLI. Do not use `tmux send-keys` or `tmux capture-pane` — the bridge is JSON in/JSON out and avoids ANSI noise, alt-screen issues, and stream collisions. Bridge addresses peer Pi sessions you did not spawn; child panes from `subagent` are addressed with `subagent`/`steer_subagent`/`stop_subagent` instead.

Discovery: `pi-bridge list` returns `(PID, IDLE, SESSION, NAME, CWD, SOCKET)`. Filters: `--pid`, `--cwd`, `--session`, `--name`, `--socket`. If exactly one bridge is active, target flags are optional.

Commands:
- `state` — structured snapshot (idle, model, cwd, session id, paths).
- `send "msg"` — deliver a prompt; auto-queues if the target is busy. Slash dispatch is hybrid: `/skill:<name>` and prompt templates expand client-side, extension/TUI commands paste into the target Pi pane, and plain text uses normal `sendUserMessage`. Repeated `/skill:<name>` sends in one Pi session use a short previously-loaded reminder unless the `SKILL.md` content hash changes; bridge restart loses this in-memory cache.
- `steer "msg"` / `follow-up "msg"` / `abort` — interrupt-and-redirect / queue-after-turn / cancel.
- `history N` / `stream` — structured events (input, message_update, tool_call, agent_end, bridge_pong, question, `vstack_activity`). Activity rows are non-chat bridge events emitted by the local activity broker.
- `questions` + `answer --request-id … --answers '[[...]]'` / `reject --request-id …` — drive `pi-questions` popups.
- `commands` — list slash commands the target session exposes.
- `/bridge:ping <text>` (via `send`) — no-LLM connectivity probe.

Installed at `~/.pi/agent/bin/pi-bridge` (global) or `<project>/.pi/bin/pi-bridge` (project).
