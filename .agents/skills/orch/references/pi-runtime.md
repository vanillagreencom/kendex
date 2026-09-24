# Pi runtime reference

Deep halves of the Pi (`pi-agents-tmux`) runtime note in [../SKILL.md](../SKILL.md). Everything here is Pi-specific.

## Pane agents (Pi)

Pane agents (`pane: true` in agent frontmatter) live in a persistent tmux pane keyed by agent name; the extension reuses the existing pane on every redelegation. Do not pass `forceSpawn: true` unless you need a fresh pane — it errors if a live pane already exists; drop the flag or `/agents:stop <name>` first. The `taskId` is returned in two places: the structured `taskId` field on the tool result and an inline `Task ID: <id>` line in the assistant-visible content text — read whichever the harness exposes; no follow-up `get_subagent_result` call is needed to learn the id. Store the `taskId` and agent name in workflow state (`child_sessions[agent].agent_id` or `review_agent_ids[...]`).

## Bg agents (Pi)

Bg agents (no `pane: true`) are background one-shot processes, ephemeral by default (no persisted session). When the same `reviewer-*` (or other bg agent) must retain conversation context across delegations, pass `sessionKey: "<workflow-scoped-stable-id>"` (e.g. `review-issue-PROJ-123`); the same `agent + sessionKey` resumes the prior pi session, and omitting it keeps the call stateless. Bg agents complete by the final assistant message captured by `subagent`; do not instruct them to call `complete_subagent`.

## Steering and completion recovery (Pi)

On re-delegation to a pane agent, use `steer_subagent` only for true mid-run correction from this same Pi parent session; its success output reads `Bridge: active` and shows the expected child `sessionFile` under this session runtime. If the bridge target is unavailable, the tool queues an inbox fallback that is **not** mid-run steering and is read only when the pane is idle — for idle follow-up work, queue a new `subagent` task to the same pane instead. A running Pi lane that is not this session's child is messaged with `lane-mail send`, never the bridge; the pi-session-bridge CLI reads its state and answers its harness dialogs ([oversee.md § Talking to a lane](../workflows/oversee.md#talking-to-a-lane)).

Use `get_subagent_result` only as a recovery/status reader for missed or truncated pane completions; it does not affect ownership or delivery. If it returns `needs_completion`, the child finished a turn without the durable `complete_subagent` record — do not count it as a return; use the verbose diagnostics/outbox path to send one recovery instruction asking the same pane to call `complete_subagent` for the stored `taskId`. Treat Pi custom completion notifications as agent returns only when the task ID matches stored workflow state; repeated display is not a second return.

## Standing watch (Pi)

The oversee watch ([watch-delivery.md](watch-delivery.md)) reaches a Pi overseer through a `pi-background-tasks` output wake. The spawn parameters are the package's [instructions](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-background-tasks/instructions.md).

| Step | Call |
|------|------|
| Arm | `bg_task action: "spawn"` on the numbered follow command of [watch-delivery.md](watch-delivery.md), with `notifyOnOutput: true`, `notifyMode: "always"`, `notifyOnExit: true` and `timeoutSeconds: 300`. The timeout is the follow's expiry, where watch-delivery.md checks the watch is alive. Keep the task id the spawn returns. |
| Read | A wake carries an inline tail capped at `outputAlertMaxChars`, so read the log numbered from the line after the last number handled: `awk 'NR >= [NEXT_LINE] { print NR ": " $0 }' [RUN_DIR]/watch.log`. |
| Re-arm | The per-task wake budget ends in one "wake budget exhausted" notice. Stop that follow with `bg_status action: "stop"` and spawn a new one from the line after the last number handled. |
| Exit | Every exit wake, whatever ended the task: run the watch-delivery.md checks, and while they read a live watch, `bg_status action: "list"`. Spawn a new follow from the line after the last number handled only when the list does not show the kept task id as running. This keeps at most one follow, even after a stop or a replayed wake. |

The `bg_task.*` activity events that pi-session-bridge relays reach external observers only, never this session.
