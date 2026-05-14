# pi-agents-tmux

https://github.com/user-attachments/assets/36192e57-a6e4-47f9-b47c-dd26920906ae

Delegate work to specialized agents from a running Pi session. Agents run either as visible persistent tmux panes or resumable background (bg) sessions.

## Highlights

- `subagent` tool delegates one task, parallel tasks, or sequential chains.
- Agents with `pane: true` open a visible tmux pane that persists across turns. Other agents run in the background.
- `/agents` browser lists project and user agents with search, static detail, Monitor task traces, and one-key launch.
- Monitor groups tasks by session (pane, bg lane, bg one-shot) with active/completed/all filters.
- Chat completion rows show actual results, never a repeat of the original request.
- Task detail shows compact Transcript rows plus Summary, Completion, and Task sections.
- Dashboard widget shows live state, model, turns, tokens, and cost for every spawned agent.
- Dashboard participates in vstack's stable mini-dashboard stack order: Flightdeck → Tasks → Agents → BG tasks.
- Grouped completion notifications batch multiple agents finishing together.
- `taskId` retrieval, mid-run steering, and pane stop without losing memory.
- Stop kills the tmux process but preserves the session — next launch resumes it.
- Bg agents get fresh sessions per call by default; opt into shared memory with an explicit `sessionKey`.
- Inventory-aware launch guard rejects unknown agent names with the available list.
- Large parallel calls are auto-batched. Pane idle waits use `wait_for_subagent_idle`.

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

Keyboard shortcuts inside the browser/dashboard popup are documented in the popup's own footer.

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

Pane tasks move through queued → running → completed | blocked | failed. Stop kills the tmux process; the session file is preserved so the next launch resumes memory.

See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for the underlying tool surface (`subagent`, `get_subagent_result`, `steer_subagent`, `stop_subagent`, `wait_for_subagent_idle`).

## Settings

Open `/extensions:settings`; settings appear under the **Agents (tmux)** tab.

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
