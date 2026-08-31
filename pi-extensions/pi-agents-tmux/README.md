# pi-agents-tmux

https://github.com/user-attachments/assets/36192e57-a6e4-47f9-b47c-dd26920906ae

Delegate work to specialized agents from a running Pi session. Agents run either as visible persistent tmux panes or resumable background (bg) sessions.

Internals, tool schemas, and lifecycle mechanics live in [`DEVELOPMENT.md`](./DEVELOPMENT.md).

## Highlights

- `subagent` tool delegates one task, parallel tasks, or sequential chains. Large parallel calls run through a flat worker pool capped at `maxConcurrency`; callers do not need to split requests.
- `delegate_subagent` is a restricted, single-mode variant child agents can call without gaining full orchestration controls. Engineer agents installed by kendex default to `allowed-subagents: scout` so they can dispatch read-only reconnaissance into a fresh bg lane.
- Agents with `pane: true` open a visible tmux pane that persists across turns. Other agents run in the background. Spawned Pi sessions use the agent name as the Pi session display name.
- `/agents` browser lists agents for the selected scope with static detail, Monitor task traces, and one-key launch. Monitor groups tasks by session (pane, bg lane, bg one-shot) under expandable Active and Completed sections, and task detail shows Summary, Completion, and Transcript tabs.
- Dashboard widget shows live state, turns, input/output/reasoning tokens, and cost for every spawned agent. Chat completion rows show actual results, never a repeat of the original request, and grouped completion notifications batch multiple agents finishing together.
- `taskId` retrieval, mid-run steering, and pane stop without losing memory. Stop kills the tmux process but preserves the session — next launch resumes it. Pane idle waits use `wait_for_subagent_idle`.
- Bg agents get fresh sessions per call by default; opt into shared memory with an explicit `sessionKey`. Bg one-shot agents have a configurable timeout so one stalled child does not block the rest of a parallel run.
- Inventory-aware launch guard rejects unknown agent names with the available list. Persistent panes can auto-resume after detected provider rate limits. When `pi-session-bridge` is loaded, other tools can subscribe to agent lifecycle updates without adding chat messages.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-agents-tmux):

```bash
pi install npm:@vanillagreen/pi-agents-tmux
```

Via [kendex](https://github.com/vanillagreencom/kendex):

```bash
cargo install --git https://github.com/vanillagreencom/kendex.git kendex
kendex add vanillagreencom/kendex --pi-extension pi-agents-tmux --harness pi -y
```

Restart Pi after installation. Persistent panes require running Pi inside tmux.

## Commands

| Command | Action |
| --- | --- |
| `/agents` | Open the agent browser for both project and user scopes. |
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

## Agent Sources

`agentScope` controls which directories are considered: `user` reads `~/.claude/agents` and `~/.pi/agent/agents`; `project` reads the nearest `<project>/.claude/agents` and the nearest `<project>/.pi/agents`; `both` reads user sources, then project sources. When Pi starts from a directory under `$HOME`, home-level harness directories such as `~/.claude/agents` are still user scope, not project scope. Duplicate names resolve in this order: user Claude, user Pi, project Claude, project Pi. Keyboard shortcuts inside the browser/dashboard popup are documented in the popup's own footer.

## Persistent pane agents

Agents with `pane: true` use a visible tmux pane. Fields go in the agent file's YAML frontmatter, delimited by `---`:

| Field | Required | Values |
| --- | --- | --- |
| `name` | yes | Unique agent name. |
| `description` | yes | Short description shown in `/agents` and completions. |
| `deny-tools` | no | Comma-separated Pi tools to deny. Future parent tools are inherited unless explicitly denied. |
| `allowed-subagents` | no | Comma-separated or array of agent names this agent may call via `delegate_subagent`. Engineer agents installed by kendex default to `scout`. Set `[]` to disable delegation. Aliases: `allowedSubagents`, `subagent-agents`, `subagent_agents`. |
| `model` | no | Pi model id; omit to inherit the parent session model. Shorthands: `sonnet`, `opus*`, `haiku`. Other ids pass through. |
| `pane` | no | `true` for a visible persistent pane; omit for bg. |
| `color` | no | Pane badge color: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`. Aliases: `orange`, `purple`/`violet`, `teal`. |

Everything after the frontmatter is the agent's system prompt. Pane tasks move through queued → running → completed | blocked | failed. If a saved pane no longer points at the right working directory, stop it and launch a fresh pane. Stop closes the tmux process but preserves the session so the next launch can resume memory.

## Restricted delegation (`delegate_subagent`)

kendex-installed engineer agents default to denying `subagent` so they cannot orchestrate fleets, but they still need to spend a fresh context window on reconnaissance work. `delegate_subagent` is the bridge: available only to child agent sessions launched by this extension, single-dispatch only, bg-only (targets with `pane: true` are rejected), and restricted to the targets listed in the caller agent's `allowed-subagents:` frontmatter — missing or unlisted targets fail with an inventory error.

kendex defaults `allowed-subagents` to `scout` for `engineer` agents and leaves it empty — delegation denied — for every other role and for an agent declaring none. Customize per agent in `kendex.toml`; an explicit empty list overrides the engineer default, and the matching agent file is regenerated without `allowed-subagents:` and gains `delegate_subagent` back in `deny-tools` so the child never sees the tool.

```toml
[agent-frontmatter.pi]
rust = { allowed-subagents = ["scout"] }
iced = { allowed-subagents = ["scout", "researcher"] }
generalist = { allowed-subagents = [] }   # disable delegation entirely
```

## Settings

Open `/extensions:settings`; settings appear under the **Agents (tmux)** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, kendex Pi extensions read user/global settings only. Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across kendex Pi extensions while leaving tool/model/user content unchanged.

| Group | Setting | What it does |
| --- | --- | --- |
| Execution | Enable agents | Master toggle for the subagent tools, dashboard, and pane helpers. |
| Execution | Max concurrency | Cap on concurrent one-shot/background agent executions in the parallel dispatch queue; persistent pane agents only occupy the queue until launch/enqueue. It is the one execution-concurrency knob: the legacy `maxParallelTasks` key is a no-op kept for settings-file compatibility and safe to delete. |
| Execution | Background task timeout | Deadline in milliseconds for bg one-shot agents. Set `0` to disable. |
| Execution | Subagent model source | Use the agent's `model:` or inherit the parent session model. kendex `opus` agents omit `model:` by default; cheaper agents such as `scout` may pin one. |
| Execution | Subagent thinking source | Use the model `:effort` suffix or inherit the parent thinking level. |
| Execution | Reused session budget threshold | Fraction of model context allowed before an explicit `sessionKey` lane is considered too full. |
| Execution | Reused session budget policy | `refuse-and-warn` (default) blocks near-limit reused lanes with a warning; `warn` logs and continues; `compact-then-resume` archives/truncates the lane before launch. |
| Execution | Reused session context limit tokens | Context limit used by the session-file-size heuristic. |
| Rendering | Show agent dashboard | Render the activity card above the editor. The first agent activity may show it each session; user-hidden state blocks automatic re-open until an explicit toggle/show. |
| Rendering | Quiet inline output with dashboard | Keep inline tool output to short crumbs; single bg launches skip the initial task preview. |
| Rendering | Dashboard max items | Maximum agent rows shown. |
| Rendering | Dashboard collapsed by default | Start collapsed. |
| Rendering | Animate spinners | Animate running-agent spinner frames; disable for a static gear icon to reduce terminal flickering. |
| Rendering | Legacy tree connector style | Fallback `unicode` or `ascii` tree connectors when Glyph style and pi-tool-renderer's global override are unset. Prefer Glyph style. |
| Rendering | Collapsed item count | Items shown in collapsed agent results. |
| Output | Truncate agent results | Apply Pi-sized inline caps to tool output so long subagent results stay artifact-first. |
| Output | Result max bytes | Base inline byte budget for returned agent output before truncation (default 32 KiB); parallel dispatch divides it across returned agents with a 1 KiB per-agent floor. |
| Output | Result max lines | Base inline line budget for returned agent output before truncation (default 1200); parallel dispatch divides it across returned agents with a 40-line per-agent floor. |
| Output | Preserve full agent output | Save oversized output and include a path to retrieve it (enabled by default). |
| Persistent panes | Completion poll interval | How often the parent checks persistent pane results. |
| Persistent panes | Child inbox poll interval | How often child panes check for new tasks. |
| Persistent panes | Force session bridge for panes | Load `pi-session-bridge` in pane launchers so steering keeps working. |
| Keyboard | Dashboard display shortcut | Cycles widget visibility and restores the last visible mode when toggled back in. |
| Keyboard | Agents popup shortcut | Opens the full `/agents` browser. |
