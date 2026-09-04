# @vanillagreen/pi-claude-bridge

A Pi provider that runs Claude Code through the Claude Agent SDK. Pi keeps its tools and its TUI; Claude Code does the reasoning on your Claude subscription, with no API key. The `pi-claude/*` models appear in `/model` while a Claude account is connected.

![Claude bridge demo response](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-claude-bridge/assets/bridge-demo.png) ![Pi Claude settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-claude-bridge/assets/settings-panel.png)

Forked from [elidickinson/pi-claude-bridge](https://github.com/elidickinson/pi-claude-bridge).

## Install

Requires Pi 0.81 or newer and a Claude Code login (`claude` on `PATH`, or the executable path set below). Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-claude-bridge"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-claude-bridge):

```bash
pi install npm:@vanillagreen/pi-claude-bridge
```

Restart Pi after installation.

## What it does

- Registers Fable 5, Opus 5, Opus 4.8 and older Opus releases, Sonnet 5, Sonnet 4.6 and Haiku as `pi-claude/*` models; `/model opus` selects Opus 5 and older releases stay selectable by full id.
- Runs every Pi tool call on Pi, including persistent subagent panes, and blocks the Claude turn until the result is back.
- Keeps parallel conversations and subagents on independent request, abort and Claude-session state.
- Keeps the Claude session across turns, `/compact`, tree navigation, abort recovery and account changes.
- Forwards Pi's thinking level, with summarized thinking shown for Opus, and lets you pin a Claude effort per model.
- Isolates Claude Code from filesystem MCP servers and suppresses its cloud MCP servers so tokens stay lean.
- Optionally exposes your Claude account's connectors (Gmail, Calendar, Drive, Slack, Jira, Confluence and whatever else the account has), read-only unless you allow writes.
- Optionally forwards `APPEND_SYSTEM.md` and the prompt blocks other kendex Pi extensions add.
- Works with a companion account router that rotates subscription profiles on a rate limit, without duplicating tool side effects.
- Shows one `[rate-limit]` warning with the reset time and emits it for `pi-qol` to resume on, and turns a silent Claude turn into a retryable error instead of a hang.

Fable 5 and Opus 5 run classifiers that can decline a turn; the bridge asks Claude Code to fall back to Opus 4.8 for those and labels the rerouted turn. That needs Claude Code's own support for the model; when routing provider-specific ids through Bedrock, Vertex or Foundry set `ANTHROPIC_DEFAULT_FABLE_MODEL` and `ANTHROPIC_DEFAULT_OPUS_MODEL` yourself.

## How it works

Each Pi request spawns or resumes a Claude Code subprocess through the Agent SDK. Pi's tools are offered to that subprocess over an in-process MCP server, so a tool call the model makes comes back to Pi, runs there, and its result is fed to the subprocess before the turn ends. The Claude session id is stored in the Pi session, so a later turn resumes it, and a session that does not match Pi's history is rebuilt from that history. Connector tools run inside the subprocess against the account, so Pi shows the answer and a payload-free audit entry, never a tool card.

## Prompt context

By default the bridge appends the nearest context file walking up from the working directory (`AGENTS.override.md`, then `AGENTS.md`, then `AGENTS.MD` in each directory, falling back to the global Pi agent directory) plus Pi's skills block to Claude Code's preset prompt. `CLAUDE.md` is not forwarded, because Claude Code loads it itself. Forwarding anything else Pi adds to the prompt is off by default and switched on per item in the settings.

## Connectors

Connectors are off by default and enabled only from user scope: the `enableConnectors` and `connectorWriteMode` keys are read from `~/.pi/agent/settings.json`, `~/.pi/agent/claude-bridge.json` and the environment (`CLAUDE_BRIDGE_ENABLE_CONNECTORS`, `CLAUDE_BRIDGE_CONNECTOR_WRITE`), never from a project's checked-in `.pi/` files, so a cloned repository cannot switch on access to your mail or calendar. The environment wins over the files.

Sessions are read-only until `connectorWriteMode` is exactly `allow`; any other value denies every write tool on every connector. Set `allow` only in the environment of a dedicated one-shot process that runs a single approved write, never in persistent settings. `/pi-claude:connectors` lists the account's installed connectors by asking the account, so the answer is complete.

With connectors on, the Claude Code subprocess also loads its user-scope settings (`~/.claude`), and only those; a checkout's `.claude/settings.json` is never loaded. A `provider.settingSources` list in `claude-bridge.json` overrides that verbatim, and naming `project` or `local` there reopens the surface.

## Customise

Open `/extensions:settings`; settings appear under the **Pi Claude** tab, and `/pi-claude` opens the same tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. The bridge also reads `claude-bridge.json` in `~/.pi/agent` and in a trusted project's `.pi/`; a value taken from one of those files is shown with the file that supplies it, and editing it in the panel writes Pi settings, which win.

- `enabled`: register the `pi-claude/*` models; reload required.
- `appendSystemPrompt`: the context file and skills block described above.
- `includeAppendSystemPromptMd`, `includeProjectAgentsHook`, `includeTaskPanelHook`, `includeCavemanHook`: forward `APPEND_SYSTEM.md` and the prompt blocks of `pi-agents-tmux`, `pi-task-panel` and `pi-caveman`.
- `strictMcpConfig`, `fastMode`, `pathToClaudeCodeExecutable`: how the Claude Code subprocess is launched.
- `forceEffort`, `modelEffortOverrides`: pin a Claude effort for every request or per model. Override keys are bare ids (`claude-opus-4-8`), `pi-claude/<id>` or `*`; values are `low`, `medium`, `high`, `xhigh` or `max`; a per-model entry beats the global force.

Environment variables:

- `CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT`: how long a turn may stay silent before its first output; bare numbers are seconds, `ms`, `s` and `m` suffixes are accepted, `0` disables.
- `CLAUDE_BRIDGE_DEBUG=1`: write the bridge log, the integrity diagnostics and per-query Claude Code CLI logs under the Pi agent directory; `CLAUDE_BRIDGE_DEBUG_PATH` and `CLAUDE_BRIDGE_DIAG_PATH` move the two log files. Nothing is written to disk without it.
- `CLAUDE_BRIDGE_ISOLATED=1`: for embedding hosts that own every config directory; the bridge then reads nothing from the working directory or home. Details in [DEVELOPMENT.md](DEVELOPMENT.md).

Tool-result integrity problems always surface as a Pi error notification plus a metadata-only `claude-bridge-integrity` entry in the Pi session file, so a lost tool result can be analysed from the session alone.

Maintainer notes, the embedding and account-router contracts, and the test suites are in [DEVELOPMENT.md](DEVELOPMENT.md).
