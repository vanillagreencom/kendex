## pi-agents-tmux — `subagent`, `delegate_subagent`, `steer_subagent`, `get_subagent_result`, `wait_for_subagent_idle`, `stop_subagent`

`subagent` delegates work to a project-defined agent (loaded from `.pi/agents`, with `.claude/agents` as a compatibility source). Agents with `pane: true` run in visible persistent tmux panes and survive across turns; others run as resumable bg agents. Child tools default to the parent's active tools minus the agent's `deny-tools:`.

`delegate_subagent` is the restricted variant that child agents (engineer-role agents in particular) can call without gaining full orchestration controls. It only runs in child Pi processes (those launched with `PI_SUBAGENT_CHILD_AGENT` set), only accepts a single `{ agent, task, cwd? }`, and only targets agents listed in the caller's `allowed-subagents:` frontmatter. Engineer agents installed by vstack default to `allowed-subagents: scout` so they can dispatch read-only reconnaissance without absorbing the context. Pane targets, parallel/chain modes, session reuse, and the `agentScope` knob are all rejected.

Use when: isolated context for a focused task; specialist review (security, performance, design); reconnaissance/planning/read-only investigation that can run in parallel; multiple independent investigations via `tasks: [...]` (parallel) or `chain: [...]` (sequential, with `{previous}` placeholder).

Do not use for: trivial work the parent can do directly with read/grep/find; anything where you need streaming tool output to make decisions (results return as a final summary).

Calling rules:
- One self-contained `task` string per delegation — the subagent cannot ask follow-ups.
- Default `agentScope` is `"project"`. Pass `"both"` only when user-level agents at `~/.pi/agent/agents` are explicitly needed.
- Bg (`pane: false`) agents start in a fresh one-shot session when `sessionKey` is omitted. Pass a stable `sessionKey` only when you intentionally want to reuse memory across calls; reused lanes are preflight-guarded near context limit and default to refuse-and-warn.
- Bg children and pane children both carry `PI_SUBAGENT_CHILD_AGENT` for identity/authorization; only visible pane children carry `PI_SUBAGENT_CHILD_PANE=1` and may update tmux pane title or poll pane inboxes.
- Bg completions are captured from the child process's final assistant output. `complete_subagent` is reserved for persistent pane/follow-up tasks and is not exposed to bg children.
- Parallel and chain bg items without `sessionKey` receive distinct one-shot lanes automatically, so same-agent tasks do not collide. Parallel calls run through a flat worker pool capped at `maxConcurrency`; do not split manually.
- Agent names are inventory-checked before launch for the selected `agentScope`. Missing names fail fast with available project/user agents; no similar-name redirect is attempted.
- Persistent-pane (`pane: true`) dispatches return immediately with a `taskId` for follow-up collection. **End your turn after dispatching.** The completion arrives as a follow-up message that wakes you in a new turn — do not call `get_subagent_result` with `wait: true` to block, unless the user asked.
- Save the `taskId`; use `get_subagent_result` only if you suspect a missed wake event. For pane-idle waits, use `wait_for_subagent_idle` (or `get_subagent_result` with `waitFor: "idle"`) instead of shell polling loops; it distinguishes `idle-after-busy` from `never-busy`.
- Dashboard, chat, Monitor, and `get_subagent_result` use persisted task summaries. If a summary is unavailable, inspect the transcript path shown with the task id instead of treating the original request as the result. Monitor/trace surfaces steer vs follow-up delivery when known. A user-hidden dashboard stays hidden until the user toggles it back in.
- If a bg subagent hits `context_length_exceeded`, the extension retries once in a fresh one-shot lane and returns both attempt summaries if the retry also fails.
- If a subagent returns `needs_completion`, inspect `cwdSnapshot.head`, `cwdSnapshot.dirty`, and `cwdSnapshot.lastCommit.subject` when present before deciding whether the subagent's work completed.
- When `pi-session-bridge` is loaded, subagent lifecycle changes also publish structured `agent.*` activity broker events for external observers; these do not appear as chat messages.
- On Linux, before queuing work into a reused live pane, `subagent` verifies the pane process cwd is live and matches the requested task `cwd`. If not, the tool returns a structured `pane-cwd-stale` error and publishes `agent.pane_cwd_stale`; stop the pane with `stop_subagent` and retry with `forceSpawn: true` for a fresh process.
- Pane idle-stall probes cache `pi-bridge` resolution at extension load. A structured `spawn`/`ENOENT` for the expected `pi-bridge` binary is treated as genuinely missing and skips silently; other ENOENT/spawn failures are written to session runtime `subagent-diagnostics.jsonl`. If initial resolver setup fails, one `pi-bridge resolver failed: ...` diagnostic is written.
- Stopping kills the tmux process but preserves the session file; the next default `subagent` call resumes it. Pass `forceSpawn: true` only when the user wants a fresh session.
- `confirmProjectAgents: true` gates project-defined agents behind explicit user approval.
