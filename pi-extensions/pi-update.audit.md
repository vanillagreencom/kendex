# Pi package update audit: 0.86.0 to 0.87.1

Marker `0.85.1` → `0.87.1`. Audited against base `8b86d5ce`. Sources fetched: every `*/CHANGELOG.md` in the Pi tree on `main` (`agent`, `ai`, `client`, `codemode`, `coding-agent`, `durable`, `mcp`, `protocol`, `server`, `session-backends/sqlite-node`, `telemetry`, `tui`), plus the curated release notes. `codemode`, `durable` and `mcp` are newly enumerated; `codemode` and `mcp` carry only an `Unreleased` block. `Unreleased` blocks scanned for heads-up only and excluded from the marker.

In scope since the previous marker: four releases, `0.86.0` (2026-09-19), `0.86.1` (2026-09-20), `0.87.0` (2026-09-21), `0.87.1` (2026-09-22). `client`, `protocol`, `server`, `session-backends/sqlite-node` and `telemetry` sections are empty across the range; `durable` has one entry, the initial Pico record contracts, which no extension imports. The `coding-agent` changelog restates `ai`, `agent` and `tui` entries as `inherited`; those restatements are not counted as separate items.

Behaviour was read from the installed Pi 0.87.1 (`dist/core/agent-session.js`, `dist/core/provider-composer.js`, `dist/core/model-runtime.js`, `dist/core/tools/*.js`) and from fixtures that load extension source into a real `createAgentSession` with a faux provider.

## Verdict

Verdict: `roll`.

- Target release: `0.87.1`, npm `@earendil-works/pi-coding-agent@0.87.1` integrity `sha512-m8ArJUtVcQMSe1lLE/Ei7vX/JV7O39sWmWBsXV2NOU70F0qCp8GubA24pT3LnwTmM6LL2xV80/h6sQg85n69ew==`, upstream source commit `f07218c4d4bbc12bef056a7058c3dd49dfe41abe` (tag `v0.87.1` in `earendil-works/pi`).
- Entries examined: every released entry of `0.86.0`, `0.86.1`, `0.87.0` and `0.87.1` across the sources above; the eight `### Breaking Changes` entries are the table below.
- Tested extension commit: `143beaa3c5cd87ab25bd31362bfd12d83c941e4d`, the merge of this audit's change, whose `pi-extensions` tree is that of the pull request head `91590ab0bca5899804394c7246bbe03ce5412176` its CI ran. The KEN-2176 Codex shim fix, § Codex provider shim, is outside that commit.
- Evidence: the real Pi 0.87.1 session fixtures in § Settled-handler deferral; `pi-hooks/tests/lane-mail-wake.test.ts`; `pi-tool-renderer/extensions/__tests__/tool-execution-context.test.ts`.

Every `### Breaking Changes` entry in range was read against `pi-hooks/pi-contract.json`, across every source; the `ai` and `agent` entries repeat the `coding-agent` ones they are inherited from. `tui` and the other sources carry none.

| Release | Entry | Names from the contract | Result |
|---|---|---|---|
| 0.87.0 | Runs requested from `agent_settled` handlers deferred until every settled handler finishes; handlers still read `ctx.isIdle() === true` | `agent_settled`, `ctx.isIdle` | Blocking. The pi-hooks change landed in KEN-2010 (`8b86d5ce`), the audit base; § Settled-handler deferral. |
| 0.87.0 | `TurnEndEvent` expanded; `ExtensionRunner.emit()` no longer accepts `turn_end` | `turn_end` | Blocking. No pi-hooks change needed: its `turn_end` listener reads no event field and pi-hooks emits no event. `tests/lane-mail-wake.test.ts` loads that listener from the manifest in a real Pi 0.87.1 session. |
| 0.87.0 | `shouldStopAfterTurn` removed | none | Not blocking. |
| 0.87.0 | `ContextEditEntry` added to the `SessionEntry` union | none | Not blocking. |
| 0.87.0 | `SessionManager` canonical for provider context | none; pi-hooks calls only `getSessionId` and `getSessionFile` on it | Not blocking. |
| 0.86.0 | Provider stream inputs are `TranscriptContext` | none | Not blocking. |
| 0.86.0 | `ToolCall.arguments` and `ToolResultMessage.details` restricted to JSON values | none | Not blocking. |
| 0.86.0 | `user_bash` fails closed | none | Not blocking. |

## Counts

| Bucket | Count |
|---|---:|
| Required parity fix (shipped) | 2 |
| Required parity fix (fixed after the audit, KEN-2176) | 1 |
| Required parity fix (open) | 1 |
| Optional improvement (deferred) | 5 |
| Non-impact | grouped below, not tallied |

## Settled-handler deferral (0.87.0)

Pi 0.87.0 defers a run requested from an `agent_settled` handler until every settled handler has returned. `AgentSession.prompt()`, which `sendUserMessage` reaches, and `sendCustomMessage(..., { triggerTurn: true })` queue their run and return at once while the settle is dispatching; the queue runs after the last handler returns. Handlers still read `ctx.isIdle() === true`. A handler that awaits the run it asked for therefore waits on itself, and every later prompt, wake and typed input waits with it until Pi restarts.

Every `agent_settled` handler in `pi-extensions` was checked:

| Handler | What it awaits | Verdict |
|---|---|---|
| `pi-hooks/extensions/hooks.ts`, `consultStop` | The run its `Stop` steer starts, when the session reads busy after the send | Froze every Pi lane on a speaking `Stop` hook. Fixed in KEN-2010 (`8b86d5ce`): the wait is armed only when the session is no longer idle after the send, which on 0.87 it never is. |
| `pi-hooks/extensions/lane-mail-wake.ts`, `check` | The lane-mail judge script; its `sendUserMessage` is not awaited | Safe. The wake's turn runs after the settle. |
| `pi-qol/extensions/qol.ts`, `fireStagedBudgetGuard` | The budget-guard compaction it starts through `ctx.compact` | Safe. `AgentSession.compact()` aborts, summarizes, appends the compaction entry and emits `session_compact` and `compaction_end`; it starts no agent run. Prompts the interactive mode flushes on `compaction_end` are deferred and run after the settle. The cost is latency: a deferred wake or typed prompt waits for the compaction to finish. |
| `pi-agents-tmux/extensions/subagent/index.ts`, `handleChildSettled` | Task-registry file I/O; its `pi.sendMessage` carries no `triggerTurn` | Safe. |

Fixture evidence, Pi 0.87.1, real `pi-qol` extension with a 1-token budget, a second settled handler loaded after it:

| Second handler | Session idle within 8 s | Compactions | Wake turn ran |
|---|---|---:|---|
| None | yes | 1 | no |
| Sends `triggerTurn: true`, returns | yes | 2 | yes, after the QOL compaction settle |
| Sends `triggerTurn: true`, awaits its `agent_start` (control) | no | 1 | no |

The control shows the fixture detects a handler that waits on its own run; the QOL handler does not. The second compaction in the middle row is the wake turn crossing the 1-token budget again.

The `pi-agents-tmux` child inbox poller is not a settled handler; its settle behaviour is under § Non-impact.

## Shipped

| Item | Extension | Fix |
|---|---|---|
| Run requested from an `agent_settled` handler deferred until every settled handler returns (0.87.0) | `pi-hooks` | Landed in KEN-2010 at the audit base `8b86d5ce`, not in this audit's change. `consultStop` no longer waits on a run Pi defers until it returns; § Settled-handler deferral holds the fix and the check of every other settled handler. |
| Strict-prefer JSON-schema sampling by default for built-in `read`, `bash`, `edit`, `write` (0.86.0) | `pi-tool-renderer` | The replacement tools in `extensions/tool-renderer/tools.ts` copied `description` and `parameters` (and `prepareArguments` on `edit`) and dropped Pi's `constrainedSampling`, so with the renderer installed `read` and `bash` always, and `edit` and `write` with `renderMutationTools` on, lost strict-prefer sampling. `piToolContract` now carries the wrapped AgentTool's description, parameters, `constrainedSampling` and `prepareArguments` onto every replacement. Test: `extensions/__tests__/tool-execution-context.test.ts`, one row per replacement; removing the forwarded field turns all seven rows red. |

The `pi-tool-renderer` fix is not live-tested inside Pi; it is proven at the registration surface, and against the installed Pi 0.87.1 each of the four replacements now carries `{ type: "json_schema", strict: "prefer" }`.

## Codex provider shim and the transcript contract (0.86.0)

Pi 0.86.0 passes a provider's `streamSimple` a normalized `TranscriptContext`: the system prompt and tool declarations live in transcript system messages, and `context.systemPrompt` and `context.tools` are absent. `pi-codex-minimal-tools` registers `openai-codex` with its own `streamSimple` when `enabled` and `nativeProviderTools` are on, the defaults. Before KEN-2176 its `buildRequestBody` in `src/provider-shim.ts` read `context.systemPrompt` into `instructions` and `context.tools` into `tools`, and its vendored `convertResponsesMessages` had no branch for a `system` message. Fed the normalized context Pi 0.87.1 builds, the request carried no `instructions` and no tools; fed the raw context, it carried both.

Impact until the fix: every `openai-codex` request through the shim on Pi 0.86.0 or later reached the model without the system prompt and with no tools. Likelihood: certain for any session on the Codex provider with the package installed and its defaults.

Fixed after this audit in KEN-2176: `buildRequestBody` and the vendored converter read the prompt and the tool set through Pi's `getCurrentSystemPrompt` and `getCurrentTools`, which fold later system messages in, and send no system message as an input item. A context with no system message, which a Pi below 0.86.0 hands, is still read from its `systemPrompt` and `tools` fields, so the package keeps its open peer range. Evidence: `pi-codex-minimal-tools/tests/transcript-context.test.ts` sends a real Pi session through the shim and fails on the old code, and builds a request from each context shape. Pi's own `openai-codex-responses` keeps later system messages in place and adds tools where they appear, when the model supports it (`resolveTranscript`, `resolveTranscriptTools`); the shim sends the folded prompt and the full current tool set instead, which is correct and forgoes that cached-prefix saving.

Still open: Pi sends the model's Off reasoning effort instead of omitting it (0.86.0, [#9191](https://github.com/earendil-works/pi/issues/9191)), which the shim still omits.

## Deferred (Optional)

| Item | Reasoning |
|---|---|
| Transcript-backed system prompt changes; `before_agent_start` prompt sections (0.86.0, [#9548](https://github.com/earendil-works/pi/pull/9548)) | `pi-task-panel`, `pi-agents-tmux` and `pi-caveman` return a whole `systemPrompt` from `before_agent_start`. Since 0.86.0 that replaces the prompt for the run and is sent as the leading system prompt, so it stays correct but forgoes the cached-prefix transcript delta Pi keeps when prompt sections change instead. `pi-task-panel`'s reminder changes with the open task count. Adopt with a per-package design. |
| `ctx.modelRegistry.stream()` / `streamSimple()` (0.86.0, [#8964](https://github.com/earendil-works/pi/issues/8964)) | `pi-qol` summaries resolve auth with `getApiKeyAndHeaders` and call pi-ai `complete`. Correct today; routing through the registry would drop that step. |
| `pi.on()` returns an unsubscribe function (0.86.0, [#8967](https://github.com/earendil-works/pi/issues/8967)) | No extension drops a handler. |
| Context edits, retain-none compaction, actionable `turn_end` / `agent_before_settle`, `context_with_system` (0.87.0) | New extension capabilities. No extension needs them for correctness; `pi-hooks` could move its `Stop` delivery onto `agent_before_settle` with `continue: true`, which would remove the settle steer, but that is a carrier redesign. |
| Exported extension hook event and result types (0.86.0, [#9642](https://github.com/earendil-works/pi/pull/9642)) | Handlers type their events loosely today; tightening them is a type-only change. |

## Non-impact

Already protected or inherited beneath us:

- **`context` handlers no longer see system messages; Pi restores prompt and tools after them (0.87.0, [#9789](https://github.com/earendil-works/pi/issues/9789))**: `pi-task-panel`'s `context` handler drops only its own stale reminder messages; the fix removes the risk rather than adding one.
- **`ContextEditEntry` in the `SessionEntry` union (0.87.0)**: every extension reads entries by an explicit `entry.type` test, none by an exhaustive switch; `pi-qol` reads model context through `buildSessionContext`, which applies context edits.
- **`SessionManager` canonical for provider context (0.87.0)**: no extension assigns `agent.state.messages`.
- **`TurnEndEvent` expanded, `ExtensionRunner.emit()` refuses `turn_end` (0.87.0)**: the `pi-hooks` `turn_end` handler returns `undefined`; `pi-session-bridge` republishes the event and constructs none.
- **`shouldStopAfterTurn` removed (0.87.0)**: no extension sets it.
- **Child inbox task picked up during a settle (0.87.0)**: the `pi-agents-tmux` child inbox poller gates on `ctx.isIdle()`, which reads true while settled handlers run, so it can take a task inside a settle. If its dispatch reaches `pi.sendUserMessage` while the settle still runs, Pi defers the prompt and runs it after the last settled handler returns. `pi.sendUserMessage` does not wait for the prompt on any Pi version from 0.84.1 on, so `recordTaskDispatchFailure` receives only the synchronous throw of a stale or uninitialized extension runtime, which still arrives inside a settle. 0.87 changes no poller failure path.
- **`user_bash` fails closed (0.86.0, [#9068](https://github.com/earendil-works/pi/issues/9068))**: `pi-background-tasks` returns `undefined` or `{ result }`, both valid.
- **Extension tools without parameter schemas rejected (0.86.0, [#9300](https://github.com/earendil-works/pi/issues/9300))**: every `registerTool` definition in the tree carries `parameters`, the factory-built ones in `pi-codex-minimal-tools` and `pi-web-tools` included.
- **`ToolCall.arguments` and `ToolResultMessage.details` restricted to JSON values (0.86.0)**: type-level, no runtime change. `pi-codex-minimal-tools`' vendored stream processor typed parsed tool arguments as `Record<string, unknown>`, which fails its typecheck against 0.86.0; since KEN-2176 it types them as `JsonObject`. Other tool details are plain data.
- **Provider stream input is `TranscriptContext` (0.86.0)**: `pi-claude-bridge` moved to it in KEN-1634; `pi-codex-minimal-tools` moved to it in KEN-2176, § Codex provider shim.
- **Compaction, branch-summary and retry spinners embedded in the editor border (0.86.0)**: `pi-qol` adopted the embedded indicator for 0.86.0 (KEN-1978).
- **Split-turn compaction summaries refused by Claude Fable 5.1 (0.87.1, [#9908](https://github.com/earendil-works/pi/pull/9908))**: Pi's default summarizer prompt. `pi-qol`'s own summary prompt already wraps the transcript in `<conversation>` tags and asks for a continuation summary.
- **Missing or invalid `--mode` now exits nonzero (0.87.1, [#9045](https://github.com/earendil-works/pi/issues/9045))**: `pi-agents-tmux` launches with `--mode json`.
- **Direct RPC `steer`/`follow_up` now pass extension `input` handlers (0.86.0, [#8718](https://github.com/earendil-works/pi/issues/8718))**: Pi stdio RPC; `pi-session-bridge` delivers through `pi.sendUserMessage`.

Provider and model catalog (our overrides are `openai-codex` in `pi-codex-minimal-tools` and the Claude native provider in `pi-claude-bridge`):

- **GPT-6 Sol and GPT-6 Luna for Codex (0.87.1), GPT-5.4 removed from the Codex catalog (0.86.0)**: the shim takes models from Pi's catalog. Its OpenAI-model probe accepts any listed id, and `gpt-6-astra` is still in Pi 0.87.1's Codex catalog, so a missing `gpt-5.4` changes no probe result.
- **Claude Opus 5.5 and Sonnet 5.5, Anthropic OAuth Claude Code version (0.87.x)**: `pi-claude-bridge` offers Opus 5.5 since KEN-1706 and drives the Claude Agent SDK, not Pi's Anthropic transport.
- **Meta Muse, Grok 4.7, Copilot Responses adapter, DeepSeek, Mistral, GLM, Fireworks, OpenRouter, OpenCode, Baseten, Bedrock, Vertex, Vercel, z.ai and Cerebras fixes; strict tool schemas for unknown Chat Completions endpoints; retry classification for Cloudflare 520 and Azure capacity errors; image-input resize metadata; prompt-cache lifetime metadata**: built-in transports and catalogs we neither register nor override.

Host, SDK and platform:

- **Prompt-cache warming and `cache_warming_decision`, `/bug` reports, Radius catalog, per-model compaction budgets, per-model image input limits, Node compile cache, `--resume`/`--continue` speedups, deferred extension compiler, bundled native clipboard readers, OSC 52 fallback, Bash/PowerShell duration format, signal-terminated shell commands no longer reported as success, capped agent retry backoff, cancellation races around compaction, session tree navigation during compaction, fullscreen footer row, Kitty image fixes, LaTeX and autocomplete fixes, fuzzy search speedup**: Pi host behaviour. The Bash tool the renderer wraps is Pi's own, so the exit-status fix is inherited; no extension imports the clipboard or fuzzy helpers.

## Heads-up (`Unreleased`, not processed)

- **Built-in extensions (`mcp`, `llama.cpp`, `codemode`, `tool-search`) named `builtin:<name>`; `--no-extensions` also disables them; `defaultTools` accepts `+name`/`-name`**: check `pi-extension-manager`'s listing when this releases.
- **Tool calls without a custom call renderer show their arguments**: `pi-tool-renderer` renders every tool it replaces; the rest gain the default.
- **Managed git packages no longer install Pi peers; a warning for host modules in `dependencies`**: no package lists a Pi host module in `dependencies`.
- **OpenAI Responses streams with unfinished tool calls end with an error**: the Codex shim vendors its own stream processor; check it in the next audit.
- **`provider_stream_event` extension event**: additive; no extension needs it.
