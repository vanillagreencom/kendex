# @vanillagreen/pi-agents-tmux

Delegate work from a running Pi session to project or user agents. An agent runs either as a visible tmux pane that persists across turns or as a background Pi session with its own context window, and the parent session gets the result back as a summary, a dashboard row and a transcript.

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-agents-tmux"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-agents-tmux):

```bash
pi install npm:@vanillagreen/pi-agents-tmux
```

Restart Pi after installation. Persistent panes need Pi running inside tmux.

## What it does

- The `subagent` tool delegates one task, a parallel set of tasks, or a chain where each task can read the previous result through a `{previous}` placeholder. Parallel work runs through one worker pool capped by `maxConcurrency`.
- Agents come from `<project>/.pi/agents` and `<project>/.claude/agents`, or with `agentScope: "both"` also from `~/.pi/agent/agents` and `~/.claude/agents`. An unknown name is refused with the inventory.
- An agent with `pane: true` in its frontmatter runs in a visible tmux pane that survives across turns. Every other agent runs in the background in a fresh session per call, or in a named memory lane when the call passes a `sessionKey`.
- `get_subagent_result`, `wait_for_subagent_idle`, `steer_subagent` and `stop_subagent` retrieve a pane task by its `taskId`, wait for a pane to go idle, send a mid-run correction, and stop a pane while keeping its session for the next launch.
- `delegate_subagent` is the restricted form a child agent may call: one background task, only to a target its own `allowed-subagents:` frontmatter lists, so an engineer agent can send reconnaissance to a scout without gaining orchestration.
- The `/agents` command opens a browser with an Agents tab (profiles) and a Monitor tab (active and completed tasks grouped by session, with summary, completion and transcript detail). `/agents:start`, `/agents:new`, `/agents:resume`, `/agents:send`, `/agents:attach`, `/agents:stop`, `/agents:trace` and `/agents:toggle` act on one pane or one trace; `/agents status` and `/agents collect` report and collect pane work.
- A dashboard card above the editor shows every spawned agent's state, turns, tokens and cost; a hidden card stays hidden until you show it again.
- A background task that overflows the model context is retried once in a fresh lane; a pane that hits a provider rate limit is resumed after the reset; a background task past `bgTaskTimeoutMs` is stopped and reported failed.
- With `pi-session-bridge` loaded, lifecycle changes publish `agent.*` activity events other extensions can subscribe to without adding chat messages.

## How it works

Each delegation spawns a separate `pi` process for the agent, so the child has its own context window and inherits the parent's tools minus the agent's `deny-tools`. A background child runs in JSON stream mode and its final assistant message is the result. A pane child polls an inbox of task files and answers through an outbox the parent polls, so a pane dispatch returns at once with a `taskId` and the completion arrives as a follow-up message in a later turn. Registries, transcripts and pane sessions live under the Pi user directory's `kendex/sessions` runtime.

## Agent files

An agent is a markdown file whose YAML frontmatter holds `name` and `description`, and optionally `model` (a Pi model id, with `:effort` suffix), `deny-tools`, `pane`, `color` and `allowed-subagents`. Everything after the frontmatter is the agent's system prompt. When the same name exists in several sources, project Pi wins over project Claude over user Pi over user Claude.

kendex generates `allowed-subagents: scout` for engineer-role agents and denies `delegate_subagent` for every other role; override per agent under `[agent-frontmatter.pi]` in `kendex.toml`, where an explicit empty list turns delegation off.

## Customise

Open `/extensions:settings`; settings appear under the **Agents (tmux)** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle.
- `maxConcurrency`, `bgTaskTimeoutMs`, `subagentModelSource`, `subagentThinkingSource`: how background children run and which model and thinking level they take.
- `reusedSessionBudgetThreshold`, `reusedSessionBudgetPolicy`, `reusedSessionContextLimitTokens`: what happens when a `sessionKey` lane is near its context limit.
- `dashboard`, `quietInlineWhenDashboard`, `dashboardMaxItems`, `dashboardCollapsed`, `animateSpinners`, `collapsedItemCount`, `glyphStyle`, `treeStyle`: the dashboard card and inline rendering.
- `truncateResults`, `resultMaxBytes`, `resultMaxLines`, `preserveFullOutput`: how much agent output returns inline and whether the full output is kept as an artifact.
- `completionPollMs`, `childInboxPollMs`, `forceSessionBridgeForPanes`: pane polling and bridge loading.
- `dashboardShortcut`, `popupShortcut`: the keyboard shortcuts.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
