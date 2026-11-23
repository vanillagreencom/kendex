# Pi package update audit: 1.0.1 to 1.6.0

Marker `1.0.1` → `1.6.0`. Run-start extension head: `e32c59e138871886379e42756eb572dd38dc3627`. The range holds eleven Pi releases: 1.0.2 (2026-10-04), 1.0.3 and 1.0.4 (2026-10-05), 1.1.0 (2026-10-07), 1.2.0 (2026-10-12), 1.3.0 (2026-10-15), 1.4.0 (2026-10-21), 1.5.0 (2026-11-02), 1.5.1 (2026-11-09), 1.5.2 (2026-11-10) and 1.6.0 (2026-11-20). Every released entry above the previous marker and at or below the target was classified; Unreleased blocks were not.

## Verdict

Verdict: `roll`.

- Target release: `1.6.0`, npm `@earendil-works/pi-coding-agent@1.6.0` integrity `sha512-zX1BVEsshx7A2MRuQ6jfr3RJGWw4Wn+vLq5ZfmlvS1RskhRmByaSZVXH/zcwRrWHO7qPgs98pNCbPOEti/t0fQ==`, upstream source commit `faac585884ae2c013a6b1400f3e9e77f10b34bac`.
- Entries examined: every entry of Pi 1.0.2 through 1.6.0 across all eleven target changelogs, 1,081 literal bullets including 37 coding-agent New Features summaries. The 128 Breaking Changes entries are listed below. Blocking entries: 2, coding-agent 667 and 668, both cleared by a real Pi session check. Required parity fixes: 33 entries in three filings, none landed in this audit.
- Tested extension commit: `27d49aa5daf025b12d0498304a80bb190fbfb9fa`.
- Evidence: `tmp/pi-update/run.ZlBrHI`, with the exact merged-main proof in `merged.VpWrjx`. Pi 1.6.0 resolved from every touched package's extension entry and suite directory before the checks and suites (`merged.VpWrjx/logs/version-proof.log`, exit 0). The pi-hooks check passed 4 of 4 tests in real Pi sessions; its regression controls fail on Pi 1.0.1 (`work.xGveD6/logs/check-pi-hooks.log`). The three Required checks pass their control rows and fail their package rows, the gaps the filings name. Suites: pi-hooks 247 of 247 (on a rerun; § Checks), pi-tool-renderer 142 of 143, pi-web-tools 428 of 428, and pi-codex-minimal-tools 172 of 187, each failure accounted for in § Checks as a Pi-caused test expectation, Filing A, or a host cause shared with the package's pinned Pi.

npm publishes no `gitHead` for 1.6.0, so the npm package is bound to the upstream tag by content: the captured tarball's SHA-512 matches the registry integrity, and all 263 source-map `sourcesContent` entries equal the files at `v1.6.0` (`npm-source-mapping.json`). The same comparison against `v1.0.1` reports 136 mismatches and 22 missing files (`npm-source-mapping-control-v1.0.1.json`), so the binding rejects another tag.

Every Breaking Changes entry in range, from every source, was checked against the current `pi-hooks/pi-contract.json`. A one-word member (`pi.on`, `ctx.signal`, `pi.events.on`, `ctx.ui.notify`) matches only in its qualified form, every other name bare or qualified. The inventory and every comparison are in `breaking-contract-check.json`.

The two blocking entries change when a starting run counts as busy and when `before_agent_start` fires. pi-hooks needs no change for either: `lane-mail-wake.ts` judges mail only while `ctx.isIdle()` is true and always sends with `deliverAs: "followUp"`, and `hooks.ts` registers no `before_agent_start` handler. § Checks gives the session check that shows it.

## Filings

Each Required parity fix is filed as one item per owner, at priority High (2), with the text below. A filing also carries its package's deferred Optional entries and its Pi-caused suite expectations, each marked as such; neither counts as a Required entry. The identifiers replace the letters below once filed.

- Filing A, pi-codex-minimal-tools (ai 19, 26, 27, 28, 30, 60, 64, 66, 74, 75, 92, 94, 106, 111, 117, 118, 128, 153; coding-agent 369, 375, 379, 380, 381, 473, 528, 622, 624, 632, 637, 648, 658, 734): the openai-codex shim in `src/provider-shim.ts` and `src/providers/openai-responses-shared.ts` copies Pi's provider, and Pi changed the copied code in this range. On gpt-6.2-sol the shim sends top-level `instructions` where Pi sends the system prompt as a developer input item, top-level `tools` where Pi declares them in `additional_tools` input items, no `max_output_tokens`, the `session_id` header where Pi sends `session-id` (a difference that predates this range), and the User-Agent `pi (<platform> <release>; <arch>)` where Pi sends `pi/<version> (...)`. The parity suite's three reasoning-effort rows fail at 1.6.0 because Pi now sends effort `none` for Off. The other entries change copied code the check does not drive: the configuration_update thinking-level items, the 45-minute WebSocket age and mid-stream connection-limit retry, abort-listener cleanup, incremental tool-call argument parsing, grammar input deltas, the strict-mode fallback, whitespace-only tool output, cross-model thinking, malformed-argument errors and header precedence. When the shim adopts `additional_tools`, its own `src/provider-native-tools.ts::rewriteNativeOpenAiTools`, which the `before_provider_request` handler in `src/index.ts` calls, must follow the tools into input items, as Filing B describes. Optional in the same item: the shim emits no `openai_input_transformations` assistant message diagnostics (ai 12), so its users get no transcript notice when OpenAI drops reasoning items (coding-agent 330); and `registerSessionResourceCleanup()` from `@earendil-works/pi-ai/session-resources` (ai 13) could release `src/provider-shim.ts::websocketSessionCache` entries per session instead of by their five-minute expiry. Suite expectation in the same item: four `tests/model-properties.test.ts` rows compare the cost object exactly and fail at 1.6.0 on `totalFromProvider` (ai 68); they pass on the package's pinned Pi.
- Filing B, pi-web-tools (ai 111, coding-agent 624): `src/native-openai.ts::rewriteNativeOpenAiWebSearch` rewrites only top-level `payload.tools`. Pi's openai provider declares every tool of a model with `supportsAdditionalTools` and `supportsMidConvoSystemMessages`, gpt-6.2-sol and the other GPT-5.6 and GPT-6 models among them, in `additional_tools` input items, so with `defaultProvider: "openai-native"` the model receives `web_search` as a function tool, and calling it returns the "should be rewritten" notice instead of a search.
- Filing C, pi-tool-renderer (coding-agent 338): Pi's `read` now records `details.imageUnsupportedByModel` instead of a text note, and Pi's read renderer draws the warning collapsed and expanded. `extensions/tool-renderer/tools.ts::createReadRenderers` replaces that drawing and never shows it, so a person reading an image on a text-only model is not told the model saw a placeholder. Suite expectation in the same item: `extensions/__tests__/user-message-layout.test.ts` asserts the highlighter runs again after a width change and fails at 1.6.0, where Pi's Markdown reuses highlighted blocks across a resize (tui 1056); it passes on the package's pinned Pi.

## Sources and counts

The run enumerated every changelog in the current upstream main snapshot and at the target tag: `agent`, `ai`, `chord`, `codemode`, `coding-agent`, `durable`, `env`, `mcp`, `schema`, `telemetry` and `tui`. Both snapshots hold the same 1,081 in-range bullets with the same text. `schema` is new since the last record. `client`, `protocol` and `server`, present in the last marker, exist through `v1.1.0` and are gone from `v1.2.0` and main; their `v1.1.0` changelogs were fetched and hold no entry in range. The release website <https://pi.dev/news/releases>, which redirects to <https://pi.dev/changelog>, lists 1.0.2 through 1.6.0, the same releases as npm and the changelogs.

The import triage, run on this tree, finds packages that import `@earendil-works/pi-agent-core`, `pi-ai`, `pi-coding-agent` and `pi-tui`, and none that imports `pi-chord`, `pi-codemode`, `pi-durable`, `pi-env`, `pi-mcp`, `pi-schema` or `pi-telemetry`. Entries from those seven sources are Non-impact. The registered providers are openai-codex in pi-codex-minimal-tools, pi-claude-bridge's Claude Agent SDK provider and pi-codex-bridge's app-server provider; the `before_provider_request` handlers are in pi-codex-minimal-tools, pi-web-tools and pi-qol.

Raw evidence under `tmp/pi-update/run.ZlBrHI`:

- `sources/tree-main.json`, `sources/tree-target.json`, `sources/changelog-keys-per-tag.txt` and the changelogs under `sources/main`, `sources/v1.6.0` and `sources/v1.1.0`; `sources/releases.html` is the website cross-check.
- `npm-view.json`, `upstream-tag-sha.txt`, `npm/earendil-works-pi-coding-agent-1.6.0.tgz`, `npm-source-mapping.json`; `src-v1.0.1` and `src-v1.6.0` hold the upstream source read for each classification.
- `import-triage.txt` and `import-inventory.txt`: the packages and symbols each Pi package reaches.
- `entries-target.json` holds each raw bullet and its source line; `classified-entries.json` holds every classification with its reason; `scripts/classify.mjs` is the rule set that wrote it.

| Bucket | Literal bullets, including summaries | Bullets excluding New Features summaries |
|---|---:|---:|
| Required parity fix | 33 | 32 |
| Optional improvement | 13 | 13 |
| Non-impact | 1,035 | 999 |
| Total | 1,081 | 1,044 |

| Source | Entries | Required | Optional | Non-impact |
|---|---:|---:|---:|---:|
| `agent` | 7 | 0 | 1 | 6 |
| `ai` | 151 | 18 | 2 | 131 |
| `chord` | 145 | 0 | 0 | 145 |
| `codemode` | 21 | 0 | 0 | 21 |
| `coding-agent` | 441 | 15 | 9 | 417 |
| `durable` | 197 | 0 | 0 | 197 |
| `env` | 15 | 0 | 0 | 15 |
| `mcp` | 21 | 0 | 0 | 21 |
| `schema` | 18 | 0 | 0 | 18 |
| `telemetry` | 14 | 0 | 0 | 14 |
| `tui` | 51 | 0 | 1 | 50 |

## Classified entries

Entry numbers index `entries-target.json`: sources in alphabetical order, and within a source each release from newest to oldest, in changelog order. No entry in range adds a field to a tool result, an extension event or a provider stream option that a kendex listener or override consumes. The only fields this range adds to those surfaces are `durationMs` on tool results and `tool_execution_end` events (agent 6, coding-agent 710) and `details.imageUnsupportedByModel` on `read` results (coding-agent 338, Filing C). The `tool_result` listeners in pi-hooks, pi-nested-agents-md, pi-output-policy and pi-qol read no field this range changed, and neither does pi-tool-renderer's `extensions/tool-renderer/tools.ts::registerWriteDiffEvents`, the opt-in write diff armed by `renderMutationTools`: it reads `toolCallId`, `toolName`, `isError`, `details` and `input` of `write` results only. The `tool_execution_end` listeners, in `registerWriteDiffEvents` and `extensions/tool-renderer/stack.ts`, read `toolCallId`, `result` and `isError`, not `durationMs`. The provider overrides are covered by Filing A.

`pi update` reconciles only `git:` and `npm:` entries in Pi's settings, so entries about it do not reach kendex's path packages. pi-tool-renderer draws read, bash, grep, find and ls through `pi.registerToolRenderer` and replaces no tool execution, so fixes to those tools reach its users; a change to how Pi draws them is a choice for the user, not an automatic mirror.

### Breaking Changes entries

| Entry | Release | Source | Entry | Names from the pi-hooks contract | Result |
|---:|---|---|---|---|---|
| 3 | 1.5.0 | `agent` | `AgentTool` takes any JSON Schema object as `parameters` (`AgentTool<TParameters extends object>`) and types `params` and `prepareArguments` throug… | None. | Not blocking. Extensions build parameters with TypeBox imported from `typebox`, which Pi 1.6.0's loader still aliases to its bundled copy (core/extensions/loader.ts getAliases); the kinds used (Object, String, Number, Boolean, Array, Optional, StringEnum) keep their static types; pi-web-tools, which builds its tool schemas this way, passes its suite at 1.6.0. |
| 34 | 1.5.1 | `ai` | `openai-completions` no longer sends `"tools": []` when a request has no tools but the conversation contains tool calls or tool results; the field… | None. | Not blocking. Openai-completions request field; no extension builds or overrides openai-completions requests (pi-qol gateway-privacy edits only privacy fields). |
| 61 | 1.5.0 | `ai` | The main entry no longer re-exports TypeBox (`Type`, `Static`, `TSchema`), and `typebox` is no longer a dependency. `Tool.parameters` is any JSON S… | None. | Not blocking. Pi-ai no longer re-exports TypeBox. Extensions import `Type` from `typebox`, which Pi's loader aliases, and `StringEnum` from pi-ai, which keeps its JSON (`{ type: "string", enum }`); pi-web-tools, which combines the two, passes its suite at 1.6.0. |
| 62 | 1.5.0 | `ai` | Tool arguments are validated as JSON Schema only; nothing runs through TypeBox's own validator any more, so TypeBox features outside JSON Schema no… | None. | Not blocking. No extension uses Type.Refine, BigInt, Undefined, Void, Codec or Format.Set (grep of pi-extensions). |
| 63 | 1.5.0 | `ai` | A `$ref` that names nothing (a missing definition, an external document) rejects only arguments at its place (`- t: unresolved reference #/definiti… | None. | Not blocking. Unresolved $ref handling; no extension declares a $ref in tool parameters. |
| 64 | 1.5.0 | `ai` | `appendGrammarToolInputJsonDelta()` (`api/constrained-sampling`) takes the input delta instead of the whole input so far and no longer closes the i… | None. | Not blocking. Required parity fix: Filing A (codex shim parity). |
| 91 | 1.4.0 | `ai` | Renamed provider request option `telemetryContext` to `telemetry?: TelemetrySpan`, without a compatibility alias. Pass a parent span, not an adapter. | None. | Not blocking. No extension passes telemetryContext (grep). |
| 92 | 1.4.0 | `ai` | The default `User-Agent` is now `pi/<version> (<platform>; <runtime>; <arch>)` instead of `pi (<platform> <release>; <arch>)`, and `@earendil-works… | None. | Not blocking. Required parity fix: Filing A (codex shim parity). |
| 93 | 1.4.0 | `ai` | `resolveTranscriptTools()` now takes a `TranscriptToolSupport` (`"none"`, `"additions"`, or `"changes"`) instead of a boolean, and `TranscriptTools… | None. | Not blocking. No extension calls resolveTranscriptTools or reads anchorsAdditions (grep). |
| 114 | 1.3.0 | `ai` | Removed `AssistantMessageFrame`, `AssistantMessageFrameEncoder`, and `reduceAssistantMessageFrames()`. They were only used by the removed experimen… | None. | Not blocking. No extension uses AssistantMessageFrame or reduceAssistantMessageFrames (grep). |
| 136 | 1.1.0 | `ai` | A stream function must return an `AssistantMessageEventStream`, for example from `createAssistantMessageEventStream()`; a hand-written `EventStream… | None. | Not blocking. Every extension stream function returns a stream from Pi's createAssistantMessageEventStream (pi-codex-bridge src/bridge.ts, the shim src/provider-shim.ts, pi-claude-bridge src/index.ts::newAssistantMessageEventStream); none subclasses EventStream. |
| 155 | 1.0.3 | `ai` | Renamed the Azure provider from `azure-openai-responses` to `azure`, since it now serves Chat Completions as well as the Responses API. Use `getMod… | None. | Not blocking. Azure provider rename; pi-qol/extensions/qol/statusline.ts maps the old id to a label only, and the `azure-openai-responses` api id is unchanged. |
| 159 | 1.6.0 | `chord` | `createWorkers` requires `store`, the store given to the server host's `createHost` (`undefined` only for a host without one): a worker's exit is p… | None. | Not blocking. No extension imports pi-chord. |
| 160 | 1.6.0 | `chord` | `telemetryIngestFacet` requires `admit(principal)`: only the pages of principals it admits may send their spans to `PageTelemetry`; a refused princ… | None. | Not blocking. No extension imports pi-chord. |
| 161 | 1.6.0 | `chord` | `HostError` `query_failed` carries `query` (the table's name for `self.query`, the named query's label for `self.liveQuery`, `self.count` and `self… | None. | Not blocking. No extension imports pi-chord. |
| 185 | 1.5.1 | `chord` | Chord v2 is the package's root: `@earendil-works/chord` exports v2 (was `@earendil-works/chord/next`). Chord v1 moved unchanged to `@earendil-works… | None. | Not blocking. No extension imports pi-chord. |
| 186 | 1.5.1 | `chord` | Chord v1 (`@earendil-works/chord/old`, `@earendil-works/chord/old/node`) removed, with its tests and docs (`src/old`, `test/old`, `docs/old`). Apps… | None. | Not blocking. No extension imports pi-chord. |
| 187 | 1.5.1 | `chord` | Chord v2's `startWorker` no longer takes `telemetry` (it was added unreleased in slice 9): with a telemetry store on the server, the kit's workers… | None. | Not blocking. No extension imports pi-chord. |
| 188 | 1.5.1 | `chord` | Chord v2's `createWorkers` returns a promise and rejects when the worker base does not build (decision "Workers start from the base code the server… | None. | Not blocking. No extension imports pi-chord. |
| 189 | 1.5.1 | `chord` | Chord v2's `host.reload` restarts every live object of a changed plugin; the pure swap in place is removed (decision "Reload restarts every affecte… | None. | Not blocking. No extension imports pi-chord. |
| 221 | 1.5.0 | `chord` | Schemas are JSON Schema checked by `@earendil-works/pi-schema` instead of TypeBox, which is no longer a dependency of Chord. Contracts, `self.state… | None. | Not blocking. No extension imports pi-chord. |
| 222 | 1.5.0 | `chord` | `traceIn(options, fn, context)` takes the context last (was `traceIn(context, options, fn)`), like the rest of the API. | None. | Not blocking. No extension imports pi-chord. |
| 223 | 1.5.0 | `chord` | Watch listeners take one change object before the context: `WatchHandle.start((change, context) => …)` with `change: WatchChange<T>` = `{ value, op… | None. | Not blocking. No extension imports pi-chord. |
| 224 | 1.5.0 | `chord` | `SqliteExecutor.runCounted(sql, ...params)` runs one statement like `run` and resolves with the rows it inserted, updated or deleted, as SQLite's `… | None. | Not blocking. No extension imports pi-chord. |
| 225 | 1.5.0 | `chord` | Retirement is a flag, not an end: `WatchEnd` loses `retired`, and `Watch.retire(context)` is removed. A source reports a retirement with `advance({… | None. | Not blocking. No extension imports pi-chord. |
| 226 | 1.5.0 | `chord` | Watch listeners get a tagged call, and a watch stays open through a failure its source recovers from: `WatchCall<T>` is `{ kind: "value", value, op… | None. | Not blocking. No extension imports pi-chord. |
| 227 | 1.5.0 | `chord` | `WatchEnd` is tagged by `kind` instead of `reason`, and a watch whose acquisition context is aborted ends `aborted` instead of `cancelled`: `{ kind… | None. | Not blocking. No extension imports pi-chord. |
| 248 | 1.4.0 | `chord` | Custom `Context` implementations must provide `telemetry: TelemetrySpan`; use the no-op span `NOOP_TELEMETRY_CONTEXT` when disabled. `withTelemetry… | None. | Not blocking. No extension imports pi-chord. |
| 253 | 1.3.0 | `chord` | Terminology follows the concepts: a reference (what `get` returns) is `Ref<C>` (was `Handle<C>`), its status `RefStatus` (was `HandleStatus`); what… | None. | Not blocking. No extension imports pi-chord. |
| 254 | 1.3.0 | `chord` | A remote object's variant is named `variant` (was `kind`): factories return `{ variant: "editor", … }`, references expose `ref.variant` and `shape.… | None. | Not blocking. No extension imports pi-chord. |
| 255 | 1.3.0 | `chord` | Links have a protocol version (`PROTOCOL_VERSION`, now 2), announced in `hello`. Peers of different versions do not talk: the side that notices clo… | None. | Not blocking. No extension imports pi-chord. |
| 256 | 1.3.0 | `chord` | `serve(…, { lifetime })` replaces `eager`: `"referenced"` (the default) creates an object at the first `get` of its address and disposes it after t… | None. | Not blocking. No extension imports pi-chord. |
| 257 | 1.3.0 | `chord` | Declarations are calls by name: `self.state(name, schema, initial, { version?, migrate? })` returns the cell, `self.resource(name, { version, deps?… | None. | Not blocking. No extension imports pi-chord. |
| 258 | 1.3.0 | `chord` | State versions belong to cells: `ServeOptions.state` is gone; a cell's `version` (default 1) and `migrate(old, from)` replace it. A raised version… | None. | Not blocking. No extension imports pi-chord. |
| 259 | 1.3.0 | `chord` | A derivation is new at every reload (computed at the commit) instead of kept with its function replaced. A listener whose state source a reload rep… | None. | Not blocking. No extension imports pi-chord. |
| 260 | 1.3.0 | `chord` | `method(args?, result?)`: without arguments a method is called `ref.name(ctx?)` and implemented `(ctx) => …`; without a result it is void (callers… | None. | Not blocking. No extension imports pi-chord. |
| 261 | 1.3.0 | `chord` | Remote contracts declare where their objects live, and callers no longer name a host: `remote(name, { …, host: hostNamed("server") })` or `host: ho… | None. | Not blocking. No extension imports pi-chord. |
| 262 | 1.3.0 | `chord` | `FacetApi` has a `signal` (below): code that builds a `FacetApi` by hand, for example to wrap `serve`, must pass it on | None. | Not blocking. No extension imports pi-chord. |
| 263 | 1.3.0 | `chord` | Principals are typed and supplied by the app: `createHost<P>`, `Host<P>`, `defineFacet<P>`, `FacetApi<P>`, `Serve<P>`, `Factory<C, P>`, `Self<P>`,… | None. | Not blocking. No extension imports pi-chord. |
| 264 | 1.3.0 | `chord` | `serve(type, factory, { lifetime: "host" })` compiles only for a local type whose input has no required fields, and without `linger`; `serve` still… | None. | Not blocking. No extension imports pi-chord. |
| 265 | 1.3.0 | `chord` | An awaited reference has its state, local or remote. `ctx.get` and `host.get` are async: they resolve once the reference is live and every state me… | None. | Not blocking. No extension imports pi-chord. |
| 266 | 1.3.0 | `chord` | State members are typed `T` (was `T \| undefined`) and `StateSource<T>` is `Readable<T>`. Reading state before the first hydration throws `not_read… | None. | Not blocking. No extension imports pi-chord. |
| 267 | 1.3.0 | `chord` | A remote reference stays subscribed to its variant's state while held, with or without listeners (it no longer forgets its value when the last list… | None. | Not blocking. No extension imports pi-chord. |
| 268 | 1.3.0 | `chord` | `Shape.codeVersion` and the `shape` frame's `codeVersion` are gone | None. | Not blocking. No extension imports pi-chord. |
| 269 | 1.3.0 | `chord` | `PROTOCOL_VERSION` is 4: a `hold` implies the state of its variant (`state: false` opts out until `sub`; `unsub` stops it); the provider answers wi… | None. | Not blocking. No extension imports pi-chord. |
| 297 | 1.2.0 | `chord` | Replaced the facet and service runtime with a typed host runtime: contracts (`local`, `remote`, `method`, `opaque`) are runtime values described wi… | None. | Not blocking. No extension imports pi-chord. |
| 298 | 1.2.0 | `chord` | Removed `defineService`, `createFacetHost`, `createRemoteServiceBinding`, `createStaticFacetLoader`, `combineFacetLoaders`, the remote-service endp… | None. | Not blocking. No extension imports pi-chord. |
| 299 | 1.2.0 | `chord` | Removed the `./bundler` export and the facet bundle loaders of `./node`; `./node` now exports the child host manager (`createHostManager`, `forkDri… | None. | Not blocking. No extension imports pi-chord. |
| 300 | 1.2.0 | `chord` | Removed `@earendil-works/pi-client`, `@earendil-works/pi-protocol`, and `@earendil-works/pi-server`, which served only the old runtime; they are no… | None. | Not blocking. No extension imports pi-chord. |
| 308 | 1.3.0 | `codemode` | Worker-backed results and `close()` now settle after requesting shutdown, not after worker exit. Hosts that require actual exit must track `onWorke… | None. | Not blocking. No extension imports pi-codemode. |
| 312 | 1.2.0 | `codemode` | Removed `MCP_TYPESCRIPT_PREAMBLE` and `mcpStructuredContentSchema()`. `renderToolOutputType()` and the declarations built on it render every output… | None. | Not blocking. No extension imports pi-codemode. |
| 326 | 1.6.0 | `coding-agent` | Extension components: `render()` now returns `readonly string[]`, and `Container` returns the same cached array while its children are unchanged. E… | None. | Not blocking. Readonly render output. Every extension render path that post-processes lines builds a new array (map, slice, spread); a search for in-place push, splice, pop or index writes on render results found none. pi-tool-renderer's suite passes at 1.6.0 except one layout-cache expectation (tui entry 1056). |
| 397 | 1.5.1 | `coding-agent` | Custom `GrepOperations.readFile` callbacks are no longer called for context lines. The field remains accepted as optional and deprecated so existin… | None. | Not blocking. No extension supplies GrepOperations (grep). |
| 398 | 1.5.1 | `coding-agent` | OpenAI-compatible models no longer send `"tools": []` when all tools are disabled in a session that has used tools; the field is omitted. This fixe… | None. | Not blocking. Restates ai entry 34. |
| 494 | 1.5.0 | `coding-agent` | Tool argument validation runs on `@earendil-works/pi-schema`. TypeBox features outside JSON Schema (`Type.Refine()`, `Type.BigInt()`, `Type.Undefin… | None. | Not blocking. Restates ai entries 61 and 62. |
| 666 | 1.2.0 | `coding-agent` | Published generated configuration schemas for models, settings, keybindings, and themes at `https://pi.dev/schemas/*.schema.json`. The theme schema… | None. | Not blocking. Theme schema location; no extension ships a theme file (grep for theme JSON with $schema). |
| 667 | 1.2.0 | `coding-agent` | Changed `before_agent_start` to also fire for runs started by `pi.sendMessage(..., { triggerTurn: true })` while idle. `BeforeAgentStartEvent` is n… | `pi.sendMessage` | Blocking; cleared by the real Pi session check (§ Checks). Names pi.sendMessage. pi-hooks registers no before_agent_start handler, and the real Pi 1.6.0 session check shows its custom sends with triggerTurn start and reach a run. The other before_agent_start handlers (pi-qol, pi-task-panel, pi-background-tasks, pi-agents-tmux, pi-caveman) read only systemPrompt, systemPromptOptions or `prompt ?? ""`, so a custom-message run gets the same prompt additions. |
| 668 | 1.2.0 | `coding-agent` | Changed the session to count as busy while a run starts, including during `before_agent_start` handlers: `ctx.isIdle()` is false, `pi.sendMessage()… | `pi.sendMessage`, `ctx.isIdle`, `pi.sendUserMessage` | Blocking; cleared by the real Pi session check (§ Checks). Names ctx.isIdle, pi.sendMessage and pi.sendUserMessage. lane-mail-wake.ts judges only while ctx.isIdle() and always passes deliverAs: "followUp"; the real Pi 1.6.0 session check shows a starting run is busy, a bare send throws there, and the wake's followUp send is delivered, so pi-hooks needs no change. |
| 669 | 1.2.0 | `coding-agent` | Changed `pi mcp list --json` to report `resources: true` for servers that offer resources instead of `resources` and `resourceTemplates` counts; Pi… | None. | Not blocking. `pi mcp list --json`; no extension reads it. |
| 756 | 1.0.3 | `coding-agent` | Renamed the Azure provider from `azure-openai-responses` to `azure`. Rename the provider key in `auth.json` (or run `/login` again), in `models.jso… | None. | Not blocking. Restates ai entry 155. |
| 766 | 1.6.0 | `durable` | `RunEndTask` and `runEndTask` are renamed `HookTask` and `hookTask`, as `afterTools` and `onYield` hooks now ask for tasks too. Migration: rename t… | None. | Not blocking. No extension imports pi-durable. |
| 767 | 1.6.0 | `durable` | A tool's `execute()` returns `Promise<ToolExecutionResult \| ToolPark>`: it may park instead of returning a result. Code that calls a tool's `execu… | None. | Not blocking. No extension imports pi-durable. |
| 768 | 1.6.0 | `durable` | `until` is optional on sleeping task states (`TaskState`, `TaskInspection`, `TaskGraphState`): a sleep may wait for signals only. Code that reads `… | None. | Not blocking. No extension imports pi-durable. |
| 769 | 1.6.0 | `durable` | `durationMs` of a tool result (`ToolResultMessage.durationMs`, `NestedToolExecutionResult.durationMs`, nested slot summaries) is the span from the… | None. | Not blocking. No extension imports pi-durable. |
| 770 | 1.6.0 | `durable` | `pi.tool` is version 4 and `pi.generation` version 3; a database written by this version is not meant to be opened by an older Harness, which would… | None. | Not blocking. No extension imports pi-durable. |
| 771 | 1.6.0 | `durable` | Code-mode namespaces come from extensions, not name prefixes: `Extension.namespace` (`ToolNamespace`: `{ name, description, instructions? }`) group… | None. | Not blocking. No extension imports pi-durable. |
| 793 | 1.5.0 | `durable` | Tool schemas are JSON Schema typed through `@earendil-works/pi-schema`: `defineTool()` and `ToolRegistration` take any JSON Schema object as `param… | None. | Not blocking. No extension imports pi-durable. |
| 794 | 1.5.0 | `durable` | `SqliteExecutor` (re-exported from Chord) gains `runCounted(sql, ...params)`, resolving with the rows the statement changed; custom `SqliteDatabase… | None. | Not blocking. No extension imports pi-durable. |
| 795 | 1.5.0 | `durable` | `Storage.commit()` stores a group of commits in one call: `commit(batches, receive, context)` resolves with a `CommitResult` (`{ stored, refused? }… | None. | Not blocking. No extension imports pi-durable. |
| 796 | 1.5.0 | `durable` | `Storage.mintId()`'s contract is narrowed to IDs greater than every ID minted since the storage was opened and every ID stored, also across reopen.… | None. | Not blocking. No extension imports pi-durable. |
| 797 | 1.5.0 | `durable` | Watches use Chord's `WatchHandle` and `WatchEnd` (Durable re-exports both, with `WatchChange` and `NativeWatchChange`). End reasons are `stopped`,… | None. | Not blocking. No extension imports pi-durable. |
| 798 | 1.5.0 | `durable` | Watch listeners take one change object before the context: `watch.start(async ({ value, ops, retired }, context) => …)` for document, conversation… | None. | Not blocking. No extension imports pi-durable. |
| 799 | 1.5.0 | `durable` | Document watches follow their address (kind, scope, and key) instead of one incarnation: `DocumentWatch<T>` is `WatchHandle<Readonly<T>>` (no `null… | None. | Not blocking. No extension imports pi-durable. |
| 800 | 1.5.0 | `durable` | Document, conversation view, and task graph watches deliver the commits made while their listener runs (or before `start()`) in one callback: the n… | None. | Not blocking. No extension imports pi-durable. |
| 801 | 1.5.0 | `durable` | Removed the Chord state getters `Session.documentState()`, `Conversation.viewState()`, and `Harness.taskGraph()`, and the `DocumentState` type; use… | None. | Not blocking. No extension imports pi-durable. |
| 802 | 1.5.0 | `durable` | Partial answers and running tool output are stored later than they are shown: their throttled commits are deferred (`CommitPersistence`, spec §4.1)… | None. | Not blocking. No extension imports pi-durable. |
| 803 | 1.5.0 | `durable` | The change type of `FileSystem.watch()` in `@earendil-works/pi-durable/env` is renamed from `WatchChange` to `FileChange` (same shape: `{ paths }`,… | None. | Not blocking. No extension imports pi-durable. |
| 804 | 1.5.0 | `durable` | `HostCallback` gains `"telemetry"`: a `host_error` report about a telemetry adapter that threw while a commit was published. Exhaustive switches ov… | None. | Not blocking. No extension imports pi-durable. |
| 805 | 1.5.0 | `durable` | `ConversationView.entries` is a window over the transcript instead of the active transcript: the fork-aware history `Conversation.entries()` scans,… | None. | Not blocking. No extension imports pi-durable. |
| 806 | 1.5.0 | `durable` | `Conversation.watch(context, window?)` and `Harness.observeConversation(id, observer, context, window?)` take a `ConversationWindow` (`from`, `min`… | None. | Not blocking. No extension imports pi-durable. |
| 807 | 1.5.0 | `durable` | `pi.live` is no longer empty after a run that ended without an answer: it keeps `runFailure` (below) until a later run starts. Code that compares a… | None. | Not blocking. No extension imports pi-durable. |
| 808 | 1.5.0 | `durable` | Removed `watchEvents()` and its types `AgentEvent`, `AgentEventStream`, `SnapshotEvent`, `MessageChange`, and `ToolEventCall`, and spec §9.4. A ren… | `turn_end` | Not blocking: `turn_end` here is an event of pi-durable's own watch API, not the extension event, and no extension imports pi-durable. |
| 809 | 1.5.0 | `durable` | Restart-limited tasks no longer park: a task cut off `settings.restartLimit` times in a row ends instead, visibly. A tool call ends with an error r… | None. | Not blocking. No extension imports pi-durable. |
| 810 | 1.5.0 | `durable` | A generation whose model request was in flight when the host died no longer resends it on open: the attempt counts as failed under `settings.retry`… | None. | Not blocking. No extension imports pi-durable. |
| 811 | 1.5.0 | `durable` | Watch listeners and synchronous observers take Chord's tagged watch shapes. Durable re-exports `WatchCall` and `NativeWatchCall` instead of `WatchC… | None. | Not blocking. No extension imports pi-durable. |
| 812 | 1.5.0 | `durable` | `Observer<T>` (`observeDoc()`, `observeConversation()`, `observeTaskGraph()`) has the watch's shapes: `advance(call: WatchCall<T>, context)` (alway… | None. | Not blocking. No extension imports pi-durable. |
| 813 | 1.5.0 | `durable` | `subscribeCommits(listener)` is `observeCommits(observer)` with the observer shape: `{ advance(publication, context), end(end) }`, returning `{ det… | None. | Not blocking. No extension imports pi-durable. |
| 814 | 1.5.0 | `durable` | `HarnessOptions.onReport(report)` takes one `Report`: the fields of `ReportInfo`, tagged by `kind` (was `type`), and the `error` (was the first arg… | None. | Not blocking. No extension imports pi-durable. |
| 815 | 1.5.0 | `durable` | `DocumentCommitChange` is tagged: a document change is `{ type: "document", kind: "change", record, conversationId, version, value, ops }` and a re… | None. | Not blocking. No extension imports pi-durable. |
| 816 | 1.5.0 | `durable` | `CompactionStatus.reason` and `CompactionFailure.reason` in `pi.live` are `trigger` (what started the compaction; a run failure's `reason` is why i… | None. | Not blocking. No extension imports pi-durable. |
| 817 | 1.5.0 | `durable` | `TaskInspection.state` uses `TaskState`'s word: `{ kind: "pending", migrates }` (was `ready`). Before: `state.kind === "ready"`. After: `state.kind… | None. | Not blocking. No extension imports pi-durable. |
| 818 | 1.5.0 | `durable` | `FileChange` (`FileSystem.watch()` in `@earendil-works/pi-durable/env`) is tagged by `kind`: `{ kind: "paths", paths }`, `{ kind: "overflow" }`, or… | None. | Not blocking. No extension imports pi-durable. |
| 819 | 1.5.0 | `durable` | `SessionEnd` (`Session.closed`, `Harness.closed`) is tagged by `kind`: `{ kind: "closed" }` or `{ kind: "failed", error }` (was `reason`). Before:… | None. | Not blocking. No extension imports pi-durable. |
| 820 | 1.5.0 | `durable` | `ReportFrom`, the second argument of a task's `runtime.report(error, from)`, is tagged by `kind`: `{ kind: "extension", extension? }` or `{ kind: "… | None. | Not blocking. No extension imports pi-durable. |
| 821 | 1.5.0 | `durable` | `afterTool` runs on every result a tool task writes, not only on an executed call's: also on the error results the Harness writes itself, for a too… | None. | Not blocking. No extension imports pi-durable. |
| 822 | 1.5.0 | `durable` | A call to a tool its request did not offer gets a `pi.tool` task like any call, flagged `unoffered: true` in its input and its `pi.live.tools` slot… | None. | Not blocking. No extension imports pi-durable. |
| 823 | 1.5.0 | `durable` | `SubmissionRecord` gains a `type: "continue"` variant (`placed` without `entry`, `done` with `answer`, `unanswered`), so narrowing a record by `sta… | None. | Not blocking. No extension imports pi-durable. |
| 824 | 1.5.0 | `durable` | `RunFailureReason` (`pi.live.runFailure.reason`) gains `nothing_to_answer` and `turn_limit`, also an `unanswered` submission's `reason`: exhaustive… | None. | Not blocking. No extension imports pi-durable. |
| 825 | 1.5.0 | `durable` | `pi.live.run` has a required `turns` field, the run's tool rounds so far; code that writes `run` itself sets it (`turns: 0`). `pi.live` is version… | None. | Not blocking. No extension imports pi-durable. |
| 826 | 1.5.0 | `durable` | A Session's close ends synchronous observers (`observeDoc()`, `observeConversation()`, `observeTaskGraph()`, `observeCommits()`) `failed` with the… | None. | Not blocking. No extension imports pi-durable. |
| 868 | 1.4.0 | `durable` | `TaskRuntime.sleep()` is removed: it waited inside a phase, which holds an invocation and, after a restart, reruns the phase and restarts the wait.… | None. | Not blocking. No extension imports pi-durable. |
| 869 | 1.4.0 | `durable` | Tasks have a `sleeping` status, so code that handles every `TaskState`, `TaskGraphState`, or `TaskInspection` state needs a case for it. | None. | Not blocking. No extension imports pi-durable. |
| 870 | 1.4.0 | `durable` | Opening a SQLite storage migrates it to schema version 2 automatically, rebuilding its task table. A migrated database cannot be opened by 1.3.0 or… | None. | Not blocking. No extension imports pi-durable. |
| 871 | 1.4.0 | `durable` | `TaskRuntime` has `sleepUntil()` and `setTimer()`, and `ToolExecutionApi` has `now()`: code that builds either object by hand, such as a test fake… | None. | Not blocking. No extension imports pi-durable. |
| 872 | 1.4.0 | `durable` | A task cut off by a crash 5 times in a row without committing a new state is parked instead of run again (see the crash-loop guard under Added); se… | None. | Not blocking. No extension imports pi-durable. |
| 873 | 1.4.0 | `durable` | `defineDoc()` and `defineDocFamily()` require an explicit `checkpointWhen` predicate on every definition; there is no default. Use `() => false` to… | None. | Not blocking. No extension imports pi-durable. |
| 899 | 1.2.0 | `durable` | `ToolTaskInput` and `ToolTaskResult` are tagged unions: a model-issued call is `{ kind: "model", ... }` with its previous fields, a nested call `{… | None. | Not blocking. No extension imports pi-durable. |
| 900 | 1.2.0 | `durable` | `ToolExecutionResult.content` is now `output`, next to the new `structuredOutput`. | None. | Not blocking. No extension imports pi-durable. |
| 901 | 1.2.0 | `durable` | `bash` and `powershell` answer a nonzero exit with an error result carrying an `exit_code` diagnostic, instead of throwing (`tool_error`). | None. | Not blocking. No extension imports pi-durable. |
| 902 | 1.2.0 | `durable` | Any error a `Storage` method throws, a read included, now fails the Session, which closes itself: every later call and every pending wait rejects w… | None. | Not blocking. No extension imports pi-durable. |
| 903 | 1.2.0 | `durable` | `subscribeCommits()` and `subscribeClose()` listeners that throw, or return a rejected promise, are reported through `onReport` instead of failing… | None. | Not blocking. No extension imports pi-durable. |
| 904 | 1.2.0 | `durable` | A display-only write submission, one of only `kind` and `data` (no `model`, `head`, or `edits`), is appended and settled `done` at once, even while… | None. | Not blocking. No extension imports pi-durable. |
| 927 | 1.1.0 | `durable` | `Storage` implementations must honor the new `order` field of `ConversationQuery`, `EntryQuery`, `TaskQuery`, and `SubmissionQuery`, and continue a… | None. | Not blocking. No extension imports pi-durable. |
| 928 | 1.1.0 | `durable` | `TaskRuntime.context()` takes the cutoff as an options object, matching `Conversation.context()`: `runtime.context(conversationId, context, { at })… | None. | Not blocking. No extension imports pi-durable. |
| 939 | 1.0.4 | `durable` | `NodeExecutionEnv.watch()` fails with `permission_denied` when a target, or a watched directory itself, cannot be read for lack of permission; befo… | None. | Not blocking. No extension imports pi-durable. |
| 940 | 1.0.4 | `durable` | The env conformance suite checks three more `watch()` behaviors: changes to the file a watched symbolic link points to, recursive coverage below a… | None. | Not blocking. No extension imports pi-durable. |
| 946 | 1.0.3 | `durable` | `FileSystem` requires `openBinaryReader()` and `openDirReader()`; custom environments must implement them. | None. | Not blocking. No extension imports pi-durable. |
| 947 | 1.0.3 | `durable` | `BinaryReader` requires `scanLines()`. | None. | Not blocking. No extension imports pi-durable. |
| 948 | 1.0.3 | `durable` | `FileSystem` requires `watch()`. | None. | Not blocking. No extension imports pi-durable. |
| 949 | 1.0.3 | `durable` | `Shell.exec()` accepts an argv array besides a shell string, and `ShellExecOptions.onOutput` receives a third `info` argument naming the stream (`s… | None. | Not blocking. No extension imports pi-durable. |
| 968 | 1.5.0 | `env` | `RemoteWatcher` follows Durable's `FileWatcher`: `close(context)` is `stop(context)`, and its changes are tagged (`{ kind: "paths", paths }`, `{ ki… | None. | Not blocking. No extension imports pi-env. |
| 993 | 1.2.0 | `mcp` | Changed `CallToolResult.structuredContent` from `Record<string, unknown>` to `unknown`: `callTool()` now accepts any JSON value as structured conte… | None. | Not blocking. No extension imports pi-mcp. |
| 1020 | 1.4.0 | `telemetry` | Adapters trust typed instrumentation inputs; behavior for malformed values is unspecified. Carrier extraction checks required string identities, wi… | None. | Not blocking. No extension imports pi-telemetry. |
| 1021 | 1.4.0 | `telemetry` | Adapters must implement `TelemetrySpan.addLink()`. Normalized span snapshots include carrier-shaped context and parent identities and ordered links. | None. | Not blocking. No extension imports pi-telemetry. |
| 1022 | 1.4.0 | `telemetry` | Adapters with optional metric or propagation capabilities must carry them through `TelemetryContext.metrics` and `TelemetryContext.propagation` on… | None. | Not blocking. No extension imports pi-telemetry. |
| 1031 | 1.6.0 | `tui` | `Component.render()` now returns `readonly string[]`, and `Container.render()` returns the same cached array while its children are unchanged, like… | None. | Not blocking. Restates coding-agent entry 326. |
| 1068 | 1.2.0 | `tui` | `Editor.render()` and `Input.render()` now wrap the drawn cursor in zero-width APC markers instead of emitting `\x1b[7m` directly. TUI renderers re… | None. | Not blocking. Editor and Input cursor markers; extensions embed these components inside the TUI, which resolves the markers, and none matches `\x1b[7m` (grep). |
| 1076 | 1.1.0 | `tui` | `Terminal` implementations must provide `setProgramStatus(status)`; a terminal without OSC 7501 support can implement it as a no-op | None. | Not blocking. No extension implements Terminal (grep). |

### Required parity fixes

| Entry | Release | Source and section | Entry | Classification and reason |
|---:|---|---|---|---|
| 19 | 1.6.0 | `ai` Fixed | Fixed tools with `strict: "prefer"` constrained sampling being sent in strict mode when their schema contains a node without a `type` (such as `ite… | Required parity fix: Filing A (codex shim parity). |
| 26 | 1.6.0 | `ai` Fixed | Fixed the OpenAI Codex WebSocket 60-minute connection limit failing the turn when it hit mid-stream, for example during long thinking. The error is… | Required parity fix: Filing A (codex shim parity). |
| 27 | 1.6.0 | `ai` Fixed | Fixed the OpenAI Codex provider getting almost no prompt cache hits for the system prompt on GPT-6.2 models. GPT-6.2 places top-level `instructions… | Required parity fix: Filing A (codex shim parity). |
| 28 | 1.6.0 | `ai` Fixed | Fixed changing the thinking level on the OpenAI Codex provider invalidating the prompt cache on GPT-6 models. Thinking level changes, including swi… | Required parity fix: Filing A (codex shim parity). |
| 30 | 1.6.0 | `ai` Fixed | Fixed the OpenAI Codex provider ignoring `maxTokens`; it is now sent as `max_output_tokens` (at least 16) unless the model sets `compat.supportsMax… | Required parity fix: Filing A (codex shim parity). |
| 60 | 1.5.1 | `ai` Fixed | Fixed OpenAI Codex SSE retries retaining abort listeners after each backoff, causing listener buildup on repeated retries | Required parity fix: Filing A (codex shim parity). |
| 64 | 1.5.0 | `ai` Breaking Changes | `appendGrammarToolInputJsonDelta()` (`api/constrained-sampling`) takes the input delta instead of the whole input so far and no longer closes the i… | Required parity fix: Filing A (codex shim parity). |
| 66 | 1.5.0 | `ai` Added | Added `StreamingJsonParser`, an incremental, tolerant parser for JSON text that arrives in pieces (each piece is read once; snapshots of the partia… | Required parity fix: Filing A (codex shim parity). |
| 74 | 1.5.0 | `ai` Fixed | Fixed streamed tool-call arguments being re-parsed in full on every delta, which made CPU time and memory grow quadratically with the size of a too… | Required parity fix: Filing A (codex shim parity). |
| 75 | 1.5.0 | `ai` Fixed | Fixed grammar (custom) tool input streaming copying the whole input so far on every delta | Required parity fix: Filing A (codex shim parity). |
| 92 | 1.4.0 | `ai` Breaking Changes | The default `User-Agent` is now `pi/<version> (<platform>; <runtime>; <arch>)` instead of `pi (<platform> <release>; <arch>)`, and `@earendil-works… | Required parity fix: Filing A (codex shim parity). |
| 94 | 1.4.0 | `ai` Added | Added client identity configuration: an `identity` request option and `createModels({ identity })` default choose the `User-Agent` (`"detailed"` wi… | Required parity fix: Filing A (codex shim parity). |
| 106 | 1.4.0 | `ai` Fixed | Fixed whitespace-only tool output (for example a bare `\r\n` from bash) being sent as-is to OpenAI Completions, OpenAI Responses, and Google provid… | Required parity fix: Filing A (codex shim parity). |
| 111 | 1.4.0 | `ai` Fixed | Fixed OpenAI Responses deferred tool loads rewriting the top-level tool list, and losing the prompt cache, on every load after a tool removal. Mode… | Required parity fix: Filing A (codex shim parity); Filing B (native web search). |
| 117 | 1.3.0 | `ai` Changed | Changed model switching to drop thinking blocks from earlier assistant messages produced by a different model, instead of sending them as plain tex… | Required parity fix: Filing A (codex shim parity). |
| 118 | 1.3.0 | `ai` Fixed | Fixed tool-call argument parsing dropping fields when a string contains an invalid `\u` escape such as `\usepackage` | Required parity fix: Filing A (codex shim parity). |
| 128 | 1.3.0 | `ai` Fixed | Fixed tool calls whose final arguments are malformed JSON silently running with only the fields parsed before the error; such calls now carry `argu… | Required parity fix: Filing A (codex shim parity). |
| 153 | 1.1.0 | `ai` Fixed | Fixed model and caller headers not overriding the `originator` and `User-Agent` headers of `openai-codex-responses` requests ) | Required parity fix: Filing A (codex shim parity). |
| 338 | 1.6.0 | `coding-agent` Fixed | Fixed `read` storing a note that the current model does not support images, which was replayed to the model as stale text after switching to a visi… | Required parity fix: Filing C (read image warning). |
| 369 | 1.6.0 | `coding-agent` Fixed | Fixed changing the thinking level on the `openai-codex` provider invalidating the prompt cache on GPT-6 models | Required parity fix: Filing A (codex shim parity). |
| 375 | 1.6.0 | `coding-agent` Fixed | Fixed OpenAI rejecting requests with a 400 error when a tool's schema contains a node without a `type` (such as `items: {}` or `Type.Unknown()`); s… | Required parity fix: Filing A (codex shim parity). |
| 379 | 1.6.0 | `coding-agent` Fixed | Fixed the OpenAI Codex WebSocket 60-minute connection limit failing the turn when it hit mid-stream, for example during long thinking; the request… | Required parity fix: Filing A (codex shim parity). |
| 380 | 1.6.0 | `coding-agent` Fixed | Fixed the `openai-codex` provider getting almost no prompt cache hits for the system prompt on GPT-6.2 models | Required parity fix: Filing A (codex shim parity). |
| 381 | 1.6.0 | `coding-agent` Fixed | Fixed the `openai-codex` provider ignoring a model's `maxTokens` | Required parity fix: Filing A (codex shim parity). |
| 473 | 1.5.1 | `coding-agent` Fixed | Fixed OpenAI Codex SSE retries retaining abort listeners after each backoff, causing listener buildup on repeated retries | Required parity fix: Filing A (codex shim parity). |
| 528 | 1.5.0 | `coding-agent` Fixed | Fixed large streamed tool calls taking excessive CPU time and memory because every delta re-parsed the accumulated arguments. Providers and agent p… | Required parity fix: Filing A (codex shim parity). |
| 622 | 1.4.0 | `coding-agent` Fixed | Fixed whitespace-only tool output (for example a bare `\r\n` from bash) making OpenAI Completions, OpenAI Responses, and Google requests fail with… | Required parity fix: Filing A (codex shim parity). |
| 624 | 1.4.0 | `coding-agent` Fixed | Fixed OpenAI Responses models losing the prompt cache on every deferred tool load after a tool was removed | Required parity fix: Filing A (codex shim parity); Filing B (native web search). |
| 632 | 1.3.0 | `coding-agent` New Features | **Clean model switching**: thinking from a previous model is dropped instead of being shown to the new model as text. | Required parity fix: Filing A (codex shim parity). |
| 637 | 1.3.0 | `coding-agent` Changed | Changed model switching to drop thinking blocks from earlier assistant messages produced by a different model, instead of sending them as plain tex… | Required parity fix: Filing A (codex shim parity). |
| 648 | 1.3.0 | `coding-agent` Fixed | Fixed tool-call argument parsing dropping fields when a string contains an invalid `\u` escape such as `\usepackage` | Required parity fix: Filing A (codex shim parity). |
| 658 | 1.3.0 | `coding-agent` Fixed | Fixed tool calls whose final arguments are malformed JSON silently running with only the fields parsed before the error; they now fail validation a… | Required parity fix: Filing A (codex shim parity). |
| 734 | 1.1.0 | `coding-agent` Fixed | Fixed model `headers` in `models.json` not overriding the `originator` and `User-Agent` headers of Codex requests ) | Required parity fix: Filing A (codex shim parity). |

### Optional improvements

| Entry | Release | Source and section | Entry | Classification and reason |
|---:|---|---|---|---|
| 6 | 1.1.0 | `agent` Added | Added `durationMs` to tool result messages, `AgentToolCallOutcome`, and `tool_execution_end` events: how long `execute()` took, measured with a mon… | durationMs on tool results and tool_execution_end could give pi-tool-renderer's bash row the recorded time; deferred because the package's Pi peer floor (>=1.0.1) predates the field. |
| 12 | 1.6.0 | `ai` Added | Added `openai_input_transformations` assistant message diagnostics to the OpenAI Responses, Azure OpenAI Responses, and OpenAI Codex providers. The… | openai_input_transformations diagnostics from Pi's openai-codex provider; the codex shim emits none. Deferred: Optional work in Filing A. |
| 13 | 1.6.0 | `ai` Added | Added the `@earendil-works/pi-ai/session-resources` export with `registerSessionResourceCleanup()` and `cleanupSessionResources()`, which release p… | registerSessionResourceCleanup() could release the shim's cached WebSocket per session. Deferred: Optional work in Filing A. |
| 330 | 1.6.0 | `coding-agent` Added | Added a transcript notice when OpenAI drops reasoning items from a request, such as `OpenAI dropped 2 reasoning items: prefix_mismatch (details in… | Transcript notice built from the provider diagnostic of ai entry 12; shim users get none. Deferred: Optional work in Filing A. |
| 372 | 1.6.0 | `coding-agent` Fixed | Fixed `pi.exec` reporting exit code 0 for commands ended by a signal, such as a timeout, an abort or a crash; it now reports 128 + the signal numbe… | pi.exec now reports 128+signal; pi-web-tools/src/utils/deadline.ts::SIGNAL_EXIT_SCRIPT wraps helpers in sh to get the same code and could go. Deferred: Pi below 1.6.0 still reports 0, and the package's peer floor is `*`. |
| 403 | 1.5.1 | `coding-agent` Added | `ctx.ui.custom()` overlays now honor the `blocked` option: pi reports blocked program status (OSC 7501) from when the overlay is shown until it cal… | ctx.ui.custom overlays honor `blocked`; see entry 501. |
| 499 | 1.5.0 | `coding-agent` Added | Extensions can format the user's configured keybindings with `keyText()` and `keyHint()` from the tool render context and the message and entry ren… | pi-tool-renderer/extensions/tool-renderer/messages.ts imports keyText from the package; the render context now injects keyText/keyHint, which also see Pi's keybindings when an extension has its own copy. Path-package installs resolve the import to Pi's own copy through the loader alias. Deferred: the injected functions start at 1.5.0, above the package's floor. |
| 501 | 1.5.0 | `coding-agent` Added | Added a `blocked` option to inline `ctx.ui.custom()` components so approval prompts and other custom dialogs can report that pi is waiting for user… | pi-questions' custom questionnaire (extensions/rpc-fallback.ts) could pass `blocked` so Pi reports it waits for the user; deferred: the option starts at 1.5.0, above the package's peer floor (`*`). |
| 710 | 1.1.0 | `coding-agent` Added | Added `durationMs` to the tool render context and to `tool_execution_end` extension events: the recorded execution time of a final tool result | durationMs in the tool render context; see agent entry 6. |
| 711 | 1.1.0 | `coding-agent` Added | Added `outputPad` to the tool render context ) | outputPad in the tool render context could align pi-tool-renderer output with Pi's padding; deferred: starts at 1.1.0, above the package's floor. |
| 718 | 1.1.0 | `coding-agent` Changed | Changed `outputPad` to also apply to `!` command output, tool output, and summary blocks  by @rwachtler) | Restates entry 711. |
| 720 | 1.1.0 | `coding-agent` Fixed | Fixed bash and PowerShell results losing `Took` after reloading a session, and the live `Took` including wall-clock steps; both now show the record… | Restates agent entry 6 for bash and PowerShell rows. |
| 1046 | 1.5.0 | `tui` Added | Added `Component.capturesViewportInput`. While a component that sets it has focus, `TuiAltScreen` sends viewport keys such as PageUp/PageDown to it… | Component.capturesViewportInput would let list overlays in pi-skills-manager and pi-session-manager take PageUp/PageDown in fullscreen; deferred: starts at 1.5.0, above those packages' floors. |

### Non-impact entries

Each line gives one reason and every entry it covers; `classified-entries.json` holds the raw bullet beside each.

- 766–962 (197): No extension imports @earendil-works/pi-durable; the import triage finds no package in reach.
- 2, 8–10, 15, 17–18, 22–25, 29, 31–32, 35–36, 38–39, 41–42, 45, 47, 49–53, 55–56, 67, 69, 71–73, 76–78, 81–89, 95–96, 99, 101, 103–105, 108, 112, 116, 119–121, 124–126, 129–130, 132–134, 140, 147, 149–152, 154, 156, 158, 328–329, 331, 336, 350, 373, 376–378, 386, 390, 393, 395, 400, 402, 404–405, 409–412, 416, 423, 426, 432, 445, 455, 474–475, 477–480, 493, 497, 503–504, 509, 511, 523, 563–567, 574–577, 579–580, 587, 593, 595, 599–602, 620, 623, 625, 629, 631, 635–636, 649–651, 654–656, 659, 661, 672, 680, 691–692, 705, 716, 733, 736, 738–740, 752, 754, 757 (163): Provider-specific change; no extension registers or mirrors this provider (the registrations are openai-codex in pi-codex-minimal-tools, pi-claude-bridge's Claude Agent SDK provider and pi-codex-bridge's app-server provider).
- 159–303 (145): No extension imports @earendil-works/pi-chord; the import triage finds no package in reach.
- 344, 346, 349, 363–364, 368, 370, 382–384, 388–389, 394, 415, 417, 421, 433–434, 436, 441–442, 447, 451, 453, 459, 462, 466, 472, 481, 491, 500, 508, 514–515, 524–526, 529, 534, 544, 548–549, 551, 554, 569–573, 581–585, 588, 591, 596, 605, 607–610, 626–628, 646, 660, 662–663, 675, 694–698, 704, 714, 727, 732, 741, 746, 760, 1032–1044, 1047, 1049–1055, 1057–1067, 1069–1075, 1078–1081 (125): Host TUI, terminal or interactive-command change; extensions draw through these components and gain the fix, and none copies the changed code.
- 102, 139, 142, 148, 335, 367, 422, 429, 435, 437–439, 450, 471, 482–487, 521, 530, 535, 539–540, 543, 547, 556, 590, 594, 611, 613, 640–641, 664, 671, 674, 676–677, 679, 684, 686, 688–689, 699–701, 706–709, 712–713, 717, 719, 724, 726, 730–731, 743, 745, 747–751, 753, 755, 758–759, 762 (71): Pi codemode, MCP or classifier host feature; no extension imports pi-codemode or pi-mcp, registers MCP servers or classifiers, or declares reachesTools.
- 340, 345, 355, 357–358, 360–362, 365–366, 371, 391, 396, 399, 424, 454, 467, 470, 490, 492, 495, 498, 507, 516, 520, 532–533, 536, 538, 545, 553, 618, 638, 642, 644, 647, 685, 721–722, 728, 1048 (41): Pi CLI, installer, RPC or package-manager change; kendex installs Pi packages as path packages, which `pi update` does not reconcile (it reads only git: and npm: entries), and no extension implements this command or mode.
- 334, 341–342, 347, 352, 408, 418, 420, 427–428, 430, 440, 443, 446, 465, 489, 522, 527, 531, 537, 555, 617, 619, 645, 723, 729 (26): Built-in tool or shell command change; pi-tool-renderer draws these tools through pi.registerToolRenderer and replaces no execution, so the fix reaches its users.
- 304–324 (21): No extension imports @earendil-works/pi-codemode; the import triage finds no package in reach.
- 978–998 (21): No extension imports @earendil-works/pi-mcp; the import triage finds no package in reach.
- 999–1016 (18): No extension imports @earendil-works/pi-schema; the import triage finds no package in reach.
- 65, 337, 343, 387, 419, 461, 468, 476, 488, 542, 546, 550, 557, 614, 616, 681, 687 (17): Host session, compaction, settings, auth or resource-loading change; no extension implements it, and extensions that read sessions or settings gain the fix.
- 37, 40, 43–44, 97, 127, 406–407, 502, 510, 589, 592, 598, 604, 657, 737 (16): Built-in model catalog, pricing or request-option change on a provider no extension mirrors; extensions read models from Pi's catalog.
- 54, 107, 109–110, 122–123, 135, 144, 348, 374, 448, 652–653, 690, 693, 735 (16): Pi's retry and overflow classification on the error message; the shim keeps Pi's error text and HTTP prefix, so its errors gain the fix.
- 963–977 (15): No extension imports @earendil-works/pi-env; the import triage finds no package in reach.
- 1017–1030 (14): No extension imports @earendil-works/pi-telemetry; the import triage finds no package in reach.
- 449, 452, 457, 561–562, 586 (6): Change to an upstream extension example, not shipped API.
- 113, 621 (2): Codex catalog change; the shim takes models from the catalog.
- 413–414 (2): Restates entry 392.
- 630, 634 (2): Restates ai entry 115.
- 1 (1): Agent-loop fix in runToolCall; no extension copies the loop, and pi-tool-renderer's tool_batch runs children through Pi.
- 3 (1): Breaking: extensions build parameters with TypeBox imported from `typebox`, which Pi 1.6.0's loader still aliases to its bundled copy (core/extensions/loader.ts getAliases); the kinds used (Object, String, Number, Boolean, Array, Optional, StringEnum) keep their static types; pi-web-tools, which builds its tool schemas this way, passes its suite at 1.6.0.
- 4 (1): streamProxy() fix; no extension uses streamProxy (grep).
- 5 (1): Agent identity option; it reaches a provider as stream options.identity, whose shim side is ai entry 94.
- 7 (1): streamProxy() return type; no extension uses streamProxy (grep).
- 11 (1): New models in Pi's catalog; the codex shim registers only streamSimple and takes models from the catalog. Their request differences are entries 27, 28 and 30.
- 14 (1): The shim imports openai types only (`import type`), so the SDK version does not reach runtime.
- 16 (1): Anthropic message threads; pi-claude-bridge streams through the Claude Agent SDK, not Pi's Anthropic transport.
- 20 (1): Pi's retry classification reads the error message; the shim keeps Pi's text and HTTP prefix, so its errors gain the fix.
- 21 (1): Same as entry 20.
- 33 (1): Pi's Anthropic OAuth client version; pi-claude-bridge authenticates through the Claude Agent SDK.
- 34 (1): Breaking: openai-completions request field; no extension builds or overrides openai-completions requests (pi-qol gateway-privacy edits only privacy fields).
- 46 (1): Provider display name; the shim registers streamSimple only and keeps Pi's provider name.
- 48 (1): BigInt and Undefined argument conversion; no extension declares those kinds (grep).
- 57 (1): openai-responses header fix. Pi 1.0.1's openai-codex provider already sent `session-id`; the shim's `session_id` predates this range and is named in the codex shim parity item.
- 58 (1): Lazy provider loading in Pi; extension providers register eagerly.
- 59 (1): Pi's provider error formatting; the shim formats its own errors with Pi's HTTP status prefix, and the bridges report their SDK errors.
- 61 (1): Breaking: pi-ai no longer re-exports TypeBox. Extensions import `Type` from `typebox`, which Pi's loader aliases, and `StringEnum` from pi-ai, which keeps its JSON (`{ type: "string", enum }`); pi-web-tools, which combines the two, passes its suite at 1.6.0.
- 62 (1): Breaking: no extension uses Type.Refine, BigInt, Undefined, Void, Codec or Format.Set (grep of pi-extensions).
- 63 (1): Breaking: unresolved $ref handling; no extension declares a $ref in tool parameters.
- 68 (1): Usage.cost.totalFromProvider is added by calculateCost, which the shim and bridges call; four pi-codex-minimal-tools model-properties expectations compare the cost object exactly and fail at 1.6.0, a test expectation, not consumer behaviour; Filing A carries the expectation update.
- 70 (1): Faux provider test behaviour.
- 79 (1): pi-messages stream validation; no extension uses the pi-messages API.
- 80 (1): pi-ai CLI auth file mode; no extension runs the pi-ai CLI.
- 90 (1): Faux provider usage accounting; test behaviour only.
- 91 (1): Breaking: no extension passes telemetryContext (grep).
- 93 (1): Breaking: no extension calls resolveTranscriptTools or reads anchorsAdditions (grep).
- 98 (1): Telemetry span status; no extension reads Pi telemetry.
- 100 (1): ChatGPT Business usage-limit message on Pi's openai provider and retry rule (api/openai-responses.ts, utils/retry.ts); the shim's own usage-limit text is for openai-codex and Pi classifies the message it carries.
- 114 (1): Breaking: no extension uses AssistantMessageFrame or reduceAssistantMessageFrames (grep).
- 115 (1): configuration_update items on Pi's openai provider; pi-web-tools' payload rewrite ignores input items of that type. The codex side is entry 28.
- 131 (1): RefreshModelsContext.baseUrl for dynamic catalogs; pi-codex-bridge's provider lists a fixed catalog.
- 136 (1): Breaking: every extension stream function returns a stream from Pi's createAssistantMessageEventStream (pi-codex-bridge src/bridge.ts, the shim src/provider-shim.ts, pi-claude-bridge src/index.ts::newAssistantMessageEventStream); none subclasses EventStream.
- 137 (1): durationMs is measured by AssistantMessageEventStream itself, which every extension provider uses.
- 138 (1): Optional ToolResultMessage field; pi-codex-bridge and pi-claude-bridge read tool results' content only.
- 141 (1): LoginOptions.agentName for Pi's own login flows; no extension runs a login flow.
- 143 (1): Faux provider cache estimate; test behaviour only.
- 145 (1): Lazy API setup timestamp; extension providers register eagerly.
- 146 (1): Pi's output-limit estimate for its own requests; the shim sends no output limit (its gap is ai entry 30).
- 155 (1): Breaking: Azure provider rename; pi-qol/extensions/qol/statusline.ts maps the old id to a label only, and the `azure-openai-responses` api id is unchanged.
- 157 (1): Pi's OAuth refresh persistence; the shim and /image-gen read credentials through Pi's model registry and gain it.
- 325 (1): GPT-6.2 availability summary; request differences are ai entries 27, 28 and 30.
- 326 (1): Breaking: readonly render output. Every extension render path that post-processes lines builds a new array (map, slice, spread); a search for in-place push, splice, pop or index writes on render results found none. pi-tool-renderer's suite passes at 1.6.0 except one layout-cache expectation (tui entry 1056).
- 327 (1): Catalog addition; see entry 325.
- 332 (1): Pi's own undici; pi-codex-minimal-tools ships its own undici ^7.29.1 dependency, a dependency choice outside this audit.
- 333 (1): Default model change; the shim serves whichever openai-codex model is selected.
- 339 (1): Host fix for extensions that deactivate their own tools at session_start; extensions gain it.
- 351 (1): Host enabledModels warning placement; no extension writes those warnings.
- 353 (1): Pi's edit diff drawing; pi-tool-renderer leaves edit to Pi's renderer unless renderMutationTools is on (default off), so the fix reaches its users by default.
- 354 (1): Abort results for unstarted calls in a batch of tool calls (agent entry 1); pi-tool-renderer's tool_batch returns one result for its own call.
- 356 (1): Host diagnostics after a session replacement; extensions that fail to load now get their error shown.
- 359 (1): AgentSession.reload() now emits session_start under bindExtensions({}); extensions that start work in session_start gain it, and the audit checks bind the same way.
- 385 (1): Host editor autocomplete fix; extensions that wrap the editor (pi-qol CustomEditor) gain it.
- 392 (1): Pi's idle cache warming; no extension implements cache warming.
- 397 (1): Breaking: no extension supplies GrepOperations (grep).
- 398 (1): Breaking: restates ai entry 34.
- 401 (1): No extension calls registerMarkdownTransformer (grep).
- 425 (1): Pi's changelog notice versions; no extension reads them.
- 431 (1): No extension supplies ReadOperations (grep).
- 444 (1): Windows installer; no extension installs Pi.
- 456 (1): The loader resolves an entry's real path before import; kendex path packages resolve their dependencies the same from the real path.
- 458 (1): Restates ai entry 57.
- 460 (1): Restates ai entry 58.
- 463 (1): SDK and RPC reloads wait for a running response; pi-skills-manager calls ctx.reload() from a command, which runs while idle.
- 464 (1): Restates entry 353 for indentation.
- 469 (1): Restates ai entry 59.
- 494 (1): Breaking: restates ai entries 61 and 62.
- 496 (1): New optional pi.exec maxBuffer; callers keep the default.
- 505 (1): Pi keeps extension imports of Type, Static and TSchema from pi-ai working; extensions import TypeBox from `typebox`.
- 506 (1): Pi's own system prompt text; extensions that append to it (pi-agents-tmux, pi-caveman) append to whatever Pi sends.
- 512 (1): Pi's glob matching dependency; no extension copies it.
- 513 (1): ctx.isProjectTrusted now honors a saved "Do not trust"; pi-hooks and the packages that gate project settings on trust gain the fix.
- 517 (1): Host fix for reordered setActiveTools lists.
- 518 (1): pi.exec output cap; callers' output is small.
- 519 (1): pi.exec SIGKILL after an ignored SIGTERM; callers gain it.
- 541 (1): `pi update` on Windows; kendex path packages are not updated by `pi update`.
- 552 (1): Host hidden-thinking drawing; pi-tool-renderer's assistant spacing patch trims blank rows after Pi's render and stays correct.
- 558 (1): pi.exec UTF-8 fix; callers gain it.
- 559 (1): pi.exec spawn-error stderr; callers gain it.
- 560 (1): Configured package install failures at startup; kendex installs path packages, which need no install step.
- 568 (1): Faux provider accounting; test behaviour only.
- 578 (1): Restates ai entry 82 on the openai provider; the shim serves openai-codex only.
- 597 (1): No extension handles before_provider_headers (grep).
- 603 (1): Restates ai entry 100.
- 606 (1): Managed install marker; no extension installs Pi.
- 612 (1): Loader alias for @earendil-works/pi-ai/models; extensions import the root entry.
- 615 (1): Resumed sessions restore extension tools; packages that sync their tools at session_start and model_select still run their sync after.
- 633 (1): Restates entry 639.
- 639 (1): Resume restores active tools; extension tool sync runs after, as in entry 615.
- 643 (1): Pi's read line-range label; pi-tool-renderer's readCallText already converts offset and limit with Number() and defaults a null offset.
- 665 (1): Summary of entry 667.
- 666 (1): Breaking: theme schema location; no extension ships a theme file (grep for theme JSON with $schema).
- 667 (1): Breaking, blocking: names pi.sendMessage. pi-hooks registers no before_agent_start handler, and the real Pi 1.6.0 session check shows its custom sends with triggerTurn start and reach a run. The other before_agent_start handlers (pi-qol, pi-task-panel, pi-background-tasks, pi-agents-tmux, pi-caveman) read only systemPrompt, systemPromptOptions or `prompt ?? ""`, so a custom-message run gets the same prompt additions.
- 668 (1): Breaking, blocking: names ctx.isIdle, pi.sendMessage and pi.sendUserMessage. lane-mail-wake.ts judges only while ctx.isIdle() and always passes deliverAs: "followUp"; the real Pi 1.6.0 session check shows a starting run is busy, a bare send throws there, and the wake's followUp send is delivered, so pi-hooks needs no change.
- 669 (1): Breaking: `pi mcp list --json`; no extension reads it.
- 670 (1): reachesTools for codemode and tool_search; no extension declares tools that reach others.
- 673 (1): Host OSC 52 clipboard option; no extension copies to the clipboard.
- 678 (1): serializeConversation() omits thinking; pi-qol's two callers (compaction.ts, transcript-risk.ts) already strip thinking before calling it.
- 682 (1): Codemode tool description text; no extension uses codemode.
- 683 (1): Host fix that keeps before_agent_start system prompt sections through a custom-triggered run; pi-agents-tmux and pi-caveman gain it.
- 702 (1): Removed unpublished experimental exports; no extension imports them.
- 703 (1): Pi dropped its chord dependency; no extension imports chord.
- 715 (1): agent_settled gains `aborted`; pi-hooks' settle check needs no distinction.
- 725 (1): Codemode output separators; no extension uses codemode.
- 742 (1): CLI `--tools` patterns; no extension parses Pi's CLI flags.
- 744 (1): Restates entry 742.
- 756 (1): Breaking: restates ai entry 155.
- 761 (1): Pi's OAuth refresh on cancellation; the shim reads Pi's stored credentials and gains it.
- 763 (1): Host terminal EIO handling; no extension owns the terminal.
- 764 (1): samplingParamsByThinkingLevel applies to openai-completions and openai-responses requests; the shim's openai-codex requests and the extension payload rewrites ignore sampling fields.
- 765 (1): Restates entry 764.
- 1031 (1): Breaking: restates coding-agent entry 326.
- 1045 (1): New helper; no extension needs it.
- 1056 (1): Markdown reuses highlighted blocks across a resize. pi-tool-renderer's user-message-layout suite row asserts the highlighter runs again on a width change and fails at 1.6.0; the layout it draws is correct, so the row's premise is the only casualty; Filing C carries the expectation update.
- 1068 (1): Breaking: Editor and Input cursor markers; extensions embed these components inside the TUI, which resolves the markers, and none matches `\x1b[7m` (grep).
- 1076 (1): Breaking: no extension implements Terminal (grep).
- 1077 (1): New setters; extensions pass padding through constructors.

## Checks

### Exact merged-main checks

The proof used `git archive 27d49aa5daf025b12d0498304a80bb190fbfb9fa pi-extensions kendex.toml crates/core/src skills hooks | tar -x -C <fresh extraction>`. The pi-hooks suite reads `kendex.toml`, `crates/core/src`, `skills` and `hooks` from the repository around the package, so the archive carries them. `.pi/kendex`, the rendered Pi hook scripts the lane-mail-wake suite copies, is tracked but was left out of the archive and copied from the worktree; it is unchanged between the run-start head and the tested commit, so the copied bytes are the tested commit's. `pi-extensions` at that commit is identical to the run-start head. All 1,121 tracked `pi-extensions` files still matched their blobs at the tested commit after the runs. `scripts/merged-proof.sh` is the sequence: install, version proof, checks, then each suite with the check moved out.

In each touched package the install named `@earendil-works/pi-agent-core`, `pi-ai`, `pi-coding-agent` and `pi-tui` at 1.6.0, plus the package's DEVELOPMENT.md extras (pi-tool-renderer: `pi-codemode`, `pi-mcp` and `pi-telemetry` at 1.6.0; pi-web-tools: `typebox`, `tsx`, `youtube-transcript-plus@^2.0.1`; pi-codex-minimal-tools: `typebox`, `undici@^7.29.1`), with `--no-save --include=dev --include=peer --include=optional --no-package-lock --ignore-scripts --no-audit --no-fund`. For pi-codex-minimal-tools the install also named `tsx`, for its `tsx --test` suite; its DEVELOPMENT.md line does not name it, and the package declares it as a devDependency. pi-agents-tmux was installed the same way, with its `typebox` peer, because the pi-hooks suite imports it. No `package.json` changed. Pi 1.6.0 pins its internal packages to exact versions (coding-agent entry 638), so the transitive Pi packages resolved to 1.6.0 without being named.

| Check | Behaviour exercised | Result at the tested commit | Control |
|---|---|---|---|
| `pi-hooks/tests/pi-update-sdk-contract.test.ts` (entries 667, 668) | Real `createAgentSession` with a scripted model: `ctx.isIdle()` and a `deliverAs: "followUp"` send inside `before_agent_start`; the wake's followUp send from `agent_settled`; an idle custom send with `triggerTurn: true`; clippy's `turn_end` send with `triggerTurn: true`. | 4 of 4 pass: a starting run is busy and the followUp reaches the model; a settled session is idle and the wake's send starts a turn; the custom run reaches `before_agent_start` as `custom`; clippy's message reaches the model. `merged.VpWrjx/logs/check-pi-hooks.log`. | On Pi 1.0.1 (`work.xGveD6`, seven Pi packages pinned) the busy row and the custom-run row fail, a starting run being idle and a custom run firing no `before_agent_start`; the wake and clippy rows pass on both. |
| `pi-codex-minimal-tools/tests/pi-update-sdk-contract.test.ts` (Filing A) | Real session on openai-codex gpt-6.2-sol over SSE, fetch stubbed, once on Pi's provider and once through the shim; both rows assert Pi 1.6.0's request shape. | Pi's row passes. The shim's row fails on all six fields: `instructions`, system prompt item, tool placement, `max_output_tokens`, session header, User-Agent. `evidence/pi-codex-minimal-tools-observations.json` in the work copy holds both requests. | Pi's own provider is the control. |
| `pi-web-tools/tests/pi-update-sdk-contract.test.ts` (Filing B) | Real session on Pi's openai provider with `defaultProvider: "openai-native"`, recording the request after every `before_provider_request` handler. | gpt-4.1 passes: its top-level `web_search` is rewritten to the native tool. gpt-6.2-sol fails: `web_search` arrives as a function tool inside an `additional_tools` input item. | gpt-4.1, a model without `additional_tools`. |
| `pi-tool-renderer/extensions/__tests__/pi-update-sdk-contract.test.ts` (Filing C) | Pi's `read` on a PNG for a text-only model, drawn by Pi's read renderer and by the package's. | The result carries `details.imageUnsupportedByModel`. Pi's renderer draws the warning collapsed and expanded; the package's draws neither (2 of 5 rows fail). | Pi's renderer. |

| Suite, unchanged entry point | Result at Pi 1.6.0 | Against the package's pinned Pi |
|---|---|---|
| pi-hooks `bun test ./tests` | 247 of 247 pass on the rerun (`suite-pi-hooks-rerun.log`). The first full run failed nine lane-mail-wake rows on `wakes: 0`; the same file then passed 13 of 13 alone and the full suite passed, so the failure was intermittent. | 247 of 247 pass at 0.87.1 in `work.R0Oa7c`. Earlier runs at both versions failed the same 32 rows for two host causes: the copy lacked `hooks/`, and fixtures under the worktree's `tmp` met this lane's own lane-mail hooks. Both passing runs put fixtures outside the worktree. |
| pi-tool-renderer `bun test ./extensions/__tests__` | 142 of 143 pass. `user-message-layout.test.ts` asserts the highlighter runs again after a width change; Pi 1.5.0's Markdown reuses highlighted blocks (tui entry 1056), so the count does not rise. | 143 of 143 pass at 1.0.1. |
| pi-web-tools `npm test` (`tsx --test`) | 428 of 428 pass. | Not run. |
| pi-codex-minimal-tools `npm test` (`tsx --test`) | 172 of 187 pass. Seven failures follow Pi: three reasoning-effort parity rows (Filing A) and four model-properties rows that compare the cost object exactly and now see `totalFromProvider` (ai entry 68). | 179 of 187 pass at 0.87.1; the eight failures common to both are host-caused: stalled SSE and WebSocket deadline rows, and an image path row that reads the fixture directory relative to the process. |

### Work-copy checks

The same checks and suites ran first in `work.Ixy4Zz`, an `rsync` copy of the worktree's `pi-extensions` with the same install, with the same results. `work.R0Oa7c` holds the pinned-Pi baseline installs and suites.

### Coverage limits

No interactive terminal, image-protocol terminal, live provider or every-package runtime suite was run. pi-agents-tmux, pi-background-tasks, pi-task-panel, pi-qol, pi-questions, pi-skills-manager, pi-extension-manager, pi-session-manager, pi-prompt-stash, pi-caveman, pi-nested-agents-md, pi-output-policy, pi-session-bridge, pi-claude-bridge and pi-codex-bridge carry no Required or blocking entry and their suites were not run at 1.6.0; their classifications rest on the source reads named beside each entry. The Filing A check drives the request shape only; the entries it lists beyond that are read from the upstream diff of `api/openai-codex-responses.ts`, `api/openai-responses-shared.ts` and `api/transform-messages.ts` between `v1.0.1` and `v1.6.0`, kept under `diffs/` and `src-v1.0.1`/`src-v1.6.0`.

## Prior-range evidence

The [previous Pi 1.0.1 record](https://github.com/vanillagreencom/kendex/blob/e32c59e138871886379e42756eb572dd38dc3627/pi-extensions/pi-update.audit.md) owns its checks. Its tested extension commit was `093a9caa96d68ef1d0c99f6f1fdb99318dea0776` and its evidence directory `tmp/pi-update/run.cLxHN9`. Its Optional native drawing entry has since landed as KEN-4495, so pi-tool-renderer now draws through `pi.registerToolRenderer`; that is why this record treats Pi's tool fixes as reaching its users.

## Record scope

This record clears Pi 1.6.0 when it and the marker land together. A Pi peer floor may rise to `>=1.6.0` only after that. The audit changes no package code, peer range or package version, and performs no refresh, apply or publication. The three filings carry the Required parity fixes; each ships its own test and changelog entry under the pi-update skill's repair rule.
