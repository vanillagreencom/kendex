# @vanillagreen/pi-agents-tmux

A Pi extension for assigning work to other agents. You can follow each agent in a tmux pane or let it run in the background.

## Install

- npm: `pi install npm:@vanillagreen/pi-agents-tmux`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-agents-tmux"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation. Persistent agent panes require tmux; where no tmux server answers, a pane agent runs in the background instead.

## Features

- Assign a task, parallel tasks or a sequence of tasks.
- Select agents from project or user agent files.
- Send corrections, read results and stop running agents.
- Follow status and transcripts in the agents dashboard.

## How it works

The parent Pi session selects an agent file and sends it a task. The extension starts a separate Pi process with that agent's instructions. Agents configured for panes appear in tmux; other agents run in the background. The child returns its result to the parent. The dashboard shows the task state and saved transcript.

## Memory and disk use

- Agent discovery keeps at most 8 working-directory and user-source combinations across Pi sessions in one process. It reuses parsed agent files until their metadata changes. File and directory checks run outside rendering every 250 ms. A listed-file change reloads only that file; a directory change rebuilds the inventory. After a check detects a change, the next tool-call preview uses the updated agents. Removing a cache entry stops its file checks.

- A one-shot result keeps its last 20 assistant messages, and the newest earlier one with text when those 20 carry only tool calls, so the final answer is kept. Each keeps only its text and tool-call parts. Tool-call arguments are cut to the tool-details bound: 8,192 characters per string, 50 array items, 80 object fields and a nesting depth of 4. The expanded view says how many earlier messages it does not show. The result also keeps the last 65,536 characters of the child's stderr.
- The transcript keeps every event except the per-token `message_update` events; `PI_AGENTS_TMUX_TRANSCRIPT_FULL=1` keeps those too. Each record holds its event once. When more than 8 MiB of transcript records wait to be written, the extension stops reading the child's stdout and stderr until the writer catches up.
- Transcripts live in `~/.pi/agent/kendex/sessions/<session>/pi-agents-tmux/transcripts/`, and full outputs too long for a tool result in `.../pi-agents-tmux/outputs/`. Each directory is deleted once the session's working directory is gone (a merged worktree), and any file in it older than 5 days is deleted. Pi applies both rules when a session starts. Pi applies them only to a directory that holds the ownership record this package writes from 3.2.0 on. A transcript directory an earlier version wrote gets that record when its session next starts; until then Pi deletes nothing in it.

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

An agent is a markdown file whose YAML frontmatter holds `name` and `description`, and optionally `model` (a Pi model id, with `:effort` suffix), `effort` (`minimal`, `low`, `medium`, `high`, `xhigh`, `max`; passed to the child as `--thinking` when the model carries no suffix; `off` passes nothing, so the child runs at Pi's default level), `deny-tools`, `pane`, `color` and `allowed-subagents`. Everything after the frontmatter is the agent's system prompt. When the same name exists in several sources, project Pi wins over project Claude over user Pi over user Claude.

kendex generates `allowed-subagents: scout` for engineer-role agents and denies `delegate_subagent` for every other role; override per agent under `[agent-frontmatter.pi]` in `kendex.toml`, where an explicit empty list turns delegation off.
