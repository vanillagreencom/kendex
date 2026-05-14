## pi-agents-tmux — `subagent`, `steer_subagent`, `get_subagent_result`, `wait_for_subagent_idle`, `stop_subagent`

`subagent` delegates work to a project-defined agent (loaded from `.pi/agents`, with `.claude/agents` as a compatibility source). Agents with `pane: true` run in visible persistent tmux panes and survive across turns; others run as resumable bg agents. Child tools default to the parent's active tools minus the agent's `deny-tools:`.

Use when: isolated context for a focused task; specialist review (security, performance, design); reconnaissance/planning/read-only investigation that can run in parallel; multiple independent investigations via `tasks: [...]` (parallel) or `chain: [...]` (sequential, with `{previous}` placeholder).

Do not use for: trivial work the parent can do directly with read/grep/find; anything where you need streaming tool output to make decisions (results return as a final summary).

Calling rules:
- One self-contained `task` string per delegation — the subagent cannot ask follow-ups.
- Default `agentScope` is `"project"`. Pass `"both"` only when user-level agents at `~/.pi/agent/agents` are explicitly needed.
- Bg (`pane: false`) agents start in a fresh one-shot session when `sessionKey` is omitted. Pass a stable `sessionKey` only when you intentionally want to reuse memory across calls; reused lanes are preflight-guarded near context limit and default to refuse-and-warn.
- Parallel and chain bg items without `sessionKey` receive distinct one-shot lanes automatically, so same-agent tasks do not collide. Parallel calls larger than the internal batch size are auto-batched; do not split manually just for the old cap.
- Agent names are inventory-checked before launch for the selected `agentScope`. Missing names fail fast with available project/user agents; no similar-name redirect is attempted.
- Persistent-pane (`pane: true`) dispatches return immediately with a `taskId` for follow-up collection. **End your turn after dispatching.** The completion arrives as a follow-up message that wakes you in a new turn — do not call `get_subagent_result` with `wait: true` to block, unless the user asked.
- Save the `taskId`; use `get_subagent_result` only if you suspect a missed wake event. For pane-idle waits, use `wait_for_subagent_idle` (or `get_subagent_result` with `waitFor: "idle"`) instead of shell polling loops; it distinguishes `idle-after-busy` from `never-busy`.
- Dashboard, chat, Monitor, and `get_subagent_result` use persisted task summaries. If a summary is unavailable, inspect the transcript path shown with the task id instead of treating the original request as the result.
- If a bg subagent hits `context_length_exceeded`, the extension retries once in a fresh one-shot lane and returns both attempt summaries if the retry also fails.
- If a bg subagent returns `needs_completion` with `reason: "compact-then-empty"`, inspect `cwdSnapshot.head`, `cwdSnapshot.dirty`, and `cwdSnapshot.lastCommit.subject` before deciding whether the subagent's work completed.
- Stopping kills the tmux process but preserves the session file; the next default `subagent` call resumes it. Pass `forceSpawn: true` only when the user wants a fresh session.
- `confirmProjectAgents: true` gates project-defined agents behind explicit user approval.
