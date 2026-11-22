## pi-agents-tmux — `subagent`, `delegate_subagent`, `steer_subagent`, `get_subagent_result`, `wait_for_subagent_idle`, `stop_subagent`

`subagent` delegates work to an agent from the selected inventory. Project scope loads the nearest `<project>/.pi/agents` plus `<project>/.claude/agents`; user scope loads `~/.pi/agent/agents` plus `~/.claude/agents`. Agents with `pane: true` run in visible persistent tmux panes and survive across turns, or headless where no tmux server answers; others run as resumable bg agents. Child tools default to the parent's active tools minus the agent's `deny-tools:`.

`delegate_subagent` is the restricted variant that child agents can call without gaining full orchestration controls. It only runs in child Pi processes (those launched with `PI_SUBAGENT_CHILD_AGENT` set), only accepts a single `{ agent, task, cwd? }`, and only targets agents listed in the caller's `allowed-subagents:` frontmatter. Pane targets, parallel/chain modes, session reuse, and the `agentScope` knob are all rejected.

Use when:

- isolated context for a focused task;
- specialist review (security, performance, design);
- reconnaissance/planning/read-only investigation that can run in parallel;
- multiple independent investigations via `tasks: [...]` (parallel) or `chain: [...]` (sequential, with `{previous}` placeholder).

Do not use for:

- trivial work the parent can do directly with read/grep/find;
- anything where you need streaming tool output to make decisions (results return as a final summary).

Calling rules:

- One self-contained `task` string per delegation — the subagent cannot ask follow-ups.
- Bg (`pane: false`) agents start fresh when `sessionKey` is omitted.
  - A stable key reuses memory only while the context guard permits it.
  - Above the guard's threshold, the call starts a fresh agent of the same type with the new task and prior final result, and reports `reused as fresh (context N%)`.
  - Store its returned `sessionKey` for later reuse instead of the exhausted key.
  - Pass `sameSession: true` only when that exact background session is required; above the threshold it returns `refused` with the guard text and fresh-agent remedy.
- Bg children and pane children both carry `PI_SUBAGENT_CHILD_AGENT` for identity/authorization; only visible pane children carry `PI_SUBAGENT_CHILD_PANE=1` and may update tmux pane title or poll pane inboxes.
- Bg completions are captured from the child process's final assistant output. `complete_subagent` is reserved for persistent pane/follow-up tasks and is not exposed to bg children.
- Bg one-shot children have a process-level deadline (`bgTaskTimeoutMs`, default 2 hours); a pane agent run headless uses the same background deadline.
  - If a child times out, the result returns as failed with `reason: "unresponsive_timeout"` and timeout/termination diagnostics.
  - Inspect the transcript before retrying.
- Bg one-shot results are artifact-first when large: oversized full output is saved under the session runtime when `preserveFullOutput` is enabled (default).
  - Use transcript/full-output paths from the result when the inline summary is insufficient.
- Parallel and chain bg items without `sessionKey` receive distinct one-shot lanes automatically, so same-agent tasks do not collide.
- Persistent-pane (`pane: true`) dispatches return immediately with a `taskId` for follow-up collection, unless the result opens with `pane-fallback reason=no-tmux`.
  - **End your turn after dispatching** a pane task that returned only its `taskId`.
  - The completion arrives as a follow-up message that wakes you in a new turn — do not call `get_subagent_result` with `wait: true` to block, unless the user asked.
- Where no tmux server is reachable, a `pane: true` agent runs headless as a bg one-shot process, on a fresh session unless you pass `sessionKey`.
  - The call blocks and returns the result like a bg call, with no follow-up wake.
  - Its text opens with `pane-fallback reason=no-tmux` and a `Task ID:` line.
  - `stop_subagent` on that agent succeeds with nothing to kill.
  - Pass `paneOnly: true` to get the tmux refusal instead.
- Save the `taskId`.
  - Before reusing an idle agent, read `get_subagent_result` with `agent`, `sessionKey`, and the next dispatch's `cwd` and `agentScope` for a background lane, or `taskId` for a pane. The check uses the same target directory and selected model as dispatch.
  - Use `contextBudget.ok` and its own `estimate.threshold`; do not substitute the parent's context or cumulative usage.
  - The tool also recovers missed completions.
  - For pane-idle waits, use `wait_for_subagent_idle` (or `get_subagent_result` with `waitFor: "idle"`) instead of shell polling loops; it distinguishes `idle-after-busy` from `never-busy`.
- Dashboard, chat, Monitor, and `get_subagent_result` use persisted task summaries.
  - If a summary is unavailable, inspect the transcript path shown with the task id instead of treating the original request as the result.
  - Monitor/trace surfaces steer vs follow-up delivery when known.
  - A user-hidden dashboard stays hidden until the user toggles it back in.
- If dashboard or Monitor output temporarily lags during heavy pane activity:
  1. Treat it as transient registry contention; the agent task itself is not failed by a skipped refresh.
  2. Retry by task id.
- On a supported provider context overflow, a bg subagent retries once in a fresh one-shot lane unless `sameSession: true`. If the retry fails, the result includes both attempt summaries. With `sameSession: true`, the result keeps the original failure and the remedy: start a fresh agent without `sameSession`.
- If a subagent returns `needs_completion`, inspect `cwdSnapshot.head`, `cwdSnapshot.dirty`, and `cwdSnapshot.lastCommit.subject` when present before deciding whether the subagent's work completed.
- On Linux, before queuing work into a reused live pane, `subagent` verifies the pane process cwd is live and matches the requested task `cwd`.
  - If not, the tool returns a structured `pane-cwd-stale` error and publishes `agent.pane_cwd_stale`.
  - On `pane-cwd-stale`:
    1. Stop the pane with `stop_subagent`.
    2. Retry with `forceSpawn: true` for a fresh process.
- Stopping kills the tmux process but preserves the session file; the next default `subagent` call resumes it. For a context-exhausted idle pane:
  1. Save its final result.
  2. Stop it.
  3. Pass `forceSpawn: true` with the new task and that result to start fresh.
