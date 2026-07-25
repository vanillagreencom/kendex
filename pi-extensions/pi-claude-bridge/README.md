# pi-claude-bridge

Works with OAuth subscription, no API key, no errors.

![Claude bridge demo response](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/bridge-demo.png)
![Claude Bridge settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/settings-panel.png)

Run Claude Code as a Pi provider. Adds `claude-bridge/*` models to `/model` while keeping Pi's tools and TUI.

Forked from [`elidickinson/pi-claude-bridge`](https://github.com/elidickinson/pi-claude-bridge). This fork removes the AskClaude tool and adds opt-in forwarding for Pi prompt context.

## Highlights

- `claude-bridge/claude-fable-5`, Opus 5, Opus 4.8, Opus 4.7, Opus 4.6, Sonnet 5, Sonnet 4.6, and Haiku in `/model`. `/model opus` selects Opus 5; older Opus releases stay selectable by full ID.
- Pi tool calls run on Pi; Claude Code handles reasoning.
- Tool-use turns block until Pi-delivered tool results reach Claude Code, including persistent subagent panes.
- Session continuity across normal turns, `/compact`, tree navigation, and abort recovery.
- Thinking-level forwarding with summarized Opus thinking display.
- Optional Claude effort overrides (`xhigh` → `max` for Opus 4.8).
- MCP isolation and Claude cloud-MCP suppression to keep tokens lean.
- Optional access to your Claude account's connectors — Gmail, Calendar, Drive, Slack, Jira, Confluence — read-only by default.
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

Pi 0.80.6 and newer expose native `max` thinking. Fable 5 bridge metadata forwards both `xhigh` and `max`; **Force Claude effort** and **Model effort overrides** remain available when one bridge model needs a different fixed effort. For example, to force only Opus 4.8 to `max`:

```json
{"claude-opus-4-8":"max"}
```

Keys may be bare model IDs (`claude-opus-4-8`), `claude-bridge/<id>`, or `*` for all bridge models. Values are `low`, `medium`, `high`, `xhigh`, or `max`.

### Connectors

Turn this on and the model can use whatever your Claude account already has connected — the same connectors you use in the Claude app, now inside Pi:

- **Gmail** — search mail, read threads and messages.
- **Google Calendar** — check calendars and events.
- **Google Drive** — find and read files.
- **Slack** — search and read channels, threads, canvases, and people.
- **Jira and Confluence** — search and read issues, pages, and spaces.
- Anything else on the account (Figma, org-specific connectors) works the same way — nothing to configure per connector.

Sessions are **read-only** by default: the model can look things up, but cannot send, post, or change anything unless you explicitly turn writes on below.

These are low-level `provider` options (set in `settings.json` under the extension-manager config, or via env). Off by default so Pi owns tool execution.

| Option (`provider.*`) | Env var | Values | Default | What it does |
| --- | --- | --- | --- | --- |
| `enableConnectors` | `CLAUDE_BRIDGE_ENABLE_CONNECTORS` | `true`/`false` | off | Expose the account's connectors to the model (env OR config enables). |
| `connectorWriteMode` | `CLAUDE_BRIDGE_CONNECTOR_WRITE` | `deny`/`allow` | `deny` | When connectors are enabled, whether their WRITE tools are exposed. |

For both, the env var wins over config. `connectorWriteMode` only matters when connectors are enabled. Any value other than exactly `allow` is treated as `deny` (fail-closed).

With `connectorWriteMode: "deny"` (the default), connector sessions are **read-only**: search/read/fetch/list tools stay available, but mutating tools (Gmail `create_draft`/labels, Calendar `create_event`/`update_event`/`delete_event`/`respond_to_event`, Drive `create_file`/`copy_file`) are denied. Enforcement is two-layered:

- **Model context:** the known write tools are passed as `disallowedTools` (exact tool ids), so the model does not see them. (Note: the CLI's MCP permission matcher only supports exact tool names or a whole-server `mcp__server__*` glob — partial tool-segment globs are inert — so exact ids are what actually removes today's writes.)
- **Runtime:** a `PreToolUse` hook blocks any connector tool classified as a write at call time, regardless of permission mode. Classification is **fail-closed** and covers the whole `mcp__claude_ai_<Server>__` space — a tool there is a write unless its name *begins* with a known read verb (`list`, `search`, `get`, `read`, `fetch`, …). The verb is matched as a word across naming styles, since connector servers differ: `search_threads` (Gmail), `slack_read_channel` (Slack, server-prefixed), `getJiraIssue` (Atlassian, camelCase) are all reads; a leading word that merely repeats the server name is skipped first. A name that opens with a read verb but also names a mutation (`getOrCreateChannel`) is a write, and so is a name that does not parse as `<server>__<tool>`. This covers both not-yet-known write tools (e.g. a future Gmail `send_message` or Drive `delete_file`) and connectors beyond the Google trio: claude.ai connectors attach account-wide, so a Slack/Atlassian/org-custom connector is visible in a connector session, and its writes are denied by the same rule.

Set `allow` only for a one-shot write-executor session that has already obtained explicit user approval — never for an interactive connector chat.

> **`allow` is per-process, not global.** Memsira's approved-write executor enables writes by setting `CLAUDE_BRIDGE_CONNECTOR_WRITE=allow` in the **child env of a dedicated one-shot process** that runs the single approved write and exits. Do not set `connectorWriteMode: "allow"` in persistent `settings.json` (or `allow` process-globally) for a shared/long-lived sidecar — that would make every connector session in that process write-capable, defeating the approval gate.

### Isolated mode (embedding hosts)

Host apps that embed the bridge and own every config dir explicitly can set `CLAUDE_BRIDGE_ISOLATED=1` in the bridge process env. Isolated mode disables every cwd/home discovery fallback so nothing outside the host-owned dirs is read:

- no `AGENTS.md` discovery, including cwd ancestors and the shared `<PI_CODING_AGENT_DIR>/AGENTS.md`;
- no extension-manager overlay from `<PI_CODING_AGENT_DIR>/settings.json`;
- no project `.pi/settings.json` / `.pi/claude-bridge.json` reads (even for trusted projects);
- no project `.pi/APPEND_SYSTEM.md`;
- no `$PATH` search for the `claude` executable — the host either pins `pathToClaudeCodeExecutable` or gets the Claude Agent SDK's bundled default.

Bridge settings come only from the authoritative `<PI_CODING_AGENT_DIR>/claude-bridge.json`; logs still resolve under `PI_CODING_AGENT_DIR`. Normal Pi CLI usage (flag unset) is unchanged.

### Fable 5 and Opus 5 caveat

The bridge registers `claude-bridge/claude-fable-5`, `claude-bridge/claude-opus-5`, `claude-bridge/claude-sonnet-5`, and `claude-bridge/claude-opus-4-8` even when Pi's Anthropic model registry has not shipped those entries yet. Fable 5 and Opus 5 both run classifiers that can decline a turn, so for each of them the bridge asks Claude Code to use Opus 4.8 as the availability fallback and preserves Claude Code's content-safety fallback events so Pi labels rerouted turns as Opus 4.8. Content-safety fallback still depends on Claude Code's own Fable 5 support; use Claude Code 2.1.170 or newer, and set `ANTHROPIC_DEFAULT_FABLE_MODEL` / `ANTHROPIC_DEFAULT_OPUS_MODEL` yourself when routing provider-specific model IDs through Bedrock, Vertex, or Foundry.

## Connector inventory

`/claude-bridge:connectors` lists the Claude account's installed claude.ai connectors by asking the account, not the model.

The older way to answer "does this account have Slack?" was a capability probe: a model turn that enumerated connectors via `ToolSearch`. A search returns what the search surfaced — a lower bound — and nothing in the result said so, so an account with Slack attached could produce an inventory without Slack and no failure signal (vstack#838). This command calls the account's connector list endpoint instead, so the answer is complete by construction.

`listAccountConnectors()` is the programmatic form for host apps. Import it from the package's `./connector-inventory` entry point:

```ts
import { listAccountConnectors, resolveClaudeOAuth } from "@vanillagreen/pi-claude-bridge/connector-inventory";
```

Consuming apps that regenerate their vendored `package.json` with a closed exports map (`{".": "./bundle/index.js"}`) cannot reach that subpath — Node rejects every unlisted subpath *and* deep path under such a map. The same functions are therefore re-exported from the package root, which is the path those manifests allow:

```ts
import { listAccountConnectors } from "@vanillagreen/pi-claude-bridge";
```

The dedicated entry point is a separate build output. It cannot come from `bundle/index.js`, which exports only pi's extension registration and is tree-shaken against what `index.ts` itself calls — `connectorServerNamespace` was dropped from it entirely for that reason. `tests/unit-connector-inventory-artifact.mjs` loads the built artifact rather than `src/` so a source change without a rebuild fails. It returns a discriminated result: on success `{ ok: true, complete: true, connectors }`, and on any transport or protocol failure `{ ok: false, reason }`. An account with no connectors is a successful empty list; a failure is never reported as an empty inventory. Credentials resolve from `CLAUDE_CONFIG_DIR` before `$HOME`, so a host running one sidecar per Claude account reads the right account.

## Extra usage and rate limits

Claude Code's `/extra-usage` local command works through the Claude Agent SDK. In Pi, use `/claude-bridge:extra` to run that flow from claude-bridge. Persist automatic launch on extra-usage errors with **Allow extra usage helper** in `/extensions:settings`.

When Claude Code reports a rate-limit reset time, the bridge shows one clear `[rate-limit]` warning with timezone context and avoids repeating the same error line. If `pi-qol` is installed, it can use the reset time to resume later.

Allowed-warning rate-limit events are filtered before user notification. The bridge normalizes unambiguous numeric utilization (`0 < value < 1` as fractional, `1 < value <= 100` as percent), suppresses low or unit-ambiguous values such as exact `1`, and only shows a neutral warning at 80%+ instead of claiming an unverified `% used` value. Check Claude Code `/usage` for exact allowed-warning utilization.

If Claude Code accepts a turn but produces no visible output, the bridge returns a retryable assistant error with a backoff hint instead of leaving Pi stuck waiting. Tune the first-output timeout with `CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT` (bare numbers are seconds; suffixes `ms`, `s`, and `m` are accepted). Default: `90s`; set `0` to disable.

## Debugging

Set `CLAUDE_BRIDGE_DEBUG=1` to write bridge logs to `<agent dir>/claude-bridge.log` and per-query Claude Code CLI logs under `<agent dir>/cc-cli-logs/`, where `<agent dir>` is `PI_CODING_AGENT_DIR` when set, else `~/.pi/agent`. Override the exact files with `CLAUDE_BRIDGE_DEBUG_PATH` / `CLAUDE_BRIDGE_DIAG_PATH`.

Tool-result integrity problems are surfaced even when debug logging is off. Pi shows an error notification and writes a diagnostic file to `<agent dir>/claude-bridge-diag.log` so lost or mismatched tool output is visible.

Startup failures include the resolved Claude executable and working directory, which makes missing binaries and wrong launch directories easier to fix.

Contributor-facing stream, tool-result, and startup diagnostics are documented in [`DEVELOPMENT.md`](./DEVELOPMENT.md).
