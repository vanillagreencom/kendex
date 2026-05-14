# pi-agents-tmux — development notes

Implementation surface for contributors and AI callers. End-user setup, commands, customization, and settings live in [`README.md`](./README.md).

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

The popup has two top-level tabs: **Agents** (unified project/user/active list, sorted by current status, Live/Chat/Inspector subtabs) and **History** (completed task traces, Summary/Completion/Task subtabs; transcript paths in Summary). Chat is scoped to the selected dashboard row, usually `@orch` ↔ the selected agent. Repeated launches of the same agent render as stable session rows (`agent`, `agent 2`, …); resumed pane work in the same transcript stays on one row.

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
