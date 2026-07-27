# Pi runtime reference

Deep halves of the Pi (`pi-agents-tmux`) runtime note in [../SKILL.md](../SKILL.md). Everything here is Pi-specific.

## Pane agents (Pi)

Pane agents (`pane: true` in agent frontmatter) live in a persistent tmux pane keyed by agent name; the extension reuses the existing pane on every redelegation. Do not pass `forceSpawn: true` unless you genuinely need a fresh pane — it errors if a live pane already exists and tells you to either drop the flag or `/agents:stop <name>` first. The `taskId` is returned in two places: the structured `taskId` field on the tool result and an inline `Task ID: <id>` line in the assistant-visible content text — read whichever the harness exposes; no follow-up `get_subagent_result` call is needed just to learn the id. Store the `taskId` and agent name in workflow state (`child_sessions[agent].agent_id` or `review_agent_ids[...]`).

## Bg agents (Pi)

Bg agents (no `pane: true`) are background one-shot processes, ephemeral by default (no persisted session). For multi-step workflows where the same `reviewer-*` (or other bg agent) must retain conversation context across delegations, pass `sessionKey: "<workflow-scoped-stable-id>"` (e.g. `review-issue-PROJ-123`); the same `agent + sessionKey` resumes the prior pi session, and omitting it keeps the call stateless. Bg agents complete by the final assistant message captured by `subagent`; do not instruct them to call `complete_subagent`.

## Steering and completion recovery (Pi)

On re-delegation to a pane agent, use `steer_subagent` only for true mid-run correction from this same Pi parent session; its success output reads `Bridge: active` and shows the expected child `sessionFile` under this session runtime. If the bridge target is unavailable, the tool queues an inbox fallback that is **not** mid-run steering and is read only when the pane is idle — for idle follow-up work, queue a new `subagent` task to the same pane instead.

Use `get_subagent_result` only as a recovery/status reader for missed or truncated pane completions; it does not affect ownership or delivery. If it returns `needs_completion`, the child finished a turn without the durable `complete_subagent` record — do not count it as a return; use the verbose diagnostics/outbox path to send one recovery instruction asking the same pane to call `complete_subagent` for the stored `taskId`. Treat Pi custom completion notifications as agent returns only when the task ID matches stored workflow state; repeated display is not a second return.
