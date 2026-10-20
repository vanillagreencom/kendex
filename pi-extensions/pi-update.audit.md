# Pi package update audit: 1.0.0 to 1.0.1

Marker `1.0.0` → `1.0.1`. Run-start extension head: `40c25ec1f77ffed5b896727965f84daf12560acd`. The range contains Pi 1.0.1, released 2026-10-03. Every released entry above the previous marker and at or below the target was classified; later releases and Unreleased blocks were not.

## Verdict

Verdict: `roll`.

- Target release: `1.0.1`, npm `@earendil-works/pi-coding-agent@1.0.1` integrity `sha512-B7FGYpHpBPvS+Ux16CbCuVnE9S4v6c2h6ykocPNarC4msD/4JM/eFrCrO2wbRkedJZ25myFozSWHvCOx4QnN+w==`, upstream source commit `a7229ddc21810d6245105978033b7df645ecc2f7`.
- Entries examined: every Pi 1.0.1 entry across all target changelogs: 42 literal bullets, including five coding-agent New Features summaries; 37 bullets excluding those summaries. The one Breaking Changes entry is listed below. Required parity fixes in this range: 0. Blocking entries: 0.
- Tested extension commit: `093a9caa96d68ef1d0c99f6f1fdb99318dea0776`.
- Evidence: `tmp/pi-update/run.cLxHN9`, with the exact merged-main proof in `merged.v1jU73/report.md`. That fresh directory holds `git archive` of the tested commit's `pi-extensions`, the retained real SDK check copied into the renderer's test directory, an unchanged-manifest target installation, and the actual logs and exit receipts. Pi 1.0.1 resolved from both the extracted extension entry and suite directory before checks and before the package suite (`merged.v1jU73/version-proof.log`, `suite-version-proof.log`). The real SDK checks and controls passed 16 tests and 117 assertions (`check-renderer.log`, exit 0). The unchanged renderer package suite passed 151 tests and 500 assertions across 25 files (`suite-renderer.log`, exit 0). This is renderer/SDK contract coverage, not a runtime pass for every extension.

Every Breaking Changes entry in range was checked against the current `pi-hooks/pi-contract.json`, including its events, calls, fields and package exports. The inventory and complete comparison are in `tmp/pi-update/run.cLxHN9/breaking-contract-check.json`.

| Release | Source | Entry | Names from the pi-hooks contract | Result |
|---|---|---|---|---|
| 1.0.1 | `mcp` | `OAuthClientProvider.clientMetadataUrl` becomes `clientMetadataDocument(metadata)`, returning a server-specific document URL and redirect URI or selecting dynamic registration; it also changes when client information is stored. | None. | Not blocking. No extension imports Pi MCP or uses its OAuth callback API. No listed pi-hooks event or call matches. |

## Sources and counts

The run enumerated every changelog in the current upstream main snapshot and the exact target tree. The fetched source-key union is `agent`, `ai`, `chord`, `client`, `codemode`, `coding-agent`, `durable`, `env`, `mcp`, `protocol`, `server`, `telemetry`, and `tui`. The release website at <https://pi.dev/news/releases> is a cross-check, recorded as `releases` in the marker. Its redirect to the changelog page includes Pi 1.0.1.

The target contains all eleven package source keys from the previous record. `chord` and `env` exist only in the fetched main snapshot, not at the target. Main no longer contains `client`, `protocol`, or `server`; their target changelogs were still fetched. No previously covered target package source disappeared. Current-main later releases and Unreleased blocks do not enter the classification range. `sourcesCovered` records the fetched union, including those distinctions, rather than asserting that all keys existed at the target.

Source discovery and raw evidence under `tmp/pi-update/run.cLxHN9`:

- `sources/tree-main.json`, `sources/tree-target.json`, `sources/changelog-paths.json`, and `sources/absent-changelogs.json` record enumeration and per-reference absence.
- `sources/main/packages/<source>/CHANGELOG.md` and `sources/v1.0.1/packages/<source>/CHANGELOG.md` retain all changelogs present at each reference; `sources/releases.html` retains the website cross-check.
- `sources/v1.0.1/packages/coding-agent/` retains the exact SDK and extension docs, SDK extension example, extension API types/loader/runner, agent-session, resource-loader and tool index read by this run.
- `target.json`, `upstream-tag-sha.txt`, `npm-package.tgz`, and `npm-source-mapping.json` bind npm metadata, tag commit and integrity-verified package to upstream source. The exact merged proof repeats the installed-byte/source-map checks in `merged.v1jU73/npm-source-proof.json`.
- `import-triage.json`, `surface-inventory.txt`, and `provider-event-surface-inventory.txt` record rediscovered package imports, provider overrides and event listeners. The generated Claude bridge bundle appears only in broad search output; no Pi behavior claim comes from it.
- `release-entries.json` retains each raw bullet and source line; `classified-entries.json` retains every classification. The source keys carrying target entries are `ai`, `codemode`, `coding-agent`, `mcp`, and `tui`. Target sections in `agent`, `client`, `durable`, `protocol`, `server`, and `telemetry` are empty.

| Bucket | Literal bullets, including summaries | Bullets excluding New Features summaries |
|---|---:|---:|
| Required parity fix | 0 | 0 |
| Optional improvement | 4 | 3 |
| Non-impact | 38 | 34 |
| Total | 42 | 37 |

## Classified entries

All entries below are Pi 1.0.1 entries dated 2026-10-03. The numbers identify the captured raw bullets; summary restatements remain visible.

| Entry | Source and section | Classification | Entry and reason |
|---|---|---|---|
| 1 | `ai` Added | Non-impact | **Clef classifier models**. No extension registers cloudflare-workers-ai or mirrors its classifier catalog; pi-qol compaction merely considers that provider. |
| 2 | `ai` Changed | Non-impact | **Anthropic inline tool additions and redefinitions**. pi-claude-bridge/src/native-provider.ts::buildNativeProvider uses Claude Agent SDK under pi-claude, not Pi Anthropic transport. pi-codex-minimal-tools/src/provider-shim.ts::registerOpenAICodexCustomProvider overrides openai-codex only. No extension emits tool_addition or imports hasToolRedefinitions. |
| 3 | `ai` Changed | Non-impact | **hasToolRedefinitions deprecation**. No extension imports or calls this helper; it remains an upstream transport concern. |
| 4 | `ai` Fixed | Non-impact | **At-capacity retry classification**. No extension copies Pi's isRetryableAssistantError classifier. pi-qol/extensions/qol/rate-limit-auto-resume.ts handles later session errors independently; Pi gains this fix. |
| 5 | `ai` Fixed | Non-impact | **Cloudflare AI Gateway Claude model IDs**. No package registers cloudflare-ai-gateway or copies its model catalog or transport. |
| 6 | `ai` Fixed | Non-impact | **ChatGPT OAuth callback port collision**. No extension replaces Pi's OAuth callback listener. Codex shim consumes Pi credentials; it does not own this login server. |
| 7 | `ai` Fixed | Non-impact | **Bedrock OpenAI long-context pricing**. No package registers Bedrock or mirrors its model pricing tiers. |
| 8 | `ai` Fixed | Non-impact | **Bedrock Claude stale thinking signatures**. No package overrides Bedrock request serialization. Claude bridge uses Claude Agent SDK, and codex shim overrides openai-codex. |
| 9 | `ai` Fixed | Non-impact | **Together DeepSeek model rename**. No package owns Together catalog or thinking-level transport settings. |
| 10 | `codemode` Fixed | Non-impact | **Codemode output bounds**. No package imports pi-codemode or copies its script host/output collection. |
| 11 | `coding-agent` New Features | Non-impact | **Nix flake summary**. Restates coding-agent Added Nix installation support; no extension owns Pi installation. |
| 12 | `coding-agent` New Features | Non-impact | **Project MCP override summary**. Restates project MCP configuration. No extension imports Pi MCP, writes .pi/mcp.json, or registers Pi MCP servers. |
| 13 | `coding-agent` New Features | Non-impact | **MCP Client ID Metadata Documents summary**. Restates new Pi MCP authorization registration; Claude bridge's Claude SDK MCP servers use a separate API. |
| 14 | `coding-agent` New Features | Optional improvement | **Tool renderers for any tool summary**. Restates entry 20. pi-tool-renderer/extensions/tool-renderer.ts::toolRenderer and tools.ts::registerRead/registerBash/registerEdit/registerWrite/registerReadOnly can use the supported native drawing API instead of replacing execution definitions. The drawing migration is separate work under KEN-4495; this audit implements no migration. |
| 15 | `coding-agent` New Features | Non-impact | **Clef classifier summary**. Restates entry 1; no extension registers cloudflare-workers-ai or mirrors its classifiers. |
| 16 | `coding-agent` Added | Non-impact | **Copy key on OAuth screens**. No extension replaces these OAuth screens or their message-copy key binding. |
| 17 | `coding-agent` Added | Non-impact | **MCP CIMD registration**. No package uses Pi MCP OAuthClientProvider or writes this option. |
| 18 | `coding-agent` Added | Non-impact | **Project MCP overrides**. No package reads or writes .pi/mcp.json or overrides Pi server exposure selection. |
| 19 | `coding-agent` Added | Non-impact | **Clef classifier availability**. Restates ai entry 1. Provider-specific triage found no Cloudflare override. |
| 20 | `coding-agent` Added | Optional improvement | **registerToolRenderer API**. pi-tool-renderer/extensions/tool-renderer.ts::toolRenderer; tools.ts::registerRead/registerBash/registerEdit/registerWrite/registerReadOnly; chrome.ts::installToolExecutionRendererPatch. Native API can remove execution replacement, but next() includes built-in drawing, and resolver precedence follows the native extension order; this audit adds no provenance mechanism. Audit fixtures demonstrate behavior, not an implemented migration. |
| 21 | `coding-agent` Added | Non-impact | **Nix installation flake**. No extension controls Pi installation or the Nix flake. |
| 22 | `coding-agent` Changed | Non-impact | **pi update managed-install advice**. kendex installs path packages; pi update reconciles npm:/git: settings entries, not these path packages. |
| 23 | `coding-agent` Changed | Non-impact | **Anthropic inline tool changes**. Restates ai entry 2. All provider overrides are bridge buildNativeProvider (Claude Agent SDK) and codex registerOpenAICodexCustomProvider (openai-codex), neither Pi Anthropic wire transport. |
| 24 | `coding-agent` Fixed | Non-impact | **brace-expansion security dependency**. Fix belongs to upstream package dependency graph; no extension imports or vendors brace-expansion. |
| 25 | `coding-agent` Fixed | Non-impact | **Trailing comma in --models**. No extension copies Pi CLI model-cycle parsing. Child launches do not own that parser. |
| 26 | `coding-agent` Fixed | Non-impact | **Codemode output memory bound**. Restates codemode entry 10; no package imports or overrides codemode script execution. |
| 27 | `coding-agent` Fixed | Optional improvement | **Non-PNG Image transcoding**. pi-tool-renderer/extensions/tool-renderer/images.ts::readImageComponent manually converts non-PNG Kitty images via convertToPng. Upstream's new transcoder could remove that conversion path; no code change is made in this audit-only step. pi-codex-minimal-tools/src/index.ts::viewImageResultComponent and src/provider-shim.ts image preview creation gain the dependency fix directly. |
| 28 | `coding-agent` Fixed | Non-impact | **MCP resumed-session and HTML drawing**. No package implements Pi MCP session connection; native renderer registration is classified in entry 20. Current renderer's generic drawing owner is chrome.ts::installToolExecutionRendererPatch, whose behavior is sampled by its unchanged suite. |
| 29 | `coding-agent` Fixed | Non-impact | **WezTerm fullscreen image scrolling**. Host TUI viewport/image-placement fix; renderer's OverlayAwareImage delegates to Image and owns no fullscreen scrolling algorithm. No interactive terminal run was performed. |
| 30 | `coding-agent` Fixed | Non-impact | **At-capacity retry fix restatement**. Same classification as ai entry 4; no copied retry classifier. |
| 31 | `coding-agent` Fixed | Non-impact | **Cloudflare dashed Claude IDs restatement**. Same classification as ai entry 5; no provider override or copied catalog. |
| 32 | `coding-agent` Fixed | Non-impact | **ChatGPT callback port fix restatement**. Same classification as ai entry 6; no owned callback server. |
| 33 | `coding-agent` Fixed | Non-impact | **Bedrock OpenAI pricing restatement**. Same classification as ai entry 7; no mirrored pricing. |
| 34 | `coding-agent` Fixed | Non-impact | **Bedrock Claude thinking fix restatement**. Same classification as ai entry 8; provider serializers differ. |
| 35 | `coding-agent` Fixed | Non-impact | **Together model rename restatement**. Same classification as ai entry 9; no copied Together model catalog. |
| 36 | `coding-agent` Fixed | Non-impact | **Default NVIDIA model**. No extension copies the host's default NVIDIA model ID. |
| 37 | `coding-agent` Removed | Non-impact | **Published npm-shrinkwrap removal**. No extension depends on the shrinkwrap file as API. It changes the audit install environment: direct target dependencies initially resolved transitive Pi 1.3.0 and failed before behavior; a clean explicit seven-Pi-package target install is the proven controlled graph. No general fresh-install compatibility claim is made. |
| 38 | `mcp` Breaking Changes | Non-impact | **MCP OAuth client metadata breaking change**. OAuthClientProvider.clientMetadataUrl becomes clientMetadataDocument(metadata). No package imports pi-mcp; no pi-hooks contract event/call matches. The contract comparison above lists the result; the run retains every examined contract name. |
| 39 | `mcp` Added | Non-impact | **MCP OAuth document/callback options**. No package uses McpOAuthProviderOptions, OAuthCallbackServerOptions, or Pi MCP waitForCallback. |
| 40 | `tui` Added | Optional improvement | **setImageTranscoder API**. pi-tool-renderer/extensions/tool-renderer/images.ts::readImageComponent can potentially drop its manual convertToPng path. It needs a focused change and image regression controls outside this audit-only step. Pi coding-agent itself wires its transcoder; the minimum/fallback policy must remain explicit. |
| 41 | `tui` Fixed | Non-impact | **Image fallback without successful transcoding**. Image callers in pi-codex-minimal-tools gain the upstream fix. pi-tool-renderer::readImageComponent still owns its pre-existing asynchronous conversion-before-Image path; no new result field/event/provider option is introduced, and image terminals were not exercised. |
| 42 | `tui` Fixed | Non-impact | **WezTerm image scrolling**. Restates coding-agent entry 29. No extension implements the host fullscreen image-placement algorithm. |

No entry in range adds or changes an extension tool-result field, extension-event field or provider-stream-option field. The Anthropic wire-input changes are triaged against both provider overrides: `pi-claude-bridge/src/native-provider.ts::buildNativeProvider` uses Claude Agent SDK under pi-claude, while `pi-codex-minimal-tools/src/provider-shim.ts::registerOpenAICodexCustomProvider` overrides openai-codex. Neither copies the changed Pi Anthropic or Bedrock serializer. The literal `tool_result` listeners in `pi-hooks/extensions/hooks.ts`, `pi-nested-agents-md/extensions/nested-agents-md.ts`, `pi-output-policy/extensions/output-policy.ts`, and `pi-qol/extensions/qol.ts` consume no changed field in this range.

The Optional native drawing entry can remove execution replacements, but the production migration is separate from this audit. The Optional Image transcoder entries can remove the renderer's manual `convertToPng` path; that simplification needs a focused image change and controls beyond this audit's runtime coverage. Neither simplification was implemented or claimed as passing production behavior here.

## Exact merged-main checks

The proof used `git archive 093a9caa96d68ef1d0c99f6f1fdb99318dea0776 pi-extensions | tar -x -C <fresh extraction>`, not the lane head or older work copy. All setup, install, version, SDK-check and original-suite operations succeeded on their first attempt. `merged.v1jU73/proof.sh`, `proof.runner`, `proof.log`, `proof.exit`, and `completion.txt` retain the sequential command, runner and zero-exit verdict. All fixtures used an owned `TMPDIR` under that extraction.

In the extracted `pi-tool-renderer`, the install included the four Pi packages from its DEVELOPMENT install line and the three Pi transitives, all at the target:

```bash
npm install --no-save --include=dev --include=peer --include=optional --no-package-lock --ignore-scripts --no-audit --no-fund @earendil-works/pi-agent-core@1.0.1 @earendil-works/pi-ai@1.0.1 @earendil-works/pi-coding-agent@1.0.1 @earendil-works/pi-tui@1.0.1 @earendil-works/pi-codemode@1.0.1 @earendil-works/pi-mcp@1.0.1 @earendil-works/pi-telemetry@1.0.1
```

The seven-package controlled graph is `merged.v1jU73/resolved-sdk-graph.json`. The install kept package manifests unchanged. The captured npm tarball's SHA-512 matches metadata, installed loader/runner/agent-session JS and source maps match that tarball, and source-map contents match the exact upstream tag's TypeScript (`merged.v1jU73/npm-source-proof.json`). All 1,068 tracked archive file contents still match the tested commit after the runs (`archive-source-inventory.json`, `archive-final.log`).

| Check | Behavior exercised | Result | Control or limit |
|---|---|---|---|
| Retained `pi-tool-renderer/extensions/__tests__/pi-update-sdk-contract.test.ts` | Real `createAgentSession`, controlled faux provider, current renderer, production batch registration, native drawing fixtures, peer tools and reload. | 16 tests and 117 assertions pass at Pi 1.0.1; 937 ms, `merged.v1jU73/check-renderer.log`, `check-renderer.exit=0`. | Delaying batch registration to session_start makes immediate readiness fail. Omitting native registration makes the drawing assertion fail. Both controls run as expected-failure assertions inside this passing suite. |
| Original `bun test ./extensions/__tests__` package entry point | Unchanged exact-commit renderer suite, with only the new audit check temporarily moved out and restored afterwards. | 151 tests and 500 assertions pass in 25 files at Pi 1.0.1; 6.60 seconds, `merged.v1jU73/suite-renderer.log`, `suite-renderer.exit=0`. | The older work copy passed 145 tests; the merged commit adds the six git-diff-command cases. The actual exact-commit suite was run, not inferred. |
| Version proof before each run | Resolve coding-agent from the extracted extension entry and suite directory. | Both paths report 1.0.1 in `merged.v1jU73/version-proof.log` and `suite-version-proof.log`, with zero exit receipts. | The proof refuses any other version. |
| Source/installation preservation | Every archived tracked file compared to its selected-commit Git blob; installed SDK compared to captured npm and upstream source. | Pass before and after execution; exact full tested commit above. | No original source or manifest was edited. |

Structured observations, source metadata, executed owners, callback counts, native component output and reload active sets are in `merged.v1jU73/evidence/sdk-contract-observations.json`. Supplementary HTML exports are in the same evidence directory. Public SDK getter/component exports are test instrumentation; the product drawing interface under examination is the documented `pi.registerToolRenderer`, not an internal-file query or execution wrapper.

## SDK observations and coverage limits

Pi 1.0.1 documents `registerToolRenderer((toolName, next) => renderers)` during factory loading. Its resolver returns only `renderShell`, `renderCall` and `renderResult`. `next()` resolves later extensions in load order and then the registered tool. Built-in read and grep definitions already carry renderers, so `next() ?? mine` preserves their default drawing as well as peer drawing. An unconditional matching resolver replaces built-in drawing, and competing resolvers follow native load order. The fixtures demonstrate these actual branches; this audit does not implement compact product callbacks.

| Caller or native branch | Observation on the exact tested commit |
|---|---|
| Embedded SDK session without bindExtensions, before first prompt | The current renderer exposes read, bash, edit, write, grep, find, ls and enabled tool_batch immediately with zero provider requests. Its real tool_batch then runs a read child through Pi successfully. |
| Peer read/grep execution in both extension orders | Current duplicate registrations are first-registration-wins and emit conflict diagnostics without unloading the extension. Native drawing-only fixtures register no replacement execution definitions, leaving peer execution intact in both orders. |
| Search discovery versus activation | Native drawing leaves grep/find/ls discoverable immediately, but inactive under Pi's default read/bash/edit/write selection. Current replacement registration activates searches. A production drawing migration must state the changed search default in its consumer changelog. |
| Explicit caller tools allowlist and reload | The native fixture exposes and activates only the allowed names, before and after reload. |
| Dynamically disabled built-in read/grep | Native-only drawing retains their disabled state across reload. The current renderer's replacement registrations reactivate them on reload. |
| Dynamically disabled extension-owned tool_batch | Pi reload reactivates the unchanged default-active batch registration even under native-only drawing. Explicit allowlist exclusion remains respected. No blanket dynamic-disable-across-reload guarantee is claimed. |
| Native drawing and peer custom drawing | Fallback preserves peer drawing in both orders and also preserves built-in drawing. Unconditional competing resolvers use native extension order. Neither observation establishes a product provenance discriminator. |
| HTML export | Pi's HTML exporter skips template-rendered read/bash/edit/write/ls; it cannot by itself prove those callbacks ran. The actual native resolver/component path exercises read drawing in these checks. |

No interactive fullscreen terminal, image-protocol terminal, complete provider transport matrix or every-extension runtime suite was run. The pi-hooks suite was not rerun: the single Breaking Changes entry names no contract member. An unchanged renderer package suite and native fixture are not evidence for a future production renderer migration.

The work-copy investigation initially installed only the four direct Pi dependencies and resolved codemode, mcp and telemetry 1.3.0 through upstream caret ranges. Import failed before behavior on missing `MCP_TYPESCRIPT_PREAMBLE`; an incremental npm no-save repair then removed optional peers, which the version proof refused. Those logs are retained under `tmp/pi-update/run.cLxHN9`. A fresh clean seven-package target installation succeeded in the work copy and, on its first attempt, in the exact merged proof. This audit establishes that controlled target graph; it does not claim that ordinary fresh installs with floating transitive Pi dependencies work. No install failure is classified as a renderer defect.

## Prior-range evidence

The [previous Pi 1.0.0 record](https://github.com/vanillagreencom/kendex/blob/40c25ec1f77ffed5b896727965f84daf12560acd/pi-extensions/pi-update.audit.md) remains the owner of its earlier checks and Required parity fix reports. Its tested extension commit was `f9013a0f0f7a68a4621a3aa0e49b832e40b540c2`; its evidence directory was `tmp/pi-update/run.R6KEmY`. The two entries below are carried as prior-range evidence, not new findings or current retest results.

| Item | Earlier entry and package | What the prior record established | Limit of this 1.0.1 run |
|---|---|---|---|
| KEN-2671 | `ai` 1.0.0 grammar-tool replay IDs; pi-codex-minimal-tools | The earlier real-session check sent an `fc_*` item ID for a foreign grammar call replayed as `custom_tool_call`; the vendor-provider control omitted it. | The grammar-replay audit check was not rerun here. No claim that this earlier fix is now applied, unresolved or retested follows from this run. |
| KEN-2187 | `coding-agent` 0.99.2 built-in prompt guidance; pi-tool-renderer | The earlier session-system-prompt check found missing built-in snippets/guidelines under replacement registration; its no-renderer control retained them. | The earlier dedicated guidance audit check was not rerun here. This run's package-suite pass is scoped to that suite and is not relabeled as the earlier proof or a claim about the item's disposition. |

The earlier record's pi-hooks settle/shutdown field checks, all-package load/value-import checks and real-component smoke retain their original Pi versions and coverage. They are not Pi 1.0.1 runtime evidence.

## Record scope

This record clears Pi 1.0.1 when the audit and marker land together. A peer floor may rise to >=1.0.1 only after that clearing record lands. This audit changes no peer range, execution definition, package version or contributor history. A production native-drawing migration remains separate and needs its own real SDK regressions and exact merged-implementation evidence. Its consumer changelog must state minimum Pi 1.0.1, tell older installs to update, and explain that drawing no longer autoactivates search tools. Refresh outputs follow the repository's existing owner; no refresh, apply or publication was performed by this audit.
