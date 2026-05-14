# pi-agents-tmux — development notes

Implementation surface for contributors and AI callers. End-user setup, commands, customization, and settings live in [`README.md`](./README.md).

## Nomenclature

Three layers, used consistently across tool output, mini dashboard widget, full `/agents` popup, and the persisted record:

- **Agent** — the static profile (name, model, kind, deny-tools, description). One per `.pi/agents/<name>.md` (or compatibility source). Reusable across many invocations.
- **Session** — the underlying Pi runtime carrying an agent. Has a `sessionId` and a session file (JSONL transcript) that survives across turns. Pane agents have ONE persistent session per pane; bg agents default to ONE-SHOT (fresh session per task) but can reuse a session via `sessionKey`.
- **Task** — a single `subagent` tool invocation. Has a `taskId`, the input prompt, status (`queued` → `working` → `completed | failed | needs_completion`), summary, transcript path, and usage. The unit of work the user observes.

Relationships:

- 1 agent → N sessions (over a project's lifetime). 1 session → M tasks. For pane agents `M >> 1`; for bg one-shot agents `M = 1` per session; for bg agents reusing a `sessionKey` lane `M >= 1`.
- A **prompt** is the input text of a task. A task is not just a prompt — it's the whole invocation record including lifecycle and result. The History tab's `Task` subtab specifically shows the input prompt of a completed task.
- `taskId` is globally unique. `sessionId` is per-runtime. `agent.name` is the static identifier.

Session-mode fields on task records use normalized user-facing values:

- `sessionMode: "new"` — pane task that launched the first task on a fresh pane session.
- `sessionMode: "resumed"` — task continuing prior context: live/reopened pane, restored archived pane, or explicit bg `sessionKey` lane.
- `sessionMode: "fresh"` — independent bg one-shot with no user-supplied `sessionKey`.
- `sessionKey` is stored only for explicit bg memory lanes. Row chips render `lane:<key>` truncated to about 14 characters; Inspector Summary renders the full key.

Do not confuse normalized record `sessionMode` (`fresh|resumed|new`) with runtime-only pane `paneSessionMode` (`live|resumed|new`); `live` and `resumed` both normalize to `resumed`.

Where the UI surfaces each layer:

- **Mini dashboard widget** — one row per dispatched task (current state + usage rollup). Resumed pane work can share a row when transcript identity matches; task children expose individual `taskId`s.
- **`/agents` popup → Agents tab** — agent profiles + currently active tasks. Selecting an agent defaults to its latest task; expanding shows task children for multi-task agents (repeated bg launches or pane reuse).
- **`/agents` popup → History tab** — completed tasks only, latest first, labelled `agent #N · time · short taskId`. Detail subtabs are `Summary` (status/usage/paths), `Completion` (final response), and `Task` (the prompt that was submitted).
- **Tool output rendering** — per-task status rows (`● Agent <name> <status> · bg|pane · ctrl+o expand`) with a `Task: <prompt>` body line when echoing the prompt and a JSON/markdown-aware preview when showing the result.

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
The detector is mutually exclusive with the `context_length_exceeded` throw-path retry from PR #35: retry logic handles thrown overflows first, and compact-then-empty only classifies attempts that did not trigger that retry path.

## Dashboard widget internals

`Alt+A` cycles the widget hidden → compact → expanded. `Alt+Shift+A` / `F3` opens the full `/agents` popup.

Each row shows agent name, kind (`pane`/`bg`), turn count, input/output tokens, cost, and (for working agents) a live tail of the latest tool/message truncated to card width.

Rows are bucketed for stability: queued/running/waiting agents stay above attention states; attention stays above completed. Within each bucket, rows preserve start-time order so token/usage updates do not reshuffle the list. The header always shows completed and working counts even when one side is zero. Missing pane artifacts render as `stale`; stale bg-only records are dropped (bg agents do not use pane handoff files).

The popup has two top-level tabs: **Agents** (unified project/user/active list, sorted by current status, Live/Chat/Inspector subtabs) and **History** (completed task traces, Summary/Completion/Task subtabs; transcript paths in Summary). Agents rows include recent task children keyed by `taskId`; selecting an agent defaults to its latest task, while selecting a child pins Live/Chat to that task. Chat is scoped to the selected task row, or to all recent rows for the selected agent row. Repeated launches of the same bg agent render as task children; resumed pane work can share one transcript row while still exposing individual task ids.

Completed task records store the durable result summary in `PaneTaskRecord.summary`. On restore, completed records with a transcript but no summary backfill from the last assistant text in the transcript. Dashboard rows, History Summary, Chat completion rows, and `get_subagent_result` all read that same field; if no real summary exists they show `completion summary unavailable; see transcript` instead of echoing the original task prompt.

## Browser keys

- Type to search by name, description, source, path, model, denied tools, or pane status.
- `Tab` / `Shift+Tab` switches between **Agents** and **History**.
- `↑/↓`, `-/=`, `Home/End` navigate. `←/→` switches list/detail focus and cycles right-pane subtabs.
- `Enter` inserts `Use agent <name> to: ` into the editor.
- `Alt+M` edits the selected agent's frontmatter.
- Pane agents: `Alt+P`/`Ctrl+P` start or reuse, `Alt+O`/`Ctrl+O` attach, `Alt+X`/`Ctrl+X` stop.
- `Esc` clears search or closes.

Status legend per row: live pane, startable, stale, background. Dashboard rows: queued, working, completed, needs completion, failed/blocked.

## Pane registry mechanics

Pane registries and task records are stored in sidecar files and mirrored into session custom entries only when the snapshot changes AND the session file's on-disk leaf still matches the active in-memory leaf. This prevents duplicate / orphaned Pi processes from advancing an older branch and making `/resume` land before the latest visible turns.
