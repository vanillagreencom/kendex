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

Parallel dispatch runs through a flat worker pool capped by `maxConcurrency` (default 4); the whole task array shares one queue. The earlier `maxParallelTasks` setting is a deprecated no-op kept for setting-file compatibility.

Bg one-shot children complete through their final assistant output, which the runner captures from the JSON stream and publishes as the `subagents:completed` summary. They do not have a durable pane task outbox, so the runner filters `complete_subagent` out of inherited active tools, passes `--exclude-tools complete_subagent`, and falls back to `--no-tools` if that was the only inherited tool. Persistent pane and follow-up tasks remain the only paths that instruct children to call `complete_subagent`.

Child process environment is split by identity vs visible pane ownership. `PI_SUBAGENT_CHILD_AGENT` exists for both persistent pane children and bg one-shot children so statusline context and `delegate_subagent` authorization work everywhere. `PI_SUBAGENT_CHILD_PANE=1` is exported only by the persistent pane launcher; only that marker allows session-start code to set the tmux pane title or poll the pane inbox. The bg runner must delete inherited `PI_SUBAGENT_CHILD_PANE`, `PI_SUBAGENT_PARENT_SESSION_ID`, and `PI_BRIDGE_*` vars because bg children run inside the parent process tree and often inherit `TMUX_PANE` from the master pane.

## Restricted delegation (`delegate_subagent`) — issue #228

`delegate_subagent` is a single-mode wrapper around the same dispatch helpers `subagent` uses (`runSingleDispatch` → `runSingleAgent`). Differences from `subagent`:

```json
// Only shape accepted. `cwd` is the sole optional field.
{ "agent": "scout", "task": "Map the cwd-snapshot module.", "cwd": "/optional/working/dir" }
```

`cwd` defaults to the caller's cwd when omitted; when present it is threaded to `runSingleDispatch` as `cwdOverride`, identical to the single-mode path of full `subagent`.

- **Authorization.** `PI_SUBAGENT_CHILD_AGENT` must be set in the calling Pi process. Pane launchers and the bg one-shot runner both export it for issue #228. Do not use it as proof that the process owns a tmux pane; use `PI_SUBAGENT_CHILD_PANE=1` for visible pane-only behavior. Without the agent identity var the tool refuses immediately. The caller agent's discovered `AgentConfig.allowedSubagents` (parsed from `allowed-subagents:` frontmatter and aliases `allowedSubagents` / `subagent-agents` / `subagent_agents`) is the canonical allowlist. Unlisted targets, undiscovered targets, and pane targets are all rejected before launch.
- **No orchestration knobs.** No `tasks`, `chain`, `agentScope`, `sessionKey`, `forceSpawn`, `resumeSession`, or `confirmProjectAgents`. The schema literally does not expose them; the resolver defaults `agentScope` to `"project"` and `sessionKey`/`forceSpawn`/`resumeSession` to undefined.
- **Tool inheritance.** Child tools start from the parent active tools then drop the target agent's `deny-tools`. vstack-generated reviewer/analyst/manager agents already deny `delegate_subagent` so a chain like `rust → scout → researcher` is impossible by default — scout's `allowed-subagents` is empty, and `delegate_subagent` is in scout's `deny-tools`. Both layers fail closed.
- **Bg-only.** Pane targets reject with a clear error; engineer-style delegation is intentionally disposable.
- **System prompt.** When the only active subagent surface is `delegate_subagent`, `before_agent_start` emits a short "Restricted Subagent Delegation" section listing the caller's allowlist (with model / pane warning) instead of the full Project Agents list. When `subagent` is also active (parent orchestrator), the full list is emitted unchanged.

vstack CLI defaults: engineer-role agents emit `allowed-subagents: scout` and omit `delegate_subagent` from `deny-tools`. Analyst/reviewer/manager agents omit `allowed-subagents` and add `delegate_subagent` to `deny-tools` so the child LLM never sees it. An explicit `allowed-subagents = []` in `vstack.toml` overrides the engineer default and re-denies the tool.

## One-shot transcript capture

Bg one-shot agents run Pi in JSON stream mode and write a sidecar transcript under `transcripts/<agent>/<taskId>.jsonl`. The writer records `start`, `exit`, `message_start`, `message_end`, tool execution events, stderr, parse errors, and diagnostics. It drops successful `message_update` events by default because those events are full message-so-far snapshots and duplicate the final `message_end` content. If the process exits nonzero or emits a process error after an unfinalized update, the latest filtered update is flushed as a `buffered: true` diagnostic record. Set `PI_AGENTS_TMUX_TRANSCRIPT_FULL=1` in the parent environment before launching Pi to keep the full stream for debugging.

The writer also normalizes Pi event shapes used by current and older bridge streams (`{type:"event", event, data}`, `{event:{type}}`, and top-level `{type}`) before processing. `agent_start` transcript entries are enriched with the static agent name, selected model, and spawned Pi args (omitting the final task prompt arg) so transcript-only telemetry can attribute cost and model selection without reading the synthetic `start` row.

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

## Needs-completion cwd snapshots

All `needs_completion` records try to include a `cwdSnapshot` when the worker cwd is known. Pane-mode marks use the pane registry cwd; bg compact-then-empty detection uses the bg worker cwd. Snapshot fields are `head` (validated 40-hex), `dirty` (from a filter-safe index/lstat snapshot), and `lastCommit.subject`.
Pane `markTaskNeedsCompletion` persists and returns the `needs_completion` record before kicking off cwd snapshot patching, so best-effort git timeouts cannot delay caller notification of the original failure.
`cwdSnapshot` reads are bounded and read-only: each git call has a 5s timeout, uses `GIT_OPTIONAL_LOCKS=0`, `--no-optional-locks`, `-c core.fsmonitor=false`, `-c core.untrackedCache=false`, `-c log.showSignature=false`, and a minimal Git env so snapshotting does not invoke repository fsmonitor/signature/filter helpers or write to the worker repo. Dirty-state collection avoids `git status` and uses index-vs-HEAD metadata, index lstat metadata, deleted-file listing, and untracked-file listing instead; the index-debug read has a larger bounded buffer than other git probes so the tracked-file scan can apply its file cap before Node maxBuffer handling. Tracked-file lstat scanning has a file cap and sub-second deadline, rejects unsafe index paths before probing, checks the deadline before each parent/final lstat, skips paths under symlinked parent directories before probing final-path metadata, and appends an incomplete-scan diagnostic when truncated, malformed, blocked by unsafe paths, blocked by symlinked parents, blocked by deadline expiry, or blocked by lstat errors.

## Compact-then-empty needs-completion detector

For vstack#38, bg subagent runs detect `session_compact → agent_end{content:[]}` or content with no `type:"text"` parts on the post-compact bridge-stream slice only. This emits `subagents:needs_completion` with `reason: "compact-then-empty"`.
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

When `pi-session-bridge` has installed `globalThis[Symbol.for("vstack.pi.activity")]`, subagent lifecycle notifications publish best-effort `agent.*` broker events. Internal `subagents:created`, `queued`, `started`, `steered`, `needs_completion`, `completed`, and `failed` signals map to `agent.spawned`, `agent.task_queued`, `agent.task_started`, `agent.steered`, `agent.needs_completion`, `agent.empty_after_compact`, `agent.task_completed`, `agent.task_blocked`, `agent.task_failed`, and `agent.pane_cwd_stale`. Refs carry `task_id` and `agent`; details include session mode/key, pane id, transcript/completion paths, model/effort, reason/status, pane-cwd-stale cwd fields, and `cwdSnapshot` when present.

Broker publication is isolated in `extensions/subagent/activity.ts` and must stay fail-open: activity publisher errors do not affect task dispatch, completion, steering, or result retrieval.

## Browser keys

- `tab` / `shift+tab` switches between **Agents** and **Monitor**.
- `↑/↓`, `-/=`, `home/end` navigate. `←/→` switches tree/detail focus and cycles task-detail subtabs. `enter` expands/collapses Monitor Active/Completed/session rows or opens task detail.
- `enter` inserts `Use agent <name> to: ` into the editor.
- `alt+g` edits the selected agent's frontmatter.
- Pane agents: `alt+p`/`ctrl+p` start or reuse, `alt+o`/`ctrl+o` attach, `alt+x`/`ctrl+x` stop.
- `esc` closes.

Status legend per row: live pane, startable, stale, background. Dashboard rows: queued, working, completed, needs completion, failed/blocked.

## Pane registry mechanics

Pane registries and task records are stored in sidecar files and mirrored into session custom entries only when the snapshot changes AND the session file's on-disk leaf still matches the active in-memory leaf. This prevents duplicate / orphaned Pi processes from advancing an older branch and making `/resume` land before the latest visible turns.

### Bounded session-state snapshots (vstack#177)

`persistRuntimeSnapshot()` enforces two guards on the `vstack-subagents:runtime-state` JSONL entry:

1. **Fingerprint dedup.** A stable hash of `{ panes, tasks }` (excluding `updatedAt`) per Pi session id; identical successive snapshots short-circuit before touching the session file.
2. **Size cap.** Default 64 KiB (`BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES`). Oversized payloads are replaced by a tiny manifest (`version: 2, fullSnapshot: false, reason: "payload-too-large", byteSize, fingerprint, counts, updatedAt`). The full registry stays on disk in `taskRegistryPath` and `paneRegistryPath`; restore continues to read those sidecars first and ignores manifest entries via `isPersistedSubagentRuntimeState`. Without this guard, a long-lived session with ~200 completed tasks accumulated ~1 GB of `vstack-subagents:runtime-state` JSONL entries and crashed `/resume` with a V8 OOM.
