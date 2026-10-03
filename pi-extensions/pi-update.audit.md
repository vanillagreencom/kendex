# Pi package update audit: 0.99.2 to 1.0.0

Marker `0.99.1` → `1.0.0`. Audited against base `e5d6ed8f`. Sources fetched: every `*/CHANGELOG.md` in the Pi tree at the target's source commit (`agent`, `ai`, `client`, `codemode`, `coding-agent`, `durable`, `mcp`, `protocol`, `server`, `telemetry`, `tui`), the same set as `main`. `session-backends/sqlite-node`, a source of the previous run, is gone from the tree at `v1.0.0`: its last changelog, at `v0.99.2`, carries an empty `0.99.2` header, and its SQLite storage now sits in `packages/durable/src/storage/sqlite`. The curated release notes at <https://pi.dev/news/releases> list the same two releases. The `Unreleased` blocks on `main` (`ai`, `codemode`, `coding-agent`, `mcp`, `tui`) are a heads-up only and are not classified here; the one Breaking entry among them is in `mcp`, which no package imports.

In scope since the previous marker: two releases, `0.99.2` (2026-09-30) and `1.0.0` (2026-10-01). Across all sources they carry 76 changelog bullets, besides the 11 `### New Features` summary bullets of `coding-agent`, which restate its own Added and Changed entries. `client`, `protocol` and `telemetry` sections are empty. `codemode`, `durable`, `mcp` and `server` carry entries, and no package imports their npm packages. The `coding-agent` changelog restates `ai`, `codemode`, `mcp` and `tui` entries; each restatement is classified with its source.

Behaviour was read from the Pi 1.0.0 and 0.99.1 npm packages (`@earendil-works/pi-coding-agent`, `pi-ai`, `pi-agent-core`, `pi-tui`: their `.d.ts` and runtime exports and `dist/`), from `packages/coding-agent/src/core/extensions/types.ts` at every Pi tag from `v0.50.0` to `v1.0.0`, and from checks that load extension source into a real `createAgentSession` with a scripted model or a stubbed `openai-codex` endpoint.

## Verdict

Verdict: `roll`.

- Target release: `1.0.0`, npm `@earendil-works/pi-coding-agent@1.0.0` integrity `sha512-/FtbxoSQU/mEv1QnichJjRjqteqaIaMWxmhB4G367+MwZfX7/DI5B9YAg5lqbN7nztFskBEtUSZ+FlmMBECtMw==`, upstream source commit `a13d35a742c6ef8462812a28fbe1d8c8b7431c32` (tag `v1.0.0` in `earendil-works/pi`).
- Entries examined: every released entry of `0.99.2` and `1.0.0` across the sources above, 76 in all; the two `### Breaking Changes` entries are the table below.
- Tested extension commit: `f9013a0f0f7a68a4621a3aa0e49b832e40b540c2`, the head of `main` when the merged-commit run started. No fix of this run lands before it; the required fixes are in § Unresolved required fixes.
- Evidence: run directory `tmp/pi-update/run.R6KEmY`. On the tested commit, `merged.64GnlF` holds `git archive` of `pi-extensions` and of the paths outside it the pi-hooks suite reads (`crates/core/src`, `hooks`, `.pi/kendex/hooks`, `kendex.toml`, `skills`), with the step 4 checks copied in. There, Pi 1.0.0 resolved from every extension entry file and suite directory of all 18 packages (`logs/merged/version-proof.log`, 40 paths); every one of the 18 packages loads from its manifest into a real session and answers one prompt (`logs/merged/<package>.load.log`); 211 value imports from `@earendil-works/pi-*` across the 18 packages resolve to a Pi 1.0.0 export (`logs/merged/import-check.log`); the pi-hooks, pi-tool-renderer, pi-codex-minimal-tools and pi-qol suites pass 213, 131, 164 and 269 package tests, and the pi-codex-minimal-tools typecheck is clean; the checks under § Checks give the results listed there. The work copy `work.rzroka` (base `e5d6ed8f`, whose `pi-extensions` tree equals the tested commit's) gave the same counts at Pi 1.0.0 (`logs/`); its package installs were removed afterwards to free disk, and its check files and fix probes remain. The `agent_before_settle` and `session_shutdown` field check also ran on Pi 0.87.1 (`work.nfS5yz`) and Pi 0.86.1 (`work.6aVimC`), each version proven the same way.

Every `### Breaking Changes` entry in range was read against `pi-hooks/pi-contract.json`, across every source. Neither names an event or call pi-hooks uses. The `ExtensionAPI`, `ExtensionContext` and event declarations of Pi 1.0.0 differ from 0.99.1 only in one added optional field, `ToolNamespace.instructions`; the `pi-coding-agent`, `pi-ai` and `pi-tui` runtime export lists remove nothing.

| Release | Source | Entry | Names from the contract | Result |
|---|---|---|---|---|
| 1.0.0 | `agent` | The experimental harness leaves `@earendil-works/pi-agent-core`: `AgentHarness`, sessions and storage, compaction, skills, prompt templates, harness tools, telemetry schemas, the `uuidv7` re-export, and the `./node`, `./harness/*` and `./experimental/pico3` subpaths | none by name. The 142 runtime exports it removes include `formatSize` and `truncateTail`, which the contract lists from `@earendil-works/pi-coding-agent`. | Not blocking. `pi-coding-agent` 1.0.0 still exports and runs both. The only `pi-agent-core` import in any package is `pi-qol`'s `import type { AgentMessage }`, erased at load; `AgentMessage` is still exported. The import check turns red on a copy of `pi-qol` that imports `uuidv7` from `pi-agent-core`. |
| 1.0.0 | `server` | `SessionMetadata` exported by `@earendil-works/pi-server`, which drops its `pi-agent-core` dependency; `TestServerHost` and `TestHarness` change | none | Not blocking. No package imports `pi-server`. |

## Counts

| Bucket | Count |
|---|---:|
| Required parity fix (open, this range) | 2 |
| Blocking | 0 |
| Optional improvement (deferred) | 4 |
| Non-impact | grouped below, not tallied |

## Unresolved required fixes

Neither fix is applied by this run. For each, the check fails on the tested commit and on the work copy at Pi 1.0.0, its control passes, and the same check passes on a probe copy that carries the fix described (`pi-codex-minimal-tools-fixprobe`, `pi-tool-renderer-fixprobe` in `work.rzroka`), whose full package suites also pass (166 and 133 tests, the pi-update checks included).

| Item | Extension | Pi entry | What it shows | Fix |
|---|---|---|---|---|
| KEN-2671 | `pi-codex-minimal-tools` | `ai` 1.0.0 Fixed: Responses requests failing with `Expected an ID that begins with 'ctc'` when replaying grammar tool calls from another provider (upstream `bc2d8dc1`) | The vendored `convertResponsesMessages` in `src/providers/openai-responses-shared.ts` keeps the old condition: a foreign grammar call, whose item id Pi normalizes to `fc_*`, replays as a `custom_tool_call` with `id: "fc_…"`, which OpenAI refuses. Reached by a session that switches to an `openai-codex` model after another provider made a grammar tool call. | In the `toolCall` branch, replace `if ((isDifferentModel && itemId?.startsWith("fc_")) \|\| (customInputProperty === undefined && !itemId?.startsWith("fc_"))) itemId = undefined;` with `const itemIdPrefix = customInputProperty === undefined ? "fc_" : "ctc_"; if (isDifferentModel \|\| !itemId?.startsWith(itemIdPrefix)) itemId = undefined;`, Pi 1.0.0's condition. A parity case goes in `tests/provider-shim-parity.test.ts`. |
| KEN-2187 | `pi-tool-renderer` | `coding-agent` 0.99.2 Fixed: the `built-in-tool-renderer.ts` and `minimal-mode.ts` examples removing the built-in tools' summaries and guidelines from the system prompt ([#10072](https://github.com/earendil-works/pi/issues/10072), [#10193](https://github.com/earendil-works/pi/pull/10193)) | The renderer builds its replacement `read`, `bash`, `grep`, `find` and `ls` (and `edit`, `write` when `renderMutationTools` is on) from `create<Tool>Tool()`, the pattern Pi's example dropped, and `piToolContract` in `extensions/tool-renderer/tools.ts` copies no `promptSnippet` or `promptGuidelines`. With the renderer loaded, the session's system prompt loses all five tools' snippets and the read guideline. | Source both fields from Pi's tool definition: for each replaced tool, read `agent.create<Tool>ToolDefinition(cwd)` and add its `promptSnippet` and `promptGuidelines` to the registered definition beside `piToolContract(original)`, with a contract-test row per tool. |

## Checks

Each check runs on the tested commit (`merged.64GnlF`) at Pi 1.0.0, with the same result as on the work copy.

| Check | Surface | Result | Control |
|---|---|---|---|
| `pi-codex-minimal-tools/tests/pi-update-grammar-replay-id.test.ts` | A real session with the shim, history holding an `anthropic` grammar tool call, sent to `openai-codex` `gpt-6-astra` at a stubbed endpoint | Fail: the replayed `custom_tool_call` carries `id=fc_109pmnaixmdh7`. | Pi's own `openai-codex` provider, same session, sends the call with no item id. |
| `pi-tool-renderer/extensions/__tests__/pi-update-prompt-guidance.test.ts` | `session.systemPrompt` with the renderer loaded | Fail: the snippets of `read`, `bash`, `grep`, `find`, `ls` and the read guideline are missing. | The same session without the renderer carries all six. |
| `pi-hooks/tests/pi-update-settle-shutdown-fields.test.ts` | `agent_before_settle` `outcome` and `session_shutdown` `reason`, with pi-hooks loaded from its manifest | Pass on Pi 1.0.0 and on Pi 0.87.1: a completed run settles with `outcome=completed`, a run whose model answers with an error settles with `outcome=error`, and `session.reload()` emits `reason=reload`. | On Pi 0.86.1 no `agent_before_settle` fires and the check fails. |
| `<package>/<test dir>/pi-update-load-check.mjs`, all 18 packages | Manifest load into a real session, one prompt | Pass: no load or runtime error, one request, answer `done`. | Pi loads extensions through jiti, so a value import Pi no longer exports loads as `undefined` instead of failing: the planted `uuidv7` import passes this check. The import check below covers that case. |
| `pi-update-import-check.mjs` | Every value import from `@earendil-works/pi-*` in the 18 packages' non-test sources, against the copy's Pi 1.0.0 | Pass: 211 imports, none missing. | A copy of `pi-qol` importing `uuidv7` from `pi-agent-core` fails it. |
| `pi-tool-renderer/extensions/__tests__/pi-update-real-components.test.ts` | The renderer's patches of Pi 1.0.0's real `UserMessageComponent.render` and `Markdown.renderToken` | Pass: a user message with a code block renders in the compact frame inside the width; a patched `Markdown` renders its code block and text. | None; a smoke check for the `UserMessageComponent` Box removal and the `Markdown` cache change. |

Fields for the pi-hooks wiring that follows this audit: `AgentBeforeSettleEvent` extends `BoundaryState`, whose `outcome: AgentActivityOutcome` is `"completed" | "aborted" | "error"`. Both the event and the field first appear at `v0.87.0` (absent at `v0.86.1`), and `agent-session.ts` passes `outcome: this._lastActivityOutcome` when it emits the event at `v0.87.0`, `v0.99.1` and `v1.0.0`. `SessionShutdownEvent.reason` is `"quit" | "reload" | "new" | "resume" | "fork"` from `v0.68.0` (the event has no fields at `v0.67.68`), unchanged through 1.0.0, with `targetSessionFile` beside it. pi-hooks' peer floor, `>=0.87.0`, carries both. The `aborted` outcome was read from the source, not run.

Observed while running the field check in the work copy, outside the range: with pi-hooks loaded under the kendex tree, the project's Stop hooks (`lane-mail-check`, `session-drift-check`) spoke at the end of an errored run and continued it, so the errored run was followed by a completed one. Without pi-hooks the errored run settles once. On the tested commit's copy the hooks stayed silent and the errored run settled once.

## Deferred (Optional)

| Item | Reasoning |
|---|---|
| `ctx.modelRegistry.generateImages()` (`coding-agent` 1.0.0) | `pi-codex-minimal-tools` generates images through the Responses `image_generation` tool on `openai-codex`, with a direct-API fallback. Pi's image models are a different path; adopting them is a design choice for the package. |
| `@earendil-works/pi-ai/models` entry point (`ai` 0.99.2) | Packages import `StringEnum` and model types from `pi-ai`; the lighter entry skips TypeBox, the built-in catalogs and provider SDKs at load. No package needs it for correctness. |
| `TuiAltScreen.getScreenLines()` (`tui` 1.0.0) | No package reads the rendered screen. |
| `quietStartup: "header"` (`coding-agent` 1.0.0) | A user setting; no package writes `quietStartup`. |

## Non-impact

Checked against an extension surface:

- **Fullscreen TUI by default (`coding-agent` 1.0.0)**: the extensions' components render through the same `Component` API; the real-component check covers the renderer's message patches. The load check runs headless, so no interactive fullscreen session was run. `pi-qol`'s notifications write terminal escape sequences to the tty, not visible text.
- **User messages keep one copy of each rendered line; `UserMessageComponent` drops its `Box` (`coding-agent` 1.0.0)**: `pi-tool-renderer`'s compact frame reads `text` and `markdownTheme`, both still present; its `contentBox` path was already unused, since 0.99.1 kept the Box in a local variable. Real-component check above.
- **`Markdown` holds parsed tokens weakly; `Markdown`, `Text` and `Box` flatten cached lines (`tui` 1.0.0)**: `pi-tool-renderer` patches `Markdown.prototype.renderToken`, which keeps its signature; `pi-background-tasks` and `pi-tool-renderer` cache their own lines in their own components.
- **`--provider` without `--model` now fails (`coding-agent` 1.0.0, [#10236](https://github.com/earendil-works/pi/issues/10236))**: `pi-agents-tmux` launches child Pi processes with `--model` and never `--provider`.
- **Extension commands without a string name or handler fail to load (`coding-agent` 0.99.2, [#10054](https://github.com/earendil-works/pi/issues/10054))**: all 18 packages load with no error.
- **Saved default model ignored for an extension-registered native provider with a stored credential (`coding-agent` 0.99.2, [#9962](https://github.com/earendil-works/pi/issues/9962))**: a Pi fix that `pi-claude-bridge`'s native provider gains; the bridge holds no workaround for it.
- **Provider retries on an unparseable `Retry-After` date use exponential backoff (`ai` 0.99.2, [#9571](https://github.com/earendil-works/pi/issues/9571))**: the fix is in Pi's `provider-retry.ts`; the shim never reads `Retry-After` and already backs off exponentially. `pi-qol`'s rate-limit resume parses the header itself.
- **MCP tool and namespace names replace `-` with `_` (`coding-agent` 0.99.2, [#10239](https://github.com/earendil-works/pi/issues/10239))**: the `mcp__` names in `pi-claude-bridge` are Claude Agent SDK names, not Pi MCP tools.
- **`/reload` enables tools newly added to `defaultTools` (`coding-agent` 0.99.2, [#10245](https://github.com/earendil-works/pi/issues/10245))**: no package reads or writes `defaultTools`; `pi-codex-minimal-tools` manages only its own tool names.
- **`codemode` and MCP: servers leave the `codemode` description, an `mcp_servers` system prompt section, background connects, `describeNamespace()`, leaner prompts, recovery errors, `"name" in tools`, `models.generateImages()`, image validation, the Windows worker, `codemode.mode: "only"` (`coding-agent`, `codemode` 0.99.2 and 1.0.0)**: no package imports `pi-codemode` or `pi-mcp`, registers a namespace, or reads the codemode description.
- **`ToolNamespace.instructions` (`coding-agent` 1.0.0 types)**: an added optional field; no package registers a namespace.

Provider, catalog and host behaviour (our overrides are `openai-codex` in `pi-codex-minimal-tools` and the Claude native provider in `pi-claude-bridge`):

- **Anthropic copy code login and workload identity federation, OAuth logo, Z.AI CN overflow detection, Anthropic strict-tool keyword fallback ([#9953](https://github.com/earendil-works/pi/issues/9953)) (`ai` 0.99.2 and 1.0.0)**: `pi-claude-bridge` drives the Claude Agent SDK, not Pi's Anthropic transport.
- **Radius in `/login`, MCP OAuth hardening, `oauth.clientName`, `oauth.authServerMetadataUrl`, provider-token MCP auth, per-server MCP credentials, `/login` and `/logout` labels, the `mcp` package fixes (0.99.2 and 1.0.0)**: host sign-in and MCP features no package touches.
- **Prompt submission and model lookup speedups, the Apple Terminal logo, the system theme's pastel palettes, fullscreen selection color bleed, slash completion after whitespace, transcript memory, the provider docs rename (0.99.2 and 1.0.0)**: Pi host behaviour.
- **`durable` initial release (1.0.0)**: no package imports it.

## Run notes

- The step 4 install used the form KEN-2244 records (`install-target.sh` in the run directory): it removes `peerDependencies` and the Pi `devDependencies` from the copy's `package.json` for the install, installs every Pi package the manifest names at 1.0.0, then restores the file.
- The pi-hooks suite reads files outside `pi-extensions`: `crates/core/src`, `hooks/`, `.pi/kendex/hooks/`, `kendex.toml`, and `skills/orch/scripts/lane-mail`. A copy of `pi-extensions` alone fails 52 of its tests on the missing files. The run copied those paths beside `pi-extensions` in `work.rzroka`.
- Suites that call `os.tmpdir()` wrote their fixtures under `/tmp`; the pi-update checks keep theirs under the work copy.
- `openai-codex` request shape, outside the range: on models with `supportsAdditionalTools`, Pi's own provider declares tools in an `additional_tools` input item; the shim declares them in the top-level `tools`. Pi 0.99.1 already does this. No check measured what the difference changes.
