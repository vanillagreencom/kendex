# Pi package update audit: 0.99.0 to 0.99.1

Marker `0.87.1` → `0.99.1`. Audited against base `3969e96b`. Sources fetched: every `*/CHANGELOG.md` in the Pi tree at the target's source commit (`agent`, `ai`, `client`, `codemode`, `coding-agent`, `durable`, `mcp`, `protocol`, `server`, `session-backends/sqlite-node`, `telemetry`, `tui`), the same set as `main` and as the previous run. The curated release notes at <https://pi.dev/news/releases> list the same two releases. No source carries an `Unreleased` block.

In scope since the previous marker: two releases, `0.99.0` and `0.99.1`, both 2026-09-29. `0.99.0` holds every entry except five: the `ai` and `coding-agent` GPT-6.1 Sol entries and the `coding-agent` `/login` fix of `0.99.1`. `client`, `protocol`, `server`, `session-backends/sqlite-node` and `telemetry` sections are empty. `codemode`, `durable` and `mcp` carry entries, and no package imports their npm packages. The `coding-agent` changelog restates `ai`, `agent` and `tui` entries as `inherited`; those restatements are not counted as separate items.

Behaviour was read from the Pi 0.99.1 npm packages (`@earendil-works/pi-coding-agent`, `@earendil-works/pi-ai`, their `.d.ts` exports and `dist/`) and from checks that load extension source into a real `createAgentSession`, or a real `pi --mode json` child, with a scripted model.

## Verdict

Verdict: `roll`.

- Target release: `0.99.1`, npm `@earendil-works/pi-coding-agent@0.99.1` integrity `sha512-cWUrTOqA5M73cOYMgsh9PlhDrsBhavd+n5kVY6F7BGbGl1RjqCteVCoeVMVqhngoGACVDyw1tbLjajL8l9jrHg==`, upstream source commit `d86654abb8862e201933517d6f1fce9f88dd117f` (tag `v0.99.1` in `earendil-works/pi`).
- Entries examined: every released entry of `0.99.0` and `0.99.1` across the sources above, 157 in all; the 20 `### Breaking Changes` entries are the table below.
- Tested extension commit: `0d6164b35cd7ca4d1b039bd46fbc4d903d71c700`, the head of `main` when the merged-commit run started. No fix of this run lands before it; the required fixes are in § Unresolved required fixes.
- Evidence: run directory `tmp/pi-update/run.8K2hDP` (local to the KEN-2178 lane). Pi 0.99.1 resolved from every extension entry file and suite directory in every package copy (`merged.*/logs/*.proof.log`, 40 paths). On the tested commit: the pi-hooks, pi-agents-tmux, pi-tool-renderer, pi-extension-manager and pi-codex-minimal-tools suites pass (123, 264, 85, 54 and 130 tests); every one of the 18 packages loads from its manifest into a real session and runs one prompt; the six checks under § Checks give the results listed there. KEN-2231, KEN-2232, KEN-2233 and KEN-2235 carry the check files.

Every `### Breaking Changes` entry in range was read against `pi-hooks/pi-contract.json`, across every source, and against `agent_before_settle`, which `pi-hooks/extensions/hooks.ts` listens on and the tested commit's contract omits (KEN-2236). No entry names an event or call pi-hooks uses; the `ExtensionAPI` and `ExtensionContext` declarations remove no member and no event between 0.87.1 and 0.99.1. `coding-agent`, `agent` and the other sources carry none.

| Release | Source | Entry | Names from the contract | Result |
|---|---|---|---|---|
| 0.99.0 | `ai` | `ImagesModels` collection and its constructors removed; image models join `Provider`/`Models` | none | Not blocking. No package calls a Pi image API. |
| 0.99.0 | `ai` | Image models are `ImageModel` with `type: "image"`; the plural image type names removed | none | Not blocking. |
| 0.99.0 | `ai` | Generated model data schema version 6 | none | Not blocking. |
| 0.99.0 | `tui` | `TUI.queryTerminalColorScheme()` and `queryTerminalBackgroundColor()` replaced by `queryTerminalColors()`; `parseOsc11BackgroundColor()` removed | none | Not blocking. No package calls them; the load check turns red on a copy of `pi-caveman` that imports `parseOsc11BackgroundColor`. |
| 0.99.0 | `durable` | Storage scan arguments reordered | none | Not blocking. No package imports `pi-durable`. |
| 0.99.0 | `durable` | Required `Storage.entry(conversationId, id, context)` overload | none | Not blocking. |
| 0.99.0 | `durable` | `Tx.createConversation()` split from `Tx.forkConversation()` | none | Not blocking. |
| 0.99.0 | `durable` | Branded numeric ID types replace untyped IDs and `TaskRef` | none | Not blocking. |
| 0.99.0 | `durable` | Task conversation membership immutable | none | Not blocking. |
| 0.99.0 | `durable` | `ConversationQuery` on conversation scans | none | Not blocking. |
| 0.99.0 | `durable` | Required `StoredDocument.deltasSinceBase` | none | Not blocking. |
| 0.99.0 | `durable` | Task definitions require `phases` and `abort` | none | Not blocking. |
| 0.99.0 | `durable` | `RegistryReader` requires `subscribe()` | none | Not blocking. |
| 0.99.0 | `durable` | `Tx.setTask()` removed | none | Not blocking. |
| 0.99.0 | `durable` | `Session.subscribeClose()` listeners run synchronously | none | Not blocking. |
| 0.99.0 | `durable` | `defineEntry<D>()` takes the data type | none | Not blocking. |
| 0.99.0 | `durable` | Required `Storage.scanSubmissions()` | none | Not blocking. |
| 0.99.0 | `durable` | `createRegistry()` pre-registers `pi.generation` and the `pi` setup | none | Not blocking. |
| 0.99.0 | `durable` | `RegistrySnapshot` requires `conversationSetups()` | none | Not blocking. |
| 0.99.0 | `durable` | `Tx` requires `settleSubmission()` | none | Not blocking. |

## Counts

| Bucket | Count |
|---|---:|
| Required parity fix (open, this range) | 4 |
| Required parity fix (fixed after the tested commit) | 1 |
| Found by this run, predates the range (open) | 2 |
| Found by this run, fixed after the tested commit | 1 |
| Optional improvement (deferred) | 7 |
| Non-impact | grouped below, not tallied |

Fixed on `main` after the tested commit `0d6164b3`, which holds neither fix: KEN-2196, carried from 0.87.1, the Codex shim's Off reasoning effort (0.86.0, [#9191](https://github.com/earendil-works/pi/issues/9191)), as `cd404e68`; KEN-2236's contract entries, as `78d3b3cd`. Its other half, a check tying the contract to the code, stays open.

## Unresolved required fixes

For KEN-2231, KEN-2232 and KEN-2233, the check fails on the tested commit at Pi 0.99.1 and its control passes. KEN-2242 was found in review after the run, by reading the Pi 0.99.1 npm packages against the tested commit's source; no check was run for it.

| Item | Extension | Pi entry | What it shows |
|---|---|---|---|
| KEN-2231 | `pi-tool-renderer` | Extension tool `outputSchema`; `bash` structured results (0.99.0) | The replacement `bash` in `extensions/tool-renderer/tools.ts` carries no `outputSchema`, so a codemode script's `bash` call gets text, not Pi's structured result. `piToolContract` does not copy the field. Control: the session without the renderer declares one. |
| KEN-2232 | `pi-codex-minimal-tools` | Responses streams that complete with an unfinished tool call end with an error (0.99.0, [#9974](https://github.com/earendil-works/pi/issues/9974)) | The vendored `processResponsesStream` in `src/providers/openai-responses-shared.ts` returns `stopReason=toolUse` and a `bash` call with `arguments: {}` while the partial JSON held `{"command":"rm -rf bu`. Control: Pi's own processor refuses the same events. |
| KEN-2233 | `pi-extension-manager` | `pi config` stores a disabled built-in extension as `-builtin:<name>` in `extensions` (0.99.0) | `buildInventory` lists `-builtin:mcp`, written by Pi's own `SettingsManager`, as an extension setting. Control: a path entry is listed. |
| KEN-2242 | `pi-output-policy` (`tool_result` handler), `pi-hooks` (`PostToolUse` append) | Extension tool `outputSchema` with `structuredContent`; `ctx.executeTool()` for nested calls; `bash` structured results (0.99.0) | `ExtensionRunner.emitToolResult` deletes `structuredContent` when a `tool_result` handler returns `content` without it, and `_afterToolCall` runs for a codemode script's nested calls too. `pi-output-policy/extensions/output-policy.ts` returns `{ content, details }` for every result it rewrites, even when only `details` changed; `pi-hooks/extensions/hooks.ts` returns the content plus the appended text when a `PostToolUse` hook speaks. Either way the script's `bash` call gets text in place of the structured result. KEN-2231 hides it while the renderer is installed. Fix: carry `structuredContent: event.structuredContent` where the text change keeps the structured result valid, and leave `content` undefined when only `details` changed. |

Found by this run, outside the range:

| Item | Extension | What the check shows |
|---|---|---|
| KEN-2235 | `pi-tool-renderer` | `tool_batch` runs each child through the built-in tool's `execute`, so no `tool_call` listener sees it: a `bash` child that a pi-hooks PreToolUse guard refuses as a direct call runs inside a batch. The code path has no Pi-version dependency. Pi 0.99.0's `ctx.executeTool()` emits `tool_call` for a nested call, and pi-hooks refuses it (§ Checks), so running the children through it is the fix. |
| KEN-2236 | `pi-hooks` | At the tested commit, `pi-contract.json` omits `agent_before_settle` for `hooks.ts` and lists `ctx.isIdle`, which `hooks.ts` no longer calls; `78d3b3cd` fixed both. Open: no check ties the contract to the code. |

## Checks

Each check loads the real extension with a scripted model and runs on the tested commit at Pi 0.99.1.

| Check | Surface | Result | Control |
|---|---|---|---|
| `pi-hooks/tests/pi-update-nested-tool-call.test.ts` | A `bash` call made through `ctx.executeTool()` (0.99.0) | Pass: the PreToolUse guard refuses it, and the `tool_call` event carries `parentToolCallId`. | With pi-hooks off, the nested call runs. |
| `pi-hooks/tests/pi-update-batch-child.test.ts` | A `bash` child of `tool_batch` | Fail: the child runs (KEN-2235). | A direct `bash` call is refused. |
| `pi-agents-tmux/tests/pi-update-real-child.test.ts` | `runSingleAgent` on a real `pi --mode json -p` child | Pass: the runner enriches the child's `agent_start` with the agent name, reads its `agent_settled`, and returns the child's answer. | Renaming `agent_start`, or dropping `agent_settled`, in the child's stream turns the check red. |
| `pi-tool-renderer/extensions/__tests__/pi-update-bash-output-schema.test.ts` | The session's `bash` definition | Fail (KEN-2231). | Pi's own `bash` declares an `outputSchema`. |
| `pi-codex-minimal-tools/tests/pi-update-unfinished-tool-call.test.ts` | The shim's Responses processor | Fail (KEN-2232). | Pi's processor refuses the stream. |
| `pi-extension-manager/test/pi-update-builtin-setting.test.ts` | The inventory's extension-setting rows | Fail (KEN-2233). | A path entry is listed. |

Real Pi 0.99.1 sessions (`tests/pi-session.ts` `startSession`): `tests/stop-continuation.test.ts` runs a `Stop` hook from `agent_before_settle`, which ends the run when silent and continues it once when it speaks, with one `agent_settled` per prompt; in `tests/lane-mail-wake.test.ts`, `session_start` arms the mailbox watcher, `agent_settled` runs the wake, and the busy-directive row's `bash` call sends its `tool_result` to the `lane-mail-deliver` hook. Stub carrier (`tests/harness.ts` `installCarrier`), made-up events: `tests/listener-dispatch.test.ts` calls the `agent_before_settle`, `tool_result` and `session_start` handlers; `tests/clippy.test.ts` calls `tool_result` and `turn_end`. `tool_call` is the two real-session checks above. No real session checked Pi's `turn_end` handler (clippy) or the `session_start` `reason` field. The pi-codex-minimal-tools suite sends a real session's system prompt and tools through the shim (`tests/transcript-context.test.ts`).

## Deferred (Optional)

| Item | Reasoning |
|---|---|
| Extension tool orchestration APIs: `exposure`, `namespace`, `annotations`, `isError`, `prepareLoadout()` (0.99.0) | No extension needs them for correctness. `pi-web-tools` could declare its tools `deferred` to shorten the tool list; that is a design choice for the package. |
| `ctx.executeTool()` (0.99.0) | `tool_batch` needs it (KEN-2235); no other extension runs a tool from inside a tool. |
| `provider_stream_event` and `onProviderStreamEvent` (0.99.0, [#9784](https://github.com/earendil-works/pi/issues/9784)) | No kendex extension listens for `provider_stream_event`. With the shim loaded, none fires for `openai-codex`: in `pi-codex-minimal-tools/src/provider-shim.ts`, `createCodexStream` forwards `onPayload` and `onResponse`, and `mapCodexEvents(events)` has no `onProviderStreamEvent` parameter. KEN-2243's triage accepted the gap on that ground. |
| `theme.style()`, `theme.colors`, `theme.appearance` and the `pi-tui` color helpers (0.99.0) | Extensions style through `theme.fg` and `theme.bg` tokens, all of which the 0.99.1 theme schema still requires; adoption is cosmetic. |
| `AssistantMessage.thinkingLevel` (0.99.0) | `pi-agents-tmux` reports the effort it passed to the child; reading the recorded level would show what ran. |
| Per-input disposition on `AgentSession.steer()`/`followUp()` and RPC (0.99.0, [#9098](https://github.com/earendil-works/pi/issues/9098)) | No extension calls them; `pi-session-bridge` delivers through `pi.sendUserMessage`. |
| Sign in with ChatGPT on the `openai` provider supersedes "OpenAI Codex (legacy)" (0.99.0) | `pi-codex-minimal-tools` registers its shim on `openai-codex` only. A user who moves to the `openai` provider leaves the shim's request shaping. Wrapping `openai` too is a design choice for the package. |

## Non-impact

Already protected, checked, or inherited beneath us:

- **Built-in extensions and tools named `builtin:<name>` in diagnostics and source info; `--no-extensions` also disables built-ins (0.99.0)**: no extension compares a source path to `<builtin:…>` or `<inline:…>`, and `pi-agents-tmux` launches pane children with `-e` and no `--no-extensions`. The settings side is KEN-2233.
- **Warning when an extension replaces a built-in extension's tool, command or flag (0.99.0, [#10174](https://github.com/earendil-works/pi/pull/10174))**: the built-in extensions register the `codemode`, `tool_search`, `list_mcp_resources`, `list_mcp_resource_templates` and `read_mcp_resource` tools, MCP server tools, and the `/mcp` and `/llama` commands; no kendex extension registers those names. `pi-tool-renderer` replaces built-in tools, not built-in extension tools.
- **Tool calls without a custom call renderer show their arguments (0.99.0)**: `pi-tool-renderer` renders every tool it replaces and `tool_batch`; other extension tools gain Pi's default, a look change for the user.
- **Full-file `read` shown as `:1` when `offset` and `limit` are `null` (0.99.0, [#9996](https://github.com/earendil-works/pi/issues/9996))**: `pi-tool-renderer`'s read title (`tool-renderer/text.ts`) adds a range only when `offset` or `limit` is truthy, so `null` shows no range.
- **Session file created with the first user message (0.99.0, [#10000](https://github.com/earendil-works/pi/issues/10000))**: the file now exists before the first answer. `pi-session-manager` lists one more session, with a prompt and no answer, for a Pi that exited early, which is the session Pi now keeps.
- **Managed git packages no longer install Pi peers (0.99.0, [#9863](https://github.com/earendil-works/pi/issues/9863)); pinned git extensions refetched on a ref change ([#9982](https://github.com/earendil-works/pi/issues/9982))**: kendex installs extensions as path packages, and `pi update` reconciles only `git:` and `npm:` entries.
- **`system` theme default, revised `dark` and `light` colors, OKHSL theme values (0.99.0)**: the 0.87.1 and 0.99.1 theme schemas require the same 51 color tokens, and every token an extension passes to `theme.fg` or `theme.bg` is among them.
- **OpenAI Fast-mode pricing (0.99.0, [#10034](https://github.com/earendil-works/pi/issues/10034))**: Pi changed the `openai` provider's service-tier multiplier; its `openai-codex` transport, which the shim mirrors, is unchanged between 0.87.1 and 0.99.1.
- **GPT-6.1 Sol, the new default Codex model (0.99.1)**: the shim takes models from Pi's catalog, and its OpenAI detection reads the provider id first. Its fallback probe list lacks `gpt-6.1-sol`, and `gpt-6-astra`, which the list holds, is still in Pi 0.99.1's `openai-codex` catalog.
- **Build on TypeScript 7.0 with an ES2024 target, `tsx` replaced by Node type stripping (0.99.0)**: every package loads into Pi 0.99.1 from its manifest.
- **Usage of tools run through `ctx.executeTool()` added to the calling tool's result (0.99.0)**: no extension calls `ctx.executeTool()` on the tested commit.
- **`RpcClient` listener fix, `/login` bundled-module fix, llama.cpp autoload presets, Finder paste, X11 clipboard, startup header and theme refresh fixes, streaming CPU reductions, Kitty image, autocomplete and cursor fixes (0.99.x)**: Pi host behaviour; no extension imports the clipboard or autocomplete helpers.

Provider and model catalog (our overrides are `openai-codex` in `pi-codex-minimal-tools` and the Claude native provider in `pi-claude-bridge`):

- **Claude Sonnet 5.5 for Anthropic (0.99.0)**: `pi-claude-bridge` drives the Claude Agent SDK with its own model list, not Pi's Anthropic transport.
- **Codemode, MCP, tool search, virtual models, classifier models, Jev on OpenRouter, Cloudflare, Vercel and OpenCode, `ModelRuntime` image generation and classification, catalog schema version 6, Fireworks, OpenCode Go and Together default models, Mistral, GLM, Qwen, Vercel cache pricing, `samplingParams`, Anthropic and Codex browser sign-in, Copilot Opus 5.5 thinking levels**: built-in features, transports and catalogs we neither register nor override. `pi-codex-minimal-tools`' image generation uses the Responses `image_generation` tool, not Pi's image models.

Sources no package imports: `codemode`, `durable` and `mcp`. `pi-qol` imports the `AgentMessage` type from `@earendil-works/pi-agent-core` (`extensions/qol/handoff.ts`, `compaction.ts`, `transcript-risk.ts`, `session-search/context.ts`) and nothing else from `agent`. The `agent` entries in range are the `onProviderStreamEvent` option and `thinkingLevel`, an added optional field on assistant messages; neither affects `pi-qol`.
