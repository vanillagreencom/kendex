# Flightdeck watchdog reference

Reference doc extracted from `SKILL.md`. See [`SKILL.md`](./SKILL.md) for the load-bearing rules; this file holds detailed reference content for on-demand consultation.

## Reliability watchdogs

Four operator-facing watchdogs run inside the daemon and the `pi-agents-tmux` extension. Agents do not interact with them; they emit activity rows and synthetic outbox payloads when child sessions misbehave.

- **agent-end** (`VSTACK_AGENT_END_WATCHDOG`, default on; grace `VSTACK_AGENT_END_WATCHDOG_GRACE_SEC`=10s) — if a child agent emits `agent_end` without writing a `complete_subagent` outbox within the grace window, the watchdog synthesizes a `needs_completion` outbox so the parent never silently stalls. Emits `agent.needs_completion` activity.
- **idle-stall** (`VSTACK_STALL_WATCHDOG`, default on; `VSTACK_STALL_WATCHDOG_INTERVAL_SEC`=60s, `VSTACK_STALL_WATCHDOG_THRESHOLD_SEC`=300s) — polls bridge-idle subagent panes whose outbox has not landed and fires a synthetic `blocked` outbox after the threshold. Emits `agent.idle_stalled`.
- **edit-loop** (`VSTACK_EDIT_LOOP_DETECTOR`, default on; `VSTACK_EDIT_LOOP_THRESHOLD_N`=5, `VSTACK_EDIT_LOOP_WINDOW_SEC`=120) — counts edit-tool failures inside a child agent's window; on threshold breach synthesizes a `blocked` outbox + `agent.edit_loop_blocked` activity row.
- **rate-limit** (`VSTACK_RATE_LIMIT_WATCHDOG`, default on; `VSTACK_RATE_LIMIT_MAX_ATTEMPTS`=5, `VSTACK_RATE_LIMIT_BACKOFF_LADDER`=`60,120,300,600,1800` seconds) — on a detected Claude API rate-limit error, schedules an exponential-backoff steer-retry. Emits `agent.rate_limit_detected` / `agent.rate_limit_retry` / `agent.rate_limit_exhausted` and short-circuits the canonical wake path while a retry is pending.

All four can be hard-disabled by setting the gate env var to `0`. The canonical decision modules and parity rules live in `DEVELOPMENT.md`.
