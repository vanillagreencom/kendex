# pi-claude-bridge

Works with OAuth subscription, no API key, no errors.

![Claude bridge demo response](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/bridge-demo.png)
![Pi Claude settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-claude-bridge/assets/settings-panel.png)

Run Claude Code as the `pi-claude` Pi provider while keeping Pi's tools and TUI.

Forked from [`elidickinson/pi-claude-bridge`](https://github.com/elidickinson/pi-claude-bridge). This fork removes the AskClaude tool and adds opt-in forwarding for Pi prompt context.

## Highlights

- `pi-claude/claude-fable-5`, Opus 5, Opus 4.8, Opus 4.7, Opus 4.6, Sonnet 5, Sonnet 4.6, and Haiku in `/model`. `/model opus` selects Opus 5; older Opus releases stay selectable by full ID.
- Pi tool calls run on Pi; Claude Code handles reasoning.
- Tool-use turns block until Pi-delivered tool results reach Claude Code, including persistent subagent panes.
- Session continuity across normal turns, `/compact`, tree navigation, abort recovery, and account-profile changes.
- Optional companion integration for usage-aware subscription account rotation without copying the bridge engine.
- Thinking-level forwarding with summarized Opus thinking display.
- Optional Claude effort overrides (`xhigh` → `max` for Opus 4.8).
- MCP isolation and Claude cloud-MCP suppression to keep tokens lean.
- Optional access to your Claude account's connectors — Gmail, Calendar, Drive, Slack, Jira, Confluence — read-only by default.
- Opt-in forwarding of `APPEND_SYSTEM.md` and recognized Pi prompt hooks.

## Install

Requires pi ≥ 0.81 (bridge 2.x registers through pi's native provider API, so pi shows the
Claude models only while a Claude account is actually connected). On older pi, install
`@vanillagreen/pi-claude-bridge@1.x` instead.

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

Open `/extensions:settings`; settings appear under the **Pi Claude** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only.

The bridge also reads `claude-bridge.json` (`~/.pi/agent/claude-bridge.json`, and `.pi/claude-bridge.json` in a trusted project). Settings the bridge takes from one of those files are shown with the file that supplies them, so the editor reports the value the bridge resolves rather than the default. Changing the setting in the editor writes Pi settings, which take precedence over `claude-bridge.json`.

### General

| Setting | What it does |
| --- | --- |
| Enable Pi Claude provider | Register `pi-claude/*` models. Reload required. |

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
| Fast mode | Enable Claude Code fast mode for bridge requests when the selected model and account support it. |
| Force Claude effort | Override Pi's thinking-level mapping for every Pi Claude request. `none` keeps Pi's selected level; `max` sends Claude Code `--effort max`. |
| Model effort overrides | JSON object mapping model IDs to Claude Code efforts, e.g. `{"claude-opus-4-8":"max"}`. Per-model entries beat the global force setting. |
| Claude executable path | Explicit `claude` binary path; empty auto-detects. |

Pi 0.80.6 and newer expose native `max` thinking. Fable 5, Opus 5, and Sonnet 5 bridge metadata forward both `xhigh` and `max`; the generic bridge fallback also maps `max` directly. **Force Claude effort** and **Model effort overrides** remain available when one bridge model needs a different fixed effort. For example, to force only Opus 4.8 to `max`:

```json
{"claude-opus-4-8":"max"}
```

Keys may be bare model IDs (`claude-opus-4-8`), `pi-claude/<id>`, or `*` for all bridge models. Values are `low`, `medium`, `high`, `xhigh`, or `max`.

### Connectors

Turn this on and the model can use whatever your Claude account already has connected — the same connectors you use in the Claude app, now inside Pi:

- **Gmail** — search mail, read threads and messages.
- **Google Calendar** — check calendars and events.
- **Google Drive** — find and read files.
- **Slack** — search and read channels, threads, canvases, and people.
- **Jira and Confluence** — search and read issues, pages, and spaces.
- Anything else on the account (Figma, org-specific connectors) works the same way — nothing to configure per connector.

Sessions are **read-only** by default: the model can look things up, but cannot send, post, or change anything unless you explicitly turn writes on below.

Connector tools run inside Claude Code rather than in Pi, so Pi shows the model's answer but no tool card for the lookup itself. (Before this was handled, Pi showed a card claiming `Tool … not found` for calls that had actually succeeded — so an answer built on real data looked invented.)

Each of those lookups is still recorded in the session file as a `claude-bridge-connector-call` entry — the tool name, whether it succeeded, and how many bytes came back, never the contents. So "did it really look that up?" has an answer even though nothing is drawn in the transcript.

That entry needs a pi session to be written into. A host that embeds the bridge **without** one — loading it through a bare resource loader, so `extensionApi` is undefined — gets no record at all, and nothing in the bridge can tell. Such a host can install its own destination:

```ts
import { setConnectorCallAuditSink } from "@vanillagreen/pi-claude-bridge";

setConnectorCallAuditSink((record) => myOwnAuditTrail(record));  // pass undefined to clear
```

The sink **adds** a destination; it never replaces the session entry. A session-backed host that installs one gets both, so turning it on can never cost you the record you already had. Same payload-free shape as the entry (`name`, `toolUseId`, `outcome`, and where known `byteSize` / `childSessionId` / `reason`), and the same never-fails-a-turn rule: a sink that throws is caught and dropped. It is process-global, like the bridge's other host handles, so a host running several conversations in one process must route by `childSessionId` itself.

Extension-manager settings use flat package-scoped keys:

```json
{
  "vstack": {
    "extensionManager": {
      "config": {
        "@vanillagreen/pi-claude-bridge": {
          "enableConnectors": true,
          "connectorWriteMode": "deny"
        }
      }
    }
  }
}
```

Legacy `claude-bridge.json` configuration nests these options under `provider` (prompt-context flags under `promptContext`); the flat keys above are accepted there too. Environment variables work with either format. Connectors remain off by default so Pi owns tool execution.

| Extension-manager key | Env var | Values | Default | What it does |
| --- | --- | --- | --- | --- |
| `enableConnectors` | `CLAUDE_BRIDGE_ENABLE_CONNECTORS` | `true`/`false` | off | Expose the account's connectors to the model (env OR config enables). |
| `connectorWriteMode` | `CLAUDE_BRIDGE_CONNECTOR_WRITE` | `deny`/`allow` | `deny` | When connectors are enabled, whether their WRITE tools are exposed. |

For both, the env var wins over config. `connectorWriteMode` only matters when connectors are enabled. Any value other than exactly `allow` is treated as `deny` (fail-closed).

> **User scope + env only.** These two keys are resolved from user-scope configuration (`<PI_CODING_AGENT_DIR>/settings.json`, `<PI_CODING_AGENT_DIR>/claude-bridge.json`) and the env vars — never from a project's checked-in `.pi/settings.json` or `.pi/claude-bridge.json`, even when the project is trusted for ordinary options. Connectors expose live account data (mail, calendar, files), so a repo you clone must not be able to switch them on or un-gate their writes just by being the cwd.

Beyond the read-only write gate, every connectors-mode child also runs under a fail-closed **tool allowlist**: a runtime PreToolUse hook permits only Pi's bridged custom tools (`mcp__custom-tools__*`), claude.ai connector tools (`mcp__claude_ai_*`, writes still subject to the write gate), and the tool-discovery built-ins — and denies anything else, including Claude Code built-ins that don't exist yet. Connector sessions ingest untrusted third-party content (mail bodies, tickets, documents); a denylist of today's built-ins would fail open on tomorrow's.

With `connectorWriteMode: "deny"` (the default), connector sessions are **read-only**: search/read/fetch/list tools stay available, while mutating tools are denied twice — the known write tools are removed from the model's tool list, and a runtime hook blocks any connector tool classified as a write at call time, regardless of permission mode. Classification is fail-closed across every connector on the account: a connector tool counts as a write unless its name begins with a known read verb, so not-yet-known write tools and future connectors are denied by the same rule.

Set `allow` only for a one-shot write-executor session that has already obtained explicit user approval — never for an interactive connector chat.

> **`allow` is per-process, not global.** A host's approved-write executor should set `CLAUDE_BRIDGE_CONNECTOR_WRITE=allow` in the **child env of a dedicated one-shot process** that runs the single approved write and exits. Do not set `connectorWriteMode: "allow"` in persistent `settings.json` (or `allow` process-globally) for a shared/long-lived sidecar — that would make every connector session in that process write-capable, defeating the approval gate.

Connectors mode also makes the child Claude Code resolve its filesystem settings (with them off, the child runs fully isolated). Only **user-scope** settings are loaded — connector state lives in the account's config dir, so that is all connectors need. Project/local scope (a checkout's `.claude/settings.json`) is deliberately excluded: settings files can set an `env` map and `apiKeyHelper`, so a hostile repo could otherwise redirect the child's API traffic (`ANTHROPIC_BASE_URL`, key overrides) just by being the cwd of a connector query. Setting `provider.settingSources` in bridge config still overrides this verbatim, but listing `"project"`/`"local"` there reopens that surface — only do it for checkouts you trust.

### Isolated mode (embedding hosts)

Host apps that embed the bridge and own every config dir explicitly can set `CLAUDE_BRIDGE_ISOLATED=1` in the bridge process env. Isolated mode disables every cwd/home discovery fallback so nothing outside the host-owned dirs is read:

- no `AGENTS.md` discovery, including cwd ancestors and the shared `<PI_CODING_AGENT_DIR>/AGENTS.md`;
- no extension-manager overlay from `<PI_CODING_AGENT_DIR>/settings.json`;
- no project `.pi/settings.json` / `.pi/claude-bridge.json` reads (even for trusted projects);
- no project `.pi/APPEND_SYSTEM.md`;
- no `$PATH` search for the `claude` executable — the host either pins `pathToClaudeCodeExecutable` or gets the Claude Agent SDK's bundled default.

Bridge settings come only from the authoritative `<PI_CODING_AGENT_DIR>/claude-bridge.json`; logs still resolve under `PI_CODING_AGENT_DIR`. Normal Pi CLI usage (flag unset) is unchanged.

### Fable 5 and Opus 5 caveat

The bridge registers `pi-claude/claude-fable-5`, `pi-claude/claude-opus-5`, `pi-claude/claude-sonnet-5`, and `pi-claude/claude-opus-4-8` even when Pi's Anthropic model registry has not shipped those entries yet. Fable 5 and Opus 5 both run classifiers that can decline a turn, so for each of them the bridge asks Claude Code to use Opus 4.8 as the availability fallback and preserves Claude Code's content-safety fallback events so Pi labels rerouted turns as Opus 4.8. Content-safety fallback still depends on Claude Code's own Fable 5 support; use Claude Code 2.1.170 or newer, and set `ANTHROPIC_DEFAULT_FABLE_MODEL` / `ANTHROPIC_DEFAULT_OPUS_MODEL` yourself when routing provider-specific model IDs through Bedrock, Vertex, or Foundry.

## Connector inventory

`/pi-claude:connectors` lists the Claude account's installed claude.ai connectors by asking the account, not the model, so the answer is complete by construction.

`listAccountConnectors()` is the programmatic form for host apps. Import it from the package's `./connector-inventory` entry point:

```ts
import { listAccountConnectors, resolveClaudeOAuth } from "@vanillagreen/pi-claude-bridge/connector-inventory";
```

The same functions are re-exported from the package root for consuming apps whose vendored `package.json` uses a closed exports map (`{".": "./bundle/index.js"}`), which blocks every subpath:

```ts
import { listAccountConnectors } from "@vanillagreen/pi-claude-bridge";
```

It returns a discriminated result: on success `{ ok: true, complete: true, connectors }`, and on any transport or protocol failure `{ ok: false, reason }`. An account with no connectors is a successful empty list; a failure is never reported as an empty inventory. Credentials resolve from `CLAUDE_CONFIG_DIR` before `$HOME`, so a host running one sidecar per Claude account reads the right account.

## Multiple subscription profiles

An optional companion extension can provide account profiles through the bridge's versioned account-router integration (`vstack.pi.claude-account-router.v1` on `globalThis`).

For each fresh Claude request, the bridge launches the Agent SDK subprocess with the selected profile's `CLAUDE_CONFIG_DIR`. Claude session files, connector inventory, and resume IDs remain account-scoped. When an account reports a rejected rate limit (or another classified pre-output failure), the bridge rebuilds the Claude session from Pi history under the next profile and retries the prompt.

Retries are deliberately limited to failures before visible output or any tool dispatch. Once text, thinking, a Pi tool call, or a child-executed connector call has begun, the bridge never replays that request on another account, preventing duplicate tool side effects. Post-output failures are still recorded so the next prompt can avoid the unhealthy account. Managed subscription subprocesses also drop inherited Anthropic API credentials and third-party provider flags so the selected Claude CLI profile remains the request's billing identity.

The companion owns profile metadata, utilization ranking, and cooldown persistence. The bridge remains the SDK/stream/session engine and can continue updating independently through the small versioned adapter.

## Account usage and rate limits

Extra Usage is owned by Claude's account settings. The bridge neither changes that setting nor blocks Claude Code's native account behavior — if the account has Extra Usage enabled on claude.ai, the child Claude Code uses it normally. If Claude rejects a request because the current allowance is exhausted, a managed account router treats it as a model-scoped limit and can try another account.

When Claude Code reports a rate-limit reset time, the bridge shows one clear `[rate-limit]` warning with timezone context and avoids repeating the same error line. If `pi-qol` is installed, it can use the reset time to resume later.

Allowed-warning rate-limit events are filtered before user notification. The bridge normalizes unambiguous numeric utilization (`0 < value < 1` as fractional, `1 < value <= 100` as percent), suppresses low or unit-ambiguous values such as exact `1`, and only shows a neutral warning at 80%+ instead of claiming an unverified `% used` value. Check Claude Code `/usage` for exact allowed-warning utilization.

If Claude Code accepts a turn but produces no visible output, the bridge returns a retryable assistant error with a backoff hint instead of leaving Pi stuck waiting. Tune the first-output timeout with `CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT` (bare numbers are seconds; suffixes `ms`, `s`, and `m` are accepted). Default: `90s`; set `0` to disable.

## Debugging

Set `CLAUDE_BRIDGE_DEBUG=1` to write bridge logs to `<agent dir>/claude-bridge.log` and per-query Claude Code CLI logs under `<agent dir>/cc-cli-logs/`, where `<agent dir>` is `PI_CODING_AGENT_DIR` when set, else `~/.pi/agent`. Override the exact files with `CLAUDE_BRIDGE_DEBUG_PATH` / `CLAUDE_BRIDGE_DIAG_PATH`.

Tool-result integrity problems are surfaced even when debug logging is off. Pi shows an error notification, writes a diagnostic file to `<agent dir>/claude-bridge-diag.log`, and appends a `claude-bridge-integrity` custom entry to the pi session transcript (compact metadata only — never tool output), so lost or mismatched tool output stays analyzable from the session file alone.

Startup failures include the resolved Claude executable and working directory, which makes missing binaries and wrong launch directories easier to fix.

Contributor-facing stream, tool-result, and startup diagnostics are documented in [`DEVELOPMENT.md`](./DEVELOPMENT.md).
