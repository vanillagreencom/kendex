# pi-agents-tmux

https://github.com/user-attachments/assets/36192e57-a6e4-47f9-b47c-dd26920906ae

Delegate work to specialized agents from a running Pi session. Agents run either as visible persistent tmux panes or resumable background (bg) sessions.

## Highlights

- `subagent` tool delegates one task, parallel tasks, or sequential chains.
- Agents with `pane: true` open a visible tmux pane that persists across turns. Other agents run in the background.
- `/agents` browser lists project and user agents with search, live detail, chat, history, and one-key launch.
- Dashboard widget shows live state, model, turns, tokens, and cost for every spawned agent.
- Dashboard participates in vstack's stable mini-dashboard stack order: Flightdeck → Tasks → Agents → BG tasks.
- Grouped completion notifications batch multiple agents finishing together.
- `taskId` retrieval, mid-run steering, and pane stop without losing memory.
- Stop kills the tmux process but preserves the session — next launch resumes it.
- Bg agents use fresh one-shot lanes by default; explicit `sessionKey` opts into memory reuse with a context-budget guard.
- Large parallel calls are auto-batched internally, and pane idle waits are first-class via `wait_for_subagent_idle`.

## Closes parts of issue #27

This package implements the pi-agents-tmux portions of vanillagreencom/vstack#27:

- #1 — fresh one-shot bg subagent sessions by default.
- #2 — distinct ephemeral lanes for same-agent parallel and chain items.
- #3 — one retry on `context_length_exceeded` with structured attempt details.
- #6 — reused-session context-budget preflight guard.
- #10 — inventory-aware launch guard for single, parallel, and chain dispatch.
- #12 — first-class pane idle wait via `wait_for_subagent_idle` / `waitFor: "idle"`.
- #13 — transparent auto-batching above the internal parallel cap.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-agents-tmux):

```bash
pi install npm:@vanillagreen/pi-agents-tmux
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-agents-tmux --harness pi -y
```

Restart Pi after installation.

Persistent panes require running Pi inside tmux.

## Tool

Single task:

```json
{ "agent": "rust", "task": "Inspect error handling and summarize findings." }
```

Parallel:

```json
{ "tasks": [
  { "agent": "iced", "task": "Review the widget layout." },
  { "agent": "reviewer-test", "task": "Check test coverage gaps." }
] }
```

Chain (with `{previous}` placeholder):

```json
{ "chain": [
  { "agent": "scout", "task": "Map the relevant files." },
  { "agent": "planner", "task": "Turn this into a plan: {previous}" }
] }
```

Useful options: `agentScope` (`project` default, `user`, `both`), `cwd` per task, `confirmProjectAgents` to prompt before running project agents.

Persistent panes return a `taskId`. Keep it to retrieve or steer the task later.

Bg agents start in a fresh one-shot lane by default. Pass `sessionKey: "<stable-id>"` only when you want a named memory lane reused across calls. Pane agents persist via their own session file and ignore `sessionKey`.

Parallel and chain items that omit `sessionKey` automatically receive distinct one-shot lanes, including same-agent parallel tasks. Calls above the internal batch size (default 8) are split into batches transparently.

Explicit reused `sessionKey` lanes run a preflight context-budget heuristic before launch. Default policy refuses when estimated saved context exceeds 80% of the configured model limit; settings can raise/lower the threshold or warn instead.

Agent names are validated against project/user inventory for the selected `agentScope` before any launch. Unknown names fail with structured details listing missing and available agents; no similar-name redirect is attempted.

## Commands

| Command | Action |
| --- | --- |
| `/agents` | Open the agent browser. |
| `/agents project\|user\|both` | Open the browser with an explicit scope. |
| `/agents show <name> [scope]` | Inspect an agent. |
| `/agents:start <name>` | Start or resume a pane. |
| `/agents:new <name>` | Archive the saved session and start fresh. |
| `/agents:resume <name> [latest\|archive-file]` | Restore an archived pane session. |
| `/agents:send <name> <task>` | Queue a task for a persistent pane. |
| `/agents:attach <name>` | Focus an existing pane. |
| `/agents:stop <name>` | Stop a persistent pane. |
| `/agents status` | Show pane status. |
| `/agents collect` | Collect completed pane results. |
| `/agents:trace <ref>` | Open or show one trace by task id or short id. |
| `/agents:toggle` | Toggle the persistent dashboard. |

Arguments support autocomplete, including known agent names.

## Browser keys

- Type to search by name, description, source, path, model, denied tools, or pane status.
- `Tab` / `Shift+Tab` switches between **Agents** and **History**.
- `↑/↓`, `-/=`, `Home/End` navigate. `←/→` switches list/detail focus and cycles right-pane subtabs.
- `Enter` inserts `Use agent <name> to: ` into the editor.
- `Alt+M` edits the selected agent's frontmatter.
- For pane agents: `Alt+P`/`Ctrl+P` starts or reuses, `Alt+O`/`Ctrl+O` attaches, `Alt+X`/`Ctrl+X` stops.
- `Esc` clears search or closes.

Status legend: ` ` live pane, ` ` startable, ` ` stale, `·` background. Dashboard rows: ` ` queued, ` ` working, ` ` completed, ` ` needs completion, ` ` failed/blocked.

## Dashboard widget

Alt+A cycles the widget hidden → compact → expanded. Alt+Shift+A or F3 opens the full `/agents` popup.

Each row shows agent name, kind (`pane` or `bg`), turn count, input/output tokens, cost, and for working agents a one-line live activity tail from the transcript (latest tool/message), truncated to the card width.

Rows are bucketed for stability: queued/running/waiting agents stay above attention states, and all of those stay above completed agents. Within each bucket, rows keep start-time order so token/usage updates do not reshuffle the list. The header always shows completed and working counts, even when either count is zero. Missing pane artifacts render as `stale` attention rows; stale bg-only records are dropped because bg agents do not use pane handoff files.

The popup has two top-level tabs: **Agents** (unified project/user/active list, sorted by current status, with Live/Chat/Inspector subtabs on the right) and **History** (completed task traces with Summary/Completion/Task subtabs; transcript paths appear in Summary). Chat is scoped to the selected dashboard row, usually `@orch` ↔ the selected agent. Running agents use an animated spinner in both mini-dashboard and popup views. Repeated launches of the same agent render as stable session rows (`agent`, `agent 2`, ...); resumed pane work in the same transcript stays on one row.

When the dashboard is on, inline tool output stays quiet — pane calls render as launch breadcrumbs, bg calls show a result preview.

## Persistent pane agents

Agents with `pane: true` use a visible tmux pane:

```yaml
---
name: iced
description: Iced UI specialist
deny-tools: bash
model: openai-codex/gpt-5.5:xhigh
color: cyan
pane: true
---
```

Frontmatter fields:

| Field | Required | Values |
| --- | --- | --- |
| `name` | yes | Unique agent name. |
| `description` | yes | Short description shown in `/agents` and completions. |
| `deny-tools` | no | Comma-separated Pi tools to deny. Future parent tools are inherited unless explicitly denied. |
| `model` | no | Pi model id; shorthands: `sonnet`, `opus*`, `haiku`. Other ids pass through. |
| `pane` | no | `true` for a visible persistent pane; omit for bg. |
| `color` | no | Pane badge color: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`. Aliases: `orange`, `purple`/`violet`, `teal`. |

Everything after the frontmatter is the agent's system prompt.

Pane tasks move through `queued → running → completed | blocked | failed`. If a child ends a turn without a valid completion record, the task is marked `needs_completion` and the child shows a warning.

Pane registries and task records are stored in sidecar files and mirrored into session custom entries only when the snapshot changes and the session file's on-disk leaf still matches the active in-memory leaf. This keeps duplicate or orphaned Pi processes from advancing an older branch and making `/resume` land before the latest visible turns.

## Result retrieval and steering

Dispatch and end your turn — the extension wakes the parent on completion. Use `get_subagent_result` only as a fallback if you suspect a missed wake event. Pass `wait: true` to block the current turn (use sparingly).

```json
{ "taskId": "iced-..." }
```

Wait for a pane agent to become idle without shell polling:

```json
{ "agent": "iced", "timeoutMs": 30000 }
```

Use the `wait_for_subagent_idle` tool for this. It reports `idle-after-busy` only after observing the pane leave idle first; if the pane never becomes busy it returns `never-busy` instead of a false completion. `get_subagent_result` also accepts `waitFor: "idle"` for compatibility with existing result lookups.

Use `steer_subagent` for mid-run correction. It targets `pi-session-bridge` when available; otherwise it queues a steering note for the pane to read when idle.

```json
{ "taskId": "iced-...", "message": "Prioritize the failing layout test.", "deliverAs": "steer" }
```

Use `stop_subagent` to kill a persistent pane. The session file is preserved; the next launch resumes memory.

## Settings

All settings live in the extension manager under **Agents (tmux)**.

### Execution

| Setting | What it does |
| --- | --- |
| Enable agents | Master toggle for the subagent tools, dashboard, and pane helpers. |
| Max parallel tasks | Internal batch size for parallel calls; larger calls are auto-batched. |
| Max concurrency | Cap on bg agent processes running simultaneously. |
| Subagent model source | Use the agent's `model:` or inherit the parent session model. |
| Subagent thinking source | Use the model `:effort` suffix or inherit the parent thinking level. |
| Reused session budget threshold | Fraction of model context allowed before an explicit `sessionKey` lane is considered too full. |
| Reused session budget policy | `refuse-and-warn` (default) blocks near-limit reused lanes with a warning; `warn` logs and continues; `compact-then-resume` archives/truncates the lane before launch. |
| Reused session context limit tokens | Context limit used by the session-file-size heuristic. |

### Rendering

| Setting | What it does |
| --- | --- |
| Show agent dashboard | Render the activity card above the editor. |
| Quiet inline output with dashboard | Keep inline tool output to short crumbs. |
| Dashboard max items | Maximum agent rows shown. |
| Dashboard collapsed by default | Start collapsed. |
| Tree connector style | `unicode` or `ascii`. |
| Collapsed item count | Items shown in collapsed agent results. |

### Output

| Setting | What it does |
| --- | --- |
| Truncate agent results | Apply Pi-sized inline caps to tool output. |
| Result max bytes | Inline byte cap per agent result. |
| Result max lines | Inline line cap per agent result. |
| Preserve full agent output | Save oversized output to the session runtime and include the artifact path. |

### Persistent panes

| Setting | What it does |
| --- | --- |
| Completion poll interval | Parent poll rate for pane completion files. |
| Child inbox poll interval | Child pane poll rate for incoming tasks. |
| Force session bridge for panes | Load `pi-session-bridge` in pane launchers so steering keeps working. |

### Keyboard

| Setting | What it does |
| --- | --- |
| Dashboard display shortcut | Cycles widget visibility. Default `alt+a`. |
| Agents popup shortcut | Opens the full `/agents` browser. Default `alt+shift+a` (F3 also works). |
