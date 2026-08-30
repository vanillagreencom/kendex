# Pi package update audit: 0.84.2

Marker `0.84.1` → `0.84.2`. Audited against base `82ecc517`. Sources fetched: `agent`, `ai`, `coding-agent`, `server`, `storage` (at `packages/session-backends/sqlite-node/` — the pre-0.84.0 `packages/storage/sqlite-node/` path 404s), `tui`, plus the curated release notes. `Unreleased` blocks scanned for heads-up only and excluded from the marker.

In scope since the previous marker (`0.84.1`): one release, `0.84.2` (2026-08-14). After deduping the curated notes and the `inherited` restatements `coding-agent` publishes for `ai`/`agent`/`tui` changes, ~35 unique items. `server` and `storage` 0.84.2 sections are empty; `agent` 0.84.2 carries a single fix.

## Counts

| Bucket | Count |
|---|---:|
| Required parity fix | 0 |
| Optional improvement (deferred) | 1 |
| Non-impact | ~34 |

## Shipped

Nothing. No 0.84.2 entry changes a surface our extensions override, mirror, or duplicate.

## Deferred (Optional)

| Item | Reasoning |
|---|---|
| `expandPromptTemplates` on `pi.sendUserMessage()` (0.84.2, [#7857](https://github.com/earendil-works/pi/pull/7857)) | Pi's option covers exactly the kendex#13 workaround surface in `pi-session-bridge/extensions/session-bridge.ts:620-680`: extension-command dispatch plus skill and prompt-template expansion. Adopting it would retire the fragile tmux-paste path (`resolveOwnTmuxPaneByParentChain` + `pasteAndSubmitToPane`) in favor of a first-party API. Deferred from this run for two reasons: our client-side `/skill:` expansion carries the per-session skill-hash reminder cache (repeated sends deliver a short reminder instead of full skill content — a documented token-cost feature Pi's dispatch does not replicate), so full adoption is a regression there; and swapping the extension/TUI-command delivery path needs a live peer-session test that an audit run cannot provide. Right end state: keep client-side skill/template expansion first, replace only the tmux-paste fallback with `sendUserMessage(content, { …, expandPromptTemplates: true })`. The `session-bridge.ts:620` comment ("pi.sendUserMessage hardcodes expandPromptTemplates: false") becomes stale wording with that change and should be updated in the same commit. |

## Non-impact

Tools, settings, and extension API:

- **`defaultTools` setting + its fix for dropping extension/SDK custom tools** — our activation logic derives from the live active set, never a hardcoded built-in list: `pi-codex-minimal-tools/src/index.ts:76,87` and `pi-web-tools/src/index.ts:60` diff against `pi.getActiveTools()` before calling `setActiveTools()`. A user-configured startup selection flows through unchanged, and Pi's in-release fix protects our registered tools.
- **Experimental strict JSON-schema constrained sampling for `read`/`bash`/`edit`/`write` under `PI_EXPERIMENTAL=1`** — Pi's default tools, opt-in; `pi-tool-renderer` renders their results and validates nothing.
- **Single-object `edit` inputs accepted as one-edit arrays ([#7835](https://github.com/earendil-works/pi/issues/7835))** — no kendex extension ships an edits-array tool (grep zero); the validation lives in Pi's coding-agent and harness edit tools.
- **Root Markdown files in skill dirs no longer reported as broken skills ([#7805](https://github.com/earendil-works/pi/issues/7805))** — `pi-skills-manager` discovers through Pi's own `DefaultPackageManager.resolve()` (`registry.ts:70-73`) and already null-drops files without name/description frontmatter (`registry.ts:23-39`); the upstream fix removes the bogus entries before we see them.
- **Fallback rendering for extension tool results collapses long output ([#7979](https://github.com/earendil-works/pi/issues/7979))** — every custom tool we ship has its own renderer; the fallback only covers unrendered tools, so this is a strict improvement beneath us.
- **`message_update` events regain cumulative usage in JSON/RPC ([#7982](https://github.com/earendil-works/pi/pull/7982))** — additive field. `pi-agents-tmux` reads usage from `agent_end`/`message_end`; `pi-session-bridge`'s sanitizer reduces `message_update` to role/contentIndex/delta preview and ignores extra fields (raw sidecar keeps them).
- **`pi.sendMessage(..., { triggerTurn: false })` no longer steers an active run ([#8022](https://github.com/earendil-works/pi/pull/8022))** — our ten `triggerTurn: false` call sites are record-only by intent: `pi-hooks/extensions/hooks.ts` (drift report at session start), `pi-task-panel/extensions/task-panel.ts:1283`, `pi-qol/extensions/qol.ts:872` and `qol/session-search/{context.ts:135,index.ts:91,115}`, `pi-codex-minimal-tools/src/background-image-generation.ts:481,520` and `provider-shim.ts:1941,1957`. Pi now matches the intent; before the fix these could steer an active run we never meant to steer, so the change is strictly protective. One `sendMessage` call of ours is not in that set and must not be read into it: `pi-hooks/extensions/hooks.ts`'s end-of-turn clippy report passes `triggerTurn: true` because it has to steer — a recorded message reaches `agent.state.messages` but never the steering queue the loop drains, so a headless run that is ending never reads one.
- **Custom system prompts no longer concatenate cwd with appended content ([#7887](https://github.com/earendil-works/pi/pull/7887))** — `pi-claude-bridge` assembles its own prompt context from `APPEND_SYSTEM.md` files (`src/prompt-context.ts:34-49`) and never routes through Pi's `customSystemPrompt` concatenation.
- **Subagent example fixes: YAML `tools` arrays ([#7598](https://github.com/earendil-works/pi/pull/7598)), parent model/thinking/tool inheritance ([#7897](https://github.com/earendil-works/pi/pull/7897))** — Pi's example extension; ours is `pi-agents-tmux`.
- **Managed-tool downloads no longer delay TUI startup; model selector no longer restarts an in-progress catalog refresh** — Pi startup orchestration outside any surface we hook.

Provider and model catalog (checked against our two provider overrides — `pi-claude-bridge`'s native provider and `pi-codex-minimal-tools`' shim, which owns its own transport):

- **OpenAI Responses namespace preservation during streaming/proxying/replay + message-anchored `additional_tools` ([#7709](https://github.com/earendil-works/pi/issues/7709))** — closes the 0.84.1 audit's heads-up: grep confirms zero namespace handling in `pi-codex-minimal-tools/src`; the shim never routes through Pi's Responses adapter or `streamProxy()`.
- **`streamProxy()` finalized tool-call metadata fix (agent 0.84.2, [#7709](https://github.com/earendil-works/pi/issues/7709))** — no `streamProxy` usage anywhere in our source.
- **Strict tool schemas auto-converted to closed objects with required-nullable optionals; `null` for optional non-nullable args treated as omitted** — provider-side transmission of tool schemas; our tools' TypeBox schemas are unchanged at registration, and the Claude bridge provider does not use strict schema mode.
- **`createGatewayBindingFetch()` ([#7901](https://github.com/earendil-works/pi/pull/7901)); `AssistantMessage.endTurn` ([#7766](https://github.com/earendil-works/pi/pull/7766)); Kimi runtime User-Agent; native Mistral transport; DeepSeek `max_tokens`/hostname fixes; Bedrock empty-object-key replay ([#7882](https://github.com/earendil-works/pi/pull/7882)); Google/Vertex stop-classification ([#8059](https://github.com/earendil-works/pi/issues/8059)); Copilot policy rate limit ([#6187](https://github.com/earendil-works/pi/issues/6187)); upstream buffer-limit retries** — built-in provider transports and catalogs we neither register nor override; nothing consumes `endTurn`.
- **`AI_AGENT=pi` marker documentation ([#7747](https://github.com/earendil-works/pi/issues/7747))** — docs only; our children are identified by `PI_SUBAGENT_CHILD_AGENT`/`PI_SUBAGENT_CHILD_PANE`.

TUI and platform:

- **Fullscreen transcript search (`Ctrl+Shift+F`, match themes, navigation), unbound single-line scroll actions ([#7903](https://github.com/earendil-works/pi/pull/7903)), fullscreen exit-output setting, `--use-theme` ([#7722](https://github.com/earendil-works/pi/pull/7722)), 9-18x alternate-screen paint reduction, SGR mouse release codes ([#7963](https://github.com/earendil-works/pi/issues/7963)), overlay wheel/PageUp scroll ([#7894](https://github.com/earendil-works/pi/issues/7894)), `Alt+Enter` over SSH + `PI_TUI_ESC_TIMEOUT` ([#7899](https://github.com/earendil-works/pi/pull/7899)), idle repaint on focus loss ([#7892](https://github.com/earendil-works/pi/pull/7892)), OSC 52 copy verification ([#8110](https://github.com/earendil-works/pi/pull/8110)), LaTeX newline-argument and control-space fixes ([#7760](https://github.com/earendil-works/pi/issues/7760)), Windows right-click paste** — Pi TUI internals and keybindings. Our popups and renderers build on Pi's components and return fresh render output each frame; no API we call changed, and the direct-line-reference paint change only affects rows Pi composes itself. Standing caveat from the 0.84.0 audit: our popups were not live-tested inside fullscreen mode this run either.
- **`nanoid` transitive dev-dependency DoS bump** — no kendex extension lockfile contains `nanoid`.

## Heads-up (`Unreleased`, not processed)

Scanned for awareness only; the marker stays at `0.84.2`.

- **Truncated-response recovery no longer mislabeled as context overflow ([#8130](https://github.com/earendil-works/pi/issues/8130))** — `pi-agents-tmux`'s bg-agent overflow retry matches context-overflow message strings; recheck the exact wording when this releases.
- `session_compact_failed` extension events ([#8175](https://github.com/earendil-works/pi/issues/8175)) — possible future consumer in `pi-qol` compaction UX.
- `pi update` no longer treats older registry versions as updates ([#8226](https://github.com/earendil-works/pi/issues/8226)) — `pi update` reconciles `git:`/`npm:` entries only; kendex path packages stay out of scope.
- `pi.registerFlag()` default-type validation ([#8064](https://github.com/earendil-works/pi/issues/8064)); llama.cpp `/model` catalog fixes; pi.dev catalog refresh retry ([#8198](https://github.com/earendil-works/pi/issues/8198)); ai `GoogleThinkingLevel` rename (no usage on our side).

## Run incident (not a changelog item)

During this run's fetch phase the host session hit a `pi-claude-bridge` defect: a five-way parallel `web_fetch` batch containing one empty-args call cross-wired the bridge's result pairing — three results reaped as stale, one orphaned handler with no timeout, session deadlocked 5h39m until manual abort. Full forensics and fix directions filed as [kendex#1469](https://github.com/vanillagreencom/kendex/issues/1469).
