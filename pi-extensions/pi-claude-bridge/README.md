# pi-claude-bridge

![Claude bridge demo response](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/bridge-demo.png)
![Claude Bridge settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/settings-panel.png)

Run Claude Code as a Pi provider. Adds `claude-bridge/*` models to `/model` while keeping Pi's tools and TUI.

Forked from [`elidickinson/pi-claude-bridge`](https://github.com/elidickinson/pi-claude-bridge). This fork removes the AskClaude tool and adds opt-in forwarding for Pi prompt context.

## Highlights

- `claude-bridge/claude-fable-5`, Opus 4.8, Opus 4.7, Sonnet, and Haiku in `/model`.
- Pi tool calls run on Pi; Claude Code handles reasoning.
- Tool-use turns block until Pi-delivered tool results reach Claude Code, including persistent subagent panes.
- Session continuity across normal turns, `/compact`, tree navigation, and abort recovery.
- Thinking-level forwarding with summarized Opus thinking display.
- Optional Claude effort overrides (`xhigh` → `max` for Opus 4.8).
- MCP isolation and Claude cloud-MCP suppression to keep tokens lean.
- Opt-in forwarding of `APPEND_SYSTEM.md` and recognized Pi prompt hooks.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-claude-bridge):

```bash
pi install npm:@vanillagreen/pi-claude-bridge
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-claude-bridge --harness pi -y
```

Restart Pi after installation.

## Prompt context

Default behavior matches upstream: append `AGENTS.md` plus Pi's skills block to Claude Code's `claude_code` preset prompt.

Extra Pi context is off by default. Enable per item in the extension manager when you want Claude Code to see prompt blocks that other Pi extensions add to your session. Forwarded blocks are wrapped in explicit XML tags so Pi 0.75+ project-context boundaries do not bleed into adjacent sections.

## Settings

Open `/extensions:settings`; settings appear under the **Claude Bridge** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only.

### General

| Setting | What it does |
| --- | --- |
| Enable Claude bridge provider | Register `claude-bridge/*` models. Reload required. |

### Base prompt

| Setting | What it does |
| --- | --- |
| Forward AGENTS.md + skills | Append AGENTS.md and Pi's skills block. |

### Pi prompt context

| Setting | What it does |
| --- | --- |
| Forward APPEND_SYSTEM.md | Forward project/global `APPEND_SYSTEM.md` content. |

### Pi prompt hooks

| Setting | What it does |
| --- | --- |
| Forward project agents hook | Forward `pi-agents-tmux` Project Agents/Subagents list. |
| Forward task panel hook | Forward `pi-task-panel` workflow reminders. |
| Forward caveman hook | Forward `pi-caveman` response-style directives. |

### Claude Code

| Setting | What it does |
| --- | --- |
| Strict MCP config | Block filesystem MCP auto-loads; Pi owns tools. |
| Allow extra usage helper | Let the bridge launch Claude Code's `/extra-usage` flow when extra usage is required. Billing/admin approval still happens in Claude's browser page. |
| Fast mode | Enable Claude Code fast mode for bridge requests when the selected model supports it. |
| Force Claude effort | Override Pi's thinking-level mapping for every claude-bridge request. `none` keeps Pi's selected level; `max` sends Claude Code `--effort max`. |
| Model effort overrides | JSON object mapping model IDs to Claude Code efforts, e.g. `{"claude-opus-4-8":"max"}`. Per-model entries beat the global force setting. |
| Claude executable path | Explicit `claude` binary path; empty auto-detects. |

Pi does not have a native `max` thinking level; it exposes up to `xhigh`, and each provider's model metadata maps Pi levels to provider values. To use Claude Code `max` effort only for Opus 4.8 through the bridge, set **Model effort overrides** to:

```json
{"claude-opus-4-8":"max"}
```

Keys may be bare model IDs (`claude-opus-4-8`), `claude-bridge/<id>`, or `*` for all bridge models. Values are `low`, `medium`, `high`, `xhigh`, or `max`.

### Fable 5 caveat

The bridge registers `claude-bridge/claude-fable-5` and `claude-bridge/claude-opus-4-8` even when Pi's Anthropic model registry has not shipped those entries yet. For Fable 5, the bridge asks Claude Code to use Opus 4.8 as the availability fallback and preserves Claude Code's content-safety fallback events so Pi labels rerouted turns as Opus 4.8. Content-safety fallback still depends on Claude Code's own Fable 5 support; use Claude Code 2.1.170 or newer, and set `ANTHROPIC_DEFAULT_FABLE_MODEL` / `ANTHROPIC_DEFAULT_OPUS_MODEL` yourself when routing provider-specific model IDs through Bedrock, Vertex, or Foundry.

## Extra usage and rate limits

Claude Code's `/extra-usage` local command works through the Claude Agent SDK. In Pi, use `/claude-bridge:extra` to run that flow from claude-bridge. Persist automatic launch on extra-usage errors with **Allow extra usage helper** in `/extensions:settings`.

When Claude Code reports a rate-limit reset time, the bridge shows one clear `[rate-limit]` warning with timezone context and avoids repeating the same error line. If `pi-qol` is installed, it can use the reset time to resume later.

Allowed-warning rate-limit events are filtered before user notification. The bridge normalizes unambiguous numeric utilization (`0 < value < 1` as fractional, `1 < value <= 100` as percent), suppresses low or unit-ambiguous values such as exact `1`, and only shows a neutral warning at 80%+ instead of claiming an unverified `% used` value. Check Claude Code `/usage` for exact allowed-warning utilization.

If Claude Code accepts a turn but produces no visible output, the bridge returns a retryable assistant error with a backoff hint instead of leaving Pi stuck waiting. Tune the first-output timeout with `CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT` (bare numbers are seconds; suffixes `ms`, `s`, and `m` are accepted). Default: `90s`; set `0` to disable.

## Debugging

Set `CLAUDE_BRIDGE_DEBUG=1` to write bridge logs to `~/.pi/agent/claude-bridge.log` and per-query Claude Code CLI logs under `~/.pi/agent/cc-cli-logs/`.

Tool-result integrity problems are surfaced even when debug logging is off. Pi shows an error notification and writes a diagnostic file to `~/.pi/agent/claude-bridge-diag.log` so lost or mismatched tool output is visible.

Startup failures include the resolved Claude executable and working directory, which makes missing binaries and wrong launch directories easier to fix.

Contributor-facing stream, tool-result, and startup diagnostics are documented in [`DEVELOPMENT.md`](./DEVELOPMENT.md).
