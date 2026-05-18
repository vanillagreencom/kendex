# pi-agents-tmux — development notes

Implementation surface for contributors and AI callers. End-user setup, commands, customization, and settings live in [`README.md`](./README.md).

## Nomenclature

Three layers, used consistently across tool output, mini dashboard widget, full `/agents` popup, and the persisted record:

- **Agent** — the static profile (name, model, kind, deny-tools, description). One per `.pi/agents/<name>.md` (or compatibility source). Reusable across many invocations.
- **Session** — the underlying Pi runtime carrying an agent. Has a `sessionId` and a session file (JSONL transcript) that survives across turns. Pane agents have ONE persistent session per pane; bg agents default to ONE-SHOT (fresh session per task) but can reuse a session via `sessionKey`.
- **Task** — a single `subagent` tool invocation. Has a `taskId`, the input prompt, status (`queued` → `working` → `completed | failed | needs_completion`), summary, transcript path, and usage. The unit of work the user observes.

Relationships:

- 1 agent → N sessions (over a project's lifetime). 1 session → M tasks. For pane agents `M >> 1`; for bg one-shot agents `M = 1` per session; for bg agents reusing a `sessionKey` lane `M >= 1`.
- A **prompt** is the input text of a task. A task is not just a prompt — it's the whole invocation record including lifecycle and result. The Monitor tab's `Task` subtab specifically shows the input prompt of a completed task.
- `taskId` is globally unique. `sessionId` is per-runtime. `agent.name` is the static identifier.

Session-mode fields on task records use normalized user-facing values:

- `sessionMode: "new"` — pane task that launched the first task on a fresh pane session.
- `sessionMode: "resumed"` — task continuing prior context: live/reopened pane, restored archived pane, or explicit bg `sessionKey` lane.
- `sessionMode: "fresh"` — independent bg one-shot with no user-supplied `sessionKey`.
- `sessionKey` is stored only for explicit bg memory lanes. Row chips render `lane:<key>` truncated to about 14 characters; Inspector Summary renders the full key.

Do not confuse normalized record `sessionMode` (`fresh|resumed|new`) with runtime-only pane `paneSessionMode` (`live|resumed|new`); `live` and `resumed` both normalize to `resumed`.

Where the UI surfaces each layer:

- **Mini dashboard widget** — one row per dispatched task (current state + usage rollup). Resumed pane work can share a row when transcript identity matches; task-centric detail surfaces expose individual `taskId`s.
- **`/agents` popup → Agents tab** — agent profiles only: static frontmatter/config, source path, and system prompt. No task children, task ids, transcripts, completion summaries, or latest-message surfaces. The Inspector is intentionally static; execution data lives on Monitor.
- **`/agents` popup → Monitor tab** — session-grouped tree of active + completed tasks. Session is the primary grouping: pane, bg-lane (`sessionKey`), or bg-one-shot. Repeated same-agent sessions get session numbers; task numbers reset inside each session. Selecting a session shows aggregate metadata/usage/status counts; selecting a task shows Summary, Completion, and Task detail.
- **Tool output rendering** — per-task status rows (`● Agent <name> <status> · bg|pane · ctrl+o to expand`) with a `Task: <prompt>` body line when echoing the prompt and a JSON/markdown-aware preview when showing the result.

When reading code, prefer the layer names above over ambiguous terms like "run" or "invocation". `PaneTaskRecord` is per-task; `PaneSession*` types refer to the session runtime; `discoveredAgent` / `agentConfig` refer to the static profile.

## Subagent tool surface

The `subagent` Pi tool accepts single, parallel, and chain forms.

```json
// Single
{ "agent": "rust", "task": "Inspect error handling and summarize findings." }

// Parallel
{ "tasks": [
  { "agent": "iced", "task": "Review the widget layout." },
  { "agent": "reviewer-test", "task": "Check test coverage gaps." }
] }

// Chain (with {previous} placeholder)
{ "chain": [
  { "agent": "scout", "task": "Map the relevant files." },
  { "agent": "planner", "task": "Turn this into a plan: {previous}" }
] }
```

Options:

- `agentScope`: `project` (default), `user`, or `both`.
- `cwd`: per-task working directory.
- `confirmProjectAgents`: prompt before running project agents.
- `sessionKey`: opt-in named memory lane (bg agents). Pane agents persist via their own session file and ignore `sessionKey`. Parallel and chain items that omit `sessionKey` automatically get distinct one-shot lanes. Reused lanes run a preflight context-budget heuristic — see Settings → Execution.

Unknown agent names fail with a structured error listing missing and available agents. No similar-name redirect is attempted.

Live pane reuse runs a Linux cwd preflight before returning an existing pane or writing a new inbox task. The parent resolves the pane process pid from tmux, reads `/proc/<pid>/cwd`, and refuses reuse with `stopReason: "pane-cwd-stale"` if the cwd is deleted, missing, or different from the requested task `cwd`. Queue failures emit `subagents:failed` with `reason: "pane-cwd-stale"`, cwd details, and no task record because no task was queued; callers should `stop_subagent` and retry with `forceSpawn: true`.

Calls above the internal batch size (default 8) are split transparently.

## Result retrieval and steering

```json
// Recovery fallback (pass wait: true to block the turn — use sparingly).
get_subagent_result { "taskId": "iced-..." }

// Idle wait without shell polling.
wait_for_subagent_idle { "agent": "iced", "timeoutMs": 30000 }
// or
get_subagent_result { "taskId": "iced-...", "waitFor": "idle" }

// Mid-run correction. Targets pi-session-bridge; falls back to queued steering note.
steer_subagent { "taskId": "iced-...", "message": "...", "deliverAs": "steer" }

// Kill the pane (preserves the session file; next launch resumes).
stop_subagent { "agent": "iced" }
```

`wait_for_subagent_idle` reports `idle-after-busy` only after observing the pane leave idle first; if it never becomes busy it returns `never-busy`.

## Compact-then-empty needs-completion detector

For vstack#38, bg subagent runs detect `session_compact → agent_end{content:[]}` or content with no `type:"text"` parts on the post-compact bridge-stream slice only. This emits `subagents:needs_completion` with `reason: "compact-then-empty"` and `cwdSnapshot` fields: `head` (validated 40-hex), `dirty` (from `git status --porcelain=v1`), and `lastCommit.subject`.
`cwdSnapshot` reads are bounded and read-only: each git call has a 5s timeout, uses `GIT_OPTIONAL_LOCKS=0` and `--no-optional-locks`, and must not write to the worker repo.
The detector is mutually exclusive with the `context_length_exceeded` throw-path retry from PR #35: retry logic handles thrown overflows first, and compact-then-empty only classifies attempts that did not trigger that retry path. Retry detection only trusts error envelopes/stderr; normal tool output or assistant text that mentions `context_length_exceeded` must not trigger a retry.

## Agent-end watchdog (vstack#66)

Fallback for the silent-abandonment case where a child agent's turn ends — pane goes idle, transcript settles — but no `complete_subagent` outbox JSON was written. The existing child `agent_end` handler only synthesizes a needs_completion outbox when the task was inbox-delivered (`childCurrentTaskFile` is set); bridge-delivered follow-ups left the parent waiting forever.

Implementation: `extensions/subagent/agent-end-watchdog.ts` exposes `createAgentEndWatchdog(deps)`. On `agent_end`, the child also scans the task registry for active (`queued`/`running`/`unknown`) records belonging to its agent and schedules a watchdog check per task. After `VSTACK_AGENT_END_WATCHDOG_GRACE_SEC` (default 10s) the watchdog confirms the outbox is still missing, the task record is still active, and the pane is `ctx.isIdle()` before writing a synthetic outbox via `O_EXCL` open at `completionPath(runtimeRoot, agent, taskId)` with `status: "needs_completion"`, `reason: "turn-ended-without-complete-subagent"`, and `synthetic: true`. Successful synthesis also calls `markTaskNeedsCompletion`, so the parent's existing wake/poll path picks the outbox up unchanged.

Race safety: the default writer uses `fs.open(path, "wx")` so a real `complete_subagent` that races the watchdog always wins. Successive `agent_end` events for the same task are deduped by an in-process `fired` set; pending grace timers are deduped by a `pending` map. Failures are warn-logged, never thrown. Disable entirely with `VSTACK_AGENT_END_WATCHDOG=0`.

## Dashboard widget internals

`alt+a` cycles the widget hidden → compact → expanded. `alt+shift+a` / `f3` opens the full `/agents` popup.

Each row shows agent name, kind (`pane`/`bg`), turn count, input/output tokens, cost, and (for working agents) a live tail of the latest tool/message truncated to card width.

Rows are bucketed for stability: queued/running/waiting agents stay above attention states; attention stays above completed. Within each bucket, rows preserve start-time order so token/usage updates do not reshuffle the list. The header always shows completed and working counts even when one side is zero. Missing pane artifacts render as `stale`; stale bg-only records are dropped (bg agents do not use pane handoff files).

The popup has two top-level tabs: **Agents** (scoped project/user agent profiles, static Inspector only) and **Monitor** (session-grouped execution tree). Monitor groups task records by pane session, explicit bg lane, or bg one-shot under expandable Active and Completed sections. Session rows show parent metadata (agent, session type/number/mode, model, effort, aggregate usage, session artifacts); task rows keep Summary/Completion detail: Summary holds task-local metadata, task artifacts, and task text; Completion holds returned result summary, files changed, validation, notes, and optional completion JSON. Repeated same-agent sessions show `session #N` in session detail, and task rows show `Task #N` within that session only. `#1` is always suppressed across mini widget, chat attribution, Monitor task rows, and trace Summary; numbers only appear from the second task per agent/session onward, so a lone task reads as plain `<agent>` / `Task <time>` instead of `<agent> #1` / `Task #1 · <time>`. Agents rows are flat and do not expose task children, transcripts, or task-scoped summaries; they may show a live-pane dot only as a pointer that execution state exists on Monitor.

Compaction events are not rendered in the Monitor popup. The transcript parser still recognizes the same `session_compact` bridge-stream shape used by the compact-then-empty detector (PR #46 / issue #38), plus compatibility variants like `{ event: "compact" }` and `message.customType: "session-compact"`, for callers that open raw trace views.

Popup browser internals are split by concern:

- `browser.ts` owns modal lifecycle, input dispatch, top-level tab layout, and re-exports the public surface used by tests and sibling modules.
- `browser/shared.ts` holds popup frame, key, modal-lock, tab strip, layout, and the cancel-input fallback.
- `browser/agents-tab.ts` builds agent rows and renders the static Inspector pane (including the system-prompt viewport).
- `browser/monitor-tree.ts` derives Monitor session groups, session/task tree rows, selection clamping, and the left tree renderer.
- `browser/monitor-session-detail.ts` renders the right-pane Detail when a session row is selected (aggregate metadata, usage, task list).
- `browser/monitor-task-detail.ts` renders the right-pane Detail when a task row is selected, plus the shared trace tab bar, line highlighter, and `traceViewerItems` builder.
- `browser/frontmatter-editor.ts` owns YAML/TOML parse + upsert for agent overrides, the modal editor flow, and the post-edit confirmation popup.
- `browser/dashboard-integration.ts` bridges task records into dashboard labels and synthesizes bg chat delegation/completion rows.
- `browser/trace-viewer.ts` owns the standalone trace popup invoked from `/agents` slash commands.
- `task-records.ts` provides neutral task numbering, session-key derivation, active/terminal status checks, usage roll-up, and a sync registry reader. Dashboard and Monitor share this without going through `browser.ts`.

`highlightInlinePreview` in `format.ts` is the shared inline JSON / status-token highlighter used by dashboard previews and tool output. After the round-2 fix it tokenizes in two passes: highlight JSON keys (`"name":`) first, replace each colored span with a placeholder sentinel before running the status-value passes (`approve` / `failed` / etc), and restore the key spans afterwards. This prevents malformed or truncated JSON from re-coloring inside an already-styled key span, which otherwise produced nested ANSI escapes and wrong-color output. Empty message content renders an `(empty)` placeholder rather than a blank row, and an empty leading user prompt does not consume the task-text fallback.

Completed task records store the durable result summary in `PaneTaskRecord.summary`. On restore, completed records with a transcript but no summary backfill from the last assistant text in the transcript. Dashboard rows, Monitor Summary, Chat completion rows, and `get_subagent_result` all read that same field; if no real summary exists they show `completion summary unavailable; see transcript` instead of echoing the original task prompt.

## Activity broker publication

When `pi-session-bridge` has installed `globalThis[Symbol.for("vstack.pi.activity")]`, subagent lifecycle notifications publish best-effort `agent.*` broker events. Internal `subagents:created`, `queued`, `started`, `steered`, `needs_completion`, `completed`, and `failed` signals map to `agent.spawned`, `agent.task_queued`, `agent.task_started`, `agent.steered`, `agent.needs_completion`, `agent.empty_after_compact`, `agent.task_completed`, `agent.task_blocked`, `agent.task_failed`, and `agent.pane_cwd_stale`. Refs carry `task_id` and `agent`; details include session mode/key, pane id, transcript/completion paths, model/effort, reason/status, pane-cwd-stale cwd fields, and the compact-then-empty `cwdSnapshot` when present.

Broker publication is isolated in `extensions/subagent/activity.ts` and must stay fail-open: activity publisher errors do not affect task dispatch, completion, steering, or result retrieval.

## Browser keys

- `tab` / `shift+tab` switches between **Agents** and **Monitor**.
- `↑/↓`, `-/=`, `home/end` navigate. `←/→` switches tree/detail focus and cycles task-detail subtabs. `enter` expands/collapses Monitor Active/Completed/session rows or opens task detail.
- `enter` inserts `Use agent <name> to: ` into the editor.
- `alt+m` edits the selected agent's frontmatter.
- Pane agents: `alt+p`/`ctrl+p` start or reuse, `alt+o`/`ctrl+o` attach, `alt+x`/`ctrl+x` stop.
- `esc` closes.

Status legend per row: live pane, startable, stale, background. Dashboard rows: queued, working, completed, needs completion, failed/blocked.

## Pane registry mechanics

Pane registries and task records are stored in sidecar files and mirrored into session custom entries only when the snapshot changes AND the session file's on-disk leaf still matches the active in-memory leaf. This prevents duplicate / orphaned Pi processes from advancing an older branch and making `/resume` land before the latest visible turns.
