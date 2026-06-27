# pi-agents-tmux

https://github.com/user-attachments/assets/36192e57-a6e4-47f9-b47c-dd26920906ae

Delegate work to specialized agents from a running Pi session. Agents run either as visible persistent tmux panes or resumable background (bg) sessions.

## Highlights

- `subagent` tool delegates one task, parallel tasks, or sequential chains.
- `delegate_subagent` is a restricted, single-mode variant child agents can call without gaining full orchestration controls. Engineer agents installed by vstack default to `allowed-subagents: scout` so they can dispatch read-only reconnaissance into a fresh bg lane.
- Agents with `pane: true` open a visible tmux pane that persists across turns. Other agents run in the background. Spawned Pi sessions use the agent name as the Pi session display name.
- `/agents` browser lists agents for the selected scope with static detail, Monitor task traces, and one-key launch.
- Monitor groups tasks by session (pane, bg lane, bg one-shot) under expandable Active and Completed sections, with active sessions first and newest invocations first inside each section; repeated same-agent launches get session numbers and task numbers reset per session. Steering/follow-up delivery mode is shown in expanded rows and trace metadata.
- Chat completion rows show actual results, never a repeat of the original request.
- Task detail shows Summary and Completion tabs; Summary contains task metadata, artifacts, and task text, while Completion contains result summary, files changed, and validation.
- Bg one-shot transcripts keep enough history to inspect results without creating oversized session files.
- When a task needs manual completion, result views include useful repository context when available.
- Dashboard widget shows live state, turns, tokens, and cost for every spawned agent; working agents stay above attention/completed agents, newest invocations lead each bucket, and activity updates do not reshuffle rows. Once you hide it, lifecycle updates do not reopen it until you toggle it back in.
- Dashboard and Monitor refreshes recover gracefully if another Pi process is updating agent state.
- Grouped completion notifications batch multiple agents finishing together.
- When `pi-session-bridge` is loaded, other tools can subscribe to agent lifecycle updates without adding chat messages.
- `taskId` retrieval, mid-run steering, and pane stop without losing memory. When `pi-session-bridge` provides compact input events, trace views humanize `steer` vs `followUp` input records instead of showing raw JSON only.
- Stop kills the tmux process but preserves the session — next launch resumes it.
- Bg agents get fresh sessions per call by default; opt into shared memory with an explicit `sessionKey`.
- Bg one-shot agents have a configurable timeout so one stalled child does not block the rest of a parallel run.
- Inventory-aware launch guard rejects unknown agent names with the available list.
- Large parallel calls run through a flat worker pool capped at `maxConcurrency`; callers do not need to split requests. Pane idle waits use `wait_for_subagent_idle`.
- Persistent panes can auto-resume after detected provider rate limits.
- Idle pane checks are quiet by default and write diagnostics only when something needs attention.

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

`agentScope` controls which directories are considered:

| Scope | Directories |
| --- | --- |
| `user` | `~/.claude/agents`, `~/.pi/agent/agents` |
| `project` | Nearest `<project>/.claude/agents`, nearest `<project>/.pi/agents` |
| `both` | User sources, then project sources |

When Pi starts from a directory under `$HOME`, home-level harness directories such as `~/.claude/agents` are still user scope, not project scope. Duplicate names resolve in this order: user Claude, user Pi, project Claude, project Pi.

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
| `allowed-subagents` | no | Comma-separated or array of agent names this agent may call via `delegate_subagent`. Engineer agents installed by vstack default to `scout`. Set `[]` to disable delegation. Aliases: `allowedSubagents`, `subagent-agents`, `subagent_agents`. |
| `model` | no | Pi model id; shorthands: `sonnet`, `opus*`, `haiku`. Other ids pass through. |
| `pane` | no | `true` for a visible persistent pane; omit for bg. |
| `color` | no | Pane badge color: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`. Aliases: `orange`, `purple`/`violet`, `teal`. |

Everything after the frontmatter is the agent's system prompt.

Pane tasks move through queued → running → completed | blocked | failed. If a saved pane no longer points at the right working directory, stop it and launch a fresh pane. Stop closes the tmux process but preserves the session so the next launch can resume memory.

Persistent pane children own their tmux pane and set the pane title to `agent:<name>`. Background one-shot children keep the same agent identity for authorization but do not update the inherited parent pane title or poll pane inbox files.

See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for contributor-facing tool schemas and lifecycle internals.

## Restricted delegation (`delegate_subagent`)

vstack-installed engineer agents default to denying `subagent` so they cannot orchestrate fleets, but they still need to spend a fresh context window on reconnaissance work. `delegate_subagent` is the bridge:

- Only available to child agent sessions launched by this extension.
- Only the targets listed in the caller agent's `allowed-subagents:` frontmatter are accepted; missing or unlisted targets fail with an inventory error.
- Single-dispatch only — no `tasks`, `chain`, `agentScope`, `sessionKey`, `forceSpawn`, or `resumeSession` exposure.
- Targets with `pane: true` are rejected — restricted delegation is bg-only.
- The child receives its own append-system prompt, skills, and a fresh one-shot session; parent conversation is not shared.

vstack defaults for `allowed-subagents`:

| Role | Default |
| --- | --- |
| `engineer` | `scout` |
| `analyst` / `reviewer` / `manager` | empty (delegation denied) |

Customize per agent in `vstack.toml`:

```toml
[agent-frontmatter.pi]
rust = { allowed-subagents = ["scout"] }
iced = { allowed-subagents = ["scout", "researcher"] }
generalist = { allowed-subagents = [] }   # disable delegation entirely
```

An explicit empty list overrides the engineer default; the matching agent file is regenerated without `allowed-subagents:` and gains `delegate_subagent` back in `deny-tools` so the child never sees the tool.

## Settings

Open `/extensions:settings`; settings appear under the **Agents (tmux)** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only.

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

### Execution

There is one execution-concurrency knob — `maxConcurrency` — and it caps concurrent one-shot/background agent execution in the parallel dispatch queue. Persistent pane agents occupy the queue only until they are launched/enqueued; after that they are not long-running bg workers for this limit. Earlier versions exposed `maxParallelTasks` as an internal chunk size; that key is now a no-op kept only for settings-file compatibility and safe to delete.

| Setting | What it does |
| --- | --- |
| Enable agents | Master toggle for the subagent tools, dashboard, and pane helpers. |
| Max concurrency | Cap on concurrent one-shot/background agent executions in the parallel dispatch queue; persistent pane agents only occupy the queue until launch/enqueue. |
| Background task timeout | Deadline in milliseconds for bg one-shot agents. Set `0` to disable. |
| Subagent model source | Use the agent's `model:` or inherit the parent session model. |
| Subagent thinking source | Use the model `:effort` suffix or inherit the parent thinking level. |
| Reused session budget threshold | Fraction of model context allowed before an explicit `sessionKey` lane is considered too full. |
| Reused session budget policy | `refuse-and-warn` (default) blocks near-limit reused lanes with a warning; `warn` logs and continues; `compact-then-resume` archives/truncates the lane before launch. |
| Reused session context limit tokens | Context limit used by the session-file-size heuristic. |

### Rendering

| Setting | What it does |
| --- | --- |
| Show agent dashboard | Render the activity card above the editor. The first agent activity may show it each session; user-hidden state blocks automatic re-open until an explicit toggle/show. |
| Quiet inline output with dashboard | Keep inline tool output to short crumbs; single bg launches skip the initial task preview. |
| Dashboard max items | Maximum agent rows shown. |
| Dashboard collapsed by default | Start collapsed. |
| Animate spinners | Animate running-agent spinner frames; disable for a static gear icon to reduce terminal flickering. |
| Tree connector style | `unicode` or `ascii`. |
| Collapsed item count | Items shown in collapsed agent results. |

### Output

| Setting | What it does |
| --- | --- |
| Truncate agent results | Apply Pi-sized inline caps to tool output. |
| Result max bytes | Inline byte cap per agent result. |
| Result max lines | Inline line cap per agent result. |
| Preserve full agent output | Save oversized output and include a path to retrieve it. |

### Persistent panes

| Setting | What it does |
| --- | --- |
| Completion poll interval | How often the parent checks persistent pane results. |
| Child inbox poll interval | How often child panes check for new tasks. |
| Force session bridge for panes | Load `pi-session-bridge` in pane launchers so steering keeps working. |

### Keyboard

| Setting | What it does |
| --- | --- |
| Dashboard display shortcut | Cycles widget visibility and restores the last visible mode when toggled back in. |
| Agents popup shortcut | Opens the full `/agents` browser. |
