# Pi runtime reference

Deep halves of the Pi (`pi-agents-tmux`) runtime note in [../SKILL.md](../SKILL.md). Everything here is Pi-specific.

## Pane agents (Pi)

Pane agents (`pane: true` in agent frontmatter) live in a persistent tmux pane keyed by agent name; the extension reuses the existing pane on every redelegation. Do not pass `forceSpawn: true` unless you need a fresh pane — it errors if a live pane already exists; drop the flag or `/agents:stop <name>` first. The `taskId` is returned in two places: the structured `taskId` field on the tool result and an inline `Task ID: <id>` line in the assistant-visible content text — read whichever the harness exposes; no follow-up `get_subagent_result` call is needed to learn the id. Store the `taskId` and agent name in workflow state (`child_sessions[agent].agent_id` or `review_agent_ids[...]`).

Where no tmux server is reachable, as in a hosted lane's sandbox, the extension runs a pane agent headless instead: the tool result opens with `pane-fallback reason=no-tmux`, carries the same `Task ID:` line and holds the agent's return with no follow-up wake, and `stop_subagent` retires it with nothing to kill.

## Bg agents (Pi)

Bg agents (no `pane: true`) are background one-shot processes. A run without `sessionKey` starts a fresh session file that later calls do not resume; [agent-transcripts.md](agent-transcripts.md) says where round recovery finds it. When the same `reviewer-*` (or other bg agent) must retain conversation context across delegations, pass `sessionKey: "<workflow-scoped-stable-id>"` (e.g. `review-issue-PROJ-123`); the same `agent + sessionKey` resumes the prior pi session, and omitting it keeps the call stateless. Bg agents complete by the final assistant message captured by `subagent`; do not instruct them to call `complete_subagent`. A bg agent that starts a full `dev-validate-run` needs a `bgTaskTimeoutMs` deadline that covers its work before the run plus `DEV_VALIDATE_TIMEOUT_SECS`, because the deadline counts from the agent's launch; otherwise the deadline kills it before its return.

## Context before reuse

Apply [skill-rules.md § Delegation](skill-rules.md#delegation) using `get_subagent_result`: pass `agent`, `sessionKey`, and the next dispatch's `cwd` and `agentScope` for a background lane, or the stored `taskId` for a pane. The background check uses the same agent profile and parent model-selection settings as dispatch. Pane checks use the pane registry's working directory and model. Read `contextBudget.ok` and its `estimate` (`tokens`, `contextLimitTokens`, `ratio`, `threshold`). These are the reuse guard's own values, not the parent's usage. For an exhausted pane, save its final result, stop the idle pane with `stop_subagent`, then delegate the new task plus that result with `forceSpawn: true`. For a background lane, omit `sessionKey` for fresh; an ordinary over-threshold reuse call also hands off automatically and reports `reused as fresh (context N%)`. Store its returned `sessionKey` for later reuse instead of the exhausted key. `sameSession: true` requires that exact background session and keeps the refusal.

## Steering and completion recovery (Pi)

On re-delegation to a pane agent, use `steer_subagent` only for true mid-run correction from this same Pi parent session; its success output reads `Bridge: active` and shows the expected child `sessionFile` under this session runtime. If the bridge target is unavailable, the tool queues an inbox fallback that is **not** mid-run steering and is read only when the pane is idle — for idle follow-up work, queue a new `subagent` task to the same pane instead. A running Pi lane that is not this session's child is messaged with `lane-mail send`, never the bridge; the pi-session-bridge CLI reads its state and answers its harness dialogs ([lane-reach.md § Per harness](lane-reach.md#per-harness)).

Use `get_subagent_result` for the context check above or as a recovery/status reader for missed or truncated pane completions; it does not affect ownership or delivery. If it returns `needs_completion`, the child finished a turn without the durable `complete_subagent` record — do not count it as a return; use the verbose diagnostics/outbox path to send one recovery instruction asking the same pane to call `complete_subagent` for the stored `taskId`. Treat Pi custom completion notifications as agent returns only when the task ID matches stored workflow state; repeated display is not a second return.

## Lane mailbox wake (Pi)

A Pi lane uses the `pi-hooks` lane mail wake and arms no mailbox monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)): its launch brief and relaunch line carry no arm line, and the package starts a turn in the idle lane when mail other than an answer lands, or when the session settles with such mail unread, by running the `lane-mail-deliver` hook's judge, and the turn opens with what that judge hands over after a tool call: `lane-mail-check: unread=[N]` and the envelopes, already marked read. Act on every directive it carries; a halt among them names the `lane-mail inbox` command that reads it. A turn opening on any other `lane-mail-check:` line is the judge's refusal, which the lane clears as it would after a tool call. What the package does is its [README](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-hooks/README.md) § Lane mail wake.

`open-terminal` refuses a fleet launch with `pi-mail-wake-missing` if the selected `pi-hooks` lists no lane mail wake. Its `root`, `scope` and `location` fields name the deciding install. Repair it on the lane machine, on the host for `location=hosted`:

| Scope | Recovery |
|---|---|
| `global` | Set `PI_CODING_AGENT_DIR` to the reported `root`; resolve a home-relative host root under that host home. Run `kendex update-pi --scope global`. |
| `project` | Run `kendex update-pi --scope project` from the project containing `root`. In a linked worktree with no manifest of its own, `update-pi` refuses project writes and has no `--project-path` option. Have the install owner replace the carrier at `root/packages/@vanillagreen/pi-hooks` from its updated declared source. A global update does not repair this project carrier. |

Repeat the original launch after repair. A hosted `create` already owns the item, so add `--relaunch`. `tests/open-terminal-harness-gate.sh` covers local recovery fields; `tests/open-terminal-record.sh` covers hosted recovery fields.

## Standing watch (Pi)

The oversee watch ([watch-delivery.md](watch-delivery.md)) reaches a Pi overseer through a `pi-background-tasks` output wake. The spawn parameters are the package's [instructions](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-background-tasks/instructions.md).

| Step | Call |
|------|------|
| Arm | `bg_task action: "spawn"` on the numbered follow command of [watch-delivery.md](watch-delivery.md), with `notifyOnOutput: true`, `notifyMode: "always"`, `notifyOnExit: true` and `timeoutSeconds: 300`. The timeout is the follow's expiry, where watch-delivery.md checks the watch is alive. Keep the pid the spawn returns (`Started [ID] (pid [PID])`): `bg_status` stops only by `pid`, and the list shows it on each task's line. |
| Read | A wake carries an inline tail capped at `outputAlertMaxChars`, so read the log numbered from the line after the last number handled: `awk 'NR >= [NEXT_LINE] { print NR ": " $0 }' "[RUN_DIR]/watch.log"`. |
| Re-arm | The per-task wake budget ends in one "wake budget exhausted" notice. Stop that follow with `bg_status action: "stop"` on the kept pid, then spawn a new one from the line after the last number handled. |
| Exit | Every exit wake, whatever ended the task: run the watch-delivery.md checks, and while they read a live watch, `bg_status action: "list"`. Spawn a new follow from the line after the last number handled only when the list does not show the kept pid as running. This keeps at most one follow, even after a stop or a replayed wake. |

The `bg_task.*` activity events that pi-session-bridge relays reach external observers only, never this session.
