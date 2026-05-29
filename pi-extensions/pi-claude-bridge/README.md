# pi-claude-bridge

![Claude bridge demo response](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/bridge-demo.png)
![Claude Bridge settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/settings-panel.png)

Run Claude Code as a Pi provider. Adds `claude-bridge/*` models to `/model` and routes Pi turns through the Claude Agent SDK while keeping Pi's tools and TUI.

Forked from [`elidickinson/pi-claude-bridge`](https://github.com/elidickinson/pi-claude-bridge). The provider, MCP bridge, session sync, and SDK plumbing come from upstream; this fork removes the AskClaude tool and adds opt-in forwarding for Pi prompt context.

## Highlights

- `claude-bridge/claude-opus-4-8`, Opus 4-7, Sonnet, and Haiku in `/model`.
- Pi tool calls run on Pi; Claude Code handles reasoning.
- Session continuity across normal turns, `/compact`, tree navigation, and abort recovery.
- Thinking-level forwarding with summarized Opus thinking display.
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
| Claude executable path | Explicit `claude` binary path; empty auto-detects. |

## Extra usage and rate limits

Claude Code's `/extra-usage` local command works through the Claude Agent SDK. In Pi, use `/claude-bridge:extra` to run that flow from claude-bridge. Persist automatic launch on extra-usage errors with **Allow extra usage helper** in `/extensions:settings`.

When Claude Code emits rate-limit reset metadata, the bridge shows one red ASCII `[rate-limit]` Pi warning with the reset timestamp including timezone context, deduplicates repeated Claude Code error lines, and suppresses the SDK's follow-up `Claude Code returned an error result: ...` wrapper when the bridge already emitted the terminal error. The bridge also emits `vstack:rate-limit` on Pi's extension event bus so `pi-qol` can opt into reset-time auto-resume.

## Debugging

Set `CLAUDE_BRIDGE_DEBUG=1` to write bridge logs to `~/.pi/agent/claude-bridge.log` and per-query Claude Code CLI logs under `~/.pi/agent/cc-cli-logs/`.

Before starting Claude Code, the bridge preflights the resolved executable and working directory. Failures include the underlying `code`, `errno`, `syscall`, `path`, `cwd`, and detected executable file type so spawn issues point at the real failing path instead of the Claude Agent SDK's generic native-binary message. If Node still emits a spawn error after preflight, the bridge wraps that error with the same context before handing it back to the SDK.
