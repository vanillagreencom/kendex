# @vanillagreen/pi-agents-tmux

A Pi extension for assigning work to other agents. You can follow each agent in a tmux pane or let it run in the background.

## Install

- npm: `pi install npm:@vanillagreen/pi-agents-tmux`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-agents-tmux"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation. Persistent agent panes require tmux.

## Features

- Assign a task, parallel tasks or a sequence of tasks.
- Select agents from project or user agent files.
- Send corrections, read results and stop running agents.
- Follow status and transcripts in the agents dashboard.

## How it works

The parent Pi session selects an agent file and sends it a task. The extension starts a separate Pi process with that agent's instructions. Agents configured for panes appear in tmux; other agents run in the background. The child returns its result to the parent. The dashboard shows the task state and saved transcript.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-agents-tmux"]`.

Open `/extensions:settings`; settings appear under the **Agents (tmux)** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle.
- `maxConcurrency`, `bgTaskTimeoutMs`, `subagentModelSource`, `subagentThinkingSource`: how background children run and which model and thinking level they take.
- `reusedSessionBudgetThreshold`, `reusedSessionBudgetPolicy`, `reusedSessionContextLimitTokens`: what happens when a `sessionKey` lane is near its context limit.
- `dashboard`, `quietInlineWhenDashboard`, `dashboardMaxItems`, `dashboardCollapsed`, `animateSpinners`, `collapsedItemCount`, `glyphStyle`, `treeStyle`: the dashboard card and inline rendering.
- `truncateResults`, `resultMaxBytes`, `resultMaxLines`, `preserveFullOutput`: how much agent output returns inline and whether the full output is kept as an artifact.
- `completionPollMs`, `childInboxPollMs`, `forceSessionBridgeForPanes`: pane polling and bridge loading.
- `dashboardShortcut`, `popupShortcut`: the keyboard shortcuts.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).

## Agent files

An agent is a markdown file whose YAML frontmatter holds `name` and `description`, and optionally `model` (a Pi model id, with `:effort` suffix), `deny-tools`, `pane`, `color` and `allowed-subagents`. Everything after the frontmatter is the agent's system prompt. When the same name exists in several sources, project Pi wins over project Claude over user Pi over user Claude.

kendex generates `allowed-subagents: scout` for engineer-role agents and denies `delegate_subagent` for every other role; override per agent under `[agent-frontmatter.pi]` in `kendex.toml`, where an explicit empty list turns delegation off.
